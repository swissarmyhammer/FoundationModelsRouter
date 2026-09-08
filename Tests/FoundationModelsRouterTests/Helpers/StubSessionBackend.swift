import Foundation
import FoundationModels
import Synchronization

@testable import FoundationModelsRouter

/// A ``LoadedLLMContainer`` whose `makeSession(transcript:)` has no special
/// wrapping/invariant/spy requirement beyond seeding a plain
/// ``StubSessionBackend`` from the given transcript's entries — the common
/// case shared by most stub containers across this suite. Conforming to this
/// protocol instead of ``LoadedLLMContainer`` directly gets a container this
/// implementation for free, so it only has to implement
/// `makeSession(instructions:)`.
///
/// A handful of containers wire special behavior through
/// `makeSession(instructions:)` — test-observation tracking, a
/// "no generation allowed" invariant, a maxTokens-recording spy, or a shared
/// mutable backend a test drives directly — and their `makeSession(transcript:)`
/// must mirror that same behavior rather than fall back to a bare stub. Those
/// containers implement `makeSession(transcript:)` themselves and conform to
/// ``LoadedLLMContainer`` directly instead of to this protocol.
protocol PlainTranscriptStubContainer: LoadedLLMContainer {}

extension PlainTranscriptStubContainer {
    /// Seeds a plain ``StubSessionBackend`` from `transcript`'s entries.
    func makeSession(transcript: Transcript) -> any LanguageModelSessionBackend {
        StubSessionBackend(entries: Array(transcript))
    }
}

/// One generation call a ``StubSessionBackend`` served, as the caller made it.
struct StubGenerationCall: Sendable, Equatable {
    /// The prompt the backend was asked to respond to.
    let prompt: String

    /// The ceiling the caller put on that call's own answer, or `nil` to leave
    /// it to the model's own default.
    let maxTokens: Int?
}

/// A generation log shared by a ``StubSessionBackend`` and every clone it
/// produces (``StubSessionBackend/makeFork(tools:)``,
/// ``StubSessionBackend/replacingTranscript(_:)``).
///
/// A fold's summarizer never calls the backend a container handed the session:
/// `BackendCompactionSummarizer` builds a fresh, blank-slate backend for each
/// call via `replacingTranscript(_:)`, so a per-instance history such as
/// ``StubSessionBackend/receivedPrompts`` cannot see the calls a fold made. A
/// log passed in at construction and carried across every clone can, which is
/// what lets a test read the prompt and the output ceiling a session's fold
/// actually handed its summarizer.
///
/// `@unchecked Sendable` invariant: ``record(prompt:maxTokens:)`` runs only
/// from inside a backend call, ``RoutedSessionActor`` serializes every
/// backend call onto its own executor, and a test reads ``calls`` only after
/// the turns that made them returned.
final class StubGenerationLog: @unchecked Sendable {
    /// Every call served through this log, in call order.
    private(set) var calls: [StubGenerationCall] = []

    /// Appends one call.
    ///
    /// - Parameters:
    ///   - prompt: The prompt the backend was asked to respond to.
    ///   - maxTokens: The ceiling on that call's own answer, or `nil`.
    func record(prompt: String, maxTokens: Int?) {
        calls.append(StubGenerationCall(prompt: prompt, maxTokens: maxTokens))
    }
}

/// A registry of every ``StubSessionBackend`` one lineage creates — the
/// initial backend a container vends, plus every clone born through
/// ``StubSessionBackend/makeFork(tools:)`` and
/// ``StubSessionBackend/replacingTranscript(_:)``.
///
/// A fold swaps a session's backend through `replacingTranscript(_:)`
/// directly on the backend (see `RoutedSessionActor`'s fold), so a container
/// that only retains what *it* vended cannot see the session's live
/// post-fold backend. Backends registered here can: the fold's swap clone is
/// the last backend the fold creates, so ``created``'s last element after a
/// `compact()` returns is the session's live backend.
///
/// `@unchecked Sendable` invariant: ``record(_:)`` runs either from direct
/// test-code construction between turns or from backend calls
/// (`makeFork`/`replacingTranscript`) that `RoutedSessionActor` serializes
/// one at a time under the owning session's turn lock. Nothing ever touches
/// an instance concurrently.
final class StubBackendRegistry: @unchecked Sendable {
    /// Every backend recorded so far, in creation order.
    private(set) var created: [StubSessionBackend] = []

