import Foundation
import MLX
import MLXEmbedders
import MLXGuidedGeneration
import MLXLLM
import MLXLMCommon

// The MLX container types are the live loaded handles. They are `final class …:
// Sendable`, so conforming them to the router's marker protocols lets
// ``LiveModelLoader`` vend real generation and embedding through the same
// orchestration the unit suite drives with stubs. These are the milestone-7
// live seams: `ModelContainer` runs the real `MLXLMCommon` / xgrammar pipeline,
// and ``LiveEmbeddingContainer`` wraps `MLXEmbedders` with a probed dimension.

/// Bounded token budgets for the live generation paths, so a routed turn cannot
/// run away. Guided decode is whole-chunk and structural, so it gets a larger
/// ceiling than plain generation.
private let liveGenerateMaxTokens = 1024
private let liveGuidedMaxTokens = 2048

extension ModelContainer: LoadedLLMContainer {
    /// Generates a complete text response through the real `MLXLMCommon` pipeline
    /// by accumulating a fresh ``ChatSession``'s stream.
    ///
    /// Each call is a one-shot session over the shared resident container: the
    /// ``LoadedLLMContainer`` generation seam carries no per-turn cache, so
    /// conversation state is not threaded through here (see ``makeCache()``).
    public nonisolated func respond(to prompt: String, instructions: String?) async throws -> String {
        try await ChatSession(
            self,
            instructions: instructions,
            generateParameters: GenerateParameters(maxTokens: liveGenerateMaxTokens)
        ).respond(to: prompt)
    }

    /// Streams a text response through the real `MLXLMCommon` pipeline as a fresh
    /// ``ChatSession``'s token stream.
    public nonisolated func streamResponse(
        to prompt: String,
        instructions: String?
    ) -> AsyncThrowingStream<String, Error> {
        ChatSession(
            self,
            instructions: instructions,
            generateParameters: GenerateParameters(maxTokens: liveGenerateMaxTokens)
        ).streamResponse(to: prompt)
    }

    /// Generates a grammar-constrained response through the real xgrammar engine.
    ///
    /// Validates the grammar (pure, GPU-free), compiles it into a
    /// ``GrammarConstraint`` over the model's own tokenizer, then drives
    /// ``GuidedGenerationLoop`` to whole-chunk constrained decode, accumulating the
    /// emitted deltas.
    public nonisolated func respond(
        to prompt: String,
        instructions: String?,
        following grammar: Grammar
    ) async throws -> String {
        try grammar.validateForXGrammar()
        return try await perform { context in
            let hostTokenizer = context.tokenizer
            let grammarVocab = TokenizerVocabExtractor.extractForGrammar(from: hostTokenizer)
            let grammarTokenizer = try GrammarTokenizer(
                vocab: grammarVocab.vocab,
                vocabType: grammarVocab.vocabType,
                eosTokenId: Int32(hostTokenizer.eosTokenId ?? 0)
            )
            let constraint = try Self.grammarConstraint(
                for: grammar,
                tokenizer: grammarTokenizer,
                hostTokenizer: hostTokenizer
            )
            // `UserInput` is not `Sendable`, so it is built inside the `@Sendable`
            // perform closure from the Sendable prompt/instructions rather than
            // captured from outside.
            let input = try await context.processor.prepare(
                input: Self.guidedUserInput(prompt: prompt, instructions: instructions)
            )
            var output = ""
            try GuidedGenerationLoop.run(
                input: input,
                context: context,
                constraint: constraint,
                maxTokens: liveGuidedMaxTokens,
                vocabSize: grammarTokenizer.vocabSize
            ) { delta in
                output += delta
                return true
            }
            return output
        }
    }

    /// Allocates a fresh MLX-backed session KV cache.
    ///
    /// Backed by a real `KVCacheSimple`, so a ``RoutedSession/fork(workingDirectory:)``
    /// copy runs the real MLX `KVCache.copy()` and the cache frees with the
    /// session (ARC). The frozen ``LoadedLLMContainer`` generation entry points
    /// carry no cache argument, so this cache is the fork/copy/free contract
    /// rather than generation-threaded prefix state.
    public nonisolated func makeCache() -> any SessionKVCache {
        MLXSessionKVCache(caches: [KVCacheSimple()])
    }

