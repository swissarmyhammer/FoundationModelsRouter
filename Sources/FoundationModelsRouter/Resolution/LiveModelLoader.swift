import Foundation
import FoundationModels
import MLX
import MLXEmbedders
import MLXFoundationModels
import MLXLLM
import MLXLMCommon

// The MLX container types are the live loaded handles. They are `final class …:
// Sendable`, so conforming them to the router's marker protocols lets
// ``LiveModelLoader`` vend real generation and embedding through the same
// orchestration the unit suite drives with stubs. These are the milestone-7
// live seams: ``MLXFoundationModelsContainer`` runs the real `LanguageModelSession`
// (`FoundationModels`) pipeline over an `MLXLanguageModel` conformance, and
// ``LiveEmbeddingContainer`` wraps `MLXEmbedders` with a probed dimension.
//
// **No `MLXLMCommon.ChatSession` and no hand-rolled generation loop.** The
// session surface every generation call runs through is Apple's own
// `LanguageModelSession`, backed by `MLXLanguageModel` (`MLXFoundationModels`,
// our `swissarmyhammer/mlx-swift-lm` fork's `mlx-foundationmodels` branch,
// tracking upstream PR ml-explore/mlx-swift-lm#334). Guided (JSON-Schema)
// generation runs through `LanguageModelSession.respond(to:schema:)`, which
// invokes `MLXLanguageModel`'s own `Executor` — the xgrammar-constrained decode
// (`MLXGuidedGeneration`) happens *underneath* the `LanguageModel` conformance,
// invoked by FoundationModels, not called directly here. See plan.md's
// "Backends" and "Guided generation" sections.

/// The default token budget for the live generation paths when a caller does
/// not supply its own `maxTokens`, so a routed turn cannot run away. Plain and
/// guided generation share the same default — there is no principled reason
/// for guided decode to get a different ceiling.
private let defaultMaxTokens = 8192

/// The live ``LoadedLLMContainer``: wraps an `MLXLanguageModel` — the
/// `FoundationModels.LanguageModel` protocol conformance `MLXFoundationModels`
/// provides over a resident MLX `ModelContainer` — and manufactures the
/// ``LanguageModelSessionBackend`` every generation call actually runs through.
///
/// This container no longer invokes generation itself (see
/// ``LoadedLLMContainer/makeSession(instructions:)``); ``makeSession(instructions:)``
/// below vends a ``MLXFoundationModelsSessionBackend`` that drives a real
/// `LanguageModelSession` built over ``model``. Constructing a session is
/// cheap: `MLXLanguageModel` is a small `Sendable` value whose actual weights
/// are loaded once and cached by its own process-global cache, keyed by model
/// id — building a session over it does not reload anything.
struct MLXFoundationModelsContainer: LoadedLLMContainer, Sendable {
    /// The `LanguageModel` conformance wrapping this slot's resident MLX model.
    let model: MLXLanguageModel

    /// Manufactures a live session backend over ``model``.
    ///
    /// - Parameter instructions: The session's system instructions, or `nil`.
    /// - Returns: A new ``MLXFoundationModelsSessionBackend`` a vended
    ///   ``RoutedSession`` drives for its lifetime.
    func makeSession(instructions: String?) -> any LanguageModelSessionBackend {
        MLXFoundationModelsSessionBackend(model: model, instructions: instructions)
    }
}

/// The live ``LanguageModelSessionBackend``: drives a real `LanguageModelSession`
/// over a resident `MLXLanguageModel`.
///
/// **Not yet conversation-preserving.** A fresh `LanguageModelSession` is
/// constructed per call, mirroring this seam's prior one-shot contract (no
/// per-turn conversation state is threaded across calls yet; see
/// ``SessionKVCache``'s documentation for why a persistent, cheaply-forkable
/// session is not yet wired through this seam). ``makeFork()`` correspondingly
/// vends an equivalent fresh backend rather than seeding from an accumulated
/// transcript — there is none yet to seed from.
final class MLXFoundationModelsSessionBackend: LanguageModelSessionBackend, Sendable {
    /// The `LanguageModel` conformance a fresh `LanguageModelSession` is built
    /// over for each call.
    private let model: MLXLanguageModel

