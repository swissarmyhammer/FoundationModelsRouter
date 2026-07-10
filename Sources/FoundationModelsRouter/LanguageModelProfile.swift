import Foundation

/// A lock-guarded, weak holder for a routed model's owning ``LanguageModelProfile``.
///
/// A ``RoutedModel`` is constructed before the profile that owns it (the profile
/// receives the three models in its initializer), so the owning profile is
/// registered after the fact through this box. The held reference is **weak**:
/// the profile already holds its models strongly for residency, and a strong
/// reference back would form a retain cycle that defeats the profile's
/// `deinit`-driven eviction. A session vended by ``RoutedModel/makeSession(instructions:workingDirectory:)``
/// reads the profile here and retains it strongly, so the resident models stay
/// alive for the session's lifetime even after the caller drops its profile
/// handle.
///
/// `@unchecked Sendable` because the weak reference is mutated through the lock,
/// which the compiler cannot verify; the lock makes the access data-race free.
final class OwningProfileBox: @unchecked Sendable {
    /// Serializes the single registration against any later reads.
    private let lock = NSLock()

    /// The owning profile, weakly held, or `nil` before registration / after the
    /// profile is released.
    private weak var stored: LanguageModelProfile?

    /// Creates an empty box, filled later by ``register(_:)``.
    init() {}

    /// Records the owning profile. Called once, from ``LanguageModelProfile``'s
    /// initializer, before the profile escapes to any other thread.
    ///
    /// - Parameter profile: The profile that owns the model holding this box.
    func register(_ profile: LanguageModelProfile) {
        lock.withLock { stored = profile }
    }

    /// The owning profile if it is still alive, else `nil`.
    var current: LanguageModelProfile? {
        lock.withLock { stored }
    }
}

/// A resolved, resident model — the storage a profile exposes for one slot,
/// generic over the kind of loaded container it holds.
///
/// It carries why the model won (its ``SlotResolution``), what it cost
/// (``footprintBytes``), the loaded container, and — populated by the router at
/// resolve time — the router's recording root (``routerId``) and
/// ``TranscriptRecorder`` so a vended session or embed call is born recorded.
///
/// The two concrete handles are the distinct typealiases ``RoutedLLM`` and
/// ``RoutedEmbedder``. They share this storage but diverge in the methods that
/// land in later milestones — `makeSession` on the generation handle (5b) and
/// `embed(...)` plus a `dimension` on the embedding handle (5a) — which arrive
/// as container-constrained extensions, so neither handle carries the other's
/// API. Storage only for now.
///
/// `Container` is constrained to `Sendable` (not ``LoadedModelContainer``) so
/// the concrete handles can specialize it with the container existentials
/// `any LoadedLLMContainer` / `any LoadedEmbeddingContainer`, which satisfy the
/// `Sendable` marker but cannot satisfy a non-marker protocol constraint.
public final class RoutedModel<Container: Sendable>: Sendable {
    /// The slot this model fills.
    public let slot: ModelSlot

    /// The chosen model reference.
    public let chosen: ModelRef

    /// The chosen candidate's `× 1.2` footprint estimate in bytes, as used at the
    /// joint-fit comparison.
    public let footprintBytes: Int64

    /// Why this model won its slot, and what was skipped or rejected.
    public let resolution: SlotResolution

    /// The loaded, resident container.
    public let container: Container

    /// The recording root id of the router that resolved this model.
    public let routerId: ULID

    /// The recorder a vended session or embed call is born holding.
    public let recorder: any TranscriptRecorder

    /// The router's durable transcripts root, or `nil` when recording to
    /// memory/none. A vended session's ``RoutedSession/recordingDirectory`` nests
    /// under this root by router id and session id.
    public let recordingsRoot: URL?