    /// Records one backend.
    ///
    /// - Parameter backend: The backend just created.
    func record(_ backend: StubSessionBackend) {
        created.append(backend)
    }
}

/// A test-only ``LanguageModelSessionBackend`` shared by the stub
/// ``LoadedLLMContainer``s across the unit suite.
///
/// Every stub container in this target used to implement stateless
/// `respond`/`streamResponse` methods directly; now that generation runs
/// through a persistent backend a session holds for its whole lifetime (see
/// ``LanguageModelSessionBackend``), the stubs instead manufacture one of
/// these per session via `makeSession(instructions:)`. It returns a
/// configurable canned response (or throws a configured error) and records
/// every prompt it is asked to respond to, so a test can assert both the
/// response a session produced and the call history the backend observed.
///
/// It also maintains a synthetic ``entries`` transcript mirroring the shape a
/// real `LanguageModelSession`/``MLXFoundationModelsSessionBackend`` would
/// accumulate: when constructed with non-nil `instructions`, ``entries``
/// opens with one `.instructions` entry (matching how supplied instructions
/// become a `LanguageModelSession`'s transcript's first entry); every
/// successful `respond`/`streamResponse`/guided-`respond` call then appends a
/// `.prompt` entry followed by a `.response` entry, so ``transcriptEntries()``
/// reports the same prompt/response-pair-per-turn shape the live backend's
/// real transcript does.
///
/// ``makeFork()`` simulates transcript inheritance without a real model: the
/// returned backend starts with a *copy* of this backend's
/// ``receivedPrompts`` and ``entries`` as of fork time (mirroring how the live
/// `MLXFoundationModelsSessionBackend.makeFork()` seeds a child session from
/// the parent's accumulated transcript), then diverges independently as each
/// backend's own further calls append only to its own history.
///
/// Like the live conformance it stands in for, this is a plain mutable class
/// rather than an actor, and it is properly `Sendable`: every mutable field
/// lives behind one ``Mutex``. The owning session drives one backend method
/// at a time, but a stream's producer can outlive the turn that started it.
/// A wrapper that drives ``streamResponse(to:maxTokens:)`` from a task of its
/// own keeps writing after a cancelled turn stopped consuming, while that
/// turn's failed-turn recording reads ``transcriptEntries()`` on the actor
/// (task ^9smkhk8). The lock lands each call as a whole, so that read sees a
/// turn complete or not at all.
final class StubSessionBackend: LanguageModelSessionBackend {
    /// A failure ``respond(to:maxTokens:)``/``streamResponse(to:maxTokens:)``/
    /// the guided `respond` raise when ``shouldThrow`` is `true`.
    enum StubError: Error, Equatable {
        case boom
    }

    /// Every field a call reads or writes, behind ``state`` so one call lands
    /// as a whole beside a concurrent ``transcriptEntries()`` read.
    private struct State {
        /// See ``StubSessionBackend/responseText``.
        var responseText: String

        /// See ``StubSessionBackend/shouldThrow``.
        var shouldThrow: Bool

        /// See ``StubSessionBackend/callCount``.
        var callCount = 0

        /// See ``StubSessionBackend/receivedPrompts``.
        var receivedPrompts: [String]

        /// See ``StubSessionBackend/entries``.
        var entries: [Transcript.Entry]

        /// See ``StubSessionBackend/usageIncrement``.
        var usageIncrement: (input: Int, output: Int)?

        /// This backend's simulated running total of metered usage, grown by
        /// ``usageIncrement`` on every successful call. See
        /// ``StubSessionBackend/usageTokenCounts()``.
        var cumulativeUsage: (input: Int, output: Int) = (0, 0)

        /// See ``StubSessionBackend/lastForkTools``.
        var lastForkTools: [any Tool] = []
    }

    /// The one lock every mutable field lives behind. See the type's own
    /// documentation for why a lock, and not the session's turn lock, is
    /// what keeps a read beside a live stream producer sound.
    private let state: Mutex<State>

