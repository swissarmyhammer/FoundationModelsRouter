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
import Synchronization
import os

/// The logger for the ceiling a live session backend applies to a call.
private let sessionBackendLogger = makeModuleLogger(category: "SessionBackend")

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
///
/// The container stores no decoding strategy. The mode belongs to the router
/// (`model-pool.md` §2.5): each `makeSession(...samplingMode:)` call gives
/// the backend it makes the mode that call names, so two routers over one
/// pooled container each decode with their own mode. A call that names no
/// mode gets the provider default.
package struct MLXFoundationModelsContainer: LoadedLLMContainer, Sendable {
    /// The `LanguageModel` conformance wrapping this slot's resident MLX model.
    let model: MLXLanguageModel

    /// The counter over the loaded model's own tokenizer. See
    /// ``LoadedLLMContainer/tokenCounter``.
    package let tokenCounter: any TokenCounter

    /// The `FoundationModels.LanguageModel` this container wraps.
    package var languageModel: any FoundationModels.LanguageModel { model }

    /// Makes a live session backend over ``model`` that decodes with the
    /// provider default.
    package func makeSession(instructions: String?) -> any LanguageModelSessionBackend {
        makeSession(instructions: instructions, tools: [], samplingMode: nil)
    }

    /// Makes a live session backend over ``model`` with `tools` that decodes
    /// with the provider default.
    package func makeSession(instructions: String?, tools: [any FoundationModels.Tool]) -> any LanguageModelSessionBackend {
        makeSession(instructions: instructions, tools: tools, samplingMode: nil)
    }

    /// Makes a live session backend seeded from `transcript`, with no tools,
    /// that decodes with the provider default.
    package func makeSession(transcript: FoundationModels.Transcript) -> any LanguageModelSessionBackend {
        makeSession(transcript: transcript, tools: [], samplingMode: nil)
    }

    /// Makes a live session backend seeded from `transcript` with `tools`
    /// that decodes with the provider default.
    package func makeSession(
        transcript: FoundationModels.Transcript,
        tools: [any FoundationModels.Tool]
    ) -> any LanguageModelSessionBackend {
        makeSession(transcript: transcript, tools: tools, samplingMode: nil)
    }

    /// Makes a live session backend over ``model`` that decodes with
    /// `samplingMode`, or with the provider default when `samplingMode` is
    /// `nil`.
    package func makeSession(
        instructions: String?, samplingMode: GenerationOptions.SamplingMode?
    ) -> any LanguageModelSessionBackend {
        makeSession(instructions: instructions, tools: [], samplingMode: samplingMode)
    }

    /// Makes a live session backend over ``model`` with `tools` that decodes
    /// with `samplingMode`, or with the provider default when `samplingMode`
    /// is `nil`.
    package func makeSession(
        instructions: String?, tools: [any FoundationModels.Tool], samplingMode: GenerationOptions.SamplingMode?
    ) -> any LanguageModelSessionBackend {
        let session = LanguageModelSession(model: model, tools: tools, instructions: instructions)
        return MLXFoundationModelsSessionBackend(
            session: session, model: model, instructions: instructions, tools: tools,
            samplingMode: samplingMode)
    }

    /// Makes a live session backend seeded from `transcript`, with no tools,
    /// that decodes with `samplingMode`, or with the provider default when
    /// `samplingMode` is `nil`.
    package func makeSession(
        transcript: FoundationModels.Transcript, samplingMode: GenerationOptions.SamplingMode?
    ) -> any LanguageModelSessionBackend {
        makeSession(transcript: transcript, tools: [], samplingMode: samplingMode)
    }

    /// Makes a live session backend seeded from `transcript` with `tools`
    /// that decodes with `samplingMode`, or with the provider default when
    /// `samplingMode` is `nil`. The backend derives its instructions from the
    /// leading `.instructions` entry of `transcript`.
    package func makeSession(
        transcript: FoundationModels.Transcript,
        tools: [any FoundationModels.Tool],
        samplingMode: GenerationOptions.SamplingMode?
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

    /// The output token count of one generation call, with the id of the last
    /// transcript entry that call left.
    private struct GenerationCallUsage {
        /// The output token count the call reported.
        let outputTokens: Int

        /// The id of the last transcript entry of the call.
        let lastEntryID: String
    }

    /// The usage of the last generation call of the most recent generating
    /// method, or `nil` before that method gave one.
    ///
    /// A lock guards it, because the stream path writes it from the task that
    /// drives the stream while the session reads it from its own actor.
    private let lastGenerationCall = Mutex<GenerationCallUsage?>(nil)

    /// What the newest snapshot of the stream in flight held, or `nil` before
    /// the stream gave one. See ``inFlightResponse()``.
    ///
    /// A lock guards it for the same reason as ``lastGenerationCall``.
    private let newestSnapshot = Mutex<InFlightResponse?>(nil)

    /// The token ceiling for a generation call whose caller gives no
    /// `maxTokens`.
    ///
    /// This is a floor, and not a policy. A routed session gives every call
    /// the ceiling it derives from the resolved context of its model (see
    /// ``RoutedSessionActor/responseTokenCeiling(requested:contextTokens:)``).
    /// This value applies only to a caller that reports no context and names
    /// no ceiling, so that the MLX executor still gets a finite budget.
    ///
    /// The number is not ``ProfileDefinition/defaultContext``. A log line
    /// that prints one of the two values then cannot be read as the other.
    /// `TurnTokenCeilingTests` keeps the two apart.
    static let responseTokenFloor = 8000

    /// Makes the generation options of one call on ``liveSession``.
    ///
    /// Each generation call uses this one helper, so the respond path and the
    /// stream path always decode with the same ``samplingMode`` and the same
    /// ceiling.
    ///
    /// - Parameter maxTokens: The ceiling the caller named, or `nil` for
    ///   ``responseTokenFloor``.
    /// - Returns: The options that carry ``samplingMode`` and the ceiling.
    private func makeGenerationOptions(maxTokens: Int?) -> GenerationOptions {
        GenerationOptions(samplingMode: samplingMode, maximumResponseTokens: appliedCeiling(maxTokens: maxTokens))
    }

    /// The ceiling one call decodes under.
    ///
    /// When the floor applies, one log line names the constant. A reader of
    /// the log can then tell ``responseTokenFloor`` from the context of a
    /// session, which is a different number.
    ///
    /// - Parameter maxTokens: The ceiling the caller named, or `nil` for
    ///   ``responseTokenFloor``.
    /// - Returns: `maxTokens` when the caller named one, else
    ///   ``responseTokenFloor``.
    private func appliedCeiling(maxTokens: Int?) -> Int {
        if let maxTokens { return maxTokens }
        sessionBackendLogger.notice(
            """
            the caller named no ceiling; the call decodes under \
            responseTokenFloor=\(Self.responseTokenFloor, privacy: .public)
            """
        )
        return Self.responseTokenFloor
    }

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

    /// The reasoning level that asks `MLXLanguageModel` to turn thinking off.
    ///
    /// `MLXLanguageModel` reads `.custom("no_think")`, and only that value, as
    /// "thinking off". For a model that turns thinking on and off with a chat
    /// template flag, the engine then renders the prompt with that flag off:
    /// for Qwen3, `enable_thinking` is `false` in the template's additional
    /// context. The flag applies to the one call that states this level.
    private static let thinkingOffReasoningLevel = ContextOptions.ReasoningLevel.custom("no_think")

    /// Generates a complete text response through ``liveSession`` with
    /// thinking off, when ``model`` turns thinking on and off with a chat
    /// template flag. Any other model generates as ``respond(to:maxTokens:)``
    /// does.
    ///
    /// The engine refuses "thinking off" for a model that always reasons and
    /// for a model with no thinking control. Thus this call asks for it only
    /// when the loaded model's reasoning strategy is a template flag.
    func respondWithoutReasoning(to prompt: String, maxTokens: Int?) async throws -> String {
        guard try await modelTurnsThinkingOffByTemplateFlag() else {
            return try await respond(to: prompt, maxTokens: maxTokens)
        }
        return try await respond(
            to: prompt, schema: nil, maxTokens: maxTokens,
            contextOptions: ContextOptions(reasoningLevel: Self.thinkingOffReasoningLevel))
    }

    /// Whether ``model`` is an `MLXLanguageModel` whose loaded configuration
    /// turns thinking on and off with a chat template flag.
    ///
    /// - Returns: `true` for a template-flag reasoning strategy, else `false`.
    /// - Throws: What loading the model's container throws.
    private func modelTurnsThinkingOffByTemplateFlag() async throws -> Bool {
        guard let mlxModel = model as? MLXLanguageModel else { return false }
        let configuration = await (try await mlxModel.loadContainer()).configuration
        guard case .templateFlag = configuration.reasoningConfig?.promptStrategy else { return false }
        return true
    }

    /// Runs ``liveSession`` and returns its response content. With a `schema`
    /// the decode is constrained to it and the result is its JSON string.
    ///
    /// - Parameters:
    ///   - prompt: The prompt text.
    ///   - schema: The schema that constrains the decode, or `nil`.
    ///   - maxTokens: The ceiling the caller named, or `nil`.
    ///   - contextOptions: The context options of this one call.
    /// - Returns: The response content.
    private func respond(
        to prompt: String,
        schema: GenerationSchema?,
        maxTokens: Int?,
        contextOptions: ContextOptions = ContextOptions()
    ) async throws -> String {
        let options = makeGenerationOptions(maxTokens: maxTokens)
        forgetLastGenerationCall()
        guard let schema else {
            let response = try await liveSession.respond(
                to: prompt, options: options, contextOptions: contextOptions)
            recordLastGenerationCall(usage: response.usage, entries: response.transcriptEntries)
            return response.content
        }
        let response = try await liveSession.respond(to: prompt, schema: schema, options: options)
        recordLastGenerationCall(usage: response.usage, entries: response.transcriptEntries)
        return response.content.jsonString
    }

    /// Clears the usage of the last generation call, so a generating method
    /// that starts now and gives no count never reads the count of an earlier
    /// method.
    private func forgetLastGenerationCall() {
        lastGenerationCall.withLock { $0 = nil }
        newestSnapshot.withLock { $0 = nil }
    }

    /// Keeps what one stream snapshot holds: a copy of its transcript
    /// entries, and the usage of its generation call.
    ///
    /// The entries are copied into an `Array`. The slice's indices point into
    /// the session's transcript, and a call that throws leaves no entry
    /// there, so the bounds would not stay valid.
    ///
    /// - Parameters:
    ///   - usage: The usage of the snapshot's generation call.
    ///   - entries: The transcript entries the method appended so far.
    private func keepNewestSnapshot(
        usage: LanguageModelSession.Usage, entries: ArraySlice<FoundationModels.Transcript.Entry>
    ) {
        let snapshot = InFlightResponse(
            entries: Array(entries), inputTokens: usage.input.totalTokenCount,
            outputTokens: usage.output.totalTokenCount)
        newestSnapshot.withLock { $0 = snapshot }
    }

    /// Returns what the newest snapshot of the stream in flight held.
    func inFlightResponse() -> InFlightResponse? {
        newestSnapshot.withLock { $0 }
    }

    /// Records the usage of the last generation call of a generating method.
    ///
    /// `LanguageModelSession.Response.usage` and the usage of a
    /// `ResponseStream` snapshot hold the usage of the generation call that
    /// made them, not the sum of the calls of the method. The session sums
    /// the calls in `LanguageModelSession.usage` alone.
    ///
    /// - Parameters:
    ///   - usage: The usage of the call.
    ///   - entries: The transcript entries the method appended up to that
    ///     call. Nothing is recorded when they are empty.
    private func recordLastGenerationCall(
        usage: LanguageModelSession.Usage, entries: ArraySlice<FoundationModels.Transcript.Entry>
    ) {
        guard let lastEntryID = entries.last?.id else { return }
        let call = GenerationCallUsage(outputTokens: usage.output.totalTokenCount, lastEntryID: lastEntryID)
        lastGenerationCall.withLock { $0 = call }
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
        let options = makeGenerationOptions(maxTokens: maxTokens)
        forgetLastGenerationCall()
        let fragments = SnapshotDeltaIterator(
            liveSession.streamResponse(to: prompt, options: options),
            content: { $0.content },
            entries: { $0.transcriptEntries },
            observe: { [self] snapshot in
                recordLastGenerationCall(usage: snapshot.usage, entries: snapshot.transcriptEntries)
                keepNewestSnapshot(usage: snapshot.usage, entries: snapshot.transcriptEntries)
            })
        return AsyncThrowingStream { try await fragments.next() }
    }

    /// Pulls cumulative snapshots and returns the fragment each one adds.
    /// ``next()`` must not be called concurrently.
    ///
    /// A snapshot that adds transcript entries and no text gives a fragment
    /// with empty text, whose ``ResponseFragment/progress`` names the newest
    /// entry. A tool-using turn thus reports its tool calls and tool results
    /// to the stall watch (task ^4799jxg).
    private final class SnapshotDeltaIterator<Snapshots: AsyncSequence>: @unchecked Sendable {
        /// The snapshot stream's own iterator, driven by ``next()``'s caller.
        private var iterator: Snapshots.AsyncIterator

        /// Reads a snapshot's cumulative text.
        private let content: (Snapshots.Element) -> String

        /// Reads the transcript entries a snapshot's method appended so far.
        private let entries: (Snapshots.Element) -> ArraySlice<FoundationModels.Transcript.Entry>

        /// Receives each snapshot the stream gives, before its text is read.
        private let observe: (Snapshots.Element) -> Void

        /// The snapshot before the current one, or the empty string at the start.
        private var previous = ""

        /// How many transcript entries the snapshot before the current one held.
        private var previousEntryCount = 0

        /// Creates an iterator that pulls from `snapshots`.
        ///
        /// - Parameters:
        ///   - snapshots: The snapshot stream to pull from.
        ///   - content: Reads the cumulative text of a snapshot.
        ///   - entries: Reads the transcript entries a snapshot holds.
        ///   - observe: Receives each snapshot, a repeated one included.
        init(
            _ snapshots: Snapshots,
            content: @escaping (Snapshots.Element) -> String,
            entries: @escaping (Snapshots.Element) -> ArraySlice<FoundationModels.Transcript.Entry>,
            observe: @escaping (Snapshots.Element) -> Void
        ) {
            self.iterator = snapshots.makeAsyncIterator()
            self.content = content
            self.entries = entries
            self.observe = observe
        }

        /// Returns the next fragment, or `nil` at the end of the stream. Skips
        /// snapshots that repeat without change.
        func next() async throws -> ResponseFragment? {
            while let snapshot = try await iterator.next() {
                observe(snapshot)
                let current = content(snapshot)
                let fragment = MLXFoundationModelsSessionBackend.fragment(of: current, after: previous)
                previous = current
                let appended = appendedEntryProgress(in: snapshot)
                if let fragment { return fragment }
                if let appended { return ResponseFragment(text: "", progress: appended) }
            }
            return nil
        }

        /// The kind of the newest entry `snapshot` added to the transcript, or
        /// `nil` when it added none. Records the entry count of `snapshot`.
        ///
        /// - Parameter snapshot: The snapshot just pulled.
        /// - Returns: The progress kind of the newest added entry, or `nil`.
        private func appendedEntryProgress(in snapshot: Snapshots.Element) -> GenerationProgressKind? {
            let current = entries(snapshot)
            let previousCount = previousEntryCount
            previousEntryCount = current.count
            guard current.count > previousCount, let newest = current.last else { return nil }
            return GenerationProgressKind(appending: newest)
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

    /// Returns the output token count of the last generation call of the most
    /// recent generating method. Call it under the turn lock.
    ///
    /// The recorded count is given only while the transcript of
    /// ``liveSession`` still ends at the last entry of the recorded call. The
    /// stream gives no snapshot for a last call that sends no text, so the
    /// last snapshot can be one of an earlier call of the same method. Its
    /// entries then end before the entries of the last call.
    func lastGenerationCallOutputTokenCount() -> Int? {
        guard let call = lastGenerationCall.withLock({ $0 }) else { return nil }
        guard call.lastEntryID == liveSession.transcript.last?.id else { return nil }
        return call.outputTokens
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
enum ModelLoaderError: Error, Equatable {
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

    /// Creates a live loader.
    ///
    /// The loader stores no decoding strategy. A container it vends serves
    /// every router in the pool, and the mode belongs to the router
    /// (`model-pool.md` §2.5): pass it to `Router.init(samplingMode:)`.
    ///
    /// - Parameter weightsLocation: Resolves a model id to its on-disk weights directory. The default never resolves a real path.
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

    /// Downloads and loads a generation model. The weights load before the
    /// container is returned.
    ///
    /// Cancelling the calling task stops the wait. The transfer itself runs on,
    /// which is what keeps the part files filling the Hugging Face cache — see
    /// ``CancellableWait``.
    ///
    /// - Throws: `CancellationError` when the calling task is cancelled, or if
    ///   the download or MLX container load fails.
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
        let container = try await CancellableWait.value { try await model.loadContainer() }
        // The tokenizer the model was loaded with counts every token the
        // router counts before a call (see ``TokenCounter``).
        let tokenizer = await container.tokenizer
        return MLXFoundationModelsContainer(
            model: model, tokenCounter: TokenizerTokenCounter(tokenizer: tokenizer))
    }

    /// Downloads and loads an embedding model. One probe embedding finds the
    /// dimension before the container is returned.
    ///
    /// Cancelling the calling task stops the wait. The transfer itself runs on,
    /// which is what keeps the part files filling the Hugging Face cache — see
    /// ``CancellableWait``.
    ///
    /// - Throws: `CancellationError` when the calling task is cancelled, or if
    ///   the download, MLX container load, or dimension probe fails.
    public func loadEmbedder(
        ref: ModelRef,
        slot: ModelSlot,
        reporting: @escaping @Sendable (DownloadProgress) -> Void
    ) async throws -> any LoadedEmbeddingContainer {
        let downloader = self.downloader
        let tokenizerLoader = self.tokenizerLoader
        let modelConfiguration = configuration(for: ref)
        let container = try await CancellableWait.value {
            try await EmbedderModelFactory.shared.loadContainer(
                from: downloader,
                using: tokenizerLoader,
                configuration: modelConfiguration,
                progressHandler: Self.handler(reporting: reporting)
            )
        }
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
