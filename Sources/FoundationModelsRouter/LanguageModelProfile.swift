import Foundation

/// A resolved, resident generation model — the handle a profile exposes for its
/// `.standard` or `.flash` slot.
///
/// It carries why the model won (its ``SlotResolution``), what it cost
/// (``footprintBytes``), the loaded container, and — populated by the router at
/// resolve time — the router's recording root (``routerID``) and
/// ``TranscriptRecorder`` so a vended session is born recorded. The
/// session-creation surface (`makeSession`) lands in milestone 5a; this type is
/// storage only for now.
public final class RoutedLLM: Sendable {
    /// The slot this model fills (`.standard` or `.flash`).
    public let slot: ModelSlot

    /// The chosen model reference.
    public let chosen: ModelRef

    /// The chosen candidate's `× 1.2` footprint estimate in bytes, as used at the
    /// joint-fit comparison.
    public let footprintBytes: Int64

    /// Why this model won its slot, and what was skipped or rejected.
    public let resolution: SlotResolution

    /// The loaded, resident generation container.
    public let container: any LoadedLLMContainer

    /// The recording root id of the router that resolved this model.
    public let routerID: ULID

    /// The recorder a vended session is born holding.
    public let recorder: any TranscriptRecorder

    /// Creates a routed generation handle.
    ///
    /// - Parameters:
    ///   - slot: The slot this model fills.
    ///   - chosen: The chosen model reference.
    ///   - footprintBytes: The chosen candidate's `× 1.2` footprint estimate.
    ///   - resolution: Why this model won its slot.
    ///   - container: The loaded, resident generation container.
    ///   - routerID: The resolving router's recording root id.
    ///   - recorder: The recorder a vended session is born holding.
    public init(
        slot: ModelSlot,
        chosen: ModelRef,
        footprintBytes: Int64,
        resolution: SlotResolution,
        container: any LoadedLLMContainer,
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

/// A resolved, resident embedding model — the handle a profile exposes for its
/// `.embedding` slot.
///
/// Like ``RoutedLLM`` it carries its ``SlotResolution``, footprint, loaded
/// container, and the router's ``routerID`` + ``TranscriptRecorder``. The
/// `embed` surface lands in milestone 5b; this type is storage only for now.
public final class RoutedEmbedder: Sendable {
    /// The slot this model fills (always `.embedding`).
    public let slot: ModelSlot

    /// The chosen model reference.
    public let chosen: ModelRef

    /// The chosen candidate's `× 1.2` footprint estimate in bytes.
    public let footprintBytes: Int64

    /// Why this model won its slot, and what was skipped or rejected.
    public let resolution: SlotResolution

    /// The loaded, resident embedding container.
    public let container: any LoadedEmbeddingContainer

    /// The recording root id of the router that resolved this model.
    public let routerID: ULID

    /// The recorder a vended embed call is born holding.
    public let recorder: any TranscriptRecorder

    /// Creates a routed embedding handle.
    ///
    /// - Parameters:
    ///   - slot: The slot this model fills (`.embedding`).
    ///   - chosen: The chosen model reference.
    ///   - footprintBytes: The chosen candidate's `× 1.2` footprint estimate.
    ///   - resolution: Why this model won its slot.
    ///   - container: The loaded, resident embedding container.
    ///   - routerID: The resolving router's recording root id.
    ///   - recorder: The recorder a vended embed call is born holding.
    public init(
        slot: ModelSlot,
        chosen: ModelRef,
        footprintBytes: Int64,
        resolution: SlotResolution,
        container: any LoadedEmbeddingContainer,
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

/// A profile resolved for *this* machine: the three models that co-fit the
/// budget, held resident for the profile's lifetime.
///
/// The slots are the joint-fit trio — ``standard`` and ``flash`` generation
/// models and an ``embedding`` model — each a handle to a loaded container with
/// its resolution reasoning. Lifecycle (`release()`) and the session surface
/// land in milestones 5a/5b; this type is storage only for now.
public final class LanguageModelProfile: Sendable {
    /// The name of the ``ProfileDefinition`` this was resolved from.
    public let definitionName: String

    /// The resident `.standard` generation model.
    public let standard: RoutedLLM

    /// The resident `.flash` generation model.
    public let flash: RoutedLLM

    /// The resident `.embedding` model.
    public let embedding: RoutedEmbedder

    /// Creates a resolved profile.
    ///
    /// - Parameters:
    ///   - definitionName: The source ``ProfileDefinition`` name.
    ///   - standard: The resident `.standard` model.
    ///   - flash: The resident `.flash` model.
    ///   - embedding: The resident `.embedding` model.
    public init(
        definitionName: String,
        standard: RoutedLLM,
        flash: RoutedLLM,
        embedding: RoutedEmbedder
    ) {
        self.definitionName = definitionName
        self.standard = standard
        self.flash = flash
        self.embedding = embedding
    }
}
