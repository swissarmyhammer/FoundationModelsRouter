import Foundation

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
    /// Generates a complete text response to a prompt.
    ///
    /// - Parameters:
    ///   - prompt: The prompt to respond to.
    ///   - instructions: The session's system instructions, or `nil`.
    ///   - maxTokens: The maximum number of tokens to generate, or `nil` to use
    ///     the container's own default ceiling.
    /// - Returns: The model's complete text response.
    /// - Throws: If the generation fails.
    func respond(to prompt: String, instructions: String?, maxTokens: Int?) async throws -> String

    /// Streams a text response to a prompt as it is produced.
    ///
    /// - Parameters:
    ///   - prompt: The prompt to respond to.
    ///   - instructions: The session's system instructions, or `nil`.
    ///   - maxTokens: The maximum number of tokens to generate, or `nil` to use
    ///     the container's own default ceiling.
    /// - Returns: A stream of response fragments, finishing when generation
    ///   completes or throwing if it fails.
    func streamResponse(
        to prompt: String,
        instructions: String?,
        maxTokens: Int?
    ) -> AsyncThrowingStream<String, Error>

    /// Generates a complete, grammar-constrained text response — the guided
    /// (xgrammar) entry point a guided ``RoutedSession`` runs through.
    ///
    /// Guided output is whole-chunk: there is no constrained streaming variant.
    /// The xgrammar engine — grammar compilation and constrained decode — lives
    /// behind this seam, so unit tests inject a stub that performs the real
    /// (GPU-free) grammar validation and returns canned text. A default
    /// implementation (see ``LoadedLLMContainer/respond(to:instructions:following:)``)
    /// validates the grammar then surfaces ``GenerationError/notWiredForLiveInference``,
    /// while the live `ModelContainer` (see ``LiveModelLoader``) overrides it with
    /// the real constrained decode — exercised by the gated integration suite
    /// (milestone 7) — so no conformer without a real pipeline has to reimplement
    /// the seam.
    ///
    /// - Parameters:
    ///   - prompt: The prompt to respond to.
    ///   - instructions: The session's system instructions, or `nil`.
    ///   - grammar: The grammar constraining the output.
    ///   - maxTokens: The maximum number of tokens to generate, or `nil` to use
    ///     the container's own default ceiling.
    /// - Returns: The constrained text response.
    /// - Throws: ``GuidedRequestError`` for an invalid grammar, or if the
    ///   generation fails.
    func respond(
        to prompt: String,
        instructions: String?,
        following grammar: Grammar,
        maxTokens: Int?
    ) async throws -> String

    /// Creates a fresh, empty KV cache for a new session over this model.
    ///
    /// A vended ``RoutedSession`` owns the returned cache for its lifetime and
    /// frees it on release; a ``RoutedSession/fork(workingDirectory:)`` instead
    /// copies the parent's via ``SessionKVCache/copy()``. A default
    /// implementation (see ``LoadedLLMContainer/makeCache()``) returns an inert
    /// cache, while the live `ModelContainer` (see ``LiveModelLoader``) overrides
    /// it with a real MLX-backed cache — exercised by the gated integration suite
    /// (milestone 7); unit tests inject a stub that records `copy()` and
    /// free-on-release.
    ///
    /// - Returns: A new, empty KV cache for the session.
    func makeCache() -> any SessionKVCache
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
    func embed(_ texts: [String]) async throws -> [[Float]]
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
        _ ref: ModelRef,
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
        _ ref: ModelRef,
        slot: ModelSlot,
        reporting: @escaping @Sendable (DownloadProgress) -> Void
    ) async throws -> any LoadedEmbeddingContainer

    /// Warms a freshly loaded container so the first generation/embedding does
    /// not pay the materialization cost.
    ///
    /// - Parameter container: The container to warm.
    /// - Throws: If warm-up fails.
    func preload(_ container: any LoadedModelContainer) async throws

    /// Evicts a resident container, releasing the memory it holds.
    ///
    /// Called from ``LanguageModelProfile/release()`` (and its `deinit`) so the
    /// router's one-active-profile rule can free RAM before another profile is
    /// resolved. Routing eviction through the loader keeps it stubbable: unit
    /// tests inject a loader whose ``evict(_:)`` counts calls, with no real MLX
    /// unload required. Best-effort and non-throwing.
    ///
    /// - Parameter container: The container to evict.
    func evict(_ container: any LoadedModelContainer) async
}

extension ModelLoader {
    /// A no-op eviction: a loader that holds nothing reclaimable (or defers real
    /// unload to a later milestone) inherits this default, so only loaders that
    /// truly manage residency — and the test stubs that spy on eviction —
    /// override it.
    public func evict(_ container: any LoadedModelContainer) async {}
}
