import Foundation
import FoundationModels
import FoundationModelsExtras
import HuggingFace
import MLXFoundationModels
import MLXLLM
// Load-bearing although this file names no `MLXVLM` symbol: keep it. The
// Extras `MLXModelLoader` loads each generation model with
// `loadModelContainer`, which selects a factory through `MLXLMCommon`'s
// `ModelFactoryRegistry`. The registry finds its built-in trampolines with
// `NSClassFromString` — a factory whose module the linker dropped is
// silently absent from that list, and Extras links no `MLXVLM`. `MLXLLM`
// above is imported for the same reason. Muse Glimmer (`muse_glimmer`), the
// model the gated suites load, is registered only in `VLMModelFactory`, so
// without this import the id throws `unsupportedModelType` *after* paying
// for the whole download.
import MLXVLM
import Synchronization

// The MLX container types are the live loaded handles. They are `final class …:
// Sendable`, so conforming them to the router's marker protocols lets
// ``LiveModelLoader`` vend real generation and embedding through the same
// orchestration the unit suite drives with stubs. These are the milestone-7
// live seams: ``MLXFoundationModelsContainer`` runs the real `LanguageModelSession`
// (`FoundationModels`) pipeline over an `MLXLanguageModel` conformance, and
// ``LoadedPooledEmbedding`` gives the router the embedding model that the
// Extras `MLXModelLoader` loads.
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

/// The live ``LoadedLLMContainer``. Wraps an `MLXLanguageModel` and makes the
/// ``LanguageModelSessionBackend`` every generation call runs through. The
/// Extras `MLXModelLoader` makes and loads the model; the router makes no
/// `MLXLanguageModel` itself (see ``make(wrapping:repo:)``).
///
/// The container stores no decoding strategy. The mode belongs to the router:
/// each `makeSession(...samplingMode:)` call gives
/// the backend it makes the mode that call names, so two routers over one
/// pooled container each decode with their own mode. A call that names no
/// mode gets the provider default.
///
/// The container holds no queue and no lock. Each backend runs over a new
/// per-session ``SessionLanguageModel``, whose passes call the model through
/// `PooledGeneration.run(ref:channel:_:)` of FoundationModelsExtras. The FIFO
/// lock of the MLX model serializes the generations, one generation at a
/// time, and no tool body runs under it.
package struct MLXFoundationModelsContainer: LoadedLLMContainer, Sendable {
    /// The raw `LanguageModel` conformance of this slot's resident MLX model.
    /// The eviction of the loader and the thinking control of a backend read
    /// it; generation runs over a ``SessionLanguageModel`` that wraps it.
    let model: MLXLanguageModel

    /// The model reference of ``model``. Each pass of each backend of this
    /// container names it in the in-flight meter.
    let ref: ModelRef

    /// The window of ``model``, in tokens: the native max context its
    /// `config.json` declares. Each backend this container makes sends it
    /// as the ceiling of a call that names none.
    let contextWindow: Int

    /// The counter over the loaded model's own tokenizer. See
    /// ``LoadedLLMContainer/tokenCounter``.
    package let tokenCounter: any TokenCounter

    /// Makes a container over a resident model.
    ///
    /// - Parameters:
    ///   - model: The raw `LanguageModel` conformance of the resident model.
    ///   - ref: The model reference of `model`.
    ///   - contextWindow: The window of `model`, in tokens.
    ///   - tokenCounter: The counter over the tokenizer of `model`.
    init(model: MLXLanguageModel, ref: ModelRef, contextWindow: Int, tokenCounter: any TokenCounter) {
        self.model = model
        self.ref = ref
        self.contextWindow = contextWindow
        self.tokenCounter = tokenCounter
    }

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
        MLXFoundationModelsSessionBackend(
            model: model, ref: ref, contextWindow: contextWindow,
            instructions: instructions, tools: tools, samplingMode: samplingMode)
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
        MLXFoundationModelsSessionBackend(
            model: model, ref: ref, contextWindow: contextWindow,
            transcript: transcript, tools: tools, samplingMode: samplingMode)
    }
}

/// An `MLXLanguageModel` turns its reasoning off for one call when its
/// loaded configuration turns the reasoning on and off with a chat template
/// flag (task ^0dcsd3t). The engine refuses "reasoning off" for any other
/// strategy: a model that always reasons, and a model with no control of its
/// reasoning.
extension MLXLanguageModel: ReasoningSwitchable {
    /// Whether the loaded configuration of this model turns the reasoning on
    /// and off with a chat template flag.
    ///
    /// - Returns: `true` for a template-flag reasoning strategy, else `false`.
    /// - Throws: What loading the container of the model throws.
    func canTurnReasoningOff() async throws -> Bool {
        let configuration = await (try await loadContainer()).configuration
        guard case .templateFlag = configuration.reasoningConfig?.promptStrategy else { return false }
        return true
    }
}

/// The live ``LanguageModelSessionBackend``. Wraps one `LanguageModelSession`
/// for the lifetime of the backend. The caller must not make two calls on one
/// backend at the same time.
final class MLXFoundationModelsSessionBackend: LanguageModelSessionBackend, Sendable {
    /// The raw `LanguageModel` conformance. The session of this backend runs
    /// over a per-session ``SessionLanguageModel`` that wraps it, and a fork
    /// builds a new wrapper over it.
    private let model: any FoundationModels.LanguageModel

    /// The model reference of ``model``. Each pass of the session of this
    /// backend names it in the in-flight meter. This backend, its forks and
    /// its replaced transcripts name it.
    let ref: ModelRef

    /// The live session every call on this backend runs through.
    private let liveSession: LanguageModelSession