    /// The canned text every generation entry point returns on success.
    var responseText: String {
        get { state.withLock { $0.responseText } }
        set { state.withLock { $0.responseText = newValue } }
    }

    /// When `true`, every generation entry point throws ``StubError/boom``
    /// instead of returning ``responseText``.
    var shouldThrow: Bool {
        get { state.withLock { $0.shouldThrow } }
        set { state.withLock { $0.shouldThrow = newValue } }
    }

    /// The number of generation calls this backend has served — every
    /// `respond`/`streamResponse`/guided `respond` call increments this,
    /// whether or not it throws.
    var callCount: Int { state.withLock { $0.callCount } }

    /// Every prompt this backend has been asked to respond to, in call order.
    ///
    /// Seeded with a copy of the parent's history at fork time (see
    /// ``makeFork()``), so a forked backend's history begins with its
    /// parent's prompts and then grows independently with its own.
    var receivedPrompts: [String] { state.withLock { $0.receivedPrompts } }

    /// The synthetic transcript this backend has accumulated, in order, as of
    /// this read.
    ///
    /// Seeded from ``instructions`` at construction time (one leading
    /// `.instructions` entry, or none), then grown by one `.prompt` + one
    /// `.response` entry per successful turn. See ``transcriptEntries()``.
    var entries: [Transcript.Entry] { state.withLock { $0.entries } }

    /// The per-turn token counts this backend adds to its simulated
    /// cumulative usage on every successful call, or `nil` (the default) to
    /// report no usage at all — ``usageTokenCounts()`` then always returns
    /// `nil`, mirroring a real backend that cannot meter.
    ///
    /// Set this before driving a turn to give a test canned, configurable
    /// counts; ``recordCall(prompt:maxTokens:preflight:)`` is what actually
    /// folds it into the running total on each successful call, the way a
    /// real `LanguageModelSession.usage` grows across turns.
    var usageIncrement: (input: Int, output: Int)? {
        get { state.withLock { $0.usageIncrement } }
        set { state.withLock { $0.usageIncrement = newValue } }
    }

    /// The log every generation call this backend and its clones serve is
    /// recorded into, or `nil` (the default) to record nowhere. See
    /// ``StubGenerationLog``.
    let generationLog: StubGenerationLog?

    /// The registry this backend and every clone it produces record
    /// themselves into at creation, or `nil` (the default) to register
    /// nowhere. See ``StubBackendRegistry``.
    let registry: StubBackendRegistry?

    /// The tools most recently passed to ``makeFork(tools:)``, or empty if
    /// never called with any.
    ///
    /// The test-only introspection point proving which tool list
    /// ``RoutedSessionActor/fork(workingDirectory:)`` actually threads into a
    /// fork's model-facing backend — mirroring how the live
    /// `MLXFoundationModelsSessionBackend.makeFork(tools:)` threads its own
    /// `tools:` argument into a forked `LanguageModelSession`.
    var lastForkTools: [any Tool] { state.withLock { $0.lastForkTools } }