    /// The session index writer a vended generation session appends its
    /// creation/fork record through, or `nil` when the router has no durable
    /// transcripts root or is recording at ``RecordingLevel/off``.
    ///
    /// Only consumed by the generation-session surface (``makeSession(instructions:workingDirectory:)``
    /// / ``makeGuidedSession(grammar:instructions:workingDirectory:)`` /
    /// ``RoutedSessionActor/fork(workingDirectory:)``); the embedding handle
    /// never vends sessions, so it carries this only for storage symmetry.
    public let sessionIndexWriter: SessionIndexWriter?

    /// The weak back-reference to the profile that owns this model, registered by
    /// ``LanguageModelProfile``'s initializer. A session vended from this handle
    /// reads it to retain the profile (see ``makeSession(instructions:workingDirectory:)``).
    let owningProfileBox = OwningProfileBox()

    /// The per-model serial generation gate (a fair FIFO ``AsyncSemaphore`` at
    /// value `1`).
    ///
    /// Every ``RoutedSession`` vended from this handle — the root session and all
    /// its forks alike — shares this one gate, so their generations serialize
    /// rather than interleave: MLX generation runs a single GPU stream and is not
    /// safe to interleave. Only the generation-session surface acquires it; the
    /// embedding handle never does.
    let serialGate = AsyncSemaphore(value: 1)

    /// The fork-admission gate (a fair FIFO ``AsyncSemaphore`` at value
    /// `maxConcurrentForks`).
    ///
    /// At most `maxConcurrentForks` fork sessions over this model may be in flight
    /// at once; a ``RoutedSession/fork(workingDirectory:)`` past the ceiling awaits
    /// a free slot, which is freed when a fork is released. This caps the K×
    /// prefix-KV cost of copying the parent's cache on each fork. Only the
    /// generation-session fork surface acquires it.
    let forkAdmissionGate: AsyncSemaphore

    /// Creates a routed model handle.
    ///
    /// - Parameters:
    ///   - slot: The slot this model fills.
    ///   - chosen: The chosen model reference.
    ///   - footprintBytes: The chosen candidate's `× 1.2` footprint estimate.
    ///   - resolution: Why this model won its slot.
    ///   - container: The loaded, resident container.
    ///   - routerId: The resolving router's recording root id.
    ///   - recorder: The recorder a vended session or embed call is born holding.
    ///   - recordingsRoot: The router's durable transcripts root, or `nil`.
    ///   - maxConcurrentForks: The in-flight fork ceiling this model's
    ///     ``forkAdmissionGate`` admits (the router's `maxConcurrentForks`).
    ///     Consumed only by the generation-session fork surface; the embedding
    ///     handle never forks.
    ///   - sessionIndexWriter: The session index writer a vended generation
    ///     session appends its creation/fork record through, or `nil`.
    public init(
        slot: ModelSlot,
        chosen: ModelRef,
        footprintBytes: Int64,
        resolution: SlotResolution,
        container: Container,
        routerId: ULID,
        recorder: any TranscriptRecorder,
        recordingsRoot: URL? = nil,
        maxConcurrentForks: Int = 4,
        sessionIndexWriter: SessionIndexWriter? = nil
    ) {
        self.slot = slot
        self.chosen = chosen
        self.footprintBytes = footprintBytes
        self.resolution = resolution
        self.container = container
        self.routerId = routerId
        self.recorder = recorder
        self.recordingsRoot = recordingsRoot
        self.forkAdmissionGate = AsyncSemaphore(value: maxConcurrentForks)
        self.sessionIndexWriter = sessionIndexWriter
    }
}

/// A resolved, resident generation model — the handle a profile exposes for its
/// `.standard` or `.flash` slot.
///
/// This is the handle to pass into a tool's constructor: it references one
/// resident model loaded once at resolve, so many tools built from the same
/// `profile.standard` / `profile.flash` share the identical loaded container
/// rather than each re-resolving. See ``SummarizeTool`` for the pattern.
public typealias RoutedLLM = RoutedModel<any LoadedLLMContainer>

