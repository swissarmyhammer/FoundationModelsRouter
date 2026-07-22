import Foundation
import FoundationModels

/// A single download-progress observation for one model: how many bytes have
/// arrived out of how many total.
///
/// The loader reports these as a repo's weights stream in so the router can
/// surface a live byte count and an overall ``ResolutionProgress/fraction``.
/// When the total is unknown (`0`), ``fraction`` is `0` rather than undefined.
public struct DownloadProgress: Sendable, Equatable {
    /// Bytes downloaded so far.
    public let bytesDownloaded: Int64

    /// Total bytes expected, or `0` when not yet known.
    public let bytesTotal: Int64

    /// Creates a download-progress observation.
    ///
    /// - Parameters:
    ///   - bytesDownloaded: Bytes downloaded so far.
    ///   - bytesTotal: Total bytes expected, or `0` when unknown.
    public init(bytesDownloaded: Int64, bytesTotal: Int64) {
        self.bytesDownloaded = bytesDownloaded
        self.bytesTotal = bytesTotal
    }

    /// The fraction downloaded in `0...1`, or `0` when the total is unknown.
    public var fraction: Double {
        bytesTotal > 0 ? Double(bytesDownloaded) / Double(bytesTotal) : 0
    }
}

/// A loaded, resident model handle the router hands to a routed slot.
///
/// This is a marker so the concrete container types from the MLX stack
/// (`ModelContainer`, `EmbedderModelContainer`) can be returned by the live
/// loader while tests substitute their own stub handles — neither the router's
/// orchestration nor its unit tests depend on the MLX containers directly. The
/// generation/embedding methods that consume the underlying container land in
/// later milestones (5a/5b).
public protocol LoadedModelContainer: Sendable {}

/// A loaded generation (`standard`/`flash`) model container — the seam the text
/// generation a ``RoutedSession`` performs runs through, so the session surface
/// is unit-testable without a GPU.
///
/// Tests substitute a stub that returns canned text (and can be made to throw);
/// the live `ModelContainer` conformance (see ``LiveModelLoader``) runs the real
/// `MLXLMCommon` generation and xgrammar constrained-decode pipelines, exercised
/// end to end by the gated integration suite (milestone 7). A vended session
/// funnels every public generation method through one recorder-bracketed
/// chokepoint that calls into these entry points.
public protocol LoadedLLMContainer: LoadedModelContainer {
    /// Manufactures a new live session backend over this resident model.
    ///
    /// This container no longer runs generation itself: every generation call a
    /// vended ``RoutedSession`` performs runs through the
    /// ``LanguageModelSessionBackend`` this factory returns, which is born
    /// carrying `instructions` and (once a real conversation-preserving
    /// conformer lands) accumulates conversation state across calls. Unit tests
    /// inject a stub container whose backend returns canned text (and can be
    /// made to throw); the live `ModelContainer` (see ``LiveModelLoader``)
    /// returns a backend wrapping a real `LanguageModelSession` — exercised by
    /// the gated integration suite (milestone 7).
    ///
    /// - Parameter instructions: The session's system instructions, or `nil`.
    /// - Returns: A new backend a vended ``RoutedSession`` drives for its
    ///   lifetime.
    func makeSession(instructions: String?) -> any LanguageModelSessionBackend

    /// Manufactures a new live session backend over this resident model, with
    /// `tools` threaded to the underlying `LanguageModelSession` so the model
    /// can call them.
    ///
    /// Defaulted (see the extension below) to ignore `tools` and forward to
    /// ``makeSession(instructions:)`` — so the many stub containers across the
    /// unit suite that never pass tools need no changes at all. Only a
    /// container that actually constructs a real `LanguageModelSession` (the
    /// live `MLXFoundationModelsContainer`, see
    /// `Resolution/LiveModelLoader.swift`) or a test that specifically
    /// exercises tool wiring needs to override this.
    ///
    /// - Parameters:
    ///   - instructions: The session's system instructions, or `nil`.
    ///   - tools: The tools the model can call during this session.
    /// - Returns: A new backend a vended ``RoutedSession`` drives for its
    ///   lifetime.
    func makeSession(instructions: String?, tools: [any Tool]) -> any LanguageModelSessionBackend

    /// Manufactures a new live session backend seeded from an existing
    /// transcript, instead of from scratch.
    ///
    /// This is the factory a restored session tree needs: rebuilding a session
    /// from a transcript persisted to disk, rather than starting a fresh one
    /// from `instructions` (``makeSession(instructions:)``). The live
    /// `ModelContainer` conformance (see ``LiveModelLoader``) seeds a real
    /// `LanguageModelSession` directly from `transcript` via its
    /// `LanguageModelSession(model:tools:transcript:)` initializer — the same
    /// one ``LanguageModelSessionBackend/makeFork()`` uses to seed a forked
    /// session from a parent's accumulated transcript, except here there is no
    /// live parent session to fork: `transcript` may have been reconstructed
    /// from persisted recordings. Unit tests inject a stub container whose
    /// backend reports `transcript`'s entries directly.
    ///
    /// - Parameter transcript: The transcript to seed the new session from.
    /// - Returns: A new backend whose accumulated history begins with
    ///   `transcript`'s entries, a vended ``RoutedSession`` drives for its
    ///   lifetime.
    func makeSession(transcript: FoundationModels.Transcript) -> any LanguageModelSessionBackend

