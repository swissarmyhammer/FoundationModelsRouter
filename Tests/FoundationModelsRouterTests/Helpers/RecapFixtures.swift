import Foundation
import FoundationModels
import FoundationModelsExtras
import FoundationModelsRouterTestSupport
import InMemoryTracing
import Synchronization
import Tracing

@testable import FoundationModelsRouter

/// The backend of each recap call of a test (D206): the fake flash model.
///
/// Each call records its prompt, its token ceiling and whether it asked for
/// the reasoning off, then signals ``changes``. A call answers with
/// ``output``, or throws ``failure`` when the test set one. A held backend
/// waits in each call until the test releases it (``releaseHeldCalls()``),
/// or until the task of the call is cancelled, and then throws
/// ``EventNeverArrived``. Each call that ended signals again. Every mutable
/// field is behind one lock: the recapper calls the backend on a task of its
/// own while the test reads it.
final class RecapProbeBackend: LanguageModelSessionBackend {
    /// One recap call, as the recapper made it.
    struct Call: Sendable, Equatable {
        /// The prompt of the call.
        let prompt: String

        /// The token ceiling of the call.
        let maxTokens: Int?

        /// `true` when the call asked for the reasoning off.
        let reasoningOff: Bool
    }

    /// The error that a failing call throws.
    struct Failure: Error, Equatable {}

    /// The fields a call reads and writes.
    private struct State {
        /// Each call so far, in call order.
        var calls: [Call] = []

        /// The text each call answers.
        var output: String

        /// The error each call throws, or `nil`.
        var failure: (any Error)?

        /// The number of calls that returned or threw.
        var endedCallCount = 0
    }

    /// The one lock every mutable field is behind.
    private let state: Mutex<State>

    /// The event that a held call waits for, or `nil` for a backend that
    /// holds no call.
    private let release: AwaitedEvent?

    /// The signal that each call signals after it recorded itself.
    let changes: ChangeSignal

    /// The backend of the other members, which a recap call never uses.
    private let inner = StubSessionBackend()

    /// Makes a backend.
    ///
    /// - Parameters:
    ///   - output: The text each call answers.
    ///   - isHeld: `true` to hold each call until the test releases it or
    ///     its task is cancelled.
    ///   - changes: The signal of each call.
    init(output: String, isHeld: Bool = false, changes: ChangeSignal) {
        state = Mutex(State(output: output))
        release = isHeld ? AwaitedEvent() : nil
        self.changes = changes
    }

    /// Each call so far, in call order.
    var calls: [Call] { state.withLock { $0.calls } }

    /// The number of calls that returned or threw.
    var endedCallCount: Int { state.withLock { $0.endedCallCount } }

    /// Lets each held call go on.
    func releaseHeldCalls() {
        release?.signal()
    }

    /// Makes each later call throw `error`.
    ///
    /// - Parameter error: The error of each call. The default is ``Failure``.
    func failEachCall(throwing error: any Error = Failure()) {
        state.withLock { $0.failure = error }
    }

    /// Records the call as a call with the reasoning on, and answers.
    func respond(to prompt: String, maxTokens: Int?) async throws -> String {
        try await answer(prompt, maxTokens: maxTokens, reasoningOff: false)
    }

    /// Records the call as a call with the reasoning off, and answers.
    func respondWithoutReasoning(to prompt: String, maxTokens: Int?) async throws -> String {
        try await answer(prompt, maxTokens: maxTokens, reasoningOff: true)
    }

    /// Streams the answer of ``respond(to:maxTokens:)`` as one chunk.
    func streamResponse(to prompt: String, maxTokens: Int?) -> AsyncThrowingStream<String, Error> {
        inner.streamResponse(to: prompt, maxTokens: maxTokens)
    }

    /// Answers as a ``StubSessionBackend`` does.
    func respond(to prompt: String, following grammar: Grammar, maxTokens: Int?) async throws -> String {
        try await inner.respond(to: prompt, following: grammar, maxTokens: maxTokens)
    }

    /// Forks the inner backend.
    func makeFork() -> any LanguageModelSessionBackend {
        inner.makeFork()
    }

    /// The transcript of the inner backend.
    func transcriptEntries() -> [Transcript.Entry] {
        inner.transcriptEntries()
    }