    /// The per-session state of the ``SessionLanguageModel`` that
    /// ``liveSession`` runs over. The session that owns this backend installs
    /// its pass observer here (``reportPasses(to:)``).
    private let sessionModelState: SessionLanguageModelState

    /// The system instructions ``liveSession`` was created with, or `nil`.
    private let instructions: String?

    /// The tools ``liveSession`` was created with.
    private let tools: [any FoundationModels.Tool]

    /// The decoding strategy every generation call requests, or `nil` for the
    /// provider default.
    private let samplingMode: GenerationOptions.SamplingMode?

    /// The window of ``model``, in tokens. A call that names no ceiling sends
    /// it as `maximumResponseTokens`.
    private let contextWindow: Int

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

    /// Makes the generation options of one call on ``liveSession``.
    ///
    /// Each generation call uses this one helper, so the respond path and the
    /// stream path always decode with the same ``samplingMode`` and the same
    /// ceiling.
    ///
    /// A routed session gives every call the ceiling it derives from the
    /// resolved context of its model and its pass token limit (see
    /// ``ResponseTokenCeiling``).
    /// A caller that names no ceiling gets ``contextWindow``, the window of
    /// the model. The backend never sends `nil`, so the default ceiling of the
    /// engine never applies to a call of the router.
    ///
    /// - Parameter maxTokens: The ceiling the caller named, or `nil` when the
    ///   caller named none.
    /// - Returns: The options that carry ``samplingMode`` and `maxTokens`, or
    ///   ``contextWindow`` when `maxTokens` is `nil`.
    private func makeGenerationOptions(maxTokens: Int?) -> GenerationOptions {
        GenerationOptions(samplingMode: samplingMode, maximumResponseTokens: maxTokens ?? contextWindow)
    }

    /// Test-only accessor onto ``liveSession``. Not part of the protocol.
    // periphery:ignore
    internal var session: LanguageModelSession { liveSession }

    /// Creates a backend over a new session. This initializer is the one
    /// place that makes the per-session ``SessionLanguageModel``: it wraps
    /// `model` and gives the wrapper to `makeSession`.
    ///
    /// - Parameters:
    ///   - model: The raw `LanguageModel` conformance that the session's
    ///     wrapper wraps.
    ///   - ref: The model reference of `model`.
    ///   - contextWindow: The window of `model`, in tokens. A call that names
    ///     no ceiling sends it as `maximumResponseTokens`.
    ///   - instructions: The system instructions of the session, or `nil`.
    ///   - tools: The tools of the session.
    ///   - samplingMode: The decoding strategy, or `nil` for the provider default.
    ///   - makeSession: Makes the live session every call runs through, over
    ///     the new per-session wrapper it receives.
    private init(
        model: any FoundationModels.LanguageModel,
        ref: ModelRef,
        contextWindow: Int,
        instructions: String?,
        tools: [any FoundationModels.Tool],
        samplingMode: GenerationOptions.SamplingMode?,
        makeSession: (SessionLanguageModel) -> LanguageModelSession
    ) {
        let sessionModel = SessionLanguageModel(wrapping: model, ref: ref)
        let liveSession = makeSession(sessionModel)
        let state = sessionModel.state
        self.liveSession = liveSession
        self.sessionModelState = state
        self.model = model
        self.ref = ref
        self.contextWindow = contextWindow
        self.instructions = instructions
        self.tools = tools
        self.samplingMode = samplingMode
    }

    /// Creates a backend over a new session with `instructions`, which runs
    /// over a new per-session ``SessionLanguageModel`` that wraps `model`.
    ///
    /// - Parameters:
    ///   - model: The raw `LanguageModel` conformance.
    ///   - ref: The model reference of `model`.
    ///   - contextWindow: The window of `model`, in tokens. A call that names
    ///     no ceiling sends it as `maximumResponseTokens`.
    ///   - instructions: The system instructions of the session, or `nil`.
    ///   - tools: The tools of the session.
    ///   - samplingMode: The decoding strategy, or `nil` for the provider default.
    convenience init(
        model: any FoundationModels.LanguageModel,
        ref: ModelRef,
        contextWindow: Int,
        instructions: String?,
        tools: [any FoundationModels.Tool],
        samplingMode: GenerationOptions.SamplingMode? = nil
    ) {
        self.init(
            model: model, ref: ref, contextWindow: contextWindow,
            instructions: instructions, tools: tools, samplingMode: samplingMode
        ) { sessionModel in
            LanguageModelSession(model: sessionModel, tools: SessionToolLayers.checked(tools), instructions: instructions)
        }
    }

    /// Creates a backend over a new session seeded from `transcript`, which
    /// runs over a new per-session ``SessionLanguageModel`` that wraps `model`.
    ///
    /// - Parameters:
    ///   - model: The raw `LanguageModel` conformance.
    ///   - ref: The model reference of `model`.
    ///   - contextWindow: The window of `model`, in tokens.
    ///   - transcript: The transcript to seed the session from.
    ///   - tools: The tools of the session.
    ///   - samplingMode: The decoding strategy, or `nil` for the provider default.
    ///   - instructions: The instructions of the backend. The outer `nil`
    ///     derives them from the leading `.instructions` entry of
    ///     `transcript`. A non-`nil` outer value, including `.some(nil)`, is
    ///     used as given.
    convenience init(
        model: any FoundationModels.LanguageModel,
        ref: ModelRef,
        contextWindow: Int,
        transcript: FoundationModels.Transcript,
        tools: [any FoundationModels.Tool],
        samplingMode: GenerationOptions.SamplingMode? = nil,
        instructions: String?? = nil
    ) {
        self.init(
            model: model, ref: ref, contextWindow: contextWindow,
            instructions: instructions ?? TranscriptDiffer.leadingInstructionsText(of: transcript),
            tools: tools, samplingMode: samplingMode
        ) { sessionModel in
            LanguageModelSession(model: sessionModel, tools: SessionToolLayers.checked(tools), transcript: transcript)
        }
    }

