import Foundation
import FoundationModels
import FoundationModelsRouterTestSupport
import MLXLMCommon
import Synchronization
import Testing

@testable import FoundationModelsRouter

/// Exercises task ^3qx0mpt: a session is a queue of messages with one pump,
/// and no lock.
///
/// A caller prompt and the mail of a session wait in its ``SessionOutbox``.
/// One pump task for each session is the only code that submits for that
/// session. It takes every waiting message that can share one submission,
/// and it submits the next item only after the result of the last one. A
/// message that arrives while a submission runs waits for the next
/// submission.
///
/// Everything runs against a stub backend that can hold a call open, so the
/// suite needs no network and no GPU.
@Suite("The message queue and the pump of a session")
struct SessionMessagePumpTests {
    // MARK: - Backend

    /// The error a ``PumpProbeBackend`` call raises when the test tells it to
    /// fail. ``ScriptedCall/fail`` raises the error before the call writes an
    /// entry, so the session finds no `.prompt` entry of the attempt to
    /// attach its mail to. ``ScriptedCall/failAfterPrompt`` raises it after
    /// the call wrote its `.prompt` entry.
    enum PumpProbeError: Error, Equatable {
        /// The call failed.
        case refused
    }

    /// What one call of a ``PumpProbeBackend`` does.
    enum ScriptedCall: Sendable {
        /// The call answers at once.
        case answer

        /// The call waits until the latch opens, or throws
        /// `CancellationError` when its task is cancelled first.
        case hold(RunLatch)

        /// The call waits until the latch opens, then throws a rejected tool
        /// call, as `MLXLanguageModel` does when it cannot parse a tool call.
        case holdThenReject(RunLatch)

        /// The call throws ``PumpProbeError/refused`` at once.
        case fail

        /// The call writes its `.prompt` entry, then throws
        /// ``PumpProbeError/refused``. The call writes no `.response` entry.
        case failAfterPrompt
    }

    /// A backend that records each prompt and follows a script for each call.
    ///
    /// A call that answers appends a `.prompt` and a `.response` entry, as a
    /// real `LanguageModelSession` does. A call that throws appends nothing,
    /// except ``ScriptedCall/failAfterPrompt``, which appends its `.prompt`.
    /// The transcript can start with seed entries that the session did not
    /// record yet. Every mutable field is behind one `Mutex`, because a test
    /// reads the prompts while a call runs.
    final class PumpProbeBackend: LanguageModelSessionBackend {
        /// The fields a call reads and writes.
        private struct State {
            /// The prompt of each call, in call order.
            var prompts: [String] = []

            /// The synthetic transcript of the answered calls.
            var entries: [Transcript.Entry] = []

            /// What each call does, by its one-based ordinal. A call with no
            /// script answers at once.
            var script: [Int: ScriptedCall]
        }

        /// The one lock every mutable field is behind.
        private let state: Mutex<State>

        /// Signals after each call records its prompt in ``prompts``. A test
        /// waits on it for a prompt that reaches the backend.
        let changes = ChangeSignal()

        /// Makes a backend that follows `script`.
        ///
        /// - Parameters:
        ///   - script: What each call does, by its one-based ordinal.
        ///   - seedEntries: The entries the transcript starts with.
        init(script: [Int: ScriptedCall], seedEntries: [Transcript.Entry] = []) {
            state = Mutex(State(entries: seedEntries, script: script))
        }

        /// The prompt of each call so far, in call order.
        var prompts: [String] {
            state.withLock { $0.prompts }
        }

        /// The answer the call with `ordinal` gives.
        ///
        /// - Parameter ordinal: The one-based ordinal of the call.
        /// - Returns: The answer text.
        static func answer(ofCall ordinal: Int) -> String {
            "answer \(ordinal)"
        }

