import Foundation
import Synchronization
import Tracing

/// A weak reference to a ``LanguageModelProfile`` in a `Sendable` shape, so a
/// `Mutex` can hold it.
private struct WeakProfile: Sendable {
    /// The owning profile, weakly held, or `nil` once it is released.
    weak var profile: LanguageModelProfile?
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

    /// The resolved working context, in tokens.
    ///
    /// This is the value the resolution ladder selected, not the value the
    /// ``ProfileDefinition`` asked for. When the ladder steps down from a
    /// candidate's native context to fit the budget, this value is smaller
    /// than `ProfileDefinition.context` (see `JointFit`). Every slot of one
    /// profile shares the same value.
    ///
    /// A session vended from this handle divides its context fill by this
    /// value, and the sidecar records it as `context`. A caller that needs a
    /// ``TokenBudget`` before it calls `makeSession` builds one with
    /// `TokenBudget(limit: contextTokens)`.
    public var contextTokens: Int { resolution.contextTokens }

    /// Why this model won its slot, and what was skipped or rejected.
    package let resolution: SlotResolution

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

    /// The weak back-reference to the profile that owns this model, guarded
    /// for the readers that race the one registration.
    ///
    /// The slot is filled after this handle's initializer, and not by it,
    /// because ``Router/resolve(profile:reporting:)`` builds the three handles
    /// first and passes them into the profile's initializer afterwards. The
    /// profile does not exist while a handle is initialized.
    ///
    /// The reference is weak because the profile holds its three handles
    /// strongly. A strong back-reference would make a cycle, so neither the
    /// profile nor its handles — and therefore no handle's ``ResidencyHold``
    /// reference — would ever be released. A vended session reads the profile
    /// out of this slot and retains it for the session's lifetime, which is
    /// what keeps a session's sibling slots reachable while it runs.
    private let owningProfileSlot = Mutex(WeakProfile())

    /// The owning profile if it is still alive, else `nil`.
    var owningProfile: LanguageModelProfile? {
        owningProfileSlot.withLock { $0.profile }
    }

    /// Records the owning profile. Called once, from
    /// ``LanguageModelProfile``'s initializer.
    ///
    /// - Parameter profile: The profile that owns this handle.
    func registerOwningProfile(_ profile: LanguageModelProfile) {
        owningProfileSlot.withLock { $0.profile = profile }
    }

    /// The per-model generation gate, a fair FIFO ``AsyncSemaphore`` at value
    /// `1`. Every session vended from this handle shares it, so generations
    /// serialize. A turn can hand it back while it waits on a person.
    let generationGate: AsyncSemaphore

    /// The fork-admission gate, a fair FIFO ``AsyncSemaphore`` at value
    /// `maxConcurrentForks`. A fork past the ceiling awaits a free slot.
    let forkAdmissionGate: AsyncSemaphore

    /// The shared claim on the residency this handle's container belongs to,
    /// or `nil` for a hand-built handle that resolved nothing.
    ///
    /// Held strongly, and shared with the two sibling handles the same resolve
    /// vended. It is what keeps the container resident, so a tool that stores
    /// only this handle keeps its model loaded after the profile object is
    /// gone. The hold refers to nothing but the router and a token, so no cycle
    /// is possible.
    ///
    /// Nothing reads the value, and nothing should: the strong reference this
    /// property makes IS the residency claim, and ARC's release of it when this
    /// handle deinitializes is the read no index can see.
    // periphery:ignore
    private let residencyHold: ResidencyHold?

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
    ///   - residencyHold: The shared claim that keeps `container` resident, or
    ///     `nil` (the default) for a hand-built handle that resolved nothing
    ///     and therefore holds no residency.
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
        tracer: (any Tracer)? = nil,
        residencyHold: ResidencyHold? = nil
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
        self.residencyHold = residencyHold
    }
}

/// A resolved, resident generation model: the handle a profile exposes for its
/// `.standard` or `.flash` slot. Pass it into a tool's constructor.
public typealias RoutedLLM = RoutedModel<any LoadedLLMContainer>

/// A resolved, resident embedding model: the handle a profile exposes for its
/// `.embedding` slot. Pass it into a tool's constructor.
public typealias RoutedEmbedder = RoutedModel<any LoadedEmbeddingContainer>

/// A profile resolved for this machine: the three models that co-fit the
/// budget, held resident while this profile OR any handle it vended is alive.
///
/// Residency is pooled. The ``Router`` reference-counts each resident model
/// across profiles. The three handles this profile vended share one
/// ``ResidencyHold``, and dropping the last of them decrements this profile's
/// references and evicts only the models that drop to zero. ``release()`` does
/// the same eagerly, and is idempotent against the hold.
///
/// This object needs no hold of its own, and no `deinit`: it holds its three
/// handles strongly, so while this profile lives at least one hold does too,
/// and the residency ends only once this object AND every handle it vended is
/// gone.
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
        // and reach its sibling slots for the session's lifetime.
        standard.registerOwningProfile(self)
        flash.registerOwningProfile(self)
        embedding.registerOwningProfile(self)
    }

    /// Decrements this profile's reference on each resident model and evicts
    /// the models that drop to zero references. Idempotent.
    public func release() async {
        await router.release(token: residencyToken)
    }
}
