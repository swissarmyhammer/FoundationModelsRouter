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

/// The default token budget for the live generation paths.
///
/// Applies when a caller does not supply its own `maxTokens`, so a routed
/// turn cannot run away. Plain and guided generation share the same default —
/// there is no principled reason for guided decode to get a different ceiling.
private let defaultMaxTokens = 8192

/// Builds a session backend directly from a transcript.
///
/// Shared by ``MLXFoundationModelsContainer/makeSession(transcript:tools:)``,
/// ``MLXFoundationModelsSessionBackend/replacingTranscript(_:)``, and
/// ``MLXFoundationModelsSessionBackend/makeFork(tools:)`` — all three build a
/// fresh `LanguageModelSession` directly over an existing transcript and wrap
/// it in a new ``MLXFoundationModelsSessionBackend``.
///
/// The three differ only in where the new backend's
/// ``MLXFoundationModelsSessionBackend/instructions`` comes from: the first
/// two have no live parent backend to copy them from (`transcript` may have
/// come from disk, long after any originating session existed), so they
/// derive instructions from `transcript`'s own leading `.instructions` entry
/// — the only place a transcript carries them forward, since there is no
/// `LanguageModelSession` initializer that accepts both `transcript:` and
/// `instructions:` together. `makeFork(tools:)` *does* have a live parent
/// backend, so it threads that backend's own retained instructions through
/// verbatim instead of re-deriving them.
///
/// `instructions` captures that choice as a doubly-optional parameter: the
/// outer optional selects the source (`nil`, the default, means "derive from
/// `transcript`"; any non-`nil` value — including `.some(nil)` — means "use
/// this verbatim, don't re-derive"), and the inner optional is the
/// instructions text itself, which is legitimately `nil` when a session
/// (forked or otherwise) carries none. This is the same "leave unchanged
/// vs. replace with `nil`" idiom ``TranscriptEvent/Partial/with(text:tokensIn:tokensOut:entry:)``
/// already uses for the same reason.
///
/// - Parameters:
///   - model: The `LanguageModel` conformance to build the new session over.
///   - transcript: The transcript to seed the new session from.
///   - tools: The tools the model can call during this session.
///   - samplingMode: The decoding strategy every generation call on the new
///     backend requests — see
///     ``MLXFoundationModelsContainer/samplingMode``.
///   - instructions: The new backend's instructions, or `nil` (the default)
///     to derive them from `transcript`'s own leading `.instructions` entry.
/// - Returns: A new ``MLXFoundationModelsSessionBackend`` a vended
///   ``RoutedSession`` drives for its lifetime.
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