    /// Builds the guided prompt input, folding any system instructions in as a
    /// leading system chat turn.
    private static func guidedUserInput(prompt: String, instructions: String?) -> UserInput {
        if let instructions, !instructions.isEmpty {
            return UserInput(chat: [.system(instructions), .user(prompt)])
        }
        return UserInput(prompt: prompt)
    }

    /// Compiles a router ``Grammar`` into an xgrammar ``GrammarConstraint`` over a
    /// bound grammar tokenizer, routing JSON-schema and EBNF sources to their
    /// respective xgrammar compile paths with fast-forward enabled.
    private static func grammarConstraint(
        for grammar: Grammar,
        tokenizer: GrammarTokenizer,
        hostTokenizer: any Tokenizer
    ) throws -> GrammarConstraint {
        switch grammar {
        case .jsonSchema(let schema):
            return try GrammarConstraint(
                tokenizer: tokenizer,
                jsonSchema: schema,
                fastForward: true,
                hostTokenizer: hostTokenizer
            )
        case .ebnf(let source):
            return try GrammarConstraint(
                tokenizer: tokenizer,
                grammar: source,
                fastForward: true,
                hostTokenizer: hostTokenizer
            )
        }
    }
}

/// A real MLX-backed ``SessionKVCache``: it owns a model KV cache and copies it
/// through the real MLX `KVCache.copy()` on fork.
///
/// `@unchecked Sendable`: MLX `KVCache` is not `Sendable`, but a session (an
/// actor) owns exactly one cache and only ``copy()``s it from its own isolation
/// on ``RoutedSession/fork(workingDirectory:)`` — never touching a single
/// instance concurrently — so the access is data-race free by construction.
final class MLXSessionKVCache: SessionKVCache, @unchecked Sendable {
    /// The owned MLX KV caches. A freshly-vended session default holds one empty
    /// ``KVCacheSimple``; ``copy()`` snapshots each through the real MLX copy.
    private let caches: [any KVCache]

    /// Creates a session cache wrapping the given MLX caches.
    init(caches: [any KVCache]) {
        self.caches = caches
    }

    /// Returns an independent copy via the real MLX `KVCache.copy()`.
    func copy() -> any SessionKVCache {
        MLXSessionKVCache(caches: caches.map { $0.copy() })
    }
}

/// The live embedding container: wraps a loaded `EmbedderModelContainer` and the
/// embedding ``dimension`` probed once at load, so the router's synchronous
/// ``LoadedEmbeddingContainer/dimension`` accessor reports a real value and
/// ``embed(_:)`` runs the real `MLXEmbedders` pooling pipeline.
///
/// The wrapper exists because `EmbedderModelContainer` exposes its model only
/// through an async `perform` closure, so the dimension is not knowable
/// synchronously from the raw container; ``LiveModelLoader/loadEmbedder(_:slot:reporting:)``
/// probes it once and stores it here.
final class LiveEmbeddingContainer: LoadedEmbeddingContainer {
    /// The loaded MLX embedder container the computation runs through.
    private let container: EmbedderModelContainer

    /// The length of every embedding vector this model produces, probed at load.
    let dimension: Int

    /// Creates a live embedding container over a loaded MLX container and its
    /// probed embedding dimension.
    init(container: EmbedderModelContainer, dimension: Int) {
        self.container = container
        self.dimension = dimension
    }

    /// Embeds each input into a ``dimension``-length, L2-normalized vector through
    /// the real `MLXEmbedders` pipeline.
    func embed(_ texts: [String]) async throws -> [[Float]] {
        try await Self.embed(texts, in: container)
    }

