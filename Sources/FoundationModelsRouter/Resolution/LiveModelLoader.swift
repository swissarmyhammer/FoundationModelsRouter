import Foundation
import FoundationModels
import MLX
import MLXEmbedders
import MLXFoundationModels
import MLXLLM
import MLXLMCommon
// Load-bearing although this file names no `MLXVLM` symbol: keep it.
// `loadModelContainer` selects a factory through `MLXLMCommon`'s
// `ModelFactoryRegistry`, which finds its built-in trampolines with
// `NSClassFromString` — a factory whose module the linker dropped is
// silently absent from that list. `MLXLLM` above is imported for the same
// reason. Muse Glimmer (`muse_glimmer`), the model the gated suites load,
// is registered only in `VLMModelFactory`, so without this import the id
// throws `unsupportedModelType` *after* paying for the whole download.
import MLXVLM

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

/// The token ceiling for a generation call that gives no `maxTokens`.
private let defaultMaxTokens = 8192

/// Builds a session backend over a new `LanguageModelSession` seeded from
/// `transcript`.
///
/// - Parameter instructions: The new backend's instructions. The outer `nil` derives them from the leading `.instructions` entry of `transcript`. A non-`nil` outer value, including `.some(nil)`, is used as given.
private func makeSessionBackend(
    model: any FoundationModels.LanguageModel,
    transcript: FoundationModels.Transcript,
    tools: [any FoundationModels.Tool],
    samplingMode: GenerationOptions.SamplingMode?,
    instructions: String?? = nil
) -> MLXFoundationModelsSessionBackend {
    let session = LanguageModelSession(model: model, tools: tools, transcript: transcript)
    return MLXFoundationModelsSessionBackend(
        session: session,
        model: model,
        instructions: instructions ?? TranscriptDiffer.leadingInstructionsText(of: transcript),
        tools: tools,
        samplingMode: samplingMode
    )
}

/// The live ``LoadedLLMContainer``. Wraps an `MLXLanguageModel` and makes the
/// ``LanguageModelSessionBackend`` every generation call runs through.
package struct MLXFoundationModelsContainer: LoadedLLMContainer, Sendable {
    /// The `LanguageModel` conformance wrapping this slot's resident MLX model.
    let model: MLXLanguageModel

    /// The decoding strategy every backend this container vends requests, or
    /// `nil` for the provider default.
    let samplingMode: GenerationOptions.SamplingMode?

    /// The `FoundationModels.LanguageModel` this container wraps.
    package var languageModel: any FoundationModels.LanguageModel { model }

    /// Makes a live session backend over ``model``.
    package func makeSession(instructions: String?) -> any LanguageModelSessionBackend {
        makeSession(instructions: instructions, tools: [])
    }

    /// Makes a live session backend over ``model`` with `tools`.
    package func makeSession(instructions: String?, tools: [any FoundationModels.Tool]) -> any LanguageModelSessionBackend {
        let session = LanguageModelSession(model: model, tools: tools, instructions: instructions)
        return MLXFoundationModelsSessionBackend(
            session: session, model: model, instructions: instructions, tools: tools, samplingMode: samplingMode)
    }

    /// Makes a live session backend seeded from `transcript`, with no tools.
    package func makeSession(transcript: FoundationModels.Transcript) -> any LanguageModelSessionBackend {
        makeSession(transcript: transcript, tools: [])
    }

    /// Makes a live session backend seeded from `transcript` with `tools`. The
    /// backend derives its instructions from the leading `.instructions` entry
    /// of `transcript`.
    package func makeSession(
        transcript: FoundationModels.Transcript,
        tools: [any FoundationModels.Tool]
    ) -> any LanguageModelSessionBackend {
        makeSessionBackend(model: model, transcript: transcript, tools: tools, samplingMode: samplingMode)
    }
}

/// The live ``LanguageModelSessionBackend``. Wraps one `LanguageModelSession`
/// for the lifetime of the backend. The caller must not make two calls on one
/// backend at the same time.
final class MLXFoundationModelsSessionBackend: LanguageModelSessionBackend, @unchecked Sendable {
    /// The `LanguageModel` conformance a fork builds its session over.
    private let model: any FoundationModels.LanguageModel

    /// The live session every call on this backend runs through.
    private let liveSession: LanguageModelSession

    /// The system instructions ``liveSession`` was created with, or `nil`.
    private let instructions: String?

    /// The tools ``liveSession`` was created with.
    private let tools: [any FoundationModels.Tool]

    /// The decoding strategy every generation call requests, or `nil` for the
    /// provider default.
    private let samplingMode: GenerationOptions.SamplingMode?

    /// Test-only accessor onto ``liveSession``. Not part of the protocol.
    // periphery:ignore
    internal var session: LanguageModelSession { liveSession }