/// The live ``LoadedLLMContainer``.
///
/// Wraps an `MLXLanguageModel` — the `FoundationModels.LanguageModel` protocol
/// conformance `MLXFoundationModels` provides over a resident MLX
/// `ModelContainer` — and manufactures the ``LanguageModelSessionBackend``
/// every generation call actually runs through.
///
/// This container no longer invokes generation itself (see
/// ``LoadedLLMContainer/makeSession(instructions:)``); ``makeSession(instructions:)``
/// below vends a ``MLXFoundationModelsSessionBackend`` that drives a real
/// `LanguageModelSession` built over ``model``, and
/// ``makeSession(transcript:)`` vends one seeded from an existing transcript
/// instead — the factory a restored session tree rebuilds from. Constructing
/// a session is cheap either way: `MLXLanguageModel` is a small `Sendable`
/// value whose actual weights are loaded once and cached by its own
/// process-global cache, keyed by model id — building a session over it does
/// not reload anything.
///
/// `package` rather than `internal`, and deliberately not `public`: the
/// `FoundationModelsRouterRealModelSupport` target's `RealModelContainer`
/// narrows every gated suite's loaded `any LoadedLLMContainer` to this
/// concrete type, and its `CompactionFold` opens blank-slate summarizer
/// sessions over it — a plain target cannot use `@testable import`, and
/// `package` stops at this package's own boundary, so the library's public
/// surface does not move (task ^cvsh3m9). The witnesses below are `package`
/// for the same reason, and because a witness must be at least as accessible
/// as the conforming type.
package struct MLXFoundationModelsContainer: LoadedLLMContainer, Sendable {
    /// The `LanguageModel` conformance wrapping this slot's resident MLX model.
    let model: MLXLanguageModel

    /// The decoding strategy every generation call on every backend this
    /// container vends requests, or `nil` (the usual case) to leave the
    /// provider's own default in place.
    ///
    /// The default is not deterministic, and neither is a repeat run of the
    /// same prompt under it: `MLXLMCommon.GenerateParameters.temperature`
    /// defaults to `0.6` — a sampling value — so MLX builds a categorical
    /// sampler that draws from `MLXRandom`'s process-global `RandomState`,
    /// which seeds itself from the clock (`DispatchTime.now().uptimeNanoseconds`).
    /// The same prompt against the same resident model therefore yields
    /// different text in every process.
    ///
    /// Pinning ``FoundationModels/GenerationOptions/SamplingMode/greedy`` here
    /// routes MLX to `ArgMaxSampler`, which consumes no randomness at all — so
    /// a caller that needs generation it can repeat, rather than merely a
    /// fixed seed it must not perturb, gets it. That is what the gated
    /// real-model suites need to be a decision procedure: while their model's
    /// replies vary run to run, so do the transcript sizes those replies
    /// produce, and a red run cannot be attributed to the change under test.
    let samplingMode: GenerationOptions.SamplingMode?

    /// The raw `FoundationModels.LanguageModel` this container wraps — the
    /// seam ``RoutedModel/makeLanguageModel()`` wraps in a
    /// ``RecordingLanguageModel`` passthrough handle. `MLXLanguageModel` is a
    /// small `Sendable` value (see the type-level doc comment above), so
    /// exposing it here reloads nothing.
    package var languageModel: any FoundationModels.LanguageModel { model }

    /// Manufactures a live session backend over ``model``.
    ///
    /// - Parameter instructions: The session's system instructions, or `nil`.
    /// - Returns: A new ``MLXFoundationModelsSessionBackend`` a vended
    ///   ``RoutedSession`` drives for its lifetime.
    package func makeSession(instructions: String?) -> any LanguageModelSessionBackend {
        makeSession(instructions: instructions, tools: [])
    }

    /// Manufactures a live session backend over ``model``, with `tools`
    /// threaded to the underlying `LanguageModelSession` so the model can call
    /// them.
    ///
    /// - Parameters:
    ///   - instructions: The session's system instructions, or `nil`.
    ///   - tools: The tools the model can call during this session.
    /// - Returns: A new ``MLXFoundationModelsSessionBackend`` a vended
    ///   ``RoutedSession`` drives for its lifetime.
    package func makeSession(instructions: String?, tools: [any FoundationModels.Tool]) -> any LanguageModelSessionBackend {
        let session = LanguageModelSession(model: model, tools: tools, instructions: instructions)
        return MLXFoundationModelsSessionBackend(
            session: session, model: model, instructions: instructions, tools: tools, samplingMode: samplingMode)
    }

    /// Manufactures a live session backend seeded from an existing transcript.
    ///
    /// Delegates to ``makeSession(transcript:tools:)`` with no tools — mirrors
    /// how ``makeSession(instructions:)`` delegates to
    /// ``makeSession(instructions:tools:)``.
    ///
    /// - Parameter transcript: The transcript to seed the new session from.
    /// - Returns: A new ``MLXFoundationModelsSessionBackend`` a vended
    ///   ``RoutedSession`` drives for its lifetime.
    package func makeSession(transcript: FoundationModels.Transcript) -> any LanguageModelSessionBackend {
        makeSession(transcript: transcript, tools: [])
    }

    /// Manufactures a live session backend seeded from an existing transcript,
    /// with `tools` threaded to the underlying `LanguageModelSession` so the
    /// model can call them — the seam a restored session tree
    /// (``RoutedModel/restoreSessionTree(root:recordingRoot:tools:)``) needs to
    /// give a restored node real, live tool-calling instead of `tools: []`.
    ///
    /// Builds the new `LanguageModelSession` directly over `transcript` via
    /// `LanguageModelSession(model:tools:transcript:)` — the identical public
    /// initializer ``MLXFoundationModelsSessionBackend/makeFork(tools:)`` calls
    /// to seed a forked session from a parent's accumulated transcript. Unlike a
    /// fork, this factory has no live parent backend to copy `instructions`
    /// from (`transcript` may have come from disk, long after any originating
    /// session existed), so the new backend's retained ``instructions`` are
    /// derived from `transcript`'s own `.instructions` entry when present —
    /// the only place a transcript carries them forward, since there is no
    /// `LanguageModelSession` initializer that accepts both `transcript:` and
    /// `instructions:` together.
    ///
    /// - Parameters:
    ///   - transcript: The transcript to seed the new session from.
    ///   - tools: The tools the model can call during this session.
    /// - Returns: A new ``MLXFoundationModelsSessionBackend`` a vended
    ///   ``RoutedSession`` drives for its lifetime.
    package func makeSession(
        transcript: FoundationModels.Transcript,
        tools: [any FoundationModels.Tool]
    ) -> any LanguageModelSessionBackend {
        makeSessionBackend(model: model, transcript: transcript, tools: tools, samplingMode: samplingMode)
    }
}