    /// Generates a complete text response through ``liveSession``.
    func respond(to prompt: String, maxTokens: Int?) async throws -> String {
        try await respond(to: prompt, schema: nil, maxTokens: maxTokens)
    }

    /// Generates a complete text response through ``liveSession`` with
    /// thinking off, when ``model`` can turn its reasoning off. Any other
    /// model generates as ``respond(to:maxTokens:)`` does.
    ///
    /// The call is ``respond(to:maxTokens:)`` under a
    /// ``ReasoningOffRequest``, so the reasoning level comes from the one
    /// place that states it for each call (``prepareCall(includingSchema:)``).
    /// The summarizer call of a compaction is the one caller. On each tier,
    /// it runs on a backend with no tools
    /// (``LanguageModelSessionBackend/replacingTranscript(_:tools:)``), so its
    /// one pass is its first pass.
    func respondWithoutReasoning(to prompt: String, maxTokens: Int?) async throws -> String {
        try await ReasoningOffRequest.$isRequested.withValue(true) {
            try await respond(to: prompt, maxTokens: maxTokens)
        }
    }

    /// The raw ``model`` as an `MLXLanguageModel`, or `nil` for any other
    /// model. It reads the raw model, never the per-session wrapper of the
    /// session, so the cast finds the MLX model behind the queue.
    ///
    /// The tests of the queue read it: a fork and a replaced transcript keep
    /// the raw MLX model.
    // periphery:ignore
    var mlxLanguageModel: MLXLanguageModel? { model as? MLXLanguageModel }

    /// Whether the first pass of the call that starts now runs with the
    /// reasoning of ``model`` off: the task asks for it
    /// (``ReasoningOffRequest/isRequested``), and the raw model can turn its
    /// reasoning off (``ReasoningSwitchable``).
    ///
    /// The engine refuses "reasoning off" for a model that always reasons and
    /// for a model with no control of its reasoning. Thus a call asks for it
    /// only when the model says that it can.
    ///
    /// - Returns: `true` when the first pass states ``ReasoningOffRequest/reasoningLevel``.
    /// - Throws: What the read of the model configuration throws.
    private func callTurnsReasoningOff() async throws -> Bool {
        guard ReasoningOffRequest.isRequested, let switchable = model as? any ReasoningSwitchable else {
            return false
        }
        return try await switchable.canTurnReasoningOff()
    }

    /// Prepares the call that starts now: states the reasoning level of its
    /// first pass, and gives its context options.
    ///
    /// Each call starts from the default of the SDK for its kind: a call
    /// under a schema keeps the schema in its prompt, and any other call
    /// gets `ContextOptions()`. The options of the call state no reasoning
    /// level, because the SDK gives them to each pass of the tool loop of
    /// the call. When the call turns the reasoning off
    /// (``callTurnsReasoningOff()``), only its first pass states
    /// ``ReasoningOffRequest/reasoningLevel``
    /// (``SessionLanguageModelState/setFirstPassReasoningLevel(_:)``, task
    /// ^bhdj5v9). Each later pass of its tool loop reasons as usual.
    ///
    /// - Parameter includingSchema: Whether the call decodes under a schema.
    /// - Returns: The context options of the call.
    /// - Throws: What the read of the model configuration throws.
    private func prepareCall(includingSchema: Bool) async throws -> ContextOptions {
        let firstPassLevel = try await callTurnsReasoningOff() ? ReasoningOffRequest.reasoningLevel : nil
        sessionModelState.setFirstPassReasoningLevel(firstPassLevel)
        return includingSchema ? ContextOptions(includeSchemaInPrompt: true) : ContextOptions()
    }

    /// The fragments of one stream call of ``liveSession``.
    ///
    /// - Parameters:
    ///   - prompt: The prompt text.
    ///   - options: The generation options of the call.
    ///   - contextOptions: The context options of the call.
    /// - Returns: The iterator that gives the fragments of the call.
    private func fragments(
        of prompt: String, options: GenerationOptions, contextOptions: ContextOptions
    ) -> SnapshotDeltaIterator<LanguageModelSession.ResponseStream<String>> {
        SnapshotDeltaIterator(
            liveSession.streamResponse(to: prompt, options: options, contextOptions: contextOptions),
            content: { $0.content },
            entries: { $0.transcriptEntries },
            observe: { [self] snapshot in
                recordLastGenerationCall(usage: snapshot.usage, entries: snapshot.transcriptEntries)
                keepNewestSnapshot(usage: snapshot.usage, entries: snapshot.transcriptEntries)
            })
    }

