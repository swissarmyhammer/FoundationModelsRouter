import Foundation
import FoundationModels
import FoundationModelsRouterTestSupport
import Synchronization
import Testing

@_spi(Testing) import FoundationModelsExtras
@testable import FoundationModelsRouter

/// Exercises the stop signal ``RoutedSession/cancelAll()`` and the order of
/// the signals of a session (`mailbox.md`, section 5).
///
/// ``RoutedSession/cancelAll()`` does not wait for the end of the work. The
/// running answer gets its terminal event at once, and the session output
/// drops each later output of that answer, also when its model call does not
/// stop on the cancel. The sweep of the background runs does not delay the
/// signal. After the stop, the session works as usual.
///
/// Each signal returns its ``SignalID`` at once. The signals run one at a
/// time, in call order, and each one ends with one
/// ``SessionEvent/signalDone(_:)``, after all its other events.
///
/// The tests run on two stub backends: ``GatedStreamBackend``, whose stream
/// call ignores the cancel and waits on a gate that the test controls, and
/// ``SessionMessagePumpTests/PumpProbeBackend`` through
/// ``MailQueueFixtures``. The suite needs no network and no GPU.
@Suite("The stop signal cancelAll() and the order of the signals")
struct CancelAllSignalTests {
    /// The backend that the tests with a cancellable held answer script.
    private typealias ProbeBackend = MailQueueFixtures.Backend

    /// The temp-directory prefix of the suite, given to
    /// ``RouterTestFixtures/makeTempDir(prefix:)``.
    private static let tempDirPrefix = "CancelAllSignalTests"

    /// The prompt of the stream message that ``RoutedSession/cancelAll()``
    /// stops.
    private static let streamPrompt = "stream question"

    /// The prompt of the message whose cancellable submission a test holds
    /// open.
    private static let heldPrompt = "held question"

    /// The prompt of the first queued message.
    private static let firstPrompt = "first queued question"

    /// The prompt of the second queued message.
    private static let secondPrompt = "second queued question"

    /// The prompt that a replace gives to a queued message.
    private static let replacedPrompt = "replaced question"

    /// The prompt that a second replace gives to the same queued message.
    private static let lastPrompt = "last replaced question"

    /// A token ceiling that keeps a message out of the batch of a message
    /// with no ceiling.
    private static let namedCeiling = 100

    /// The time that a test gives the session to send output that it must
    /// not send. The test uses it only to prove that something does not
    /// happen.
    private static let noOutputWindow = Duration.milliseconds(100)

    // MARK: - The gated stream backend

    /// A backend whose stream call gives one fragment at once, and then waits
    /// on ``gate`` for its second fragment. The wait ignores the cancel of
    /// the task, so the model call runs on after a stop, as a model call
    /// that does not stop on a cancel does. A reply call answers at once.
    ///
    /// The stream is an unfolding `AsyncThrowingStream`: after a cancel of
    /// its reader, the stream gives the value of the call that runs, and then
    /// ends. Thus the session reads the late fragment and then ends the
    /// stopped answer.
    ///
    /// Each mutable field is behind one `Mutex`, because a test reads the
    /// fields while a call runs.
    final class GatedStreamBackend: LanguageModelSessionBackend {
        /// The fields that a call reads and writes.
        private struct State {
            /// The prompt of each call, in call order.
            var prompts: [String] = []

            /// The synthetic transcript of the answered reply calls.
            var entries: [Transcript.Entry] = []

            /// Whether the stream call waits on ``GatedStreamBackend/gate``
            /// for its late fragment.
            var isLateFragmentWaiting = false

            /// Whether the stream call gave its late fragment.
            var isLateFragmentGiven = false
        }

        /// Counts the fragment requests of one stream.
        private final class FragmentCounter: Sendable {
            /// The count of the fragment requests so far.
            private let count = Mutex(0)

            /// Gives the zero-based ordinal of the next fragment request.
            ///
            /// - Returns: The ordinal.
            func next() -> Int {
                count.withLock { count in
                    defer { count += 1 }
                    return count
                }
            }
        }