/// The live ``LanguageModelSessionBackend``.
///
/// Wraps a real `LanguageModelSession` — held for this backend's entire
/// lifetime, not rebuilt per call — so it accumulates conversation state (the
/// transcript) across calls the way a real multi-turn chat does: a second
/// ``respond(to:maxTokens:)`` sees the first turn's content in context.
///
/// `@unchecked Sendable`: `LanguageModelSession` is itself `@unchecked
/// Sendable` (confirmed: `extension FoundationModels::LanguageModelSession :
/// @unchecked Swift::Sendable` in the macOS 27 SDK interface), which only
/// certifies the type as safe to *hold* across an isolation boundary, not
/// safe for *concurrent* calls. Concurrent access to this backend's
/// ``session`` is safe in practice because every call runs inside
/// ``RoutedSessionActor``'s `turnLock` — an `AsyncSemaphore` at value 1, held
/// for the whole of every turn on the owning session — so at most one call
/// against a given session's backend is ever in flight at a time, and the
/// nested per-model `generationGate` further limits actual generation to one
/// call across that model's whole family of sessions; this backend's session is
/// never actually touched from two tasks concurrently despite being a reference
/// type.
final class MLXFoundationModelsSessionBackend: LanguageModelSessionBackend, @unchecked Sendable {
    /// The `LanguageModel` conformance ``makeFork()`` builds its forked session
    /// over, seeded from this backend's own accumulated transcript.
    ///
    /// Held as the `FoundationModels.LanguageModel` existential rather than as
    /// the concrete `MLXLanguageModel` the live loader supplies. Nothing here
    /// needs the concrete type — the session is built through
    /// `LanguageModelSession(model:tools:transcript:)`, which takes
    /// `some LanguageModel` — and widening it is what lets a deterministic,
    /// weightless `LanguageModel` conformance drive this exact backend, so
    /// ``streamResponseFragments(to:maxTokens:)`` and ``respond(to:schema:maxTokens:)``
    /// have coverage that needs no GPU.
    private let model: any FoundationModels.LanguageModel

    /// The live session every call on this backend runs through, accumulating
    /// conversation state (the transcript) for this backend's lifetime.
    private let liveSession: LanguageModelSession

    /// The system instructions ``liveSession`` was created with, or `nil`.
    ///
    /// `LanguageModelSession` exposes no `instructions` accessor of its own —
    /// the only trace of them is the `Transcript.Entry.instructions` case
    /// `liveSession.transcript` carries as its first entry when instructions
    /// were supplied. Stored here explicitly (rather than re-derived from the
    /// transcript on demand) so ``makeFork()`` can hand it straight to the
    /// forked backend, keeping every backend in a fork chain able to report
    /// the instructions it was seeded with without re-parsing transcript
    /// entries.
    private let instructions: String?

    /// The tools ``liveSession`` was created with.
    ///
    /// Stored (rather than only baked into `liveSession`) so ``makeFork()``
    /// (called with no fork-composed tool list of its own to supply) can
    /// hand these identical instances to the forked session, mirroring how
    /// ``instructions`` is retained here for the same reason — there is no
    /// way to read a `LanguageModelSession`'s tools back off it.
    /// ``makeFork(tools:)`` threads a caller-supplied list instead, so this
    /// field only ever matters to the zero-argument overload.
    private let tools: [any FoundationModels.Tool]

    /// The decoding strategy every generation call this backend makes
    /// requests, or `nil` to leave the provider's own default in place —
    /// carried verbatim from the container that vended this backend (see
    /// ``MLXFoundationModelsContainer/samplingMode``) and propagated to every
    /// backend derived from this one, so a fork and a post-fold replacement
    /// decode exactly as their parent did.
    private let samplingMode: GenerationOptions.SamplingMode?

    /// Test-only accessor onto ``liveSession``, for `@testable import` in the
    /// gated integration suite (e.g. asserting `transcript.count` grows across
    /// turns, or matches a fork's parent at fork time). Deliberately not part
    /// of ``LanguageModelSessionBackend`` — this is test-only surface, not
    /// something a caller of the protocol should drive.
    ///
    /// ``liveSession`` is `private`, thus no code outside this type can
    /// read it, and `@testable import` does not raise `private`. This
    /// accessor must therefore stay here. Only the suites in the
    /// IntegrationTests package read it, and periphery reads only this
    /// package's index, thus it finds no reader.
    // periphery:ignore
    internal var session: LanguageModelSession { liveSession }