        func respond(to prompt: String, maxTokens: Int?) async throws -> String {
            let (ordinal, scripted) = state.withLock { state in
                state.prompts.append(prompt)
                return (state.prompts.count, state.script[state.prompts.count] ?? .answer)
            }
            changes.signal()
            if case .failAfterPrompt = scripted {
                state.withLock { $0.entries.append(Self.promptEntry(prompt)) }
                throw PumpProbeError.refused
            }
            try await Self.perform(scripted)
            let answer = Self.answer(ofCall: ordinal)
            state.withLock { state in
                state.entries.append(Self.promptEntry(prompt))
                state.entries.append(.response(Transcript.Response(segments: [.text(Transcript.TextSegment(content: answer))])))
            }
            return answer
        }

        /// The `.prompt` entry that a call writes for `prompt`.
        ///
        /// - Parameter prompt: The prompt of the call.
        /// - Returns: The entry.
        static func promptEntry(_ prompt: String) -> Transcript.Entry {
            .prompt(Transcript.Prompt(segments: [.text(Transcript.TextSegment(content: prompt))]))
        }

        /// Does what one scripted call does before it answers.
        ///
        /// - Parameter scripted: The script of the call.
        /// - Throws: `CancellationError`, a rejected tool call, or
        ///   ``PumpProbeError/refused``, as the script says.
        private static func perform(_ scripted: ScriptedCall) async throws {
            switch scripted {
            case .answer:
                return
            case .hold(let latch):
                try await waitCancellably(on: latch)
            case .holdThenReject(let latch):
                try await waitCancellably(on: latch)
                throw RejectedToolCallError(RejectingLanguageModel.Executor.rejection)
            case .fail, .failAfterPrompt:
                throw PumpProbeError.refused
            }
        }

        /// Waits until `latch` opens, and throws when the task of the call is
        /// cancelled first.
        ///
        /// - Parameter latch: The latch to wait on.
        /// - Throws: `CancellationError` when the task of the call is cancelled.
        private static func waitCancellably(on latch: RunLatch) async throws {
            await withTaskCancellationHandler {
                await latch.waitUntilOpen()
            } onCancel: {
                Task { await latch.open() }
            }
            try Task.checkCancellation()
        }

        func streamResponse(to prompt: String, maxTokens: Int?) -> AsyncThrowingStream<String, Error> {
            AsyncThrowingStream { continuation in
                let task = Task {
                    do {
                        continuation.yield(try await self.respond(to: prompt, maxTokens: maxTokens))
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: error)
                    }
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        }

        func respond(to prompt: String, following grammar: Grammar, maxTokens: Int?) async throws -> String {
            try await respond(to: prompt, maxTokens: maxTokens)
        }

        func makeFork() -> any LanguageModelSessionBackend {
            PumpProbeBackend(script: [:])
        }

        func transcriptEntries() -> [Transcript.Entry] {
            state.withLock { $0.entries }
        }

        func usageTokenCounts() -> (input: Int, output: Int)? {
            nil
        }
    }

    /// Vends the one ``PumpProbeBackend`` a test scripts, for the session
    /// that the test makes.
    struct PumpProbeContainer: LoadedLLMContainer {
        /// The scripted counter of this container: one token per `Character`.
        let tokenCounter: any TokenCounter = CharacterTokenCounter()

        /// The backend the vended session runs on.
        let backend: PumpProbeBackend

        func makeSession(instructions: String?) -> any LanguageModelSessionBackend {
            backend
        }

        func makeSession(transcript: Transcript) -> any LanguageModelSessionBackend {
            StubSessionBackend(entries: Array(transcript))
        }
    }

    // MARK: - Constants

    /// The prompt of the first caller, whose submission the test holds open.
    private static let firstPrompt = "first question"

    /// The prompt of the second caller, which arrives while the first
    /// submission runs.
    private static let secondPrompt = "second question"

    /// The prompt of the third caller, which also arrives while the first
    /// submission runs.
    private static let thirdPrompt = "third question"

    /// How many caller messages wait in the outbox while the first
    /// submission runs, in the test with three callers.
    private static let waitingCallerCount = 2

    /// The detail of the terminal of the background run of a test.
    private static let settledRunDetail = "the background job finished"