    /// Creates a stub backend.
    ///
    /// - Parameters:
    ///   - responseText: The canned text returned on success.
    ///   - shouldThrow: Whether every call should throw instead of
    ///     succeeding.
    ///   - receivedPrompts: The initial prompt history — non-empty only for a
    ///     backend born via ``makeFork()``.
    ///   - instructions: The session's system instructions, or `nil`. When
    ///     non-nil, ``entries`` opens with a single `.instructions` entry
    ///     carrying this text — mirroring how a real `LanguageModelSession`'s
    ///     transcript begins. Ignored when `entries` is supplied directly
    ///     (the fork path).
    ///   - entries: The initial transcript — non-nil only for a backend born
    ///     via ``makeFork()``, which snapshots the parent's ``entries`` as of
    ///     fork time. When `nil`, ``entries`` is derived from `instructions`.
    ///   - usageIncrement: The per-turn token counts to add to the running
    ///     total on every successful call, or `nil` to report no usage. See
    ///     ``usageIncrement``.
    ///   - generationLog: The shared log to record every call into, or `nil`
    ///     (the default) to record nowhere. Carried by every clone this
    ///     backend produces. See ``StubGenerationLog``.
    ///   - registry: The shared registry to record this backend and every
    ///     clone into at creation, or `nil` (the default) to register
    ///     nowhere. See ``StubBackendRegistry``.
    init(
        responseText: String = "stub response",
        shouldThrow: Bool = false,
        receivedPrompts: [String] = [],
        instructions: String? = nil,
        entries: [Transcript.Entry]? = nil,
        usageIncrement: (input: Int, output: Int)? = nil,
        generationLog: StubGenerationLog? = nil,
        registry: StubBackendRegistry? = nil
    ) {
        let initialEntries: [Transcript.Entry]
        if let entries {
            initialEntries = entries
        } else if let instructions {
            initialEntries = [Self.instructionsEntry(for: instructions)]
        } else {
            initialEntries = []
        }
        self.state = Mutex(
            State(
                responseText: responseText,
                shouldThrow: shouldThrow,
                receivedPrompts: receivedPrompts,
                entries: initialEntries,
                usageIncrement: usageIncrement
            )
        )
        self.generationLog = generationLog
        self.registry = registry
        registry?.record(self)
    }

    /// Records the call and returns ``responseText``, or throws
    /// ``StubError/boom`` when ``shouldThrow`` is set.
    func respond(to prompt: String, maxTokens: Int?) async throws -> String {
        try recordCall(prompt: prompt, maxTokens: maxTokens)
    }

    /// Records the call and streams ``responseText`` as a single chunk, or
    /// finishes with ``StubError/boom`` when ``shouldThrow`` is set. The call
    /// is recorded here, when the stream is made, not when it is consumed.
    func streamResponse(to prompt: String, maxTokens: Int?) -> AsyncThrowingStream<String, Error> {
        let outcome = Result { try recordCall(prompt: prompt, maxTokens: maxTokens) }
        return AsyncThrowingStream { continuation in
            switch outcome {
            case .success(let responseText):
                continuation.yield(responseText)
                continuation.finish()
            case .failure(let error):
                continuation.finish(throwing: error)
            }
        }
    }

    /// Records the call, runs the real (GPU-free) grammar validation, then
    /// returns ``responseText`` — or throws ``StubError/boom`` when
    /// ``shouldThrow`` is set — mirroring the live backend's guided entry
    /// point, which validates before decoding.
    func respond(to prompt: String, following grammar: Grammar, maxTokens: Int?) async throws -> String {
        try recordCall(prompt: prompt, maxTokens: maxTokens) {
            try grammar.validateForXGrammar()
        }
    }

    /// Returns a new ``StubSessionBackend`` pre-seeded with a copy of
    /// ``receivedPrompts`` and ``entries`` as of this call, sharing this
    /// backend's ``responseText``/``shouldThrow`` configuration.
    ///
    /// Delegates to ``makeFork(tools:)`` with no tools, mirroring how the
    /// live `MLXFoundationModelsSessionBackend.makeFork()` delegates to its
    /// own `tools:` overload with its own stored tools.
    func makeFork() -> any LanguageModelSessionBackend {
        makeFork(tools: [])
    }

    /// Returns a new ``StubSessionBackend`` pre-seeded the same way as
    /// ``makeFork()``, additionally recording `tools` into ``lastForkTools``
    /// so a test can assert which tool list
    /// ``RoutedSessionActor/fork(workingDirectory:)`` actually passed.
    func makeFork(tools: [any Tool]) -> any LanguageModelSessionBackend {
        let snapshot = state.withLock { state in
            state.lastForkTools = tools
            return state
        }
        let fork = StubSessionBackend(
            responseText: snapshot.responseText,
            shouldThrow: snapshot.shouldThrow,
            receivedPrompts: snapshot.receivedPrompts,
            entries: snapshot.entries,
            usageIncrement: snapshot.usageIncrement,
            generationLog: generationLog,
            registry: registry
        )
        fork.state.withLock { $0.cumulativeUsage = snapshot.cumulativeUsage }
        return fork
    }