    /// The raw `FoundationModels.LanguageModel` this container wraps — the
    /// seam ``RoutedModel/makeLanguageModel()`` wraps in a
    /// ``RecordingLanguageModel`` passthrough handle so any caller can build
    /// a `LanguageModelSession(model:tools:instructions:)` directly over a
    /// recorded, serial-gated, tool-capable handle.
    ///
    /// Defaulted (see the extension below) to a precondition failure: only a
    /// container that actually supports the recording-handle surface — the
    /// live `MLXFoundationModelsContainer` and a purpose-built stub in
    /// `RecordingLanguageModelTests` — needs to override it, so the many stub
    /// containers elsewhere in the unit suite that only ever exercise
    /// ``RoutedSession`` (never ``RoutedModel/makeLanguageModel()``) need no
    /// changes and never call this accessor.
    var languageModel: any FoundationModels.LanguageModel { get }
}

extension LoadedLLMContainer {
    /// Traps: see ``LoadedLLMContainer/languageModel``'s doc comment for
    /// which containers need to override this default.
    public var languageModel: any FoundationModels.LanguageModel {
        preconditionFailure(
            "this LoadedLLMContainer does not expose a languageModel; RoutedModel.makeLanguageModel() is unavailable for it"
        )
    }

    /// Ignores `tools` and forwards to ``makeSession(instructions:)``: see
    /// ``makeSession(instructions:tools:)``'s doc comment for which
    /// containers need to override this default.
    public func makeSession(instructions: String?, tools: [any Tool]) -> any LanguageModelSessionBackend {
        makeSession(instructions: instructions)
    }
}

/// A loaded embedding model container — the seam the embedding computation runs
/// through, so ``RoutedEmbedder`` is unit-testable without a GPU.
///
/// Tests substitute a stub that returns fixed-length vectors; the live path
/// (``LiveEmbeddingContainer``, wrapping an `MLXEmbedders` `EmbedderModelContainer`)
/// runs the real embedding pipeline and reports a ``dimension`` probed once at
/// load, exercised end to end by the gated integration suite (milestone 7).
public protocol LoadedEmbeddingContainer: LoadedModelContainer {
    /// The length of every embedding vector this model produces.
    var dimension: Int { get }

    /// Embeds each input string into a ``dimension``-length vector.
    ///
    /// - Parameter texts: The strings to embed.
    /// - Returns: One ``dimension``-length vector per input, in order.
    /// - Throws: If the embedding computation fails.
    func embed(texts: [String]) async throws -> [[Float]]
}

/// The download-and-load step behind ``Router/resolve(_:reporting:)``,
/// abstracted so the orchestration is unit-testable without network or GPU.
///
/// The live implementation is ``LiveModelLoader``, which downloads weights from
/// the Hugging Face Hub and materializes MLX containers; tests inject a stub
/// that returns fake handles. `loadLLM` and `loadEmbedder` perform the download
/// (reporting byte progress) and produce a resident container; ``preload(_:)``
/// is the warm-up hook run once a container exists.
public protocol ModelLoader: Sendable {
    /// Downloads and loads a generation model, reporting download progress.
    ///
    /// - Parameters:
    ///   - ref: The chosen model reference.
    ///   - slot: The slot the model is being loaded for (`.standard`/`.flash`).
    ///   - context: The working context size in tokens.
    ///   - reporting: A best-effort callback invoked with download progress.
    /// - Returns: A resident generation container.
    /// - Throws: If the download or load fails.
    func loadLLM(
        ref: ModelRef,
        slot: ModelSlot,
        context: Int,
        reporting: @escaping @Sendable (DownloadProgress) -> Void
    ) async throws -> any LoadedLLMContainer

    /// Downloads and loads an embedding model, reporting download progress.
    ///
    /// - Parameters:
    ///   - ref: The chosen model reference.
    ///   - slot: The slot the model is being loaded for (`.embedding`).
    ///   - reporting: A best-effort callback invoked with download progress.
    /// - Returns: A resident embedding container.
    /// - Throws: If the download or load fails.
    func loadEmbedder(
        ref: ModelRef,
        slot: ModelSlot,
        reporting: @escaping @Sendable (DownloadProgress) -> Void
    ) async throws -> any LoadedEmbeddingContainer

    /// Warms a freshly loaded container so the first generation/embedding does
    /// not pay the materialization cost.
    ///
    /// - Parameter container: The container to warm.
    /// - Throws: If warm-up fails.
    func preload(container: any LoadedModelContainer) async throws

    /// Evicts a resident container, releasing the memory it holds.
    ///
    /// Called from ``LanguageModelProfile/release()`` (and its `deinit`) so the
    /// router's one-active-profile rule can free RAM before another profile is
    /// resolved. Routing eviction through the loader keeps it stubbable: unit
    /// tests inject a loader whose ``evict(_:)`` counts calls, with no real MLX
    /// unload required. Best-effort and non-throwing.
    ///
    /// - Parameter container: The container to evict.
    func evict(container: any LoadedModelContainer) async
}

extension ModelLoader {
    /// A no-op eviction: a loader that holds nothing reclaimable (or defers real
    /// unload to a later milestone) inherits this default, so only loaders that
    /// truly manage residency — and the test stubs that spy on eviction —
    /// override it.
    ///
    /// - Parameter container: The container to evict.
    public func evict(container: any LoadedModelContainer) async {}
}