    /// The ordinal of the first submission of the answer that only mail
    /// starts, in the tests of a mail-only answer: one caller answer runs
    /// before it.
    private static let mailOnlySubmission = 2

    /// The ordinal of the continuation submission of the mail-only answer.
    private static let mailOnlyContinuation = 3

    /// The ordinal of the first submission of the answer after the mail-only
    /// answer.
    private static let nextAnswerSubmission = 4

    /// The token ceiling that a caller names, so that the options of a
    /// mail-only answer do not admit its message.
    private static let namedTokenCeiling = 256

    // MARK: - Fixtures

    /// Makes a session over `backend`.
    ///
    /// - Parameters:
    ///   - backend: The backend the session runs on.
    ///   - dir: The temporary directory the router caches under.
    /// - Returns: The session and the profile that keeps its models resident.
    private static func makeSession(
        over backend: PumpProbeBackend, dir: URL
    ) async throws -> (session: any RoutedSession, profile: LanguageModelProfile) {
        let profile = try await RouterTestFixtures.resolveStandardProfile(
            over: PumpProbeContainer(backend: backend), cacheDir: dir
        ).profile
        return (profile.standard.makeSession(), profile)
    }

    /// Settles one background run on the run plane of `session`, and gives its
    /// terminal. A test posts that terminal to the outbox when it wants the
    /// mail to arrive, as the funnel of a background tool does.
    ///
    /// The run settles before the test sends a message, so the session has
    /// no settlement observer yet, and the settlement wakes no pump. The
    /// run plane keeps the token as a settled background run, so the terminal
    /// can start a submission once it is posted.
    ///
    /// - Parameter session: The session whose run plane tracks the run.
    /// - Returns: The terminal of the run.
    /// - Throws: When the run does not settle inside the run plane wait.
    private static func settledRunTerminal(on session: any RoutedSession) async throws -> OperationEvent {
        let latch = RunLatch()
        await latch.open()
        let token = await trackFakeRun(on: session.runPlane, latch: latch, detailOnSettle: settledRunDetail)
        return try await MountFixtures.settledTerminal(of: token, in: session.runPlane)
    }

    /// Starts an answer that only mail starts, and waits until its first
    /// submission (``mailOnlySubmission``) reaches `backend`.
    ///
    /// One caller answer runs first, so the outbox of the session is
    /// attached. Then the terminal of a settled background run arrives, and
    /// it starts the mail-only answer with no caller call.
    ///
    /// - Parameters:
    ///   - session: The session to start the answer on.
    ///   - backend: The backend of the session.
    /// - Throws: When the run does not settle, or ``ConditionNeverHeld`` when
    ///   the task is cancelled before the submission reaches the backend.
    private static func startMailOnlyAnswer(on session: any RoutedSession, backend: PumpProbeBackend) async throws {
        let settledRun = try await settledRunTerminal(on: session)
        _ = try await session.respond(to: firstPrompt)
        await session.outbox.post(event: settledRun)
        try await MailQueueFixtures.waitForPrompts(mailOnlySubmission, on: backend, endingWhenIdle: session)
        #expect(backend.prompts.last?.hasSuffix(RoutedSessionActor.settledRunDeliveryPrompt) == true)
    }

    /// Waits until `count` caller messages wait in the outbox of `session`.
    ///
    /// Each mail that the queue gets is a change of
    /// ``RoutedSession/stateChanges``, so the wait reads the count again
    /// after each new message.
    ///
    /// - Parameters:
    ///   - count: How many waiting caller messages to wait for.
    ///   - session: The session whose outbox is watched.
    /// - Throws: ``ConditionNeverHeld`` when the task is cancelled before the
    ///   messages arrive.
    private static func awaitWaitingMessages(_ count: Int, on session: any RoutedSession) async throws {
        try await session.stateChanges.wait(until: { session.waitingUserMailCount == count })
    }

    /// Whether `event` is the terminal event ``SessionEvent/answered(_:)``.
    ///
    /// - Parameter event: One event of a session.
    /// - Returns: `true` for an answered event.
    private static func isAnswered(_ event: SessionEvent) -> Bool {
        if case .answered = event {
            return true
        }
        return false
    }