    /// Creates a backend over an existing session.
    init(
        session: LanguageModelSession,
        model: any FoundationModels.LanguageModel,
        instructions: String? = nil,
        tools: [any FoundationModels.Tool] = [],
        samplingMode: GenerationOptions.SamplingMode? = nil
    ) {
        self.liveSession = session
        self.model = model
        self.instructions = instructions
        self.tools = tools
        self.samplingMode = samplingMode
    }

    /// Generates a complete text response through ``liveSession``.
    func respond(to prompt: String, maxTokens: Int?) async throws -> String {
        try await respond(to: prompt, schema: nil, maxTokens: maxTokens)
    }

    /// Runs ``liveSession`` and returns its response content. With a `schema`
    /// the decode is constrained to it and the result is its JSON string.
    private func respond(
        to prompt: String,
        schema: GenerationSchema?,
        maxTokens: Int?
    ) async throws -> String {
        let options = GenerationOptions(
            samplingMode: samplingMode, maximumResponseTokens: maxTokens ?? defaultMaxTokens)
        guard let schema else {
            let response = try await liveSession.respond(to: prompt, options: options)
            return response.content
        }
        let response = try await liveSession.respond(to: prompt, schema: schema, options: options)
        return response.content.jsonString
    }

    /// Streams a text response through ``liveSession`` as text fragments.
    /// Empty fragments are dropped.
    func streamResponse(to prompt: String, maxTokens: Int?) -> AsyncThrowingStream<String, Error> {
        let fragments = streamResponseFragments(to: prompt, maxTokens: maxTokens)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await fragment in fragments where !fragment.text.isEmpty {
                        continuation.yield(fragment.text)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    /// Streams the response of ``liveSession`` as ``ResponseFragment``s. A
    /// fragment reports a restart when a snapshot does not extend the response
    /// so far.
    ///
    /// - Returns: A stream of fragments. It throws if generation fails.
    func streamResponseFragments(
        to prompt: String,
        maxTokens: Int?
    ) -> AsyncThrowingStream<ResponseFragment, Error> {
        let options = GenerationOptions(
            samplingMode: samplingMode, maximumResponseTokens: maxTokens ?? defaultMaxTokens)
        let fragments = SnapshotDeltaIterator(
            liveSession.streamResponse(to: prompt, options: options)
        ) { $0.content }
        return AsyncThrowingStream { try await fragments.next() }
    }

    /// Pulls cumulative snapshots and returns the fragment each one adds.
    /// ``next()`` must not be called concurrently.
    private final class SnapshotDeltaIterator<Snapshots: AsyncSequence>: @unchecked Sendable {
        /// The snapshot stream's own iterator, driven by ``next()``'s caller.
        private var iterator: Snapshots.AsyncIterator

        /// Reads a snapshot's cumulative text.
        private let content: (Snapshots.Element) -> String

        /// The snapshot before the current one, or the empty string at the start.
        private var previous = ""

        /// Creates an iterator that pulls from `snapshots`.
        init(_ snapshots: Snapshots, content: @escaping (Snapshots.Element) -> String) {
            self.iterator = snapshots.makeAsyncIterator()
            self.content = content
        }

        /// Returns the next fragment, or `nil` at the end of the stream. Skips
        /// snapshots that repeat without change.
        func next() async throws -> ResponseFragment? {
            while let snapshot = try await iterator.next() {
                let current = content(snapshot)
                let fragment = MLXFoundationModelsSessionBackend.fragment(of: current, after: previous)
                previous = current
                if let fragment { return fragment }
            }
            return nil
        }
    }

    /// The fragment `current` adds to `previous`, or `nil` when they are equal.
    /// A snapshot that does not extend `previous` gives its whole text as a
    /// restarting fragment.
    private static func fragment(of current: String, after previous: String) -> ResponseFragment? {
        guard current != previous else { return nil }
        guard current.hasPrefix(previous) else {
            return ResponseFragment(text: current, restartsResponse: true)
        }
        return ResponseFragment(text: String(current.dropFirst(previous.count)))
    }

    /// Generates a grammar-constrained response through ``liveSession``.
    ///
    /// - Throws: ``GuidedRequestError/ebnfNotSupportedByLanguageModelSession`` for ``Grammar/ebnf(_:)``.
    func respond(to prompt: String, following grammar: Grammar, maxTokens: Int?) async throws -> String {
        try grammar.validateForXGrammar()
        switch grammar {
        case .ebnf:
            throw GuidedRequestError.ebnfNotSupportedByLanguageModelSession
        case .jsonSchema(let schemaText):
            let schema = try RuntimeJSONSchemaConverter.compile(schemaText)
            return try await respond(to: prompt, schema: schema, maxTokens: maxTokens)
        }
    }

    /// Makes a new backend seeded from the accumulated transcript of this
    /// session, with the same ``tools`` and ``instructions``.
    func makeFork() -> any LanguageModelSessionBackend {
        makeFork(tools: tools)
    }

    /// Makes a new backend seeded from the accumulated transcript of this
    /// session, with `tools` in place of this backend's own.
    func makeFork(tools: [any FoundationModels.Tool]) -> any LanguageModelSessionBackend {
        makeSessionBackend(
            model: model,
            transcript: liveSession.transcript,
            tools: tools,
            samplingMode: samplingMode,
            instructions: instructions
        )
    }

    /// Makes a new backend over ``model`` seeded from `transcript`, with this
    /// backend's ``tools``.
    func replacingTranscript(_ transcript: FoundationModels.Transcript) -> any LanguageModelSessionBackend {
        makeSessionBackend(model: model, transcript: transcript, tools: tools, samplingMode: samplingMode)
    }

    /// Returns the current transcript of ``liveSession``. Call it under the turn lock.
    func transcriptEntries() -> [FoundationModels.Transcript.Entry] {
        Array(liveSession.transcript)
    }

    /// Returns the cumulative token usage of ``liveSession``. Call it under the turn lock.
    func usageTokenCounts() -> (input: Int, output: Int)? {
        let usage = liveSession.usage
        return (usage.input.totalTokenCount, usage.output.totalTokenCount)
    }
}

/// The live embedding container. Wraps a loaded `EmbedderModelContainer` and
/// the ``dimension`` probed at load.
final class LiveEmbeddingContainer: LoadedEmbeddingContainer, Sendable {
    /// The loaded MLX embedder container the computation runs through.
    private let container: EmbedderModelContainer

    /// The length of every embedding vector this model produces, probed at load.
    let dimension: Int

    /// Creates a live embedding container over a loaded MLX container and its probed embedding dimension.
    init(container: EmbedderModelContainer, dimension: Int) {
        self.container = container
        self.dimension = dimension
    }

    /// Embeds each input into a ``dimension``-length, L2-normalized vector through the real `MLXEmbedders` pipeline.
    func embed(texts: [String]) async throws -> [[Float]] {
        try await Self.embed(texts: texts, in: container)
    }

    /// Embeds `texts` through `container`. Static so a loader can probe the
    /// dimension at load.
    ///
    /// - Returns: One vector per input string.
    static func embed(texts: [String], in container: EmbedderModelContainer) async throws -> [[Float]] {
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
    /// No real loader was configured. See ``UnconfiguredModelLoader``.
    case notConfigured
}

/// The live ``ModelLoader``. Downloads weights through an injected
/// `Downloader` and `TokenizerLoader`. Makes an ``MLXFoundationModelsContainer``
/// for generation and a ``LiveEmbeddingContainer`` for embedding.
public struct LiveModelLoader: ModelLoader {
    /// The source that fetches model and tokenizer files.
    private let downloader: any Downloader

    /// The factory that loads a tokenizer from downloaded files.
    private let tokenizerLoader: any TokenizerLoader

    /// Resolves a model id to its on-disk weights directory for
    /// `MLXLanguageModel` availability checks.
    private let weightsLocation: @Sendable (String) -> URL

    /// The decoding strategy every generation container this loader vends
    /// uses, or `nil` for the provider default.
    private let samplingMode: GenerationOptions.SamplingMode?

    /// Creates a live loader.
    ///
    /// - Parameters:
    ///   - weightsLocation: Resolves a model id to its on-disk weights directory. The default never resolves a real path.
    ///   - samplingMode: The decoding strategy. `nil` samples. `.greedy` gives repeatable output.
    public init(
        downloader: any Downloader,
        tokenizerLoader: any TokenizerLoader,
        weightsLocation: @escaping @Sendable (String) -> URL = { _ in
            FileManager.default.temporaryDirectory
        },
        samplingMode: GenerationOptions.SamplingMode? = nil
    ) {
        self.downloader = downloader
        self.tokenizerLoader = tokenizerLoader
        self.weightsLocation = weightsLocation
        self.samplingMode = samplingMode
    }

    /// Downloads and loads a generation model. The weights load before the
    /// container is returned.
    ///
    /// - Throws: If the download or MLX container load fails.
    public func loadLLM(
        ref: ModelRef,
        slot: ModelSlot,
        context: Int,
        reporting: @escaping @Sendable (DownloadProgress) -> Void
    ) async throws -> any LoadedLLMContainer {
        let downloader = self.downloader
        let tokenizerLoader = self.tokenizerLoader
        let modelConfiguration = configuration(for: ref)
        let model = MLXLanguageModel(
            configuration: modelConfiguration,
            // `.reasoning` is declared for every model this loader builds, not
            // only the ones that reason. A model that always reasons and cannot
            // be turned off — Muse Glimmer, the model the gated suites load —
            // throws at the first unconstrained turn when `.reasoning` is
            // omitted ("This model always reasons; .reasoning must be declared
            // at MLXLanguageModel init to receive its output"), because the
            // engine would otherwise have to re-render the prompt with thinking
            // off and it cannot. Declaring it costs a toggleable model nothing
            // the router throws away: reasoning arrives as `.reasoning`
            // transcript entries, which the recording path already maps
            // (``TranscriptEntryMapper``) and the event path already surfaces
            // as ``SessionEvent/reasoningDelta(_:)``.
            capabilities: [.guidedGeneration, .toolCalling, .reasoning],
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
                        Self.handler(reporting: reporting)(progress)
                    }
                )
            }
        )
        _ = try await model.loadContainer()
        return MLXFoundationModelsContainer(model: model, samplingMode: samplingMode)
    }