        /// The text of the fragment that the stream gives at once.
        static let earlyText = "early words"

        /// The text of the fragment that the stream gives after ``gate``
        /// opens.
        static let lateText = "late words"

        /// The one lock that each mutable field is behind.
        private let state = Mutex(State())

        /// The gate that holds the late fragment of the stream. The wait on
        /// it ignores the cancel of the task.
        let gate = RunLatch()

        /// Makes a backend with no call.
        init() {}

        /// The prompt of each call so far, in call order.
        var prompts: [String] {
            state.withLock { $0.prompts }
        }

        /// Whether the stream call waits on ``gate`` for its late fragment.
        var isLateFragmentWaiting: Bool {
            state.withLock { $0.isLateFragmentWaiting }
        }

        /// Whether the stream call gave its late fragment.
        var isLateFragmentGiven: Bool {
            state.withLock { $0.isLateFragmentGiven }
        }

        /// The answer of the reply call with `ordinal`.
        ///
        /// - Parameter ordinal: The one-based ordinal of the call.
        /// - Returns: The answer text.
        static func answer(ofCall ordinal: Int) -> String {
            "answer \(ordinal)"
        }

        /// Records the call, and answers at once. The call appends a
        /// `.prompt` and a `.response` entry, as a real
        /// `LanguageModelSession` does.
        ///
        /// - Parameters:
        ///   - prompt: The prompt of the call.
        ///   - maxTokens: The token ceiling of the call. The stub does not
        ///     read it.
        /// - Returns: The answer text.
        func respond(to prompt: String, maxTokens: Int?) async throws -> String {
            state.withLock { state in
                state.prompts.append(prompt)
                let answer = Self.answer(ofCall: state.prompts.count)
                state.entries.append(
                    .prompt(Transcript.Prompt(segments: [.text(Transcript.TextSegment(content: prompt))])))
                state.entries.append(
                    .response(Transcript.Response(segments: [.text(Transcript.TextSegment(content: answer))])))
                return answer
            }
        }

        /// A stream with no text. The session reads
        /// ``streamResponseFragments(to:maxTokens:)``, not this call.
        ///
        /// - Parameters:
        ///   - prompt: The prompt of the call.
        ///   - maxTokens: The token ceiling of the call.
        /// - Returns: A stream that ends at once.
        func streamResponse(to prompt: String, maxTokens: Int?) -> AsyncThrowingStream<String, Error> {
            AsyncThrowingStream { $0.finish() }
        }

        /// Records the call, and gives a stream of two fragments: the early
        /// fragment at once, and the late fragment after ``gate`` opens.
        ///
        /// - Parameters:
        ///   - prompt: The prompt of the call.
        ///   - maxTokens: The token ceiling of the call. The stub does not
        ///     read it.
        /// - Returns: The stream of the fragments.
        func streamResponseFragments(to prompt: String, maxTokens: Int?) -> AsyncThrowingStream<ResponseFragment, Error> {
            state.withLock { $0.prompts.append(prompt) }
            let counter = FragmentCounter()
            return AsyncThrowingStream(unfolding: { [self] in
                switch counter.next() {
                case 0:
                    return ResponseFragment(text: Self.earlyText)
                case 1:
                    return await lateFragment()
                default:
                    return nil
                }
            })
        }

        /// Waits until ``gate`` opens, and gives the late fragment. The wait
        /// ignores the cancel of the task on purpose.
        ///
        /// - Returns: The late fragment.
        private func lateFragment() async -> ResponseFragment {
            state.withLock { $0.isLateFragmentWaiting = true }
            await gate.waitUntilOpen()
            state.withLock { $0.isLateFragmentGiven = true }
            return ResponseFragment(text: Self.lateText)
        }

        /// Answers as ``respond(to:maxTokens:)`` does. The stub does not
        /// read the grammar.
        ///
        /// - Parameters:
        ///   - prompt: The prompt of the call.
        ///   - grammar: The grammar of the call.
        ///   - maxTokens: The token ceiling of the call.
        /// - Returns: The answer text.
        func respond(to prompt: String, following grammar: Grammar, maxTokens: Int?) async throws -> String {
            try await respond(to: prompt, maxTokens: maxTokens)
        }