    /// Whether `event` is the terminal event ``SessionEvent/answerFailed(_:)``.
    ///
    /// - Parameter event: One event of a session.
    /// - Returns: `true` for an answer failure.
    private static func isAnswerFailed(_ event: SessionEvent) -> Bool {
        if case .answerFailed = event {
            return true
        }
        return false
    }

    /// Waits for the end of the signal `signal`, and expects that its
    /// terminal event is ``SessionEvent/signalDone(_:)``. The effect of a
    /// signal is not synchronous, so a test calls this before it checks the
    /// effect.
    ///
    /// - Parameters:
    ///   - signal: The id of the signal.
    ///   - session: The session that got the signal.
    /// - Throws: When the wait for the terminal event fails.
    private static func expectSignalEnds(_ signal: SignalID, on session: any RoutedSession) async throws {
        #expect(try await session.awaitTerminal(of: signal) == .signalDone(signal))
    }

    // MARK: - Caller messages

    @Test("a send on an idle session starts a submission with no other call, and the answer of the message ends it")
    func aSendOnAnIdleSessionStartsASubmission() async throws {
        let dir = RouterTestFixtures.makeTempDir(prefix: "SessionMessagePumpTests")
        defer { try? FileManager.default.removeItem(at: dir) }
        let backend = PumpProbeBackend(script: [:])
        let (session, profile) = try await Self.makeSession(over: backend, dir: dir)
        defer { await session.close() }

        let id = try session.send(Self.firstPrompt)

        // No driver call and no wait: the pump takes the message by itself.
        try await MailQueueFixtures.waitForPrompts(1, on: backend, endingWhenIdle: session)
        #expect(Self.isAnswered(try await session.awaitTerminal(of: id)))
        #expect(await session.becomesIdle())
        #expect(backend.prompts == [Self.firstPrompt])
        #expect(await session.pendingMessages().isEmpty)
        // The mail left the queue, so the signal of a cancel finds nothing to
        // remove: the terminal event of the mail is still its answer.
        try await Self.expectSignalEnds(session.cancel(id), on: session)
        #expect(Self.isAnswered(try await session.awaitTerminal(of: id)))
        withExtendedLifetime(profile) {}
    }

    @Test("cancel withdraws a message that waits: it never reaches a prompt, and its terminal event is cancelled")
    func cancelOfAWaitingMessageWithdrawsIt() async throws {
        let dir = RouterTestFixtures.makeTempDir(prefix: "SessionMessagePumpTests")
        defer { try? FileManager.default.removeItem(at: dir) }
        let latch = RunLatch()
        let backend = PumpProbeBackend(script: [1: .hold(latch)])
        let (session, profile) = try await Self.makeSession(over: backend, dir: dir)
        defer { await SessionFixtureLifecycle.close(session, opening: [latch]) }

        let first = Task { try await session.respond(to: Self.firstPrompt) }
        try await backend.waitForPrompts(1, endingOnEndOf: first)
        let waiting = try session.send(Self.secondPrompt)
        #expect(await session.pendingMessages().map(\.id) == [waiting])

        try await Self.expectSignalEnds(session.cancel(waiting), on: session)

        #expect(try await session.awaitTerminal(of: waiting) == .cancelled(waiting))
        #expect(await session.pendingMessages().isEmpty)
        await latch.open()
        #expect(try await first.value == PumpProbeBackend.answer(ofCall: 1))
        #expect(await session.becomesIdle())
        #expect(backend.prompts == [Self.firstPrompt])
        withExtendedLifetime(profile) {}
    }