    /// Creates a backend over an already-constructed session and the model it
    /// was built over. `model` is kept alongside so ``makeFork()`` can build a
    /// forked session of the same type, continuing this session's transcript.
    ///
    /// - Parameters:
    ///   - session: The live `LanguageModelSession` this backend drives.
    ///   - model: The `LanguageModel` conformance `session` was built over.
    ///   - instructions: The system instructions `session` was created with,
    ///     or `nil`. Stored so ``makeFork()`` can propagate it to the forked
    ///     backend; see ``instructions``.
    ///   - tools: The tools `session` was created with. Stored so
    ///     ``makeFork()`` can propagate them to the forked backend; see
    ///     ``tools``. Defaults to none.
    ///   - samplingMode: The decoding strategy every generation call this
    ///     backend makes requests, or `nil` (the default) to leave the
    ///     provider's own default in place; see ``samplingMode``.
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

    /// Runs ``liveSession`` and returns its response content, constrained to
    /// `schema` when one is given.
    ///
    /// Shared by ``respond(to:maxTokens:)`` and the `.jsonSchema` case of
    /// ``respond(to:following:maxTokens:)``: both call the matching
    /// `session.respond` overload with the same prompt and options, and differ
    /// only in whether a schema is supplied and in how the resulting content is
    /// stringified.
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

    /// Streams a text response through ``liveSession``.
    ///
    /// Adapts its snapshot-based stream into this seam's delta (fragment)
    /// contract.
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

    /// Streams ``liveSession``'s response as ``ResponseFragment``s, reporting a
    /// restart whenever a snapshot abandons the response so far.
    ///
    /// The override the protocol's doc comment names: this backend's session
    /// runs the SDK's own tool loop, which closes the pre-tool
    /// `Transcript.Response` entry, runs the tool, and resumes generation into
    /// a new one — so a snapshot after a tool boundary does not extend the one
    /// before it, and only the last response is what
    /// ``respond(to:maxTokens:)`` returns.
    ///
    /// Pull-based, like the protocol's default implementation: an independent
    /// relay `Task` between ``liveSession``'s snapshot stream and this stream
    /// is a second, separately-cancellable consumer. A cancellation that
    /// propagates through `onTermination` can land after that task received a
    /// snapshot but before it forwarded the fragment, and the delivered text
    /// is dropped — a violation of "a cancelled stream is truncated, never
    /// retracted" (the default implementation's doc comment in
    /// LanguageModelSessionBackend.swift gives the full account). Pulling
    /// straight from the snapshot stream's own iterator removes that second
    /// consumer: this stream's only consumer is the same one the SDK stream
    /// sees.
    ///
    /// - Parameters:
    ///   - prompt: The prompt to respond to.
    ///   - maxTokens: The response token ceiling, or `nil` for this backend's
    ///     own default.
    /// - Returns: A stream of fragments, finishing when generation completes or
    ///   throwing if it fails.
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

    /// Pulls ``liveSession``'s cumulative snapshots and returns the fragment
    /// each snapshot adds, from whatever task calls ``next()``.
    ///
    /// The pull-based replacement for the relay-task pattern
    /// ``streamResponseFragments(to:maxTokens:)`` removed (see its doc comment
    /// for why the relay task is a correctness bug). Keeps the delta state
    /// (``previous``) across calls, so each snapshot is measured against the
    /// snapshot before it and a repeated snapshot yields no fragment.
    ///
    /// `@unchecked Sendable`: ``iterator`` and ``previous`` change without a
    /// lock. This is sound only because an `AsyncThrowingStream` has exactly
    /// one active reader at a time by contract — the same reasoning the
    /// protocol extension's private `ChunkIterator` documents.
    private final class SnapshotDeltaIterator<Snapshots: AsyncSequence>: @unchecked Sendable {
        /// The snapshot stream's own iterator, driven by ``next()``'s caller.
        private var iterator: Snapshots.AsyncIterator

        /// Reads a snapshot's cumulative text.
        private let content: (Snapshots.Element) -> String

        /// The snapshot before the current one, or the empty string at the
        /// start of the turn.
        private var previous = ""

        /// Creates an iterator that pulls from `snapshots`.
        ///
        /// - Parameters:
        ///   - snapshots: The cumulative-snapshot stream to pull from.
        ///   - content: Reads a snapshot's cumulative text.
        init(_ snapshots: Snapshots, content: @escaping (Snapshots.Element) -> String) {
            self.iterator = snapshots.makeAsyncIterator()
            self.content = content
        }

        /// The next fragment, or `nil` when the snapshot stream ends.
        ///
        /// Skips a snapshot that repeats without a change, so a `nil` result
        /// always means the stream ended.
        ///
        /// - Returns: The next fragment, or `nil` at the end of the stream.
        /// - Throws: If the snapshot stream fails.
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