    /// Returns a new ``StubSessionBackend`` seeded from `transcript`'s
    /// entries instead of this backend's own accumulated ``entries`` —
    /// fresh ``callCount``/``receivedPrompts``/running usage, mirroring
    /// how a freshly-constructed real `LanguageModelSession` reports zero
    /// usage regardless of the transcript it was seeded with (usage tracks
    /// calls made on *this* session object, not the seeded transcript's own
    /// history). See ``LanguageModelSessionBackend/replacingTranscript(_:)``.
    func replacingTranscript(_ transcript: Transcript) -> any LanguageModelSessionBackend {
        let snapshot = state.withLock { $0 }
        return StubSessionBackend(
            responseText: snapshot.responseText,
            shouldThrow: snapshot.shouldThrow,
            entries: Array(transcript),
            usageIncrement: snapshot.usageIncrement,
            generationLog: generationLog,
            registry: registry
        )
    }

    /// Returns ``entries``, this backend's synthetic transcript so far.
    ///
    /// Safe beside a stream producer that is still appending: the read holds
    /// ``state``'s lock, and each call appends under that same lock, so the
    /// read sees a call whole or not at all.
    func transcriptEntries() -> [Transcript.Entry] {
        entries
    }

    /// Returns the running usage total, or `nil` when ``usageIncrement`` is
    /// unset — mirroring a backend that cannot report usage at all.
    func usageTokenCounts() -> (input: Int, output: Int)? {
        state.withLock { state -> (input: Int, output: Int)? in
            guard state.usageIncrement != nil else { return nil }
            return state.cumulativeUsage
        }
    }

    /// Records one generation call as a whole, under ``state``'s lock —
    /// shared by every generation entry point.
    ///
    /// In order: bumps ``callCount``, appends the prompt to
    /// ``receivedPrompts``, ``generationLog`` and ``entries``; runs
    /// `preflight`; throws ``StubError/boom`` when ``shouldThrow`` is set;
    /// then appends a `.response` entry carrying ``responseText`` and folds
    /// ``usageIncrement`` (when set) into the running total, so the two
    /// snapshots ``RoutedSessionActor``'s chokepoint takes around a turn
    /// differ by exactly one turn's worth of usage. A call that throws
    /// leaves its `.prompt` entry and no `.response` entry, the way a real
    /// session that failed mid-turn does.
    ///
    /// - Parameters:
    ///   - prompt: The prompt this call was asked to respond to.
    ///   - maxTokens: The ceiling this call was made under, or `nil`.
    ///   - preflight: A check that runs after the prompt is recorded and
    ///     before the throw check — the guided entry point's grammar
    ///     validation. Its error propagates.
    /// - Returns: ``responseText``.
    /// - Throws: `preflight`'s error, or ``StubError/boom`` when
    ///   ``shouldThrow`` is set.
    private func recordCall(
        prompt: String,
        maxTokens: Int?,
        preflight: () throws -> Void = {}
    ) throws -> String {
        try state.withLock { state in
            state.callCount += 1
            state.receivedPrompts.append(prompt)
            generationLog?.record(prompt: prompt, maxTokens: maxTokens)
            state.entries.append(.prompt(Transcript.Prompt(segments: [.text(Transcript.TextSegment(content: prompt))])))
            try preflight()
            if state.shouldThrow { throw StubError.boom }
            state.entries.append(
                .response(Transcript.Response(segments: [.text(Transcript.TextSegment(content: state.responseText))]))
            )
            if let usageIncrement = state.usageIncrement {
                state.cumulativeUsage = (
                    state.cumulativeUsage.input + usageIncrement.input,
                    state.cumulativeUsage.output + usageIncrement.output
                )
            }
            return state.responseText
        }
    }

    /// Builds the leading `.instructions` entry a non-nil `instructions`
    /// string seeds ``entries`` with, mirroring how a real
    /// `LanguageModelSession`'s transcript carries supplied instructions as
    /// its first entry.
    private static func instructionsEntry(for instructions: String) -> Transcript.Entry {
        .instructions(
            Transcript.Instructions(
                segments: [.text(Transcript.TextSegment(content: instructions))],
                toolDefinitions: []
            )
        )
    }
}