        /// Gives a new backend with no call.
        ///
        /// - Returns: The new backend.
        func makeFork() -> any LanguageModelSessionBackend {
            GatedStreamBackend()
        }

        /// Gives the synthetic transcript of the answered reply calls.
        ///
        /// - Returns: The entries, in order.
        func transcriptEntries() -> [Transcript.Entry] {
            state.withLock { $0.entries }
        }

        /// Gives no usage: the stub cannot meter.
        ///
        /// - Returns: `nil`.
        func usageTokenCounts() -> (input: Int, output: Int)? {
            nil
        }
    }

    /// Gives the one ``GatedStreamBackend`` that a test scripts to the
    /// session that the test makes.
    struct GatedStreamContainer: LoadedLLMContainer {
        /// The scripted counter of this container: one token for each
        /// `Character`.
        let tokenCounter: any TokenCounter = CharacterTokenCounter()

        /// The backend of the session.
        let backend: GatedStreamBackend

        /// Gives ``backend``.
        ///
        /// - Parameter instructions: The instructions of the session. The
        ///   stub does not read them.
        /// - Returns: ``backend``.
        func makeSession(instructions: String?) -> any LanguageModelSessionBackend {
            backend
        }

        /// Gives a plain stub backend that `transcript` seeds.
        ///
        /// - Parameter transcript: The transcript of the new session.
        /// - Returns: The stub backend.
        func makeSession(transcript: Transcript) -> any LanguageModelSessionBackend {
            StubSessionBackend(entries: Array(transcript))
        }
    }

    // MARK: - The output recorder

    /// Reads the session-wide feed of one session in a task of its own, and
    /// keeps each output, so a test reads the output while the session runs.
    private final class OutputRecorder: Sendable {
        /// Each output so far, in order.
        private let recorded = Mutex<[SessionOutput]>([])

        /// The task that reads the feed. It ends when the feed ends.
        private let reading = Mutex<Task<Void, Never>?>(nil)

        /// Makes a recorder with no output. ``record(_:)`` makes a recorder
        /// that reads a feed.
        private init() {}

        /// Makes a recorder that reads `feed`.
        ///
        /// - Parameter feed: The session-wide feed of one session.
        /// - Returns: The recorder.
        static func record(_ feed: AsyncStream<SessionOutput>) -> OutputRecorder {
            let recorder = OutputRecorder()
            let task = Task {
                for await output in feed {
                    recorder.recorded.withLock { $0.append(output) }
                }
            }
            recorder.reading.withLock { $0 = task }
            return recorder
        }

        /// Each output so far, in order.
        var outputs: [SessionOutput] {
            recorded.withLock { $0 }
        }

        /// Waits, bounded, until the outputs so far satisfy `condition`.
        ///
        /// - Parameters:
        ///   - label: What the test waits for, for the issue.
        ///   - condition: The condition on the outputs so far.
        /// - Throws: When the condition did not hold inside the bound.
        func waitFor(_ label: String, _ condition: @escaping @Sendable ([SessionOutput]) -> Bool) async throws {
            try #require(await BoundedWait.conditionReached(label) { condition(self.outputs) })
        }

        /// Waits until the feed ended, and gives each output. Call it after
        /// ``RoutedSession/close()``, which finishes the feed.
        ///
        /// - Returns: Each output of the feed, in order.
        func finished() async -> [SessionOutput] {
            await reading.withLock { $0 }?.value
            return outputs
        }
    }

    // MARK: - A run with a slow canceler

    /// A background run whose canceler waits on ``cancelerGate`` before it
    /// stops the run.
    private final class SlowCancelRun: Sendable {
        /// The completion token of the run.
        let token: String

        /// The gate that the canceler waits on.
        let cancelerGate = RunLatch()

        /// Whether the canceler started.
        private let cancelerStarted = Mutex(false)

        /// Makes the record of the run `token`.
        ///
        /// - Parameter token: The completion token of the run.
        init(token: String) {
            self.token = token
        }