    /// Downloads and loads an embedding model. One probe embedding finds the
    /// dimension before the container is returned.
    ///
    /// - Throws: If the download, MLX container load, or dimension probe fails.
    public func loadEmbedder(
        ref: ModelRef,
        slot: ModelSlot,
        reporting: @escaping @Sendable (DownloadProgress) -> Void
    ) async throws -> any LoadedEmbeddingContainer {
        let container = try await EmbedderModelFactory.shared.loadContainer(
            from: downloader,
            using: tokenizerLoader,
            configuration: configuration(for: ref),
            progressHandler: Self.handler(reporting: reporting)
        )
        let probe = try await LiveEmbeddingContainer.embed(texts: ["dimension probe"], in: container)
        return LiveEmbeddingContainer(container: container, dimension: probe.first?.count ?? 0)
    }

    /// Builds the MLX `ModelConfiguration` for a model ref. An unpinned ref
    /// uses ``defaultRevision``.
    private func configuration(for ref: ModelRef) -> ModelConfiguration {
        ModelConfiguration(id: ref.repo, revision: ref.revision ?? Self.defaultRevision)
    }

    /// A no-op: the load paths already load weights.
    public func preload(container: any LoadedModelContainer) async throws {}

    /// Evicts a live generation container from the `MLXLanguageModel` cache.
    /// A no-op for any other container.
    public func evict(container: any LoadedModelContainer) async {
        guard let generation = container as? MLXFoundationModelsContainer else { return }
        await generation.model.evict()
    }

