import Foundation
import Testing

@testable import FoundationModelsRouter

/// Exercises task ^x7cxsg3: the events of a submission and of an answer
/// (`generation-queue.md`, section 5.6).
///
/// A submission is one SDK call of the chain that answers the messages of a
/// session. It opens with ``SessionEvent/submissionStarted(_:)`` and closes
/// with ``SessionEvent/submissionEnded(_:)``. The chain ends with one
/// ``SessionEvent/answered(_:)``, or with one
/// ``SessionEvent/answerFailed(_:)`` when it gives no answer.
///
/// Everything runs against ``SessionMessagePumpTests/PumpProbeBackend``, a
/// stub backend that can hold a call open, so the suite needs no network and
/// no GPU. Each wait waits for an event: a prompt that reaches the backend,
/// or the end of an answer on the feed of the session. No clock ends a wait.
@Suite("The submission and answer events of a session (task ^x7cxsg3)")
struct SubmissionAnswerEventTests {
    /// The backend the suite scripts.
    private typealias Backend = SessionMessagePumpTests.PumpProbeBackend

    /// The suite's temp-directory prefix, handed to
    /// ``RouterTestFixtures/makeTempDir(prefix:)``.
    private static let tempDirPrefix = "SubmissionAnswerEventTests"

    /// The prompt of the first message, whose submission the test holds open.
    private static let firstPrompt = "first question"

    /// The prompt of the second message, which arrives while the first
    /// submission runs.
    private static let secondPrompt = "second question"

    /// The prompt of the third message, which also arrives while the first
    /// submission runs.
    private static let thirdPrompt = "third question"

    /// How many answers the test with two chains waits for.
    private static let twoAnswers = 2

    /// Makes a session over `backend`.
    ///
    /// - Parameters:
    ///   - backend: The backend the session runs on.
    ///   - dir: The temporary directory the router caches under.
    /// - Returns: The session and the profile that keeps its models resident.
    private static func makeSession(
        over backend: Backend, dir: URL
    ) async throws -> (session: any RoutedSession, profile: LanguageModelProfile) {
        let profile = try await RouterTestFixtures.resolveStandardProfile(
            over: SessionMessagePumpTests.PumpProbeContainer(backend: backend), cacheDir: dir
        ).profile
        return (profile.standard.makeSession(), profile)
    }

    /// Waits until `log` holds `count` events that end an answer:
    /// ``SessionEvent/answered(_:)`` or ``SessionEvent/answerFailed(_:)``.
    ///
    /// - Parameters:
    ///   - count: How many ends of an answer to wait for.
    ///   - log: The log of the session-wide feed.
    /// - Throws: ``ConditionNeverHeld`` when the test task was cancelled first.
    private static func waitForAnswersToEnd(_ count: Int, in log: SessionEventLog) async throws {
        try await log.wait(until: { $0.answers.count + $0.answerFailures.count >= count })
    }

    @Test("one answered event names every message that its chain delivered in one submission")
    func anAnswerNamesEveryMessageOfItsSubmission() async throws {
        let dir = RouterTestFixtures.makeTempDir(prefix: Self.tempDirPrefix)
        defer { try? FileManager.default.removeItem(at: dir) }
        let latch = RunLatch()
        let backend = Backend(script: [1: .hold(latch)])
        let (session, profile) = try await Self.makeSession(over: backend, dir: dir)
        let (log, drain) = await SessionEventLog.watch(session)

        let first = try await MailQueueFixtures.startHeldAnswer(Self.firstPrompt, on: session, backend: backend)
        let second = try session.send(Self.secondPrompt)
        let third = try session.send(Self.thirdPrompt)
        await latch.open()
        try await Self.waitForAnswersToEnd(Self.twoAnswers, in: log)
        drain.cancel()

        let events = await log.events
        #expect(events.eventsInsideEachAnswerFrame().count == Self.twoAnswers)
        #expect(events.answers.map(\.mailIds) == [[first], [second, third]])
        #expect(events.answers.map(\.reply) == [Backend.answer(ofCall: 1), Backend.answer(ofCall: 2)])
        #expect(events.submissionStarts.map(\.mailIds) == [[first], [second, third]])
        #expect(events.submissionStarts.map(\.cause) == [.message, .message])
        #expect(events.answerFailures.isEmpty)
        withExtendedLifetime(profile) {}
    }

    @Test("one answered event names the message that joined its chain in a continuation")
    func anAnswerNamesAMessageThatJoinedAContinuation() async throws {
        let dir = RouterTestFixtures.makeTempDir(prefix: Self.tempDirPrefix)
        defer { try? FileManager.default.removeItem(at: dir) }
        let latch = RunLatch()
        let backend = Backend(script: [1: .holdThenReject(latch)])
        let (session, profile) = try await Self.makeSession(over: backend, dir: dir)
        let (log, drain) = await SessionEventLog.watch(session)

        let first = try await MailQueueFixtures.startHeldAnswer(Self.firstPrompt, on: session, backend: backend)
        let second = try session.send(Self.secondPrompt)
        // The first submission ends with a rejected tool call. The retry is a
        // continuation of the same chain, and the waiting message joins it.
        await latch.open()
        try await Self.waitForAnswersToEnd(1, in: log)
        drain.cancel()

        let events = await log.events
        _ = eventsInsideAnswerFrame(events)
        #expect(events.answers.map(\.mailIds) == [[first, second]])
        let starts = events.submissionStarts
        #expect(starts.map(\.mailIds) == [[first], [second]])
        #expect(starts.map(\.cause) == [.message, .continuation])
        #expect(events.submissionEnds.map(\.submissionId) == starts.map(\.submissionId))
        withExtendedLifetime(profile) {}
    }