    @Test("cancel never stops the submission that carries a message; cancelAll() stops it, and the pump then ends")
    func cancelOfAMessageInARunningSubmissionDoesNotStopIt() async throws {
        let dir = RouterTestFixtures.makeTempDir(prefix: "SessionMessagePumpTests")
        defer { try? FileManager.default.removeItem(at: dir) }
        let latch = RunLatch()
        let backend = PumpProbeBackend(script: [1: .hold(latch)])
        let (session, profile) = try await Self.makeSession(over: backend, dir: dir)
        defer { await SessionFixtureLifecycle.close(session, opening: [latch]) }

        let id = try await MailQueueFixtures.startHeldAnswer(Self.firstPrompt, on: session, backend: backend)
        #expect(await session.mailQueueDepth().running == [id])

        // The mail left the queue, so the signal of the cancel finds
        // nothing, and the answer goes on.
        try await Self.expectSignalEnds(session.cancel(id), on: session)
        #expect(await session.mailQueueDepth().running == [id])

        // The latch never opens, so only cancelAll() can end the held call.
        // The answer ends at once; the pump ends when the call unwinds.
        try await Self.expectSignalEnds(session.cancelAll(), on: session)
        #expect(Self.isAnswerFailed(try await session.awaitTerminal(of: id)))
        #expect(await session.pumpEnds())
        #expect(backend.prompts == [Self.firstPrompt])
        // A cancel after the end finds nothing: the terminal event stays.
        try await Self.expectSignalEnds(session.cancel(id), on: session)
        #expect(Self.isAnswerFailed(try await session.awaitTerminal(of: id)))
        withExtendedLifetime(profile) {}
    }

    @Test(
        "a respond that arrives while a submission runs waits in the outbox, not on a lock, and each caller gets the answer of the submission that carried its prompt"
    )
    func aRespondDuringASubmissionWaitsInTheOutboxForTheNextSubmission() async throws {
        let dir = RouterTestFixtures.makeTempDir(prefix: "SessionMessagePumpTests")
        defer { try? FileManager.default.removeItem(at: dir) }
        let latch = RunLatch()
        let backend = PumpProbeBackend(script: [1: .hold(latch)])
        let (session, profile) = try await Self.makeSession(over: backend, dir: dir)
        defer { await SessionFixtureLifecycle.close(session, opening: [latch]) }

        let first = Task { try await session.respond(to: Self.firstPrompt) }
        try await backend.waitForPrompts(1, endingOnEndOf: first)
        // The later prompts arrive one after the other, so their order in
        // the outbox is known.
        let second = Task { try await session.respond(to: Self.secondPrompt) }
        try await Self.awaitWaitingMessages(1, on: session)
        let third = Task { try await session.respond(to: Self.thirdPrompt) }

        // Both later prompts are messages in the outbox. Neither went into
        // the running submission.
        try await Self.awaitWaitingMessages(Self.waitingCallerCount, on: session)
        #expect(backend.prompts == [Self.firstPrompt])

        await latch.open()
        let firstAnswer = try await first.value
        let secondAnswer = try await second.value
        let thirdAnswer = try await third.value

        // One submission carried both waiting prompts, in the order they
        // arrived, and both callers got its answer.
        #expect(backend.prompts.count == 2)
        #expect(backend.prompts.last == Self.secondPrompt + RoutedSessionActor.messageSeparator + Self.thirdPrompt)
        #expect(firstAnswer == PumpProbeBackend.answer(ofCall: 1))
        #expect(secondAnswer == PumpProbeBackend.answer(ofCall: 2))
        #expect(thirdAnswer == PumpProbeBackend.answer(ofCall: 2))
        #expect(session.waitingUserMailCount == 0)
        withExtendedLifetime(profile) {}
    }