    /// The system instructions every `LanguageModelSession` this backend
    /// constructs is given.
    private let instructions: String?

    /// Creates a backend over a resident model and its session instructions.
    init(model: MLXLanguageModel, instructions: String?) {
        self.model = model
        self.instructions = instructions
    }

    /// Generates a complete text response through a real `LanguageModelSession`.
    func respond(to prompt: String, maxTokens: Int?) async throws -> String {
        let session = LanguageModelSession(model: model, instructions: instructions)
        let response = try await session.respond(
            to: prompt,
            options: GenerationOptions(maximumResponseTokens: maxTokens ?? defaultMaxTokens)
        )
        return response.content
    }

    /// Streams a text response through a real `LanguageModelSession`, adapting
    /// its snapshot-based stream into this seam's delta (fragment) contract.
    ///
    /// **Verified, not assumed** (per the FoundationModels v2 SDK's
    /// `LanguageModelSession.ResponseStream`): each element the stream yields is
    /// a `Snapshot` whose `content` is the *cumulative* response text so far
    /// (`Content.PartiallyGenerated`, `= String` for `Content == String`) — not
    /// a per-token delta. `RoutedSession/streamResponse(to:)`'s documented
    /// contract is a stream of *fragments* a caller accumulates (mirroring the
    /// prior `ChatSession`-backed behavior), so this yields only the new suffix
    /// of each snapshot, computed against the previous one.
    func streamResponse(to prompt: String, maxTokens: Int?) -> AsyncThrowingStream<String, Error> {
        let session = LanguageModelSession(model: model, instructions: instructions)
        let options = GenerationOptions(maximumResponseTokens: maxTokens ?? defaultMaxTokens)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var previous = ""
                    for try await snapshot in session.streamResponse(to: prompt, options: options) {
                        let current = snapshot.content
                        let delta = Self.suffix(of: current, after: previous)
                        if !delta.isEmpty {
                            continuation.yield(delta)
                        }
                        previous = current
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    /// The new suffix `current` has beyond `previous`, assuming `current`
    /// extends `previous` the way a cumulative streaming snapshot does.
    ///
    /// - Returns: The whole of `current` if it does not have `previous` as a
    ///   prefix — a defensive fallback for a non-monotonic snapshot, not
    ///   expected in practice — otherwise just the new suffix.
    private static func suffix(of current: String, after previous: String) -> String {
        guard current.hasPrefix(previous) else { return current }
        return String(current.dropFirst(previous.count))
    }

    /// Generates a grammar-constrained response through a real
    /// `LanguageModelSession`.
    ///
    /// ``Grammar/jsonSchema(_:)`` compiles the caller's JSON Schema source into
    /// a `GenerationSchema` via ``RuntimeJSONSchemaConverter`` (see its
    /// documentation for why `GenerationSchema`'s own `Codable` conformance
    /// cannot be used for this) and drives `LanguageModelSession.respond(to:schema:)`
    /// — the xgrammar-constrained decode this produces runs entirely inside
    /// `MLXLanguageModel`'s `Executor`, invoked by FoundationModels, never by a
    /// loop of our own. ``Grammar/ebnf(_:)`` has no equivalent entry point on
    /// `LanguageModelSession` (which only accepts a typed `schema:` parameter,
    /// never a raw grammar string) and is not supported under this backend —
    /// see ``GuidedRequestError/ebnfNotSupportedByLanguageModelSession``.
    func respond(to prompt: String, following grammar: Grammar, maxTokens: Int?) async throws -> String {
        try grammar.validateForXGrammar()
        switch grammar {
        case .ebnf:
            throw GuidedRequestError.ebnfNotSupportedByLanguageModelSession
        case .jsonSchema(let schemaText):
            let schema = try RuntimeJSONSchemaConverter.compile(schemaText)
            let session = LanguageModelSession(model: model, instructions: instructions)
            let response = try await session.respond(
                to: prompt,
                schema: schema,
                options: GenerationOptions(maximumResponseTokens: maxTokens ?? defaultMaxTokens)
            )
            return response.content.jsonString
        }
    }

    /// Vends a fresh backend over the same model and instructions.
    ///
    /// There is no accumulated transcript to seed from yet (see this type's
    /// documentation), so a fork today is simply another independent backend —
    /// equivalent to, not derived from, the parent.
    func makeFork() -> any LanguageModelSessionBackend {
        MLXFoundationModelsSessionBackend(model: model, instructions: instructions)
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
/// probes it once and stores it here. Embedding does not go through
/// `LanguageModelSession` — `MLXEmbedders` has no `FoundationModels.LanguageModel`
/// surface, so this stays on the direct `MLXEmbedders` pipeline (see plan.md's
/// "Backends" section).
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
/// source and materializes an ``MLXFoundationModelsContainer`` for generation
/// (backed by `MLXLanguageModel` + `LanguageModelSession`) and a
/// ``LiveEmbeddingContainer`` for embedding.
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
/// Generation models load through `MLXFoundationModels.MLXLanguageModel`, which
/// wraps `MLXLMCommon`'s `loadModelContainer` (resolving the configuration
/// against the registered `MLXLLM` factories) and caches the resident
/// `ModelContainer` itself, keyed by model id; embedding models load through
/// `MLXEmbedders`' `EmbedderModelFactory` directly. Both map the Foundation
/// `Progress` into ``DownloadProgress``.
public struct LiveModelLoader: ModelLoader {
    /// The source that fetches model and tokenizer files.
    private let downloader: any Downloader

    /// The factory that loads a tokenizer from downloaded files.
    private let tokenizerLoader: any TokenizerLoader

    /// Resolves a model identifier to its on-disk weights directory, passed
    /// through to `MLXLanguageModel` for its availability checks
    /// (`modelExistsOnDisk()`, free-disk-space checks) — **not** consulted by
    /// the load path itself, which always goes through `load`/`downloader`
    /// below. Defaults to a harmless temporary-directory stub for callers that
    /// don't need those availability checks to resolve real paths.
    private let weightsLocation: @Sendable (String) -> URL

    /// Creates a live loader over an injected downloader and tokenizer loader.
    ///
    /// - Parameters:
    ///   - downloader: The source that fetches model and tokenizer files (e.g. a
    ///     Hub client supplied by the integration suite).
    ///   - tokenizerLoader: The factory that loads a tokenizer from those files.
    ///   - weightsLocation: Resolves a model id to its on-disk weights
    ///     directory, for `MLXLanguageModel`'s availability checks. Defaults to
    ///     a stub that never resolves a real path — pass the Hub cache's real
    ///     repo-directory resolver (e.g. `HubCache.repoDirectory(repo:kind:)`)
    ///     when those checks matter.
    public init(
        downloader: any Downloader,
        tokenizerLoader: any TokenizerLoader,
        weightsLocation: @escaping @Sendable (String) -> URL = { _ in
            FileManager.default.temporaryDirectory
        }
    ) {
        self.downloader = downloader
        self.tokenizerLoader = tokenizerLoader
        self.weightsLocation = weightsLocation
    }

    /// Downloads and loads a generation model into an ``MLXFoundationModelsContainer``.
    ///
    /// Builds an `MLXLanguageModel` over the model's configuration and this
    /// loader's downloader/tokenizer loader, then forces eager loading now
    /// (`MLXLanguageModel` itself otherwise defers loading until first
    /// inference), matching the router's residency model: `preload()`s and
    /// holds every slot resident for the profile's lifetime (see plan.md's
    /// "Residency" section).
    ///
    /// - Parameters:
    ///   - ref: The model reference to download and load.
    ///   - slot: The slot the model is being loaded for.
    ///   - context: The context length to size the model for.
    ///   - reporting: The byte-based download-progress callback, invoked as
    ///     weights stream in.
    /// - Returns: The loaded generation container.
    /// - Throws: If the download or MLX container load fails.
    public func loadLLM(
        _ ref: ModelRef,
        slot: ModelSlot,
        context: Int,
        reporting: @escaping @Sendable (DownloadProgress) -> Void
    ) async throws -> any LoadedLLMContainer {
        let downloader = self.downloader
        let tokenizerLoader = self.tokenizerLoader
        let modelConfiguration = configuration(for: ref)
        let model = MLXLanguageModel(
            configuration: modelConfiguration,
            capabilities: [.guidedGeneration],
            weightsLocation: weightsLocation,
            load: { configuration, mlxProgressHandler in
                try await loadModelContainer(
                    from: downloader,
                    using: tokenizerLoader,
                    configuration: configuration,
                    progressHandler: { progress in
                        // Forward to both: `MLXLanguageModel`'s own global
                        // `MLXDownloadProgress` broadcast (its usual signal for
                        // e.g. a SwiftUI observer bound to `.shared`) and this
                        // router's own byte-based progress plumbing, which is
                        // what `Router`/`ResolutionProgress` actually consume.
                        mlxProgressHandler(progress)
                        Self.handler(reporting)(progress)
                    }
                )
            }
        )
        _ = try await model.loadContainer()
        return MLXFoundationModelsContainer(model: model)
    }

    /// Downloads and loads an embedding model, wrapping it in a
    /// ``LiveEmbeddingContainer`` with its embedding dimension probed once now.
    ///
    /// `EmbedderModelContainer` only exposes its model through an async closure, so
    /// the dimension is not available synchronously; a single probe embedding
    /// establishes it (and warms the model) before the container is vended.
    ///
    /// - Parameters:
    ///   - ref: The embedding model reference to download and load.
    ///   - slot: The slot the model is being loaded for.
    ///   - reporting: The byte-based download-progress callback, invoked as
    ///     weights stream in.
    /// - Returns: The loaded ``LiveEmbeddingContainer`` with its probed dimension.
    /// - Throws: If the download, MLX container load, or dimension probe fails.
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
    /// `loadLLM`/`loadEmbedder` already materialize weights eagerly (an
    /// `MLXLanguageModel`'s `loadContainer()` is forced there; the embedder's
    /// container loads synchronously in `loadEmbedder`), so this hook is a
    /// no-op seam for any future explicit warm-up (e.g. a throwaway forward
    /// pass beyond weight materialization).
    public func preload(_ container: any LoadedModelContainer) async throws {}

    /// Evicts a loaded container, freeing the GPU memory its weights hold.
    ///
    /// Routed through ``MLXFoundationModelsContainer/model``'s real
    /// `MLXLanguageModel.evict()` when the container is a live generation
    /// container (dropping it from `MLXLanguageModel`'s process-global cache,
    /// so a subsequent load reloads from the on-disk snapshot); a no-op for any
    /// other container (e.g. the embedding container, which has no equivalent
    /// eviction hook today).
    public func evict(_ container: any LoadedModelContainer) async {
        guard let generation = container as? MLXFoundationModelsContainer else { return }
        await generation.model.evict()
    }

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
    ///
    /// - Parameter reporting: The router's byte-based progress callback to invoke
    ///   for each Foundation `Progress` update.
    /// - Returns: A `@Sendable` `Progress` observer that maps each update into a
    ///   byte-based ``DownloadProgress`` and forwards it to `reporting`.
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
    ///
    /// - Parameters:
    ///   - ref: The model reference that would be loaded.
    ///   - slot: The slot the model would be loaded for.
    ///   - context: The context length the model would be sized for.
    ///   - reporting: The download-progress callback (never invoked).
    /// - Returns: Never returns normally — this sentinel always throws.
    /// - Throws: ``ModelLoaderError/notConfigured``, always.
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
    ///
    /// - Parameters:
    ///   - ref: The embedding model reference that would be loaded.
    ///   - slot: The slot the model would be loaded for.
    ///   - reporting: The download-progress callback (never invoked).
    /// - Returns: Never returns normally — this sentinel always throws.
    /// - Throws: ``ModelLoaderError/notConfigured``, always.
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
