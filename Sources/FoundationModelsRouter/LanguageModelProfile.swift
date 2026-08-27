import Foundation
import Tracing

/// A lock-guarded, weak holder for a routed model's owning ``LanguageModelProfile``.
///
/// The reference is weak to avoid a retain cycle with the profile. A vended
/// session reads the profile here and retains it for the session's lifetime.
final class OwningProfileBox: @unchecked Sendable {
    /// Serializes the registration against later reads.
    private let lock = NSLock()

    /// The owning profile, weakly held, or `nil`.
    private weak var stored: LanguageModelProfile?

    /// Creates an empty box, filled later by ``register(profile:)``.
    init() {}

    /// Records the owning profile. Called once from the profile's initializer.
    ///
    /// - Parameter profile: The profile that owns the model holding this box.
    func register(profile: LanguageModelProfile) {
        lock.withLock { stored = profile }
    }

    /// The owning profile if it is still alive, else `nil`.
    var current: LanguageModelProfile? {
        lock.withLock { stored }
    }
}

/// A resolved, resident model: the storage a profile exposes for one slot,
/// generic over the kind of loaded container it holds.
///
/// The two concrete handles are ``RoutedLLM`` and ``RoutedEmbedder``. Each
/// gains its own methods through container-constrained extensions.
public final class RoutedModel<Container: Sendable>: Sendable {
    /// The slot this model fills.
    let slot: ModelSlot

    /// The chosen model reference.
    public let chosen: ModelRef

    /// The chosen candidate's `× 1.2` footprint estimate in bytes.
    public let footprintBytes: Int64

    /// Why this model won its slot, and what was skipped or rejected.
    public let resolution: SlotResolution

    /// The loaded, resident container.
    let container: Container

    /// The recording root id of the router that resolved this model.
    let routerId: ULID

    /// The recorder a vended session or embed call is born holding.
    let recorder: any TranscriptRecorder

    /// The tracer an embed call opens its span through, or `nil` to read
    /// `InstrumentationSystem.tracer` at call time.
    ///
    /// `nil` is the resolve-late shape, and it is the default: an application
    /// that bootstraps a tracing backend *after* it constructs its ``Router``
    /// still traces, because nothing is captured until the call itself.
    let tracer: (any Tracer)?

    /// Where this handle's sessions record durably, with the sidecar writer, or
    /// `nil` when recording to memory or none.
    let durableRecording: DurableRecording?

    /// The router's durable transcripts root, or `nil` when recording to
    /// memory or none.
    var recordingsRoot: URL? { durableRecording?.root }

    /// The sidecar writer a vended session writes its `session.json` through,
    /// or `nil` when there is no durable transcripts root.
    var sessionSidecarWriter: SessionSidecarWriter? { durableRecording?.sidecarWriter }

    /// The weak back-reference to the profile that owns this model.
    let owningProfileBox = OwningProfileBox()

    /// The per-model generation gate, a fair FIFO ``AsyncSemaphore`` at value
    /// `1`. Every session vended from this handle shares it, so generations
    /// serialize. A turn can hand it back while it waits on a person.
    let generationGate: AsyncSemaphore

    /// The fork-admission gate, a fair FIFO ``AsyncSemaphore`` at value
    /// `maxConcurrentForks`. A fork past the ceiling awaits a free slot.
    let forkAdmissionGate: AsyncSemaphore