    @Test("a continuation submission of an answer carries the caller messages that wait when it starts")
    func aContinuationCarriesTheWaitingMessages() async throws {
        let dir = RouterTestFixtures.makeTempDir(prefix: "SessionMessagePumpTests")
        defer { try? FileManager.default.removeItem(at: dir) }
        let latch = RunLatch()
        let backend = PumpProbeBackend(script: [1: .holdThenReject(latch)])
        let (session, profile) = try await Self.makeSession(over: backend, dir: dir)
        defer { await SessionFixtureLifecycle.close(session, opening: [latch]) }

        let first = Task { try await session.respond(to: Self.firstPrompt) }
        try await backend.waitForPrompts(1, endingOnEndOf: first)
        let second = Task { try await session.respond(to: Self.secondPrompt) }
        try await Self.awaitWaitingMessages(1, on: session)

        // The first submission ends with a rejected tool call. The retry is a
        // continuation of the same answer, and the waiting prompt rides it.
        await latch.open()
        let firstAnswer = try await first.value
        let secondAnswer = try await second.value

        #expect(backend.prompts.count == 2)
        let retryPrompt = try #require(backend.prompts.last)
        // The prompt renders the mail in take order: the mail that the retry
        // carries from the failed attempt, then the mail that joins it. The
        // tool error comes after the mail.
        #expect(retryPrompt.hasPrefix(Self.firstPrompt + RoutedSessionActor.messageSeparator + Self.secondPrompt))
        #expect(firstAnswer == PumpProbeBackend.answer(ofCall: 2))
        #expect(secondAnswer == PumpProbeBackend.answer(ofCall: 2))
        withExtendedLifetime(profile) {}
    }

    // MARK: - Mail

    @Test(
        "mail that arrives while a submission runs goes into the next submission, never the running one, and that submission starts with no caller call"
    )
    func mailDuringASubmissionStartsTheNextSubmission() async throws {
        let dir = RouterTestFixtures.makeTempDir(prefix: "SessionMessagePumpTests")
        defer { try? FileManager.default.removeItem(at: dir) }
        let latch = RunLatch()
        let backend = PumpProbeBackend(script: [1: .hold(latch)])
        let (session, profile) = try await Self.makeSession(over: backend, dir: dir)
        defer { await SessionFixtureLifecycle.close(session, opening: [latch]) }
        let settledRun = try await Self.settledRunTerminal(on: session)

        let first = Task { try await session.respond(to: Self.firstPrompt) }
        try await backend.waitForPrompts(1, endingOnEndOf: first)
        await session.outbox.post(event: settledRun)
        await latch.open()
        let firstAnswer = try await first.value

        // The running submission did not take the mail.
        #expect(firstAnswer == PumpProbeBackend.answer(ofCall: 1))
        #expect(backend.prompts.first == Self.firstPrompt)

        // No caller asks again: the mail itself starts the next submission.
        try await MailQueueFixtures.waitForPrompts(2, on: backend, endingWhenIdle: session)
        let deliveryPrompt = try #require(backend.prompts.last)
        #expect(deliveryPrompt.contains(OperationEventSegment.renderedLine(for: settledRun)))
        #expect(deliveryPrompt.hasSuffix(RoutedSessionActor.settledRunDeliveryPrompt))
        // The pump takes the mail before it renders the prompt of the
        // delivery submission, so the outbox gave its mail away before the
        // prompt reached the backend.
        #expect(await session.outbox.pending().events.isEmpty)
        withExtendedLifetime(profile) {}
    }

    @Test("a delivery submission that fails before it writes an entry puts its mail back, and the pump does not retry it")
    func aFailedDeliveryPutsItsMailBackAndIsNotRetried() async throws {
        let dir = RouterTestFixtures.makeTempDir(prefix: "SessionMessagePumpTests")
        defer { try? FileManager.default.removeItem(at: dir) }
        let backend = PumpProbeBackend(script: [1: .answer, 2: .fail])
        let (session, profile) = try await Self.makeSession(over: backend, dir: dir)
        defer { await session.close() }
        let settledRun = try await Self.settledRunTerminal(on: session)

        // One answered call attaches the outbox of the session to it, so a
        // posted terminal starts a delivery submission.
        _ = try await session.respond(to: Self.firstPrompt)
        await session.outbox.post(event: settledRun)
        try await MailQueueFixtures.waitForPrompts(2, on: backend, endingWhenIdle: session)

        // The delivery submission failed with no `.prompt` entry. The pump
        // itself puts the mail back into the outbox before it ends, so the
        // end of the pump comes after the put back. A third call for the
        // mail could only come from that pump, so the count of the prompts
        // after its end is final.
        #expect(await session.pumpEnds())
        #expect(await session.outbox.pending().events.map(\.event) == [settledRun])
        #expect(backend.prompts.count == 2)

        // The next caller message carries the mail that came back.
        _ = try await session.respond(to: Self.secondPrompt)
        let nextPrompt = try #require(backend.prompts.last)
        #expect(nextPrompt.contains(OperationEventSegment.renderedLine(for: settledRun)))
        #expect(nextPrompt.hasSuffix(Self.secondPrompt))
        withExtendedLifetime(profile) {}
    }