    /// Runs ``liveSession`` and returns its response content. With a `schema`
    /// the decode is constrained to it and the result is its JSON string.
    ///
    /// - Parameters:
    ///   - prompt: The prompt text.
    ///   - schema: The schema that constrains the decode, or `nil`.
    ///   - maxTokens: The ceiling the caller named, or `nil`.
    /// - Returns: The response content.
    private func respond(to prompt: String, schema: GenerationSchema?, maxTokens: Int?) async throws -> String {
        let options = makeGenerationOptions(maxTokens: maxTokens)
        let contextOptions = try await prepareCall(includingSchema: schema != nil)
        forgetLastGenerationCall()
        guard let schema else {
            let response = try await liveSession.respond(
                to: prompt, options: options, contextOptions: contextOptions)
            recordLastGenerationCall(usage: response.usage, entries: response.transcriptEntries)
            return response.content
        }
        let response = try await liveSession.respond(
            to: prompt, schema: schema, options: options, contextOptions: contextOptions)
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

    /// Gives the transcript of ``liveSession`` each time it changes inside a
    /// pass of a call.
    ///
    /// `LanguageModelSession` is `Observable`, and its transcript grows while
    /// a call is in flight, reasoning included. A read loop reads it at each
    /// change (``relayTranscript(of:into:)``), in a pass watch of the wrapper
    /// of the session (``SessionLanguageModelState/addPassWatch(_:)``): each
    /// pass starts a new loop, and the end of the pass cancels the loop and
    /// waits for it. The SDK writes the transcript with no guard between two
    /// passes of a tool loop, and a read in that window aborts the process
    /// (task ^vg6bmq6). The first value of each pass holds what the SDK wrote
    /// between the passes. The reader ends the stream, and the watch is then
    /// taken out.
    func transcriptUpdates() -> AsyncStream<[FoundationModels.Transcript.Entry]> {
        let session = liveSession
        let state = sessionModelState
        return AsyncStream { continuation in
            let watch = state.addPassWatch {
                await Self.relayTranscript(of: session, into: continuation)
            }
            continuation.onTermination = { _ in state.removePassWatch(watch) }
        }
    }

    /// Gives the transcript of `session` to `continuation` now and after each
    /// change of it, until the task is cancelled.
    ///
    /// - Parameters:
    ///   - session: The session whose transcript to read.
    ///   - continuation: The stream that gets each value.
    private static func relayTranscript(
        of session: LanguageModelSession,
        into continuation: AsyncStream<[FoundationModels.Transcript.Entry]>.Continuation
    ) async {
        await observeTranscript(of: session) { entries in
            continuation.yield(entries)
            return true
        }
    }

    /// Gives the transcript of `session` to `read` now and after each change
    /// of it, until `read` returns `false` or the task is cancelled.
    ///
    /// The loop reads the transcript only on its own task, and a cancel ends
    /// the wait for the next change at once: the wait is on an `AsyncStream`,
    /// which ends at a cancel. A loop over `Observations` in its place hung
    /// the stress test of task ^vg6bmq6 in 3 of 3 runs: at times its
    /// iteration does not end at the cancel of the pass, and the pass then
    /// waits for a change that comes only after the pass returns.
    ///
    /// - Parameters:
    ///   - session: The session whose transcript to read.
    ///   - read: Takes each value, and returns whether to read the next one.
    private static func observeTranscript(
        of session: LanguageModelSession, _ read: ([FoundationModels.Transcript.Entry]) -> Bool
    ) async {
        let (changes, change) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        var wakes = changes.makeAsyncIterator()
        repeat {
            let entries = withObservationTracking(options: .didSet) {
                Array(session.transcript)
            } onChange: { event in
                event.cancel()
                change.yield()
            }
            guard read(entries) else { return }
        } while await wakes.next() != nil
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
    /// A call under a ``ReasoningOffRequest`` starts the stream call of the
    /// session at the first read of the stream: the reasoning level of its
    /// first pass needs a read of the model configuration, which is `async`
    /// (``prepareCall(includingSchema:)``). Any other call starts the stream
    /// call at once, and its first pass states no reasoning level.
    ///
    /// - Returns: A stream of fragments. It throws if generation fails.
    func streamResponseFragments(
        to prompt: String,
        maxTokens: Int?
    ) -> AsyncThrowingStream<ResponseFragment, Error> {
        let options = makeGenerationOptions(maxTokens: maxTokens)
        forgetLastGenerationCall()
        guard ReasoningOffRequest.isRequested else {
            sessionModelState.setFirstPassReasoningLevel(nil)
            let fragments = fragments(of: prompt, options: options, contextOptions: ContextOptions())
            return AsyncThrowingStream { try await fragments.next() }
        }
        let deferred = DeferredFragments { [self] in
            try await ReasoningOffRequest.$isRequested.withValue(true) {
                fragments(of: prompt, options: options, contextOptions: try await prepareCall(includingSchema: false))
            }
        }
        return AsyncThrowingStream { try await deferred.next() }
    }

    /// The fragments of a stream call that starts at the first read.
    ///
    /// The actor isolates the state. ``next()`` must not be called
    /// concurrently, as for ``SnapshotDeltaIterator``: a second call during
    /// the first read can start a second stream call.
    private actor DeferredFragments {
        /// Starts the stream call, and gives its fragments.
        private let start: @Sendable () async throws -> SnapshotDeltaIterator<LanguageModelSession.ResponseStream<String>>

        /// The fragments of the stream call, or `nil` before the first read.
        private var fragments: SnapshotDeltaIterator<LanguageModelSession.ResponseStream<String>>?

        /// Keeps `start` for the first read.
        ///
        /// - Parameter start: Starts the stream call, and gives its fragments.
        init(
            start: @escaping @Sendable () async throws -> SnapshotDeltaIterator<LanguageModelSession.ResponseStream<String>>
        ) {
            self.start = start
        }

        /// Returns the next fragment, or `nil` at the end of the stream. The
        /// first read starts the stream call.
        func next() async throws -> ResponseFragment? {
            if fragments == nil {
                fragments = try await start()
            }
            return try await fragments?.next()
        }
    }

    /// Pulls cumulative snapshots and returns the fragment each one adds.
    ///
    /// The actor isolates the state. ``next()`` must not be called
    /// concurrently: each call pulls from the one snapshot iterator.
    ///
    /// A snapshot that adds transcript entries and no text gives a fragment
    /// with empty text, whose ``ResponseFragment/progress`` names the newest
    /// entry. A tool-using submission thus reports its tool calls and tool results
    /// to the stall watch (task ^4799jxg).
    private actor SnapshotDeltaIterator<Snapshots: AsyncSequence> {
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
            while let snapshot = try await nextSnapshot() {
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

        /// Pulls the next snapshot from ``iterator`` on this actor.
        ///
        /// An actor property cannot be an `inout` argument of an `async`
        /// call. Thus the pull uses a copy of ``iterator``, and the copy
        /// replaces ``iterator`` when the pull ends.
        ///
        /// - Returns: The next snapshot, or `nil` at the end of the stream.
        /// - Throws: What the snapshot stream throws.
        private func nextSnapshot() async throws -> Snapshots.Element? {
            var pulling = iterator
            defer { iterator = pulling }
            return try await pulling.next(isolation: self)
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
    /// session, with the same ``tools`` and ``instructions``. A fork is a
    /// new session, so its session runs over a new per-session wrapper, and
    /// it names the same model reference.
    func makeFork() -> any LanguageModelSessionBackend {
        MLXFoundationModelsSessionBackend(
            model: model,
            ref: ref,
            contextWindow: contextWindow,
            transcript: liveSession.transcript,
            tools: tools,
            samplingMode: samplingMode,
            instructions: instructions
        )
    }

    /// Makes a new backend over ``model`` seeded from `transcript`, with this
    /// backend's ``tools``. Its session runs over a new per-session wrapper,
    /// and it names the same model reference.
    func replacingTranscript(_ transcript: FoundationModels.Transcript) -> any LanguageModelSessionBackend {
        replacingTranscript(transcript, tools: tools)
    }

    /// Makes a new backend over ``model`` seeded from `transcript`, with
    /// `tools` in place of this backend's ``tools``. Its session runs over a
    /// new per-session wrapper, and it names the same model reference.
    func replacingTranscript(
        _ transcript: FoundationModels.Transcript, tools: [any FoundationModels.Tool]
    ) -> any LanguageModelSessionBackend {
        MLXFoundationModelsSessionBackend(
            model: model, ref: ref, contextWindow: contextWindow,
            transcript: transcript, tools: tools, samplingMode: samplingMode)
    }

    /// Returns the current transcript of ``liveSession``. Call it only where
    /// ``LanguageModelSessionBackend/transcriptEntries()`` allows.
    func transcriptEntries() -> [FoundationModels.Transcript.Entry] {
        Array(liveSession.transcript)
    }

    /// Returns the cumulative token usage of ``liveSession``. Call it only
    /// where ``LanguageModelSessionBackend/usageTokenCounts()`` allows.
    func usageTokenCounts() -> (input: Int, output: Int)? {
        let usage = liveSession.usage
        return (usage.input.totalTokenCount, usage.output.totalTokenCount)
    }

    /// Returns the cumulative input tokens that the prompt cache of the
    /// executor reused for ``liveSession``. Call it only where
    /// ``LanguageModelSessionBackend/cachedInputTokenCount()`` allows.
    func cachedInputTokenCount() -> Int? {
        liveSession.usage.input.cachedTokenCount
    }

    /// Returns the output token count of the last generation call of the most
    /// recent generating method. Call it only from the pump of the owning
    /// session.
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

extension MLXFoundationModelsSessionBackend: GenerationPassReporting {
    /// Gives `observer` the passes of ``liveSession``, through the
    /// per-session state of its wrapper (task ^ake8sax). A fork and a
    /// replaced transcript are new backends with a new wrapper, so each
    /// reports to the observer its own session installs.
    ///
    /// - Parameter observer: The observer of the session that owns this
    ///   backend.
    func reportPasses(to observer: GenerationPassObserver) {
        sessionModelState.reportPasses(to: observer)
    }
}

extension MLXFoundationModelsSessionBackend: SessionPromptCacheScoping {
    /// Keys the prompt cache of each later pass of ``liveSession`` by
    /// `sessionID`, through the per-session state of its wrapper (task
    /// ^cc2tezn). A fork and a replaced transcript are new backends with a
    /// new wrapper, so the session that adopts each one installs its id
    /// again.
    ///
    /// - Parameter sessionID: The id of the session that owns this backend.
    func scopePromptCache(toSession sessionID: String) {
        sessionModelState.scopePromptCache(toSession: sessionID)
    }

    /// Makes each later pass of ``liveSession`` keep no prompt cache, through
    /// the per-session state of its wrapper (task ^ptev9yy). The executor of
    /// the wrapper binds `.uncached` on the task of each pass.
    func keepNoPromptCache() {
        sessionModelState.keepNoPromptCache()
    }

    /// Releases the prompt cache of `sessionID` on ``model``, when ``model``
    /// keeps a prompt cache for each session.
    ///
    /// - Parameter sessionID: The id that the passes of the session bound.
    func releasePromptCache(ofSession sessionID: String) async {
        await (model as? any SessionPromptCacheReleasing)?.releasePromptCache(sessionID: sessionID)
    }
}

/// The router container of an embedding model that the model loader of
/// ``LiveModelLoader`` loaded, for example the Extras `MLXModelLoader`. The
/// router makes no MLX embedder itself: this container only gives the
/// router's ``LoadedEmbeddingContainer`` shape to the ``PooledEmbedding`` of
/// that loader.
struct LoadedPooledEmbedding: LoadedEmbeddingContainer {
    /// The embedding model that the model loader returned. The eviction
    /// gives it back to that loader.
    let embedding: any PooledEmbedding

    /// Takes the container that the model loader returned for `key`.
    ///
    /// - Parameters:
    ///   - container: The container that the model loader returned.
    ///   - key: The embedding key of the load.
    /// - Throws: ``PooledEmbedderError/notAnEmbedding(key:containerType:)``
    ///   when `container` does not conform to ``PooledEmbedding``.
    init(container: any Sendable, of key: ModelPoolKey) throws {
        guard let embedding = container as? any PooledEmbedding else {
            throw PooledEmbedderError.notAnEmbedding(
                key: key, containerType: String(describing: type(of: container)))
        }
        self.embedding = embedding
    }

    /// Gives one vector for each text through ``embedding``.
    ///
    /// - Parameter texts: The texts.
    /// - Returns: One vector for each text, in the order of `texts`.
    /// - Throws: What the embedding model throws.
    func embed(texts: [String]) async throws -> [[Float]] {
        try await embedding.embed(texts: texts)
    }
}

/// A failure constructing or invoking a ``ModelLoader``.
public enum ModelLoaderError: Error, Equatable {
    /// No real loader was configured. See ``UnconfiguredModelLoader``.
    case notConfigured
}

/// A failure of a load of ``LiveModelLoader``.
public enum LiveModelLoaderError: Error, Equatable, LocalizedError {
    /// The model loader gave a container of the type `containerType` for the
    /// generation key `key`, which is not an `MLXLanguageModel`.
    case notAnMLXLanguageModel(key: ModelPoolKey, containerType: String)

    /// A message that tells what is wrong.
    public var errorDescription: String? {
        switch self {
        case .notAnMLXLanguageModel(let key, let containerType):
            """
            The model loader gave a \(containerType) for \(key.ref.stringValue), which is not an \
            MLXLanguageModel. The live loader wraps only an MLXLanguageModel in a generation container.
            """
        }
    }
}

/// The live ``ModelLoader``. Each model loads through the Extras
/// `MLXModelLoader`, the one MLX loader of the family, which downloads the
/// model when the Hugging Face cache does not hold it. The router wraps a
/// generation model in a live generation container, and wraps an embedding
/// model in an embedding container.
///
/// It is also a loader of the Extras model pool (``PooledModelLoader``), which
/// loads by ``ModelPoolKey`` only. An application that does not use a
/// ``Router`` (for example a model registry) can make one and give it to the
/// Extras pool. A load through the Extras protocol gives each step of the
/// model loader to the progress handler of the pool, and the bytes of each
/// download to the `reporting` callback of the init. A router load reports
/// the bytes of each download to the callback of its resolve.
public struct LiveModelLoader: ModelLoader, PooledModelLoader {
    /// Receives the download progress of each load through the Extras loader
    /// protocol: ``load(_:)`` and ``load(key:progressHandler:)``.
    private let reporting: @Sendable (DownloadProgress) -> Void

    /// The loader of each model: `MLXModelLoader` in a live loader. The pool
    /// evicts each container through it too. It is not private, thus a unit
    /// test can read the cache folder of the `MLXModelLoader` that the public
    /// init makes.
    let modelLoader: any PooledModelLoader

    /// Creates a live loader. The init needs no ``Router``.
    ///
    /// The loader stores no decoding strategy. A container it vends serves
    /// every router in the pool, and the mode belongs to the router:
    /// pass it to `Router.init(samplingMode:)`.
    ///
    /// The cache folder holds only the models. The sizing metadata of a
    /// router is in a different folder: pass that folder to
    /// `Router.init(cacheDir:)`.
    ///
    /// ```swift
    /// let support = URL.applicationSupportDirectory
    /// let router = Router(
    ///     cacheDir: support.appending(path: "RouterMetadata"),
    ///     loader: LiveModelLoader(cacheDirectory: support.appending(path: "Models")))
    /// ```
    ///
    /// A host with its own home gives one token provider to the loader and to
    /// the metadata source of its router, so the downloads and the sizing send
    /// the token of the host, and not the token in the Hugging Face folder of
    /// the user:
    ///
    /// ```swift
    /// let token: TokenProvider = .custom { try? String(contentsOf: tokenFile, encoding: .utf8) }
    /// let router = Router(
    ///     metadataSource: HuggingFaceMetadataSource(tokenProvider: token),
    ///     loader: LiveModelLoader(tokenProvider: token))
    /// ```
    ///
    /// - Parameters:
    ///   - reporting: Receives the download progress of each load through
    ///     ``load(_:)`` and ``load(key:progressHandler:)``. The default drops
    ///     each value. A router load does not use it: it reports to the
    ///     callback of its resolve.
    ///   - cacheDirectory: The Hugging Face cache folder of the models. Each
    ///     download writes to this folder, and each load reads the weights
    ///     from it, also when `HF_HUB_CACHE` or `HF_HOME` names a different
    ///     folder. `nil` (the default) uses the default Hugging Face cache,
    ///     which reads these variables.
    ///   - tokenProvider: The provider of the token of each download, a
    ///     `TokenProvider` of swift-huggingface, which the Extras
    ///     `MLXModelLoader` gives to its Hub client. The default `.environment`
    ///     reads `HF_TOKEN` and `~/.cache/huggingface/token`. `.none` sends no
    ///     token.
    public init(
        reporting: @escaping @Sendable (DownloadProgress) -> Void = { _ in }, cacheDirectory: URL? = nil,
        tokenProvider: TokenProvider = .environment
    ) {
        self.init(
            reporting: reporting,
            modelLoader: MLXModelLoader(cacheDirectory: cacheDirectory, tokenProvider: tokenProvider))
    }

    /// Creates a live loader whose models load through `modelLoader`. A test
    /// gives a loader that needs no network. The real-model test support
    /// gives an Extras `MLXModelLoader` with a tokenizer loader that pins the
    /// date of the chat template, so the init is `package`.
    ///
    /// - Parameters:
    ///   - reporting: Receives the download progress of each load through
    ///     ``load(_:)`` and ``load(key:progressHandler:)``.
    ///   - modelLoader: The loader of each model.
    package init(reporting: @escaping @Sendable (DownloadProgress) -> Void, modelLoader: any PooledModelLoader) {
        self.reporting = reporting
        self.modelLoader = modelLoader
    }

    /// Loads the model of `key` for the Extras model pool: a generation model
    /// for ``ModelRole/llm`` and an embedding model for
    /// ``ModelRole/embedding``. Reports the download progress to the
    /// `reporting` callback of the init. See
    /// ``load(key:progressHandler:)``.
    ///
    /// - Parameter key: The model and its role.
    /// - Returns: A live generation container for ``ModelRole/llm``, or an
    ///   embedding container for ``ModelRole/embedding``.
    /// - Throws: `CancellationError` when the calling task is cancelled, or if
    ///   the download or the load fails.
    public func load(_ key: ModelPoolKey) async throws -> any Sendable {
        try await load(key: key) { _ in }
    }

    /// Loads the model of `key` for the Extras model pool, as ``load(_:)``
    /// does. Gives each step of the model loader to `progressHandler`: the
    /// real bytes of each download, and then the load. Also reports the bytes
    /// of each download to the `reporting` callback of the init.
    ///
    /// - Parameters:
    ///   - key: The model and its role.
    ///   - progressHandler: Gets each step of the load. It can run on any
    ///     thread.
    /// - Returns: A live generation container for ``ModelRole/llm``, or an
    ///   embedding container for ``ModelRole/embedding``.
    /// - Throws: `CancellationError` when the calling task is cancelled, or if
    ///   the download or the load fails.
    public func load(
        key: ModelPoolKey, progressHandler: @escaping @Sendable (ModelLoadProgress) -> Void
    ) async throws -> any Sendable {
        let reportDownload = Self.downloadHandler(reporting: reporting)
        let handler: @Sendable (ModelLoadProgress) -> Void = { progress in
            progressHandler(progress)
            reportDownload(progress)
        }
        switch key.role {
        case .llm: return try await loadGeneration(ref: key.ref, progressHandler: handler)
        case .embedding: return try await loadEmbedding(ref: key.ref, progressHandler: handler)
        }
    }

    /// Loads a generation model through the model loader: the Extras
    /// `MLXModelLoader` in a live loader, which downloads the model when the
    /// cache does not hold it. The weights load before the container is
    /// returned. The live loader uses neither `slot` nor `context`.
    ///
    /// Cancelling the calling task stops the wait. The transfer itself runs on,
    /// which is what keeps the part files filling the Hugging Face cache, so a
    /// later load continues that same transfer.
    ///
    /// - Throws: `CancellationError` when the calling task is cancelled, the
    ///   error of the model loader or of the wrap of the model, or
    ///   ``LiveModelLoaderError/notAnMLXLanguageModel(key:containerType:)``
    ///   when the model loader gives no `MLXLanguageModel`.
    public func loadLLM(
        ref: ModelRef,
        slot: ModelSlot,
        context: Int,
        reporting: @escaping @Sendable (DownloadProgress) -> Void
    ) async throws -> any LoadedLLMContainer {
        try await loadGeneration(ref: ref, progressHandler: Self.downloadHandler(reporting: reporting))
    }

    /// Loads a generation model through the model loader, gives each step of
    /// the load to `progressHandler`, and wraps
    /// the model in a live container. When the wrap fails, the model loader
    /// evicts the model, so no model stays in memory with no owner. See
    /// ``loadLLM(ref:slot:context:reporting:)``.
    ///
    /// - Parameters:
    ///   - ref: The model to load.
    ///   - progressHandler: Gets each step of the load.
    /// - Returns: The loaded generation container.
    /// - Throws: `CancellationError` when the calling task is cancelled, the
    ///   error of the model loader or of the wrap, or
    ///   ``LiveModelLoaderError/notAnMLXLanguageModel(key:containerType:)``.
    private func loadGeneration(
        ref: ModelRef, progressHandler: @escaping @Sendable (ModelLoadProgress) -> Void
    ) async throws -> MLXFoundationModelsContainer {
        let key = ModelPoolKey(ref: ref, role: .llm)
        let loaded = try await loadThroughModelLoader(key, progressHandler: progressHandler)
        do {
            guard let model = loaded as? MLXLanguageModel else {
                throw LiveModelLoaderError.notAnMLXLanguageModel(
                    key: key, containerType: String(describing: type(of: loaded)))
            }
            return try await MLXFoundationModelsContainer.make(wrapping: model, ref: ref)
        } catch {
            await modelLoader.evict(loaded)
            throw error
        }
    }

    /// Loads an embedding model through the model loader: the Extras
    /// `MLXModelLoader` in a live loader, which downloads the model when the
    /// cache does not hold it. The live loader does not use `slot`.
    ///
    /// Cancelling the calling task stops the wait. The transfer itself runs on,
    /// which is what keeps the part files filling the Hugging Face cache, so a
    /// later load continues that same transfer.
    ///
    /// - Throws: `CancellationError` when the calling task is cancelled, the
    ///   error of the model loader, or
    ///   ``PooledEmbedderError/notAnEmbedding(key:containerType:)`` when the
    ///   model loader gives no ``PooledEmbedding``.
    public func loadEmbedder(
        ref: ModelRef,
        slot: ModelSlot,
        reporting: @escaping @Sendable (DownloadProgress) -> Void
    ) async throws -> any LoadedEmbeddingContainer {
        try await loadEmbedding(ref: ref, progressHandler: Self.downloadHandler(reporting: reporting))
    }

    /// Loads an embedding model through the model loader, and gives each step
    /// of the load to `progressHandler`. See
    /// ``loadEmbedder(ref:slot:reporting:)``.
    ///
    /// - Parameters:
    ///   - ref: The model to load.
    ///   - progressHandler: Gets each step of the load.
    /// - Returns: The loaded embedding container.
    /// - Throws: `CancellationError` when the calling task is cancelled, the
    ///   error of the model loader, or
    ///   ``PooledEmbedderError/notAnEmbedding(key:containerType:)``.
    private func loadEmbedding(
        ref: ModelRef, progressHandler: @escaping @Sendable (ModelLoadProgress) -> Void
    ) async throws -> LoadedPooledEmbedding {
        let key = ModelPoolKey(ref: ref, role: .embedding)
        let container = try await loadThroughModelLoader(key, progressHandler: progressHandler)
        return try LoadedPooledEmbedding(container: container, of: key)
    }

    /// Loads the model of `key` through the model loader, and gives each step
    /// of the load to `progressHandler`.
    ///
    /// Cancelling the calling task stops the wait. The transfer itself runs
    /// on (``CancellableWait``).
    ///
    /// - Parameters:
    ///   - key: The model and its role.
    ///   - progressHandler: Gets each step of the load.
    /// - Returns: The container that the model loader gave.
    /// - Throws: `CancellationError` when the calling task is cancelled, or
    ///   the error of the model loader.
    private func loadThroughModelLoader(
        _ key: ModelPoolKey, progressHandler: @escaping @Sendable (ModelLoadProgress) -> Void
    ) async throws -> any Sendable {
        let modelLoader = self.modelLoader
        return try await CancellableWait.value {
            try await modelLoader.load(key: key, progressHandler: progressHandler)
        }
    }

    /// A progress handler that gives the bytes of each download step to
    /// `reporting`, and ignores each other step. The router shows the load
    /// step itself: a resolve marks a slot `loading` when the acquire of the
    /// slot returns.
    ///
    /// - Parameter reporting: Receives the bytes of each download step.
    /// - Returns: The progress handler.
    private static func downloadHandler(
        reporting: @escaping @Sendable (DownloadProgress) -> Void
    ) -> @Sendable (ModelLoadProgress) -> Void {
        { progress in
            guard case .downloading(let completedBytes, let totalBytes) = progress else { return }
            reporting(DownloadProgress(bytesDownloaded: completedBytes, bytesTotal: totalBytes))
        }
    }

    /// A no-op: the load paths already load weights.
    public func preload(container: any LoadedModelContainer) async throws {}

    /// Gives a live generation container or an embedding container back to
    /// the model loader. A no-op for any other container. The router
    /// eviction goes through the Extras loader protocol, ``evict(_:)``.
    public func evict(container: any LoadedModelContainer) async {
        await evict(container as any Sendable)
    }

    /// Evicts a container that ``load(_:)`` returned, for the Extras model
    /// pool: the model loader evicts the model of a live generation container
    /// or of an embedding container. A no-op for any other container.
    ///
    /// - Parameter container: The container to evict.
    public func evict(_ container: any Sendable) async {
        switch container {
        case let generation as MLXFoundationModelsContainer:
            await modelLoader.evict(generation.model)
        case let embedding as LoadedPooledEmbedding:
            await modelLoader.evict(embedding.embedding)
        default:
            return
        }
    }

    /// Measures the bytes of the model of `key` for the Extras model pool,
    /// through the model loader: the Extras `MLXModelLoader` in a live loader,
    /// which measures the weights of the model in its cache folder. A pool
    /// that the application gives this loader counts the result as the
    /// footprint of the model.
    ///
    /// - Parameter key: The model that ``load(_:)`` loaded.
    /// - Returns: The bytes that the model loader measures.
    /// - Throws: The error of the measure of the model loader.
    public func footprintBytes(of key: ModelPoolKey) async throws -> Int64 {
        try await modelLoader.footprintBytes(of: key)
    }

    /// Sends the memory budget to the process-wide prompt cache of the fork,
    /// `MLXLanguageModel.configurePromptCache(memoryBudgetBytes:)`. The fork
    /// applies it at once: a smaller budget moves the least recently used
    /// entries to its disk spool before the call returns.
    ///
    /// The fork API is on its `stable` branch at `ffac55d` (2026-09-25) and
    /// later. Both `Package.resolved` files (the root package and
    /// `IntegrationTests/`) resolve `stable` to
    /// `ffac55d4e9e0f75d30347c561cea042b674be831`.
    ///
    /// The Router does not set the disk budget. It keeps the fork default: one
    /// quarter of the free space of the volume of the spool folder, read at the
    /// first use. The Router knows nothing about the disk that the fork does
    /// not know, and a file on disk costs no memory. A read of a spilled entry
    /// costs much less than the prefill it saves, so a larger disk budget than
    /// the default has no clear gain.
    ///
    /// - Parameter memoryBudgetBytes: The most bytes the prompt-cache entries
    ///   in memory may hold.
    public func configurePromptCache(memoryBudgetBytes: Int) async {
        await MLXLanguageModel.configurePromptCache(memoryBudgetBytes: memoryBudgetBytes)
    }

    /// The bytes the process-wide prompt cache of the fork holds now,
    /// `MLXLanguageModel.promptCacheUsage`.
    public var promptCacheUsage: PromptCacheUsage {
        get async {
            let usage = await MLXLanguageModel.promptCacheUsage
            return PromptCacheUsage(
                memoryBytes: usage.memoryBytes,
                spillingBytes: usage.spillingBytes,
                diskBytes: usage.diskBytes
            )
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