    /// The fragment `current` adds to `previous`, or `nil` when the snapshot
    /// repeated without changing.
    ///
    /// A cumulative snapshot that extends the one before it contributes its new
    /// suffix, continuing the response. A snapshot that does *not* extend it is
    /// a new response — measured, not assumed: a tool-using turn against a real
    /// `LanguageModelSession` yields the snapshot sequence
    /// `["PRETOOL ", …, "FINAL-ANSWER", …]` while `respond(to:)` on the same
    /// turn returns `"FINAL-ANSWER"` alone, because the SDK closed one
    /// `Transcript.Response` entry at the tool boundary and opened another. Its
    /// whole text is therefore the new response's text so far, carried as a
    /// restarting fragment so an accumulator replaces rather than appends —
    /// appending is what left the superseded pre-tool text as a spurious prefix
    /// of the answer.
    ///
    /// - Parameters:
    ///   - current: The snapshot just received.
    ///   - previous: The snapshot before it, or the empty string at the start
    ///     of the turn.
    /// - Returns: The fragment to deliver, or `nil` when `current` equals
    ///   `previous` and there is nothing new to say.
    private static func fragment(of current: String, after previous: String) -> ResponseFragment? {
        guard current != previous else { return nil }
        guard current.hasPrefix(previous) else {
            return ResponseFragment(text: current, restartsResponse: true)
        }
        return ResponseFragment(text: String(current.dropFirst(previous.count)))
    }