    // MARK: - A caller message during a mail-only answer

    @Test(
        "a caller message that arrives while a mail-only answer runs, and that the options of the answer admit, joins its continuation and gets its final reply"
    )
    func aCallerMessageJoinsARunningMailOnlyAnswer() async throws {
        let dir = RouterTestFixtures.makeTempDir(prefix: "SessionMessagePumpTests")
        defer { try? FileManager.default.removeItem(at: dir) }
        let latch = RunLatch()
        let backend = PumpProbeBackend(script: [Self.mailOnlySubmission: .holdThenReject(latch)])
        let (session, profile) = try await Self.makeSession(over: backend, dir: dir)
        defer { await SessionFixtureLifecycle.close(session, opening: [latch]) }
        try await Self.startMailOnlyAnswer(on: session, backend: backend)

        let joining = Task { try await session.respond(to: Self.secondPrompt) }
        try await Self.awaitWaitingMessages(1, on: session)

        // The mail-only submission ends with a rejected tool call. The retry
        // is a continuation of the same answer, and the waiting prompt rides it.
        await latch.open()
        let joiningAnswer = try await joining.value

        #expect(joiningAnswer == PumpProbeBackend.answer(ofCall: Self.mailOnlyContinuation))
        #expect(await session.becomesIdle())
        #expect(backend.prompts.count == Self.mailOnlyContinuation)
        let retryPrompt = try #require(backend.prompts.last)
        // The failed submission wrote no `.prompt` entry, so its run mail went
        // back to the queue. The retry takes it again with the caller message,
        // in take order, and the retry text comes after the mail.
        #expect(
            retryPrompt.contains(
                Self.secondPrompt + RoutedSessionActor.messageSeparator + RoutedSessionActor.settledRunDeliveryPrompt))
        #expect(await session.mailQueueDepth() == MailQueueDepth(waiting: 0, depthByKind: [:], running: []))
        withExtendedLifetime(profile) {}
    }

    @Test(
        "caller messages that the options of a running mail-only answer do not admit wait for the next answer, in the order they arrived"
    )
    func messagesThatAMailOnlyAnswerDoesNotAdmitWaitForTheNextAnswer() async throws {
        let dir = RouterTestFixtures.makeTempDir(prefix: "SessionMessagePumpTests")
        defer { try? FileManager.default.removeItem(at: dir) }
        let latch = RunLatch()
        let backend = PumpProbeBackend(script: [Self.mailOnlySubmission: .holdThenReject(latch)])
        let (session, profile) = try await Self.makeSession(over: backend, dir: dir)
        defer { await SessionFixtureLifecycle.close(session, opening: [latch]) }
        try await Self.startMailOnlyAnswer(on: session, backend: backend)

        // A named token ceiling is not the ceiling of a mail-only answer.
        // The later prompts arrive one after the other, so their order in
        // the outbox is known.
        let second = Task { try await session.respond(to: Self.secondPrompt, maxTokens: Self.namedTokenCeiling) }
        try await Self.awaitWaitingMessages(1, on: session)
        let third = Task { try await session.respond(to: Self.thirdPrompt, maxTokens: Self.namedTokenCeiling) }
        try await Self.awaitWaitingMessages(Self.waitingCallerCount, on: session)

        await latch.open()
        let secondAnswer = try await second.value
        let thirdAnswer = try await third.value

        #expect(backend.prompts.count == Self.nextAnswerSubmission)
        let retryPrompt = backend.prompts[Self.mailOnlyContinuation - 1]
        #expect(!retryPrompt.contains(Self.secondPrompt))
        #expect(!retryPrompt.contains(Self.thirdPrompt))
        #expect(backend.prompts.last == Self.secondPrompt + RoutedSessionActor.messageSeparator + Self.thirdPrompt)
        #expect(secondAnswer == PumpProbeBackend.answer(ofCall: Self.nextAnswerSubmission))
        #expect(thirdAnswer == PumpProbeBackend.answer(ofCall: Self.nextAnswerSubmission))
        withExtendedLifetime(profile) {}
    }