    /// The usage of the inner backend.
    func usageTokenCounts() -> (input: Int, output: Int)? {
        inner.usageTokenCounts()
    }

    /// Records one call, signals ``changes``, waits while the backend is
    /// held, and answers. The end of the call signals again.
    ///
    /// - Parameters:
    ///   - prompt: The prompt of the call.
    ///   - maxTokens: The token ceiling of the call.
    ///   - reasoningOff: `true` when the call asked for the reasoning off.
    /// - Returns: ``State/output``.
    /// - Throws: ``EventNeverArrived`` when a held call is cancelled, or
    ///   the error that the test set (``failEachCall(throwing:)``).
    private func answer(_ prompt: String, maxTokens: Int?, reasoningOff: Bool) async throws -> String {
        let (output, failure) = state.withLock { current in
            current.calls.append(Call(prompt: prompt, maxTokens: maxTokens, reasoningOff: reasoningOff))
            return (current.output, current.failure)
        }
        changes.signal()
        defer {
            state.withLock { $0.endedCallCount += 1 }
            changes.signal()
        }
        try await release?.wait()
        if let failure { throw failure }
        return output
    }
}

/// The host of a ``SessionRecapper`` in a test of the recapper alone (D206):
/// the directory side, with one fake flash model.
///
/// The host gives each session that the test lets in (``admit(_:previousRecap:)``)
/// the fake flash model, tells whether that model is busy
/// (``setBusy(_:)``), and records each recap write. Each busy check and each
/// write signals the signal of the host, which is the signal of the jobs of
/// the recapper, so a test waits for all of them on one signal.
final class FakeRecapHost: Sendable {
    /// One recap write.
    struct Write: Sendable, Equatable {
        /// The recap.
        let recap: String

        /// The session of the recap.
        let id: ULID
    }

    /// The fields the recapper reads and writes.
    private struct State {
        /// The previous recap of each session the host lets in.
        var admitted: [ULID: String?] = [:]

        /// Whether the flash model has a running turn.
        var isBusy = false

        /// The number of busy checks so far.
        var busyChecks = 0

        /// Each write so far, in order.
        var writes: [Write] = []
    }

    /// The model reference of the fake flash model.
    static let flashModel = ModelRef(repo: "test/recap-flash")

    /// The one lock of the mutable fields.
    private let state = Mutex(State())

    /// The signal of each busy check and each write.
    private let changes: ChangeSignal

    /// The fake flash model.
    let backend: RecapProbeBackend

    /// The tracer of the recap spans when the test gives none.
    let tracer: InMemoryTracer

    /// The tracer that the recap spans go to.
    private let spanTracer: any Tracer

    /// Makes a host whose flash model answers `output`.
    ///
    /// - Parameters:
    ///   - output: The text each recap call answers.
    ///   - isHeld: `true` to hold each recap call until the test releases it
    ///     or its task is cancelled.
    ///   - changes: The signal of the jobs of the recapper under test.
    ///   - spanTracer: The tracer of the recap spans, or `nil` (the default)
    ///     for ``tracer``.
    init(output: String, isHeld: Bool = false, changes: ChangeSignal, spanTracer: (any Tracer)? = nil) {
        self.changes = changes
        backend = RecapProbeBackend(output: output, isHeld: isHeld, changes: changes)
        let ownTracer = InMemoryTracer()
        tracer = ownTracer
        self.spanTracer = spanTracer ?? ownTracer
    }

    /// Lets the session `id` in: it gets a recap, with `previousRecap` as the
    /// recap of its record.
    ///
    /// - Parameters:
    ///   - id: The session id.
    ///   - previousRecap: The recap of its record, or `nil`.
    func admit(_ id: ULID, previousRecap: String? = nil) {
        state.withLock { $0.admitted[id] = .some(previousRecap) }
    }

    /// Sets whether the flash model has a running turn.
    ///
    /// - Parameter isBusy: `true` while the flash model has a running turn.
    func setBusy(_ isBusy: Bool) {
        state.withLock { $0.isBusy = isBusy }
    }

    /// The number of busy checks so far.
    var busyChecks: Int { state.withLock { $0.busyChecks } }