    /// The revision used when a ``ModelRef`` does not pin one.
    private static let defaultRevision = "main"

    /// Maps a Foundation `Progress` snapshot to a byte-based
    /// ``DownloadProgress``. `totalUnitCount` must be the byte total.
    /// `bytesDownloaded` is `fractionCompleted × totalUnitCount`, rounded.
    internal static func mapProgress(_ progress: Progress) -> DownloadProgress {
        let bytesTotal = progress.totalUnitCount
        let bytesDownloaded = Int64((progress.fractionCompleted * Double(bytesTotal)).rounded())
        return DownloadProgress(bytesDownloaded: bytesDownloaded, bytesTotal: bytesTotal)
    }

    /// Wraps ``mapProgress(_:)`` in a `@Sendable` `Progress` observer.
    private static func handler(
        reporting: @escaping @Sendable (DownloadProgress) -> Void
    ) -> @Sendable (Progress) -> Void {
        { progress in
            reporting(Self.mapProgress(progress))
        }
    }
}

/// The default ``ModelLoader`` when none is supplied. Every load throws
/// ``ModelLoaderError/notConfigured``.
public struct UnconfiguredModelLoader: ModelLoader {
    /// Creates the unconfigured sentinel loader.
    public init() {}

    /// Always throws ``ModelLoaderError/notConfigured``.
    public func loadLLM(
        ref: ModelRef,
        slot: ModelSlot,
        context: Int,
        reporting: @escaping @Sendable (DownloadProgress) -> Void
    ) async throws -> any LoadedLLMContainer {
        throw ModelLoaderError.notConfigured
    }

    /// Always throws ``ModelLoaderError/notConfigured``.
    public func loadEmbedder(
        ref: ModelRef,
        slot: ModelSlot,
        reporting: @escaping @Sendable (DownloadProgress) -> Void
    ) async throws -> any LoadedEmbeddingContainer {
        throw ModelLoaderError.notConfigured
    }

    /// Always throws ``ModelLoaderError/notConfigured``.
    public func preload(container: any LoadedModelContainer) async throws {
        throw ModelLoaderError.notConfigured
    }
}