    @Test(
        "a caller message cancelled while a mail-only answer runs is not taken into the answer, and its caller gets CancellationError"
    )
    func aCallerMessageCancelledBeforeTheJoinIsNotTaken() async throws {
        let dir = RouterTestFixtures.makeTempDir(prefix: "SessionMessagePumpTests")
        defer { try? FileManager.default.removeItem(at: dir) }
        let latch = RunLatch()
        let backend = PumpProbeBackend(script: [Self.mailOnlySubmission: .holdThenReject(latch)])
        let (session, profile) = try await Self.makeSession(over: backend, dir: dir)
        defer { await SessionFixtureLifecycle.close(session, opening: [latch]) }
        try await Self.startMailOnlyAnswer(on: session, backend: backend)

        let cancelled = Task { try await session.respond(to: Self.secondPrompt) }
        try await Self.awaitWaitingMessages(1, on: session)
        let cancelledID = try #require(await session.pendingMessages().first { !$0.isRunMail }?.id)
        cancelled.cancel()

        // The cancel handler of the caller withdraws the message. The
        // session removes the message from the queue before it sends the
        // terminal event `cancelled`, so the queue is empty after that event.
        #expect(try await session.awaitTerminal(of: cancelledID) == .cancelled(cancelledID))
        #expect(session.waitingUserMailCount == 0)
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        await latch.open()

        #expect(await session.becomesIdle())
        #expect(backend.prompts.count == Self.mailOnlyContinuation)
        #expect(backend.prompts.allSatisfy { !$0.contains(Self.secondPrompt) })
        withExtendedLifetime(profile) {}
    }

    // MARK: - Stop of all work

    @Test(
        "cancelAll() cancels the waiting caller messages, stops the running submission, and cancels the waiting run mail"
    )
    func cancelAllCancelsCallerMessagesStopsTheSubmissionAndCancelsTheMail() async throws {
        let dir = RouterTestFixtures.makeTempDir(prefix: "SessionMessagePumpTests")
        defer { try? FileManager.default.removeItem(at: dir) }
        let latch = RunLatch()
        let backend = PumpProbeBackend(script: [1: .hold(latch)])
        let (session, profile) = try await Self.makeSession(over: backend, dir: dir)
        defer { await SessionFixtureLifecycle.close(session, opening: [latch]) }
        let settledRun = try await Self.settledRunTerminal(on: session)

        let first = Task { try await session.respond(to: Self.firstPrompt) }
        try await backend.waitForPrompts(1, endingOnEndOf: first)
        let second = Task { try await session.respond(to: Self.secondPrompt) }
        try await Self.awaitWaitingMessages(1, on: session)
        await session.outbox.post(event: settledRun)
        let runMailID = try #require(session.outbox.pendingRunMail.first?.id)

        try await Self.expectSignalEnds(session.cancelAll(), on: session)

        await #expect(throws: CancellationError.self) { try await second.value }
        await #expect(throws: CancellationError.self) { try await first.value }
        #expect(session.waitingUserMailCount == 0)
        // The stop of all work cancels the run mail too.
        #expect(await session.outbox.pending().events.isEmpty)
        #expect(try await session.awaitTerminal(of: runMailID) == .cancelled(runMailID))
        #expect(await session.pumpEnds())
        #expect(backend.prompts == [Self.firstPrompt])
        withExtendedLifetime(profile) {}
    }
}
