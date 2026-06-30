import Foundation
import MLXEmbedders
import MLXLLM
import MLXLMCommon

// The MLX container types are the live loaded handles. They are `final class …:
// Sendable`, so conforming them to the router's marker protocols lets
// ``LiveModelLoader`` vend them where the orchestration expects an
// `any LoadedLLMContainer` / `any LoadedEmbeddingContainer`.
//
// The `ModelContainer` exposes its model only through an async `perform` closure
// over non-`Sendable` MLX state, so the real text-generation pipeline is GPU
// work that lands in the gated integration suite (milestone 7). These
// conformances are the deferred seam: the unit suite drives a stub container,
// while the live path makes its unwired state explicit (throwing
// ``GenerationError/notWiredForLiveInference``) rather than returning fabricated
// text — mirroring the embedder seam below.
extension ModelContainer: LoadedLLMContainer {
    /// Generates a complete text response — wired through the real `MLXLMCommon`
    /// pipeline in the gated integration suite (milestone 7). Until then it
    /// throws, so no caller mistakes an unwired live container for a working one.
    public nonisolated func respond(to prompt: String, instructions: String?) async throws -> String {
        throw GenerationError.notWiredForLiveInference
    }

    /// Streams a text response — wired through the real `MLXLMCommon` pipeline in
    /// the gated integration suite (milestone 7). Until then the stream finishes
    /// by throwing, so no caller mistakes an unwired live container for a working
    /// one.
    public nonisolated func streamResponse(
        to prompt: String,
        instructions: String?
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { $0.finish(throwing: GenerationError.notWiredForLiveInference) }
    }
}

// The MLX `EmbedderModelContainer` exposes its model only through an async
// `perform` closure over non-`Sendable` MLX tensors, so the real embedding
// pipeline (and the dimension it produces) is GPU work that lands in the gated
// integration suite (milestone 7). This conformance is the deferred seam: the
// unit suite drives a stub embedder, while the live path makes its unwired
// state explicit rather than returning fabricated vectors.
extension EmbedderModelContainer: LoadedEmbeddingContainer {
    /// The embedding dimension, derived from the loaded model when the live
    /// pipeline is wired (milestone 7). Until then it reports `0` (unknown),
    /// matching the ``DownloadProgress`` "unknown total" sentinel.
    public var dimension: Int { 0 }

    /// Embeds through the real `MLXEmbedders` pipeline — wired in the gated
    /// integration suite (milestone 7). Until then it throws, so no caller
    /// mistakes an unwired live container for a working one.
    public func embed(_ texts: [String]) async throws -> [[Float]] {
        throw EmbeddingError.notWiredForLiveInference
    }
}

/// A failure constructing or invoking a ``ModelLoader``.
public enum ModelLoaderError: Error, Equatable {
    /// No real loader was configured: the ``Router`` was built without a
    /// ``LiveModelLoader`` (which requires a `Downloader` and `TokenizerLoader`)
    /// and without an injected stub. See ``UnconfiguredModelLoader``.
    case notConfigured
}

/// The live ``ModelLoader``: downloads weights from a Hugging Face-compatible
/// source and materializes MLX containers for generation and embedding.
///
/// This fork of `mlx-swift-lm` intentionally does **not** bundle a default Hub
/// client — integration packages "inject their own `Downloader` and
/// `TokenizerLoader`" (the `MLXHuggingFace` `#hubDownloader()` /
/// `#huggingFaceTokenizerLoader()` macros pull in `swift-huggingface` /
/// `swift-transformers`, which are not in this package's dependency graph). So
/// ``LiveModelLoader`` is the real wiring over the **core** loader API and takes
/// the `Downloader` and `TokenizerLoader` as construction parameters; the
/// integration suite (milestone 7) supplies concrete Hub-backed instances.
///
/// Generation models load through `MLXLMCommon`'s `loadModelContainer`, which
/// resolves the configuration against the registered `MLXLLM` factories;
/// embedding models load through `MLXEmbedders`' `EmbedderModelFactory`. Both
/// map the Foundation `Progress` into ``DownloadProgress``.
public struct LiveModelLoader: ModelLoader {
    /// The source that fetches model and tokenizer files.
    private let downloader: any Downloader

    /// The factory that loads a tokenizer from downloaded files.
    private let tokenizerLoader: any TokenizerLoader

    /// Creates a live loader over an injected downloader and tokenizer loader.
    ///
    /// - Parameters:
    ///   - downloader: The source that fetches model and tokenizer files (e.g. a
    ///     Hub client supplied by the integration suite).
    ///   - tokenizerLoader: The factory that loads a tokenizer from those files.
    public init(downloader: any Downloader, tokenizerLoader: any TokenizerLoader) {
        self.downloader = downloader
        self.tokenizerLoader = tokenizerLoader
    }