/// A resolved, resident embedding model — the handle a profile exposes for its
/// `.embedding` slot.
///
/// Like ``RoutedLLM``, this is the handle to pass into a tool's constructor:
/// tools built from the same `profile.embedding` share its one resident model
/// rather than each re-resolving. See ``EmbedTool`` for the pattern.
public typealias RoutedEmbedder = RoutedModel<any LoadedEmbeddingContainer>

/// A profile resolved for *this* machine: the three models that co-fit the
/// budget, held resident for the profile's lifetime.
///
/// The slots are the joint-fit trio — ``standard`` and ``flash`` generation
/// models and an ``embedding`` model — each a handle to a loaded container with
/// its resolution reasoning.
///
/// Residency is bounded: the resolving ``Router`` allows only one active profile
/// at a time, so a profile must be released before another can be resolved.
/// ``release()`` evicts all three models through the router's loader and frees
/// the router's residency slot; `deinit` runs the same release best-effort, so a
/// dropped profile cannot strand resident memory. The session surface lands in
/// milestone 5b.
public final class LanguageModelProfile: Sendable {
    /// The name of the ``ProfileDefinition`` this was resolved from.
    public let definitionName: String

    /// The resident `.standard` generation model.
    public let standard: RoutedLLM

    /// The resident `.flash` generation model.
    public let flash: RoutedLLM

    /// The resident `.embedding` model.
    public let embedding: RoutedEmbedder

    /// The router that resolved this profile and owns its residency slot;
    /// ``release()`` routes eviction back through it.
    private let router: Router

    /// The router-minted residency token identifying this profile's residency.
    ///
    /// A unique, never-reused id (unlike an `ObjectIdentifier`, which a freed
    /// profile's address — and therefore identity — could hand to a later
    /// profile). The router matches on it in ``Router/release(token:containers:)``
    /// so a stale `deinit` firing after this profile has been released and a
    /// *different* profile resolved cannot match, and so cannot evict the wrong
    /// models or clear the newer profile's residency.
    let residencyToken: ULID

    /// Creates a resolved profile.
    ///
    /// - Parameters:
    ///   - definitionName: The source ``ProfileDefinition`` name.
    ///   - standard: The resident `.standard` model.
    ///   - flash: The resident `.flash` model.
    ///   - embedding: The resident `.embedding` model.
    ///   - router: The resolving router, which owns the residency slot and the
    ///     loader eviction runs through.
    ///   - residencyToken: The router-minted token identifying this residency.
    public init(
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
        standard.owningProfileBox.register(self)
        flash.owningProfileBox.register(self)
        embedding.owningProfileBox.register(self)
    }

    /// The three resident containers, in slot order, for eviction.
    private var containers: [any LoadedModelContainer] {
        [standard.container, flash.container, embedding.container]
    }

    /// Evicts all three resident models and frees the router's residency slot,
    /// so the next ``Router/resolve(_:reporting:)`` can proceed.
    ///
    /// Idempotent: the router only evicts and clears while this profile is the
    /// resident one, so calling ``release()`` more than once — or after `deinit`
    /// has already run it — is a safe no-op. The eviction runs through the
    /// injected loader, so it carries no MLX dependency of its own.
    public func release() async {
        await router.release(token: residencyToken, containers: containers)
    }

    /// Runs ``release()`` best-effort when the profile is dropped, so a profile
    /// that goes out of scope without an explicit release still frees its
    /// resident models and the router's residency slot.
    ///
    /// The eviction is dispatched onto an unstructured task because it is async;
    /// the task captures only the router, the residency token, and the containers
    /// as values — never `self` — so it cannot resurrect the deallocating
    /// profile. The token (not the profile's address) is what the router matches,
    /// so a `deinit` racing a newer profile's residency is a safe no-op.
    deinit {
        let router = self.router
        let residencyToken = self.residencyToken
        let containers = self.containers
        Task { await router.release(token: residencyToken, containers: containers) }
    }
}