        /// Whether the canceler started. It then waits on ``cancelerGate``
        /// until the test opens it.
        var isCancelerStarted: Bool {
            cancelerStarted.withLock { $0 }
        }

        /// Records that the canceler started.
        func markCancelerStarted() {
            cancelerStarted.withLock { $0 = true }
        }
    }

    // MARK: - Fixtures

    /// Makes a session over `backend`.
    ///
    /// - Parameters:
    ///   - backend: The backend the session runs on.
    ///   - dir: The temporary directory the router caches under.
    /// - Returns: The session and the profile that keeps its models resident.
    private static func makeSession(
        over backend: GatedStreamBackend, dir: URL
    ) async throws -> (session: any RoutedSession, profile: LanguageModelProfile) {
        let profile = try await RouterTestFixtures.resolveStandardProfile(
            over: GatedStreamContainer(backend: backend), cacheDir: dir
        ).profile
        return (profile.standard.makeSession(), profile)
    }

    /// Sends a stream message for ``streamPrompt``, and waits until its
    /// early text is on the feed and its stream waits for the late
    /// fragment.
    ///
    /// - Parameters:
    ///   - session: The session.
    ///   - backend: The backend of the session.
    ///   - recorder: The recorder of the feed of the session.
    /// - Returns: The mail and its subscription.
    /// - Throws: When the early text or the wait did not come inside the
    ///   bound.
    private static func startGatedStream(
        on session: any RoutedSession, backend: GatedStreamBackend, recorder: OutputRecorder
    ) async throws -> (mail: Mail, subscription: MailSubscription<SessionOutput>) {
        let mail = RoutedSessionActor.userMessage(streamPrompt, maxTokens: nil, mode: .stream)
        let subscription = try session.mail(mail)
        try await recorder.waitFor("the early text of the stream") { outputs in
            outputs.contains { $0.event == .textDelta(GatedStreamBackend.earlyText) }
        }
        try #require(
            await BoundedWait.conditionReached("the late fragment waiting at the gate") {
                backend.isLateFragmentWaiting
            })
        return (mail, subscription)
    }

    /// Starts an answer for ``heldPrompt`` on a backend that holds the call
    /// open, and waits until its submission reached the backend.
    ///
    /// - Parameters:
    ///   - session: The session.
    ///   - backend: The backend of the session.
    /// - Returns: The id of the held message.
    /// - Throws: When the submission does not reach the backend inside the
    ///   bound.
    private static func startHeldAnswer(on session: any RoutedSession, backend: ProbeBackend) async throws -> MailID {
        let held = try session.send(heldPrompt)
        try await BoundedWait.awaitPrompts(1, in: { backend.prompts })
        return held
    }

    /// Starts a background run on the run plane of `session`. The body of
    /// the run waits until its task is cancelled. The canceler of the run
    /// waits on the gate of the record, and then cancels the body.
    ///
    /// - Parameter session: The session whose run plane tracks the run.
    /// - Returns: The record of the run.
    private static func startSlowCancelRun(on session: any RoutedSession) async -> SlowCancelRun {
        let run = SlowCancelRun(token: RunPlane.makeCompletionToken())
        let bodyLatch = RunLatch()
        let token = run.token
        let settling = Task<OperationEvent, Never> {
            await withTaskCancellationHandler {
                await bodyLatch.waitUntilOpen()
            } onCancel: {
                Task { await bodyLatch.open() }
            }
            return OperationEvent(
                tool: FakeRun.tool, op: FakeRun.op, correlationID: token, kind: .completed,
                detail: "the slow run ended", outcome: Task.isCancelled ? .cancelled : .succeeded)
        }
        await session.runPlane.start(
            tool: FakeRun.tool,
            op: FakeRun.op,
            kind: .swiftTask,
            completionToken: token,
            canceler: {
                run.markCancelerStarted()
                await run.cancelerGate.waitUntilOpen()
                settling.cancel()
                return .cancelled
            },
            body: { await settling.value }
        )
        return run
    }

    /// A user message body in reply mode with no ceiling.
    ///
    /// - Parameter prompt: The prompt text.
    /// - Returns: The body.
    private static func replyBody(_ prompt: String) -> MailBody {
        .userMessage(prompt: prompt, options: UserMessageOptions())
    }

    /// The prompt text of a queued user message.
    ///
    /// - Parameter mail: One queued mail.
    /// - Returns: The prompt, or `nil` for other mail.
    private static func prompt(of mail: Mail) -> String? {
        if case .userMessage(let prompt, _) = mail.body {
            return prompt
        }
        return nil
    }

    /// The events of `outputs` that belong to the mail `id`: each output
    /// whose origin holds the id, and each terminal event that ends it.
    ///
    /// - Parameters:
    ///   - id: The id of one mail.
    ///   - outputs: The output of a session, in order.
    /// - Returns: The events, in order.
    private static func events(of id: MailID, in outputs: [SessionOutput]) -> [SessionEvent] {
        outputs.filter { output in
            output.origin.contains(id) || TerminalEventLedger.mailIdsEnded(by: output.event)?.contains(id) == true
        }.map(\.event)
    }

    /// The ``SessionEvent/runSettled(_:)`` events of the run `token` in
    /// `outputs`, in order.
    ///
    /// - Parameters:
    ///   - token: The completion token of the run.
    ///   - outputs: The output of a session, in order.
    /// - Returns: The terminal events of the run.
    private static func settledEvents(of token: String, in outputs: [SessionOutput]) -> [OperationEvent] {
        outputs.compactMap { output in
            if case .runSettled(let event) = output.event, event.correlationID == token {
                return event
            }
            return nil
        }
    }

    /// The signal ids of the ``SessionEvent/signalDone(_:)`` events of
    /// `outputs`, in order.
    ///
    /// - Parameter outputs: The output of a session, in order.
    /// - Returns: The signal ids.
    private static func doneSignals(in outputs: [SessionOutput]) -> [SignalID] {
        outputs.compactMap { output in
            if case .signalDone(let signal) = output.event {
                return signal
            }
            return nil
        }
    }

    /// The ``SessionEvent/cancelled(_:)`` events of `outputs`, with their
    /// origins, in order.
    ///
    /// - Parameter outputs: The output of a session, in order.
    /// - Returns: The id and the origin of each cancelled event.
    private static func cancellations(in outputs: [SessionOutput]) -> [(id: MailID, origin: Origin)] {
        outputs.compactMap { output in
            if case .cancelled(let id) = output.event {
                return (id, output.origin)
            }
            return nil
        }
    }

    /// The index of the first output of `outputs` whose event is `event`.
    ///
    /// - Parameters:
    ///   - event: The event.
    ///   - outputs: The output of a session, in order.
    /// - Returns: The index.
    /// - Throws: When `outputs` does not have the event.
    private static func index(of event: SessionEvent, in outputs: [SessionOutput]) throws -> Int {
        try #require(outputs.firstIndex { $0.event == event }, "the output has no \(event)")
    }

    // MARK: - The stop of the running answer

    @Test(
        "cancelAll() ends the running answer at once with one answerFailed(cancelled), and a model call that ignores the cancel sends no more output"
    )
    func cancelAllEndsTheRunningAnswerAtOnce() async throws {
        let dir = RouterTestFixtures.makeTempDir(prefix: Self.tempDirPrefix)
        defer { try? FileManager.default.removeItem(at: dir) }
        let backend = GatedStreamBackend()
        let (session, profile) = try await Self.makeSession(over: backend, dir: dir)
        let recorder = OutputRecorder.record(await session.streamSessionEvents())
        let (stopped, subscription) = try await Self.startGatedStream(
            on: session, backend: backend, recorder: recorder)

        let signal = session.cancelAll()
        #expect(try await session.awaitTerminal(of: signal) == .signalDone(signal))

        // The model call ignores the cancel: it still waits at the shut gate.
        #expect(await session.isPumpRunning)
        #expect(backend.isLateFragmentWaiting)
        #expect(!backend.isLateFragmentGiven)
        let failure = AnswerFailure(mailIds: [stopped.id], reason: .cancelled)
        #expect(try await session.awaitTerminal(of: stopped.id) == .answerFailed(failure))
        let mailOutputs = await MailQueueFixtures.readToEnd(subscription)
        #expect(mailOutputs.last?.event == .answerFailed(failure))
        #expect(TerminalEventLedger(outputs: mailOutputs).endedMailIds == [[stopped.id]])
        let atStop = Self.events(of: stopped.id, in: recorder.outputs)
        #expect(atStop.last == .answerFailed(failure))

        // While the model call runs on, no output of the answer arrives.
        try await Task.sleep(for: Self.noOutputWindow)
        #expect(Self.events(of: stopped.id, in: recorder.outputs) == atStop)

        // The model call gives its late fragment and ends. Its output and
        // its own end do not arrive.
        await backend.gate.open()
        #expect(await session.isIdleOnceThePumpEnds())
        #expect(backend.isLateFragmentGiven)
        try await Task.sleep(for: Self.noOutputWindow)
        #expect(Self.events(of: stopped.id, in: recorder.outputs) == atStop)
        await session.close()

        let outputs = await recorder.finished()
        #expect(Self.events(of: stopped.id, in: outputs) == atStop)
        #expect(!outputs.contains { $0.event == .textDelta(GatedStreamBackend.lateText) })
        #expect(outputs.filter { $0.origin == .signal(signal) }.map(\.event) == [.signalDone(signal)])
        #expect(backend.prompts == [Self.streamPrompt])
        let ledger = TerminalEventLedger(outputs: outputs)
        ledger.expectExactlyOneTerminal(for: [stopped.id])
        ledger.expectExactlyOneTerminal(forSignals: [signal])
        withExtendedLifetime(profile) {}
    }

    // MARK: - The sweep of the background runs

    @Test("a slow run canceler does not delay the signalDone of cancelAll(), and the run gets one terminal when its cancel ends")
    func aSlowCancelerDoesNotDelayCancelAll() async throws {
        let dir = RouterTestFixtures.makeTempDir(prefix: Self.tempDirPrefix)
        defer { try? FileManager.default.removeItem(at: dir) }
        let backend = ProbeBackend(script: [:])
        let (session, profile) = try await MailQueueFixtures.makeSession(over: backend, dir: dir)
        let recorder = OutputRecorder.record(await session.streamSessionEvents())
        let run = await Self.startSlowCancelRun(on: session)

        let signal = session.cancelAll()
        #expect(try await session.awaitTerminal(of: signal) == .signalDone(signal))

        // The canceler starts, and waits at the shut gate. The run is open.
        try #require(await BoundedWait.conditionReached("the start of the canceler") { run.isCancelerStarted })
        #expect(await session.runPlane.backgroundRuns().map(\.completionToken) == [run.token])
        #expect(Self.settledEvents(of: run.token, in: recorder.outputs).isEmpty)

        // The cancel ends, and the run gets its terminal.
        await run.cancelerGate.open()
        try await recorder.waitFor("the terminal of the run") { outputs in
            !Self.settledEvents(of: run.token, in: outputs).isEmpty
        }
        await session.runPlane.joinRunBodies()
        #expect(await session.runPlane.backgroundRuns().isEmpty)
        // The body of the run ended after the sweep: no second terminal.
        try await Task.sleep(for: Self.noOutputWindow)
        await session.close()

        let outputs = await recorder.finished()
        #expect(Self.settledEvents(of: run.token, in: outputs).map(\.outcome) == [.cancelled])
        #expect(Self.doneSignals(in: outputs) == [signal])
        #expect(backend.prompts.isEmpty)
        TerminalEventLedger(outputs: outputs).expectExactlyOneTerminal(forSignals: [signal])
        withExtendedLifetime(profile) {}
    }

    // MARK: - The session after cancelAll()

    @Test(
        "after cancelAll(), new mail waits for the stopped work and is answered, and cancel(_:) and replace(_:with:) of queued mail work"
    )
    func theSessionWorksAfterCancelAll() async throws {
        let dir = RouterTestFixtures.makeTempDir(prefix: Self.tempDirPrefix)
        defer { try? FileManager.default.removeItem(at: dir) }
        let backend = GatedStreamBackend()
        let (session, profile) = try await Self.makeSession(over: backend, dir: dir)
        let recorder = OutputRecorder.record(await session.streamSessionEvents())
        let (stopped, _) = try await Self.startGatedStream(on: session, backend: backend, recorder: recorder)
        let stop = session.cancelAll()
        #expect(try await session.awaitTerminal(of: stop) == .signalDone(stop))

        // The stopped model call still runs, so new mail waits in the queue.
        let replaced = try session.send(Self.firstPrompt)
        let cancelled = RoutedSessionActor.userMessage(Self.secondPrompt, maxTokens: Self.namedCeiling, mode: .reply)
        _ = try session.mail(cancelled)
        let replace = session.replace(replaced, with: Self.replyBody(Self.replacedPrompt))
        #expect(try await session.awaitTerminal(of: replace) == .signalDone(replace))
        let pending = await session.pendingMessages()
        #expect(pending.map(\.id) == [replaced, cancelled.id])
        #expect(pending.map(Self.prompt(of:)) == [Self.replacedPrompt, Self.secondPrompt])

        let cancel = session.cancel(cancelled.id)
        #expect(try await session.awaitTerminal(of: cancel) == .signalDone(cancel))
        #expect(try await session.awaitTerminal(of: cancelled.id) == .cancelled(cancelled.id))
        #expect(await session.pendingMessages().map(\.id) == [replaced])

        // The stopped work ends, and the pump answers the queued mail.
        await backend.gate.open()
        let end = try await session.awaitTerminal(of: replaced)
        #expect(MailQueueFixtures.answer(of: end)?.mailIds == [replaced])
        #expect(await session.isIdleOnceThePumpEnds())
        await session.close()

        #expect(backend.prompts == [Self.streamPrompt, Self.replacedPrompt])
        let outputs = await recorder.finished()
        #expect(Self.cancellations(in: outputs).map(\.id) == [cancelled.id])
        #expect(Self.cancellations(in: outputs).map(\.origin) == [.signal(cancel)])
        #expect(Self.doneSignals(in: outputs) == [stop, replace, cancel])
        let ledger = TerminalEventLedger(outputs: outputs)
        ledger.expectExactlyOneTerminal(for: [stopped.id, replaced, cancelled.id])
        ledger.expectExactlyOneTerminal(forSignals: [stop, replace, cancel])
        withExtendedLifetime(profile) {}
    }

    // MARK: - The order of the signals

    @Test(
        "signals run one at a time in call order, and each cancelled of a signal has the origin of that signal and comes before its signalDone"
    )
    func signalsRunInCallOrder() async throws {
        let dir = RouterTestFixtures.makeTempDir(prefix: Self.tempDirPrefix)
        defer { try? FileManager.default.removeItem(at: dir) }
        let latch = RunLatch()
        let backend = ProbeBackend(script: [1: .hold(latch)])
        let (session, profile) = try await MailQueueFixtures.makeSession(over: backend, dir: dir)
        let recorder = OutputRecorder.record(await session.streamSessionEvents())
        let held = try await Self.startHeldAnswer(on: session, backend: backend)
        let first = try session.send(Self.firstPrompt)
        let second = RoutedSessionActor.userMessage(Self.secondPrompt, maxTokens: Self.namedCeiling, mode: .reply)
        _ = try session.mail(second)

        // Two replaces of one mail, with no wait between them: the later
        // replace runs last, so its prompt stays.
        let replaceOne = session.replace(first, with: Self.replyBody(Self.replacedPrompt))
        let replaceTwo = session.replace(first, with: Self.replyBody(Self.lastPrompt))
        #expect(try await session.awaitTerminal(of: replaceTwo) == .signalDone(replaceTwo))
        #expect(await session.pendingMessages().map(Self.prompt(of:)) == [Self.lastPrompt, Self.secondPrompt])

        // A replace, a cancel of the same mail, and two stops, with no wait
        // between them.
        let replaceThree = session.replace(second.id, with: Self.replyBody(Self.replacedPrompt))
        let cancel = session.cancel(second.id)
        let stopOne = session.cancelAll()
        let stopTwo = session.cancelAll()
        #expect(try await session.awaitTerminal(of: stopTwo) == .signalDone(stopTwo))
        #expect(await session.pendingMessages().isEmpty)
        #expect(await session.isIdleOnceThePumpEnds())
        await session.close()

        let outputs = await recorder.finished()
        let signals = [replaceOne, replaceTwo, replaceThree, cancel, stopOne, stopTwo]
        #expect(Self.doneSignals(in: outputs) == signals)
        let cancellations = Self.cancellations(in: outputs)
        #expect(cancellations.map(\.id) == [second.id, first])
        #expect(cancellations.map(\.origin) == [.signal(cancel), .signal(stopOne)])

        // Each event of a signal comes after the end of the signal before
        // it, and before its own end.
        let replaceThreeDone = try Self.index(of: .signalDone(replaceThree), in: outputs)
        let cancelDone = try Self.index(of: .signalDone(cancel), in: outputs)
        let stopOneDone = try Self.index(of: .signalDone(stopOne), in: outputs)
        let secondCancelled = try Self.index(of: .cancelled(second.id), in: outputs)
        let firstCancelled = try Self.index(of: .cancelled(first), in: outputs)
        let heldFailed = try Self.index(
            of: .answerFailed(AnswerFailure(mailIds: [held], reason: .cancelled)), in: outputs)
        #expect(replaceThreeDone < secondCancelled && secondCancelled < cancelDone)
        #expect(cancelDone < firstCancelled && firstCancelled < stopOneDone)
        #expect(cancelDone < heldFailed && heldFailed < stopOneDone)
        // The second stop finds no work: it sends only its own end.
        #expect(outputs.filter { $0.origin == .signal(stopTwo) }.map(\.event) == [.signalDone(stopTwo)])
        #expect(backend.prompts == [Self.heldPrompt])
        let ledger = TerminalEventLedger(outputs: outputs)
        ledger.expectExactlyOneTerminal(for: [held, first, second.id])
        ledger.expectExactlyOneTerminal(forSignals: signals)
        withExtendedLifetime(profile) {}
    }

    // MARK: - cancel(_:) of mail that is not queued

    @Test("cancel(_:) of a delivered mail or of an unknown id sends only its signalDone, and the answer goes on")
    func cancelOfMailThatIsNotQueuedSendsOnlySignalDone() async throws {
        let dir = RouterTestFixtures.makeTempDir(prefix: Self.tempDirPrefix)
        defer { try? FileManager.default.removeItem(at: dir) }
        let latch = RunLatch()
        let backend = ProbeBackend(script: [1: .hold(latch)])
        let (session, profile) = try await MailQueueFixtures.makeSession(over: backend, dir: dir)
        let recorder = OutputRecorder.record(await session.streamSessionEvents())
        let held = try await Self.startHeldAnswer(on: session, backend: backend)

        let delivered = session.cancel(held)
        let unknown = session.cancel(MailID())
        #expect(try await session.awaitTerminal(of: unknown) == .signalDone(unknown))
        #expect(await session.isPumpRunning)
        await latch.open()
        let end = try await session.awaitTerminal(of: held)
        #expect(MailQueueFixtures.answer(of: end)?.mailIds == [held])
        #expect(await session.isIdleOnceThePumpEnds())
        await session.close()

        let outputs = await recorder.finished()
        #expect(outputs.filter { $0.origin == .signal(delivered) }.map(\.event) == [.signalDone(delivered)])
        #expect(outputs.filter { $0.origin == .signal(unknown) }.map(\.event) == [.signalDone(unknown)])
        #expect(Self.cancellations(in: outputs).isEmpty)
        #expect(Self.doneSignals(in: outputs) == [delivered, unknown])
        #expect(backend.prompts == [Self.heldPrompt])
        let ledger = TerminalEventLedger(outputs: outputs)
        ledger.expectExactlyOneTerminal(for: [held])
        ledger.expectExactlyOneTerminal(forSignals: [delivered, unknown])
        withExtendedLifetime(profile) {}
    }
}