    /// Generates a grammar-constrained response through ``liveSession``.
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
            return try await respond(to: prompt, schema: schema, maxTokens: maxTokens)
        }
    }

    /// Vends a fresh backend seeded from this session's accumulated transcript.
    ///
    /// `LanguageModelSession.init(model:tools:transcript:)` is the real
    /// transcript-continuation primitive the FoundationModels v2 SDK provides
    /// (see plan.md's "Sessions & KV cache" section for why this is a
    /// correctness primitive, not a cheap-prefix-reuse one, against the pinned
    /// `mlx-swift-lm` dependency): the forked session begins holding every
    /// entry ``liveSession``'s transcript has accumulated so far — including
    /// the `Transcript.Entry.instructions` entry the parent's system
    /// instructions were recorded as, if any — then diverges independently as
    /// each session's own further turns append to its own transcript.
    ///
    /// ``instructions`` is threaded into the new backend alongside the
    /// transcript-seeded session, so the fork reports the same instructions
    /// the parent was created with (there is no `LanguageModelSession`
    /// initializer that accepts both `transcript:` and `instructions:`
    /// together — the transcript's own `.instructions` entry is what actually
    /// carries them forward into generation). Delegates to
    /// ``makeFork(tools:)`` with ``tools`` (this backend's own, unchanged) so
    /// the forked session's model can still call whatever tools the parent
    /// could — the only behavior a direct `makeFork()` call (bypassing
    /// ``RoutedSessionActor/fork(workingDirectory:)``) can ask for, since it
    /// has no fork-composed tool list of its own to supply.
    func makeFork() -> any LanguageModelSessionBackend {
        makeFork(tools: tools)
    }

    /// Produces a new backend seeded from this session's accumulated
    /// transcript, with `tools` threaded to the forked `LanguageModelSession`
    /// instead of this backend's own.
    ///
    /// This is the overload ``RoutedSessionActor/fork(workingDirectory:)``
    /// actually calls, with its own fork-then-detach composed child tool
    /// list (each of the parent's true originals forked via
    /// ``ForkableTool/forked()`` where applicable, then wrapped in the
    /// child's own binding layer — ``RunToCompletionTool`` or
    /// ``BackgroundTool`` for a String-output tool, ``ContextBindingTool``
    /// for a non-String-output one — posting
    /// to its own outbox) — so the
    /// live model backing the fork calls the child's own tool instances,
    /// wired to the child's own outbox, rather than silently carrying
    /// forward whatever instances this backend was built with (which would
    /// still be wired to an ancestor's outbox, defeating the fork-then-detach
    /// composition's whole point for any tool the model actually invokes).
    ///
    /// Delegates to ``makeSessionBackend(model:transcript:tools:samplingMode:instructions:)``,
    /// passing ``instructions`` explicitly so the forked backend reports this
    /// backend's own instructions verbatim rather than re-deriving them from
    /// the (identical, at fork time) transcript.
    func makeFork(tools: [any FoundationModels.Tool]) -> any LanguageModelSessionBackend {
        makeSessionBackend(
            model: model,
            transcript: liveSession.transcript,
            tools: tools,
            samplingMode: samplingMode,
            instructions: instructions
        )
    }

    /// Vends a fresh backend over ``model``, seeded from `transcript` instead
    /// of ``liveSession``'s own accumulated history.
    ///
    /// The mechanism ``RoutedSessionActor/compact(prompt:budget:)`` swaps its
    /// inner session through in place once folding actually changes
    /// something: `transcript` there is `Compactor`'s folded output, built
    /// via the identical `LanguageModelSession(model:tools:transcript:)`
    /// initializer ``makeFork(tools:)`` uses, so the new backend picks up
    /// generation exactly where the fold left off. This session's own
    /// ``tools`` carry forward unchanged (compaction never affects
    /// tool-calling capability); ``instructions`` are re-derived from
    /// `transcript`'s own leading `.instructions` entry — mirroring
    /// ``MLXFoundationModelsContainer/makeSession(transcript:)`` — since a
    /// fold's header is never touched (compaction_plan.md §1.3's
    /// "instructions never modified or dropped" invariant) and so always
    /// still carries them when this session had any.
    ///
    /// Also how ``compact(prompt:budget:)``'s model-assisted summarization
    /// stage gets a disposable, blank-slate one-shot backend to call:
    /// `transcript` there is empty, so the resulting session carries no
    /// accumulated history to either leak between independent map-reduce
    /// calls or double up against the very content being summarized.
    ///
    /// - Parameter transcript: The transcript to seed the new backend from.
    /// - Returns: A new ``MLXFoundationModelsSessionBackend`` over the same
    ///   ``model``, whose accumulated history begins with `transcript`'s
    ///   entries.
    func replacingTranscript(_ transcript: FoundationModels.Transcript) -> any LanguageModelSessionBackend {
        makeSessionBackend(model: model, transcript: transcript, tools: tools, samplingMode: samplingMode)
    }

    /// Returns ``liveSession``'s current transcript, in order.
    ///
    /// See the protocol requirement's doc comment
    /// (``LanguageModelSessionBackend/transcriptEntries()``) for the
    /// turn-lock precondition this call must be made under.
    func transcriptEntries() -> [FoundationModels.Transcript.Entry] {
        Array(liveSession.transcript)
    }

    /// Returns ``liveSession``'s cumulative token usage.
    ///
    /// See the protocol requirement's doc comment
    /// (``LanguageModelSessionBackend/usageTokenCounts()``) for the
    /// turn-lock precondition this call must be made under.
    ///
    /// **Empirical status: measured.** `LanguageModelSession.usage`
    /// (`Usage{input: Input{totalTokenCount, cachedTokenCount}, output:
    /// Output{totalTokenCount, reasoningTokenCount}}`) is present in the
    /// macOS 27 `FoundationModels` swiftinterface. The gated integration
    /// suite `LanguageModelSessionBackendIntegrationTests` (nested
    /// `IntegrationTests/` package, run with
    /// `swift test --package-path IntegrationTests`) runs against a real
    /// model on a machine that has the model, and it is green: 11 tests in 1
    /// suite passed on 2026-08-21 with the `swissarmyhammer/mlx-swift-lm`
    /// fork pinned at branch `stable`, revision `41e9f41`. `MLXLanguageModel`'s
    /// `Executor` populates the totals with positive values:
    /// `recordedTokenUsageMatchesLiveBackendDelta` printed
    /// `tokensIn=62 tokensOut=149`, so `usage.input.totalTokenCount` and
    /// `usage.output.totalTokenCount` are both positive after one turn.
    /// `usage.input.cachedTokenCount` is positive on the second turn of a
    /// session: `secondTurnReusesFirstTurnsKVCache` printed
    /// `turn1In=49 turn1Out=93 turn2Cached=50`. Both of those measurements come
    /// from a run that took the provider's default sampling, so the generated
    /// counts in them do not repeat: the same test printed `turn1Out=84` on
    /// another run of the same code. That suite pins argmax decoding from task
    /// ^g1s1efb on, and the two whole runs of 2026-08-22 each printed
    /// `tokensIn=62 tokensOut=128` and `turn1In=49 turn1Out=76 turn2Cached=50`.
    /// This implementation returns the SDK's value as it is — never a
    /// fabricated zero and never a preemptive `nil`. `Package.resolved` is
    /// gitignored and the root package and the nested package resolve the fork
    /// branch independently, so read the revision your package resolved before
    /// you apply this measurement to a different revision.
    func usageTokenCounts() -> (input: Int, output: Int)? {
        let usage = liveSession.usage
        return (usage.input.totalTokenCount, usage.output.totalTokenCount)
    }
}