    /// The shared embedding computation: tokenize, pad to the batch max, run the
    /// model, pool (normalized), and read the vectors back to `[[Float]]`. Static
    /// so ``LiveModelLoader`` can probe the dimension at load without a wrapper
    /// instance. Mirrors the fork's own `MLXEmbedders` usage example.
    static func embed(_ texts: [String], in container: EmbedderModelContainer) async throws -> [[Float]] {
        guard !texts.isEmpty else { return [] }
        return await container.perform { context in
            let tokenizer = context.tokenizer
            let encoded = texts.map { tokenizer.encode(text: $0, addSpecialTokens: true) }
            let maxLength = encoded.reduce(into: 1) { $0 = max($0, $1.count) }
            let padded = stacked(
                encoded.map { tokens in
                    MLXArray(
                        tokens
                            + Array(
                                repeating: tokenizer.eosTokenId ?? 0,
                                count: maxLength - tokens.count
                            )
                    )
                }
            )
            let mask = padded .!= (tokenizer.eosTokenId ?? 0)
            let tokenTypes = MLXArray.zeros(like: padded)
            let output = context.model(
                padded, positionIds: nil, tokenTypeIds: tokenTypes, attentionMask: mask
            )
            let pooled = context.pooling(output, normalize: true, applyLayerNorm: true)
            pooled.eval()
            return pooled.map { $0.asArray(Float.self) }
        }
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

    /// Downloads and loads an embedding model, wrapping it in a
    /// ``LiveEmbeddingContainer`` with its embedding dimension probed once now.
    ///
    /// `EmbedderModelContainer` only exposes its model through an async closure, so
    /// the dimension is not available synchronously; a single probe embedding
    /// establishes it (and warms the model) before the container is vended.
    public func loadEmbedder(
        _ ref: ModelRef,
        slot: ModelSlot,
        reporting: @escaping @Sendable (DownloadProgress) -> Void
    ) async throws -> any LoadedEmbeddingContainer {
        let container = try await EmbedderModelFactory.shared.loadContainer(
            from: downloader,
            using: tokenizerLoader,
            configuration: configuration(for: ref),
            progressHandler: Self.handler(reporting)
        )
        let probe = try await LiveEmbeddingContainer.embed(["dimension probe"], in: container)
        return LiveEmbeddingContainer(container: container, dimension: probe.first?.count ?? 0)
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

    /// Adapts the injected Hub downloader's Foundation `Progress` to the router's
    /// byte-based ``DownloadProgress`` callback.
    ///
    /// The unit contract is **bytes**: `bytesTotal` is the snapshot's total byte
    /// size and `bytesDownloaded` is the bytes streamed so far, so the surfaced
    /// percentage is byte-accurate for the multi-GB weight downloads a UI bar
    /// tracks. The concrete Hub downloader the integration wiring injects
    /// (`#hubDownloader()`, forwarding `HubClient.downloadSnapshot`) builds its
    /// snapshot `Progress` byte-weighted: `totalUnitCount` is the sum of every
    /// entry's byte size, and each file is a child progress whose unit weight is
    /// that file's byte size. So `totalUnitCount` is the real byte total (mapped
    /// straight to ``DownloadProgress/bytesTotal``, no synthetic total).
    ///
    /// The downloaded count, however, is **not** `completedUnitCount`. Foundation
    /// aggregates a parent-with-children `Progress` only through
    /// `fractionCompleted`; its `completedUnitCount` counts only *whole completed
    /// children* — a shard streaming through reads `0` until it finishes and then
    /// jumps by its full size. For a multi-GB single-shard model that is a single
    /// `0 → 100` leap, not a live percentage. The honest incremental byte count is
    /// therefore `fractionCompleted × totalUnitCount`, rounded — which streams
    /// smoothly and still reaches exactly `bytesTotal` at completion
    /// (`fractionCompleted == 1`).
    ///
    /// Before any total is known the parent reports `0` bytes, which
    /// ``SlotProgress/progressFraction`` treats as an unknown total (fraction `0`)
    /// rather than a divide-by-zero; the ``Router/reporter(slot:progress:)`` this
    /// feeds only adopts a `bytesTotal` once it is reported (`> 0`).
    static func handler(
        _ reporting: @escaping @Sendable (DownloadProgress) -> Void
    ) -> @Sendable (Progress) -> Void {
        { progress in
            let bytesTotal = progress.totalUnitCount
            let bytesDownloaded = Int64((progress.fractionCompleted * Double(bytesTotal)).rounded())
            reporting(
                DownloadProgress(bytesDownloaded: bytesDownloaded, bytesTotal: bytesTotal)
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