    @Test(
        "a chain that cancelAll() stops sends answerFailed with the reason cancelled at once, no answered, and no later end of its submission"
    )
    func aCancelledChainSendsAnswerFailed() async throws {
        let dir = RouterTestFixtures.makeTempDir(prefix: Self.tempDirPrefix)
        defer { try? FileManager.default.removeItem(at: dir) }
        let latch = RunLatch()
        let backend = Backend(script: [1: .hold(latch)])
        let (session, profile) = try await Self.makeSession(over: backend, dir: dir)
        defer {
            await latch.open()
            await session.close()
        }
        let (log, drain) = await SessionEventLog.watch(session)

        let id = try await MailQueueFixtures.startHeldAnswer(Self.firstPrompt, on: session, backend: backend)
        // The latch never opens, so only cancelAll() can end the held call.
        let signal = session.cancelAll()
        #expect(try await session.awaitTerminal(of: signal) == .signalDone(signal))
        try await Self.waitForAnswersToEnd(1, in: log)
        // cancelAll() does not wait for the pump. The test waits for the end
        // of the stopped work, so a late event of that work can come first.
        #expect(await session.isIdleOnceThePumpEnds())
        // The close finishes the feed after each event of the stopped work,
        // and the drain ends after the last of them. Thus a late end of the
        // submission is in the log now, or it never came.
        await session.close()
        await drain.value

        let events = await log.events
        #expect(events.answerFailures == [AnswerFailure(mailIds: [id], reason: .cancelled)])
        #expect(events.answers.isEmpty)
        // The submission started. The output drops each later event of the
        // stopped answer, also the end of its submission.
        #expect(events.submissionStarts.map(\.mailIds) == [[id]])
        #expect(events.submissionEnds.isEmpty)
        withExtendedLifetime(profile) {}
    }

    @Test("a chain that fails with an error sends answerFailed with the text of the error")
    func aFailedChainSendsAnswerFailedWithTheError() async throws {
        let dir = RouterTestFixtures.makeTempDir(prefix: Self.tempDirPrefix)
        defer { try? FileManager.default.removeItem(at: dir) }
        let backend = Backend(script: [1: .fail])
        let (session, profile) = try await Self.makeSession(over: backend, dir: dir)
        let (log, drain) = await SessionEventLog.watch(session)

        let id = try session.send(Self.firstPrompt)
        try await Self.waitForAnswersToEnd(1, in: log)
        drain.cancel()

        let events = await log.events
        _ = eventsInsideAnswerFrame(events)
        let reason = AnswerFailure.Reason.error(String(describing: SessionMessagePumpTests.PumpProbeError.refused))
        #expect(events.answerFailures == [AnswerFailure(mailIds: [id], reason: reason)])
        #expect(events.answers.isEmpty)
        withExtendedLifetime(profile) {}
    }

    @Test("a respond whose caller cancels its task throws CancellationError, does not stop the process, and does not stop the running answer")
    func aRespondWhoseCallerCancelsThrowsCancellationError() async throws {
        let dir = RouterTestFixtures.makeTempDir(prefix: Self.tempDirPrefix)
        defer { try? FileManager.default.removeItem(at: dir) }
        let latch = RunLatch()
        let backend = Backend(script: [1: .hold(latch)])
        let (session, profile) = try await Self.makeSession(over: backend, dir: dir)
        let (log, drain) = await SessionEventLog.watch(session)

        let run = Task { try await session.respond(to: Self.firstPrompt, observing: nil) }
        try await backend.waitForPrompts(1, endingOnEndOf: run)
        // The stream of the message ends with no error when the task that
        // reads it is cancelled. The respond must throw, not stop the process.
        run.cancel()

        await #expect(throws: CancellationError.self) { try await run.value }

        // The mail left the queue before the cancel, so the cancel of the
        // caller does not stop its answer: the answer goes on to its end.
        await latch.open()
        try await Self.waitForAnswersToEnd(1, in: log)
        drain.cancel()

        let events = await log.events
        #expect(events.answers.map(\.reply) == [Backend.answer(ofCall: 1)])
        #expect(events.answerFailures.isEmpty)
        withExtendedLifetime(profile) {}
    }

    /// The text of the error in the failure that
    /// ``aStreamThatEndsWithAnAnswerFailureThrowsIt()`` feeds.
    private static let failureText = "the model refused"

    @Test("a message stream that ends with answerFailed and no error throws that failure to the reader")
    func aStreamThatEndsWithAnAnswerFailureThrowsIt() async throws {
        let failure = AnswerFailure(mailIds: [], reason: .error(Self.failureText))
        let events = AsyncThrowingStream<SessionEvent, Error> { continuation in
            continuation.yield(.answerFailed(failure))
            continuation.finish()
        }

        await #expect(throws: failure) { try await SessionAnswer.awaitEnd(of: events, observing: nil) }
    }
}