/// The live embedding container.
///
/// Wraps a loaded `EmbedderModelContainer` and the embedding ``dimension``
/// probed once at load, so the router's synchronous
/// ``LoadedEmbeddingContainer/dimension`` accessor reports a real value and
/// ``embed(texts:)`` runs the real `MLXEmbedders` pooling pipeline.
///
/// The wrapper exists because `EmbedderModelContainer` exposes its model only
/// through an async `perform` closure, so the dimension is not knowable
/// synchronously from the raw container; ``LiveModelLoader/loadEmbedder(ref:slot:reporting:)``
/// probes it once and stores it here. Embedding does not go through
/// `LanguageModelSession` — `MLXEmbedders` has no `FoundationModels.LanguageModel`
/// surface, so this stays on the direct `MLXEmbedders` pipeline (see plan.md's
/// "Backends" section).
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

    /// The shared embedding computation.
    ///
    /// Tokenizes, pads to the batch max, runs the model, pools (normalized),
    /// and reads the vectors back to `[[Float]]`. Static so ``LiveModelLoader``
    /// can probe the dimension at load without a wrapper instance. Mirrors the
    /// fork's own `MLXEmbedders` usage example.
    ///
    /// - Parameters:
    ///   - texts: The strings to embed.
    ///   - container: The embedder model container to use.
    /// - Returns: One vector per input string.
    /// - Throws: If embedding computation fails.
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
    /// No real loader was configured.
    ///
    /// The ``Router`` was built without a ``LiveModelLoader`` (which requires
    /// a `Downloader` and `TokenizerLoader`) and without an injected stub. See
    /// ``UnconfiguredModelLoader``.
    case notConfigured
}

/// The live ``ModelLoader``.
///
/// Downloads weights from a Hugging Face-compatible source and materializes
/// an ``MLXFoundationModelsContainer`` for generation (backed by
/// `MLXLanguageModel` + `LanguageModelSession`) and a
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

    /// Resolves a model identifier to its on-disk weights directory.
    ///
    /// Passed through to `MLXLanguageModel` for its availability checks
    /// (`modelExistsOnDisk()`, free-disk-space checks) — **not** consulted by
    /// the load path itself, which always goes through `load`/`downloader`
    /// below. Defaults to a harmless temporary-directory stub for callers that
    /// don't need those availability checks to resolve real paths.
    private let weightsLocation: @Sendable (String) -> URL

    /// The decoding strategy every generation model this loader vends
    /// generates with, or `nil` (the default) to leave the provider's own
    /// default in place — stamped onto every
    /// ``MLXFoundationModelsContainer`` ``loadLLM(ref:slot:context:reporting:)``
    /// produces. See that property's own doc comment for why the provider
    /// default is not repeatable and what pinning `.greedy` buys.
    private let samplingMode: GenerationOptions.SamplingMode?

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
    ///   - samplingMode: The decoding strategy every generation model this
    ///     loader vends generates with. Defaults to `nil` — the provider's own
    ///     default, which samples. Pass
    ///     ``FoundationModels/GenerationOptions/SamplingMode/greedy`` for
    ///     generation that repeats exactly; see ``samplingMode``.
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

    /// Downloads and loads an embedding model.
    ///
    /// Wraps it in a ``LiveEmbeddingContainer`` with its embedding dimension
    /// probed once now. `EmbedderModelContainer` only exposes its model
    /// through an async closure, so the dimension is not available
    /// synchronously; a single probe embedding establishes it (and warms the
    /// model) before the container is vended.
    ///
    /// - Parameters:
    ///   - ref: The embedding model reference to download and load.
    ///   - slot: The slot the model is being loaded for.
    ///   - reporting: The byte-based download-progress callback, invoked as
    ///     weights stream in.
    /// - Returns: The loaded ``LiveEmbeddingContainer`` with its probed dimension.
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

    /// Builds the MLX `ModelConfiguration` for a model ref.
    ///
    /// Pins the ref's revision or falls back to ``defaultRevision`` — shared
    /// by the generation and embedding load paths.
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
    ///
    /// - Parameter container: The container to warm.
    /// - Throws: If warm-up fails.
    public func preload(container: any LoadedModelContainer) async throws {}

    /// Evicts a loaded container, freeing the GPU memory its weights hold.
    ///
    /// Routed through ``MLXFoundationModelsContainer/model``'s real
    /// `MLXLanguageModel.evict()` when the container is a live generation
    /// container (dropping it from `MLXLanguageModel`'s process-global cache,
    /// so a subsequent load reloads from the on-disk snapshot); a no-op for any
    /// other container (e.g. the embedding container, which has no equivalent
    /// eviction hook today).
    ///
    /// - Parameter container: The container to evict.
    public func evict(container: any LoadedModelContainer) async {
        guard let generation = container as? MLXFoundationModelsContainer else { return }
        await generation.model.evict()
    }

    /// The revision used when a ``ModelRef`` does not pin one.
    private static let defaultRevision = "main"

    /// Maps a single Foundation `Progress` snapshot to the router's byte-based
    /// ``DownloadProgress``.
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
    /// Kept at the default (module-internal) access level, distinct from
    /// ``handler(reporting:)`` below: this is the pure byte-accounting logic, and
    /// ``LiveModelLoaderTests`` exercises it directly (no network, no GPU) via
    /// `@testable import`. `handler(reporting:)` is just `@Sendable`-closure
    /// plumbing over this function for `loadLLM`'s progress forwarding, used
    /// nowhere else, so it stays `private`.
    ///
    /// - Parameter progress: The Foundation `Progress` snapshot to map.
    /// - Returns: The equivalent byte-based ``DownloadProgress``.
    internal static func mapProgress(_ progress: Progress) -> DownloadProgress {
        let bytesTotal = progress.totalUnitCount
        let bytesDownloaded = Int64((progress.fractionCompleted * Double(bytesTotal)).rounded())
        return DownloadProgress(bytesDownloaded: bytesDownloaded, bytesTotal: bytesTotal)
    }

    /// Adapts the injected Hub downloader's progress to the router's callback.
    ///
    /// Thin `@Sendable`-closure plumbing over ``mapProgress(_:)``, used only by
    /// `loadLLM` above to forward each downloaded-bytes update to its
    /// `reporting` callback. See ``mapProgress(_:)`` for the actual byte-mapping
    /// contract and rationale.
    ///
    /// - Parameter reporting: The router's byte-based progress callback to invoke
    ///   for each Foundation `Progress` update.
    /// - Returns: A `@Sendable` `Progress` observer that maps each update into a
    ///   byte-based ``DownloadProgress`` and forwards it to `reporting`.
    private static func handler(
        reporting: @escaping @Sendable (DownloadProgress) -> Void
    ) -> @Sendable (Progress) -> Void {
        { progress in
            reporting(Self.mapProgress(progress))
        }
    }
}

