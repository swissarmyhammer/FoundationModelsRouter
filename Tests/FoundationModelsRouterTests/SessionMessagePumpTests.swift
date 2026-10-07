import Foundation
import FoundationModels
import FoundationModelsRouterTestSupport
import MLXLMCommon
import Synchronization
import Testing

@testable import FoundationModelsRouter

/// Exercises task ^3qx0mpt: a session is a queue of messages with one pump,
/// and no lock (`generation-queue.md`, section 5.4).
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
    /// fail. It raises the error before the call writes an entry, so the
    /// session finds no `.prompt` entry to attach its mail to.
    enum PumpProbeError: Error, Equatable {
        /// The call failed before it wrote an entry.
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
    }

    /// A backend that records each prompt and follows a script for each call.
    ///
    /// A call that answers appends a `.prompt` and a `.response` entry, as a
    /// real `LanguageModelSession` does. A call that throws appends nothing.
    /// Every mutable field is behind one `Mutex`, because a test reads the
    /// prompts while a call runs.
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

        /// Makes a backend that follows `script`.
        ///
        /// - Parameter script: What each call does, by its one-based ordinal.
        init(script: [Int: ScriptedCall]) {
            state = Mutex(State(script: script))
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
            try await Self.perform(scripted)
            let answer = Self.answer(ofCall: ordinal)
            state.withLock { state in
                state.entries.append(.prompt(Transcript.Prompt(segments: [.text(Transcript.TextSegment(content: prompt))])))
                state.entries.append(.response(Transcript.Response(segments: [.text(Transcript.TextSegment(content: answer))])))
            }
            return answer
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
            case .fail:
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

    /// Settles one background run on the mailbox of `session`, and gives its
    /// terminal. A test posts that terminal to the outbox when it wants the
    /// mail to arrive, as the funnel of a background tool does.
    ///
    /// The run settles before the test sends a message, so the session has
    /// no settlement observer yet, and the settlement wakes no pump. The
    /// mailbox keeps the token as a settled background run, so the terminal
    /// can start a submission once it is posted.
    ///
    /// - Parameter session: The session whose mailbox tracks the run.
    /// - Returns: The terminal of the run.
    /// - Throws: When the run does not settle inside the mailbox wait.
    private static func settledRunTerminal(on session: any RoutedSession) async throws -> OperationEvent {
        let latch = RunLatch()
        await latch.open()
        let token = await trackFakeRun(on: session.mailbox, latch: latch, detailOnSettle: settledRunDetail)
        return try await MountFixtures.settledTerminal(of: token, in: session.mailbox)
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
    /// - Throws: When the run does not settle, or when the submission does
    ///   not reach the backend inside the bound.
    private static func startMailOnlyAnswer(on session: any RoutedSession, backend: PumpProbeBackend) async throws {
        let settledRun = try await settledRunTerminal(on: session)
        _ = try await session.respond(to: firstPrompt)
        await session.outbox.post(event: settledRun)
        try await BoundedWait.awaitPrompts(mailOnlySubmission, in: { backend.prompts })
        #expect(backend.prompts.last?.hasSuffix(RoutedSessionActor.settledRunDeliveryPrompt) == true)
    }

    /// Waits, bounded, until `count` caller messages wait in the outbox of
    /// `session`.
    ///
    /// - Parameters:
    ///   - count: How many waiting caller messages to wait for.
    ///   - session: The session whose outbox is watched.
    /// - Throws: ``SignalNeverArrived`` when the messages did not arrive
    ///   inside the bound.
    private static func awaitWaitingMessages(_ count: Int, on session: any RoutedSession) async throws {
        guard
            await BoundedWait.conditionReached(
                "\(count) caller messages waiting in the outbox",
                when: { session.outbox.messages.depth.waiting == count })
        else { throw SignalNeverArrived() }
    }

    // MARK: - Caller messages

    @Test("a send on an idle session starts a submission with no other call, and the answer of the message ends it")
    func aSendOnAnIdleSessionStartsASubmission() async throws {
        let dir = RouterTestFixtures.makeTempDir(prefix: "SessionMessagePumpTests")
        defer { try? FileManager.default.removeItem(at: dir) }
        let backend = PumpProbeBackend(script: [:])
        let (session, profile) = try await Self.makeSession(over: backend, dir: dir)

        let id = await session.send(Self.firstPrompt)

        // No driver call and no wait: the pump takes the message by itself.
        try await BoundedWait.awaitPrompts(1, in: { backend.prompts })
        #expect(await session.becomesIdle())
        #expect(backend.prompts == [Self.firstPrompt])
        #expect(await session.pendingMessages().isEmpty)
        #expect(await session.cancel(message: id) == .alreadyAnswered)
        withExtendedLifetime(profile) {}
    }

    @Test("cancel(message:) withdraws a message that waits: it never reaches a prompt")
    func cancelOfAWaitingMessageWithdrawsIt() async throws {
        let dir = RouterTestFixtures.makeTempDir(prefix: "SessionMessagePumpTests")
        defer { try? FileManager.default.removeItem(at: dir) }
        let latch = RunLatch()
        let backend = PumpProbeBackend(script: [1: .hold(latch)])
        let (session, profile) = try await Self.makeSession(over: backend, dir: dir)

        let first = Task { try await session.respond(to: Self.firstPrompt) }
        try await BoundedWait.awaitPrompts(1, in: { backend.prompts })
        let waiting = await session.send(Self.secondPrompt)
        #expect(await session.pendingMessages().map(\.id) == [waiting])

        #expect(await session.cancel(message: waiting) == .withdrawn)

        #expect(await session.pendingMessages().isEmpty)
        await latch.open()
        #expect(try await first.value == PumpProbeBackend.answer(ofCall: 1))
        #expect(await session.becomesIdle())
        #expect(backend.prompts == [Self.firstPrompt])
        withExtendedLifetime(profile) {}
    }

    @Test("cancel(message:) stops the submission that carries a message, and the pump then ends")
    func cancelOfAMessageInARunningSubmissionStopsIt() async throws {
        let dir = RouterTestFixtures.makeTempDir(prefix: "SessionMessagePumpTests")
        defer { try? FileManager.default.removeItem(at: dir) }
        let latch = RunLatch()
        let backend = PumpProbeBackend(script: [1: .hold(latch)])
        let (session, profile) = try await Self.makeSession(over: backend, dir: dir)

        let id = await session.send(Self.firstPrompt)
        try await BoundedWait.awaitPrompts(1, in: { backend.prompts })
        #expect(await session.messageQueueDepth().running == [id])

        #expect(await session.cancel(message: id) == .cancelledInSubmission)

        // The latch never opens, so only the cancel can end the held call.
        #expect(await BoundedWait.pumpStops(on: session))
        #expect(backend.prompts == [Self.firstPrompt])
        #expect(await session.cancel(message: id) == .alreadyAnswered)
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

        let first = Task { try await session.respond(to: Self.firstPrompt) }
        try await BoundedWait.awaitPrompts(1, in: { backend.prompts })
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
        #expect(session.outbox.messages.depth.waiting == 0)
        withExtendedLifetime(profile) {}
    }

    @Test("a continuation submission of an answer carries the caller messages that wait when it starts")
    func aContinuationCarriesTheWaitingMessages() async throws {
        let dir = RouterTestFixtures.makeTempDir(prefix: "SessionMessagePumpTests")
        defer { try? FileManager.default.removeItem(at: dir) }
        let latch = RunLatch()
        let backend = PumpProbeBackend(script: [1: .holdThenReject(latch)])
        let (session, profile) = try await Self.makeSession(over: backend, dir: dir)

        let first = Task { try await session.respond(to: Self.firstPrompt) }
        try await BoundedWait.awaitPrompts(1, in: { backend.prompts })
        let second = Task { try await session.respond(to: Self.secondPrompt) }
        try await Self.awaitWaitingMessages(1, on: session)

        // The first submission ends with a rejected tool call. The retry is a
        // continuation of the same answer, and the waiting prompt rides it.
        await latch.open()
        let firstAnswer = try await first.value
        let secondAnswer = try await second.value

        #expect(backend.prompts.count == 2)
        let retryPrompt = try #require(backend.prompts.last)
        #expect(retryPrompt.hasPrefix(Self.firstPrompt))
        #expect(retryPrompt.hasSuffix(RoutedSessionActor.messageSeparator + Self.secondPrompt))
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
        let settledRun = try await Self.settledRunTerminal(on: session)

        let first = Task { try await session.respond(to: Self.firstPrompt) }
        try await BoundedWait.awaitPrompts(1, in: { backend.prompts })
        await session.outbox.post(event: settledRun)
        await latch.open()
        let firstAnswer = try await first.value

        // The running submission did not take the mail.
        #expect(firstAnswer == PumpProbeBackend.answer(ofCall: 1))
        #expect(backend.prompts.first == Self.firstPrompt)

        // No caller asks again: the mail itself starts the next submission.
        try await BoundedWait.awaitPrompts(2, in: { backend.prompts })
        let deliveryPrompt = try #require(backend.prompts.last)
        #expect(deliveryPrompt.contains(OperationEventSegment.renderedLine(for: settledRun)))
        #expect(deliveryPrompt.hasSuffix(RoutedSessionActor.settledRunDeliveryPrompt))
        #expect(
            await BoundedWait.conditionReached("the outbox giving its mail to the delivery submission") {
                await session.outbox.pending().events.isEmpty
            })
        withExtendedLifetime(profile) {}
    }

    @Test("a delivery submission that fails before it writes an entry puts its mail back, and the pump does not retry it")
    func aFailedDeliveryPutsItsMailBackAndIsNotRetried() async throws {
        let dir = RouterTestFixtures.makeTempDir(prefix: "SessionMessagePumpTests")
        defer { try? FileManager.default.removeItem(at: dir) }
        let backend = PumpProbeBackend(script: [1: .answer, 2: .fail])
        let (session, profile) = try await Self.makeSession(over: backend, dir: dir)
        let settledRun = try await Self.settledRunTerminal(on: session)

        // One answered call attaches the outbox of the session to it, so a
        // posted terminal starts a delivery submission.
        _ = try await session.respond(to: Self.firstPrompt)
        await session.outbox.post(event: settledRun)
        try await BoundedWait.awaitPrompts(2, in: { backend.prompts })

        // The delivery submission failed with no `.prompt` entry, so the mail
        // goes back into the outbox, and no third call runs for it.
        #expect(
            await BoundedWait.conditionReached("the failed delivery putting its mail back") {
                await session.outbox.pending().events.map(\.event) == [settledRun]
            })
        #expect(await BoundedWait.pumpStops(on: session))
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
        #expect(retryPrompt.contains(RoutedSessionActor.settledRunDeliveryPrompt))
        #expect(retryPrompt.hasSuffix(RoutedSessionActor.messageSeparator + Self.secondPrompt))
        #expect(await session.messageQueueDepth() == MessageQueueDepth(waiting: 0, running: []))
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
        try await Self.startMailOnlyAnswer(on: session, backend: backend)

        let cancelled = Task { try await session.respond(to: Self.secondPrompt) }
        try await Self.awaitWaitingMessages(1, on: session)
        cancelled.cancel()

        // The cancel handler of the caller withdraws the message, which
        // gives its caller `CancellationError` before the value is read.
        try await Self.awaitWaitingMessages(0, on: session)
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        await latch.open()

        #expect(await session.becomesIdle())
        #expect(backend.prompts.count == Self.mailOnlyContinuation)
        #expect(backend.prompts.allSatisfy { !$0.contains(Self.secondPrompt) })
        withExtendedLifetime(profile) {}
    }

    // MARK: - Cancel

    @Test(
        "a cancel withdraws the waiting caller messages, stops the running submission, and keeps the waiting mail in the outbox"
    )
    func aCancelWithdrawsCallerMessagesStopsTheSubmissionAndKeepsTheMail() async throws {
        let dir = RouterTestFixtures.makeTempDir(prefix: "SessionMessagePumpTests")
        defer { try? FileManager.default.removeItem(at: dir) }
        let latch = RunLatch()
        let backend = PumpProbeBackend(script: [1: .hold(latch)])
        let (session, profile) = try await Self.makeSession(over: backend, dir: dir)
        let settledRun = try await Self.settledRunTerminal(on: session)

        let first = Task { try await session.respond(to: Self.firstPrompt) }
        try await BoundedWait.awaitPrompts(1, in: { backend.prompts })
        let second = Task { try await session.respond(to: Self.secondPrompt) }
        try await Self.awaitWaitingMessages(1, on: session)
        await session.outbox.post(event: settledRun)

        #expect(await session.cancel() == .requested)

        await #expect(throws: CancellationError.self) { try await second.value }
        await #expect(throws: CancellationError.self) { try await first.value }
        #expect(session.outbox.messages.depth.waiting == 0)
        #expect(await session.outbox.pending().events.map(\.event) == [settledRun])
        #expect(await BoundedWait.pumpStops(on: session))
        #expect(backend.prompts == [Self.firstPrompt])
        withExtendedLifetime(profile) {}
    }
}