    /// Each write so far, in order.
    var writes: [Write] { state.withLock { $0.writes } }

    /// The host closures that the recapper uses.
    var host: SessionRecapper.Host {
        SessionRecapper.Host(
            target: { [self] id in target(of: id) },
            isModelBusy: { [self] model in isBusy(model) },
            write: { [self] recap, _, id in record(Write(recap: recap, id: id)) })
    }

    /// The target of the session `id`: the fake flash model and the previous
    /// recap, or `nil` for a session the test did not let in.
    ///
    /// - Parameter id: The session id.
    /// - Returns: The target.
    private func target(of id: ULID) -> SessionRecapper.Target? {
        guard let previousRecap = state.withLock({ $0.admitted[id] }) else { return nil }
        let model = SessionRecapModel(
            model: Self.flashModel, tokenCounter: CharacterTokenCounter(), tracer: spanTracer,
            makeBackend: { [backend] in backend })
        return SessionRecapper.Target(model: model, previousRecap: previousRecap)
    }

    /// Counts one busy check, signals, and tells whether `model` is busy.
    ///
    /// - Parameter model: The flash model of the recap.
    /// - Returns: `true` while the test holds the flash model busy.
    private func isBusy(_ model: ModelRef) -> Bool {
        defer { changes.signal() }
        return state.withLock { current in
            current.busyChecks += 1
            return current.isBusy && model == Self.flashModel
        }
    }

    /// Records one write and signals.
    ///
    /// - Parameter write: The write.
    private func record(_ write: Write) {
        state.withLock { $0.writes.append(write) }
        changes.signal()
    }
}

/// The sampling modes that the recap calls of a ``RecapProbeContainer``
/// asked for, in order.
final class SamplingModeLog: Sendable {
    /// The modes, behind one lock: the recapper makes its backend on a task
    /// of its own.
    private let modes = Mutex<[GenerationOptions.SamplingMode?]>([])

    /// The modes so far.
    var all: [GenerationOptions.SamplingMode?] { modes.withLock { $0 } }

    /// Appends `mode`.
    ///
    /// - Parameter mode: The mode of one blank session.
    func record(_ mode: GenerationOptions.SamplingMode?) {
        modes.withLock { $0.append(mode) }
    }
}

/// A container whose sessions run over the container `sessions`, and whose
/// blank session with no tools is the fake flash model of the recap
/// (``RecapProbeBackend``).
///
/// A vended session asks its container for a session with tools
/// (``makeSession(instructions:tools:)``); the recap call asks for a blank
/// session with no tools and with a sampling mode
/// (``makeSession(instructions:samplingMode:)``). So the recap call never
/// reaches the backend of a session, and a test can read both apart.
struct RecapProbeContainer<Sessions: LoadedLLMContainer>: LoadedLLMContainer {
    /// The container of the sessions.
    let sessions: Sessions

    /// The fake flash model of the recap calls.
    let recap: RecapProbeBackend

    /// The sampling mode of each recap call.
    let samplingModes = SamplingModeLog()

    /// The counter of the container of the sessions.
    var tokenCounter: any TokenCounter { sessions.tokenCounter }

    /// The fake flash model: a blank session with no tools.
    func makeSession(instructions: String?) -> any LanguageModelSessionBackend {
        recap
    }

    /// Records `samplingMode`, and gives the fake flash model.
    func makeSession(
        instructions: String?, samplingMode: GenerationOptions.SamplingMode?
    ) -> any LanguageModelSessionBackend {
        samplingModes.record(samplingMode)
        return recap
    }

    /// A session of ``sessions`` with `tools`.
    func makeSession(instructions: String?, tools: [any Tool]) -> any LanguageModelSessionBackend {
        sessions.makeSession(instructions: instructions, tools: tools)
    }

    /// A session of ``sessions`` seeded from `transcript`.
    func makeSession(transcript: Transcript) -> any LanguageModelSessionBackend {
        sessions.makeSession(transcript: transcript)
    }

    /// A session of ``sessions`` seeded from `transcript`, with `tools`.
    func makeSession(transcript: Transcript, tools: [any Tool]) -> any LanguageModelSessionBackend {
        sessions.makeSession(transcript: transcript, tools: tools)
    }
}