/// The default ``ModelLoader`` when none is supplied.
///
/// It cannot load anything and throws ``ModelLoaderError/notConfigured`` on
/// first use. Because the live download path requires an injected `Downloader` /
/// `TokenizerLoader` (see ``LiveModelLoader``), a `Router` built with no loader
/// can size and joint-fit a profile but cannot download or load models — callers
/// that want real loading pass a configured ``LiveModelLoader``, and unit tests
/// pass a stub. This makes that requirement explicit rather than silently
/// loading nothing.
public struct UnconfiguredModelLoader: ModelLoader {
    /// Creates the unconfigured sentinel loader.
    public init() {}

    /// Always throws ``ModelLoaderError/notConfigured``.
    ///
    /// This sentinel cannot load a generation model. Real loading is
    /// configured/injected via ``LiveModelLoader`` (milestone 7).
    ///
    /// - Parameters:
    ///   - ref: The model reference that would be loaded.
    ///   - slot: The slot the model would be loaded for.
    ///   - context: The context length the model would be sized for.
    ///   - reporting: The download-progress callback (never invoked).
    /// - Returns: Never returns normally — this sentinel always throws.
    /// - Throws: ``ModelLoaderError/notConfigured``, always.
    public func loadLLM(
        ref: ModelRef,
        slot: ModelSlot,
        context: Int,
        reporting: @escaping @Sendable (DownloadProgress) -> Void
    ) async throws -> any LoadedLLMContainer {
        throw ModelLoaderError.notConfigured
    }

    /// Always throws ``ModelLoaderError/notConfigured``.
    ///
    /// This sentinel cannot load an embedding model. Real loading is
    /// configured/injected via ``LiveModelLoader`` (milestone 7).
    ///
    /// - Parameters:
    ///   - ref: The embedding model reference that would be loaded.
    ///   - slot: The slot the model would be loaded for.
    ///   - reporting: The download-progress callback (never invoked).
    /// - Returns: Never returns normally — this sentinel always throws.
    /// - Throws: ``ModelLoaderError/notConfigured``, always.
    public func loadEmbedder(
        ref: ModelRef,
        slot: ModelSlot,
        reporting: @escaping @Sendable (DownloadProgress) -> Void
    ) async throws -> any LoadedEmbeddingContainer {
        throw ModelLoaderError.notConfigured
    }

    /// Always throws ``ModelLoaderError/notConfigured``.
    ///
    /// This sentinel has no container to warm. Real loading is
    /// configured/injected via ``LiveModelLoader`` (milestone 7).
    ///
    /// - Parameter container: The container to warm.
    /// - Throws: Always throws ``ModelLoaderError/notConfigured``.
    public func preload(container: any LoadedModelContainer) async throws {
        throw ModelLoaderError.notConfigured
    }
}