    /// Creates a routed model handle. ``Router/resolve(profile:reporting:)`` is
    /// the one way a consumer obtains a handle.
    ///
    /// - Parameters:
    ///   - slot: The slot this model fills.
    ///   - chosen: The chosen model reference.
    ///   - footprintBytes: The chosen candidate's `× 1.2` footprint estimate.
    ///   - resolution: Why this model won its slot.
    ///   - container: The loaded, resident container.
    ///   - routerId: The resolving router's recording root id.
    ///   - recorder: The recorder a vended session or embed call is born holding.
    ///   - durableRecording: The durable recording root and sidecar writer, or `nil`.
    ///   - gates: The gates `container` carries.
    ///   - tracer: The tracer an embed call opens its span through, or `nil`
    ///     (the default) to read `InstrumentationSystem.tracer` at call time.
    package init(
        slot: ModelSlot,
        chosen: ModelRef,
        footprintBytes: Int64,
        resolution: SlotResolution,
        container: Container,
        routerId: ULID,
        recorder: any TranscriptRecorder,
        durableRecording: DurableRecording? = nil,
        gates: ResidentModelGates,
        tracer: (any Tracer)? = nil
    ) {
        self.slot = slot
        self.chosen = chosen
        self.footprintBytes = footprintBytes
        self.resolution = resolution
        self.container = container
        self.routerId = routerId
        self.recorder = recorder
        self.tracer = tracer
        self.durableRecording = durableRecording
        generationGate = gates.generation
        forkAdmissionGate = gates.forkAdmission
    }
}

/// A resolved, resident generation model: the handle a profile exposes for its
/// `.standard` or `.flash` slot. Pass it into a tool's constructor.
public typealias RoutedLLM = RoutedModel<any LoadedLLMContainer>

/// A resolved, resident embedding model: the handle a profile exposes for its
/// `.embedding` slot. Pass it into a tool's constructor.
public typealias RoutedEmbedder = RoutedModel<any LoadedEmbeddingContainer>

/// A profile resolved for this machine: the three models that co-fit the
/// budget, held resident for the profile's lifetime.
///
/// Residency is pooled. The ``Router`` reference-counts each resident model
/// across profiles. ``release()`` and `deinit` decrement this profile's
/// references and evict only the models that drop to zero.
public final class LanguageModelProfile: Sendable {
    /// The name of the ``ProfileDefinition`` this was resolved from.
    public let definitionName: String

    /// The resident `.standard` generation model.
    public let standard: RoutedLLM

    /// The resident `.flash` generation model.
    public let flash: RoutedLLM

    /// The resident `.embedding` model.
    public let embedding: RoutedEmbedder

    /// The router that resolved this profile and owns its residency slot.
    private let router: Router

    /// The router-minted, never-reused token that identifies this residency.
    let residencyToken: ULID

    /// Creates a resolved profile. ``Router/resolve(profile:reporting:)`` is the
    /// one way a consumer obtains a profile.
    ///
    /// - Parameters:
    ///   - definitionName: The source ``ProfileDefinition`` name.
    ///   - standard: The resident `.standard` model.
    ///   - flash: The resident `.flash` model.
    ///   - embedding: The resident `.embedding` model.
    ///   - router: The resolving router.
    ///   - residencyToken: The router-minted token that identifies this residency.
    package init(
        definitionName: String,
        standard: RoutedLLM,
        flash: RoutedLLM,
        embedding: RoutedEmbedder,
        router: Router,
        residencyToken: ULID
    ) {
        self.definitionName = definitionName
        self.standard = standard
        self.flash = flash
        self.embedding = embedding
        self.router = router
        self.residencyToken = residencyToken

        // Register the weak back-reference now that `self` is fully initialized,
        // so a session vended from any of these handles can retain this profile
        // and keep the resident models alive for its lifetime.
        standard.owningProfileBox.register(profile: self)
        flash.owningProfileBox.register(profile: self)
        embedding.owningProfileBox.register(profile: self)
    }

    /// Decrements this profile's reference on each resident model and evicts
    /// the models that drop to zero references. Idempotent.
    public func release() async {
        await router.release(token: residencyToken)
    }

    /// Runs ``release()`` best-effort when the profile is dropped. The task
    /// captures only the router and the token, never `self`.
    deinit {
        let router = self.router
        let residencyToken = self.residencyToken
        Task { await router.release(token: residencyToken) }
    }
}