    /// Downloads and loads a generation model into a `ModelContainer`.
    public func loadLLM(
        _ ref: ModelRef,
        slot: ModelSlot,
        context: Int,
        reporting: @escaping @Sendable (DownloadProgress) -> Void
    ) async throws -> any LoadedLLMContainer {
        try await loadModelContainer(
            from: downloader,
            using: tokenizerLoader,
            configuration: configuration(for: ref),
            progressHandler: Self.handler(reporting)
        )
    }

    /// Downloads and loads an embedding model into an `EmbedderModelContainer`.
    public func loadEmbedder(
        _ ref: ModelRef,
        slot: ModelSlot,
        reporting: @escaping @Sendable (DownloadProgress) -> Void
    ) async throws -> any LoadedEmbeddingContainer {
        try await EmbedderModelFactory.shared.loadContainer(
            from: downloader,
            using: tokenizerLoader,
            configuration: configuration(for: ref),
            progressHandler: Self.handler(reporting)
        )
    }

    /// Builds the MLX `ModelConfiguration` for a model ref, pinning the ref's
    /// revision or falling back to ``defaultRevision`` — shared by the
    /// generation and embedding load paths.
    private func configuration(for ref: ModelRef) -> ModelConfiguration {
        ModelConfiguration(id: ref.repo, revision: ref.revision ?? Self.defaultRevision)
    }

    /// Warms a loaded container.
    ///
    /// The MLX containers materialize their weights at load time, so loading
    /// already brings the model resident; this hook is the seam for any future
    /// explicit warm-up (e.g. a throwaway forward pass).
    public func preload(_ container: any LoadedModelContainer) async throws {}

    /// Evicts a loaded container.
    ///
    /// Real MLX unload is not required at this milestone (the lifecycle only
    /// needs eviction to route through the loader so it is stubbable); this is
    /// the no-op seam where an explicit unload lands later.
    public func evict(_ container: any LoadedModelContainer) async {}

    /// The revision used when a ``ModelRef`` does not pin one.
    private static let defaultRevision = "main"

    /// Adapts the router's ``DownloadProgress`` callback to MLX's Foundation
    /// `Progress` progress handler.
    private static func handler(
        _ reporting: @escaping @Sendable (DownloadProgress) -> Void
    ) -> @Sendable (Progress) -> Void {
        { progress in
            reporting(
                DownloadProgress(
                    bytesDownloaded: progress.completedUnitCount,
                    bytesTotal: progress.totalUnitCount
                )
            )
        }
    }
}

/// The default ``ModelLoader`` when none is supplied: it cannot load anything and
/// throws ``ModelLoaderError/notConfigured`` on first use.
///
/// Because the live download path requires an injected `Downloader` /
/// `TokenizerLoader` (see ``LiveModelLoader``), a `Router` built with no loader
/// can size and joint-fit a profile but cannot download or load models — callers
/// that want real loading pass a configured ``LiveModelLoader``, and unit tests
/// pass a stub. This makes that requirement explicit rather than silently
/// loading nothing.
public struct UnconfiguredModelLoader: ModelLoader {
    /// Creates the unconfigured sentinel loader.
    public init() {}

    /// Always throws ``ModelLoaderError/notConfigured``: this sentinel cannot
    /// load a generation model. Real loading is configured/injected via
    /// ``LiveModelLoader`` (milestone 7).
    public func loadLLM(
        _ ref: ModelRef,
        slot: ModelSlot,
        context: Int,
        reporting: @escaping @Sendable (DownloadProgress) -> Void
    ) async throws -> any LoadedLLMContainer {
        throw ModelLoaderError.notConfigured
    }

    /// Always throws ``ModelLoaderError/notConfigured``: this sentinel cannot
    /// load an embedding model. Real loading is configured/injected via
    /// ``LiveModelLoader`` (milestone 7).
    public func loadEmbedder(
        _ ref: ModelRef,
        slot: ModelSlot,
        reporting: @escaping @Sendable (DownloadProgress) -> Void
    ) async throws -> any LoadedEmbeddingContainer {
        throw ModelLoaderError.notConfigured
    }

    /// Always throws ``ModelLoaderError/notConfigured``: this sentinel has no
    /// container to warm. Real loading is configured/injected via
    /// ``LiveModelLoader`` (milestone 7).
    public func preload(_ container: any LoadedModelContainer) async throws {
        throw ModelLoaderError.notConfigured
    }
}
