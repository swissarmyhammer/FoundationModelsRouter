import Foundation

/// A resolved, resident model — the storage a profile exposes for one slot,
/// generic over the kind of loaded container it holds.
///
/// It carries why the model won (its ``SlotResolution``), what it cost
/// (``footprintBytes``), the loaded container, and — populated by the router at
/// resolve time — the router's recording root (``routerID``) and
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
    public let routerID: ULID

    /// The recorder a vended session or embed call is born holding.
    public let recorder: any TranscriptRecorder

    /// Creates a routed model handle.
    ///
    /// - Parameters:
    ///   - slot: The slot this model fills.
    ///   - chosen: The chosen model reference.
    ///   - footprintBytes: The chosen candidate's `× 1.2` footprint estimate.
    ///   - resolution: Why this model won its slot.
    ///   - container: The loaded, resident container.
    ///   - routerID: The resolving router's recording root id.
    ///   - recorder: The recorder a vended session or embed call is born holding.
    public init(
        slot: ModelSlot,
        chosen: ModelRef,
        footprintBytes: Int64,
        resolution: SlotResolution,
        container: Container,
        routerID: ULID,
        recorder: any TranscriptRecorder
    ) {
        self.slot = slot
        self.chosen = chosen
        self.footprintBytes = footprintBytes
        self.resolution = resolution
        self.container = container
        self.routerID = routerID
        self.recorder = recorder
    }
}

/// A resolved, resident generation model — the handle a profile exposes for its
/// `.standard` or `.flash` slot.
///
/// The session-creation surface (`makeSession`) lands in milestone 5b; this is
/// storage only for now.
public typealias RoutedLLM = RoutedModel<any LoadedLLMContainer>

/// A resolved, resident embedding model — the handle a profile exposes for its
/// `.embedding` slot.
///
/// The `embed` surface and `dimension` land in milestone 5a; this is storage
/// only for now.
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
