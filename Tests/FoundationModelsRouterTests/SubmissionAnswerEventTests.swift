import Foundation
import FoundationModelsRouterTestSupport
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
/// no GPU. No wait here is a bare `await` on an answer that can stay
/// suspended: each wait is bounded, so a regression fails the test and does
/// not hang the run.
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

    /// Waits, bounded, until `backend` received `count` prompts.
    ///
    /// - Parameters:
    ///   - count: How many prompts to wait for.
    ///   - backend: The backend to watch.
    /// - Throws: ``SignalNeverArrived`` when the prompts did not arrive
    ///   inside the bound.
    private static func awaitPrompts(_ count: Int, on backend: Backend) async throws {
        let arrived = await BoundedWait.conditionReached("\(count) prompts reaching the backend") {
            backend.prompts.count >= count
        }
        try #require(arrived)
    }

    /// Waits, bounded, until `log` holds `count` events that end an answer:
    /// ``SessionEvent/answered(_:)`` or ``SessionEvent/answerFailed(_:)``.
    ///
    /// - Parameters:
    ///   - count: How many ends of an answer to wait for.
    ///   - log: The log of the session-wide feed.
    /// - Returns: `true` when the events arrived inside the bound.
    private static func answersEnd(_ count: Int, in log: SessionEventLog) async -> Bool {
        await BoundedWait.conditionReached("\(count) answers ending on the session feed") {
            let events = await log.events
            return events.answers.count + events.answerFailures.count >= count
        }
    }

    @Test("one answered event names every message that its chain delivered in one submission")
    func anAnswerNamesEveryMessageOfItsSubmission() async throws {
        let dir = RouterTestFixtures.makeTempDir(prefix: Self.tempDirPrefix)
        defer { try? FileManager.default.removeItem(at: dir) }
        let latch = RunLatch()
        let backend = Backend(script: [1: .hold(latch)])
        let (session, profile) = try await Self.makeSession(over: backend, dir: dir)
        let (log, drain) = await SessionEventLog.watch(session)

        let first = await session.send(Self.firstPrompt)
        try await Self.awaitPrompts(1, on: backend)
        let second = await session.send(Self.secondPrompt)
        let third = await session.send(Self.thirdPrompt)
        await latch.open()
        let ended = await Self.answersEnd(Self.twoAnswers, in: log)
        drain.cancel()

        #expect(ended)
        let events = await log.events
        #expect(events.answers.map(\.messageIds) == [[first], [second, third]])
        #expect(events.answers.map(\.reply) == [Backend.answer(ofCall: 1), Backend.answer(ofCall: 2)])
        #expect(events.submissionStarts.map(\.messageIds) == [[first], [second, third]])
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

        let first = await session.send(Self.firstPrompt)
        try await Self.awaitPrompts(1, on: backend)
        let second = await session.send(Self.secondPrompt)
        // The first submission ends with a rejected tool call. The retry is a
        // continuation of the same chain, and the waiting message joins it.
        await latch.open()
        let ended = await Self.answersEnd(1, in: log)
        drain.cancel()

        #expect(ended)
        let events = await log.events
        #expect(events.answers.map(\.messageIds) == [[first, second]])
        let starts = events.submissionStarts
        #expect(starts.map(\.messageIds) == [[first], [second]])
        #expect(starts.map(\.cause) == [.message, .continuation])
        #expect(events.submissionEnds.map(\.submissionId) == starts.map(\.submissionId))
        withExtendedLifetime(profile) {}
    }

    @Test("a cancelled chain sends answerFailed with the reason cancelled, and no answered")
    func aCancelledChainSendsAnswerFailed() async throws {
        let dir = RouterTestFixtures.makeTempDir(prefix: Self.tempDirPrefix)
        defer { try? FileManager.default.removeItem(at: dir) }
        let latch = RunLatch()
        let backend = Backend(script: [1: .hold(latch)])
        let (session, profile) = try await Self.makeSession(over: backend, dir: dir)
        let (log, drain) = await SessionEventLog.watch(session)

        let id = await session.send(Self.firstPrompt)
        try await Self.awaitPrompts(1, on: backend)
        #expect(await session.cancel() == .requested)
        // The latch never opens, so only the cancel can end the held call.
        let ended = await Self.answersEnd(1, in: log)
        drain.cancel()

        #expect(ended)
        let events = await log.events
        #expect(events.answerFailures == [AnswerFailure(messageIds: [id], reason: .cancelled)])
        #expect(events.answers.isEmpty)
        #expect(events.submissionEnds.count == 1)
        withExtendedLifetime(profile) {}
    }

    @Test("a chain that fails with an error sends answerFailed with the text of the error")
    func aFailedChainSendsAnswerFailedWithTheError() async throws {
        let dir = RouterTestFixtures.makeTempDir(prefix: Self.tempDirPrefix)
        defer { try? FileManager.default.removeItem(at: dir) }
        let backend = Backend(script: [1: .fail])
        let (session, profile) = try await Self.makeSession(over: backend, dir: dir)
        let (log, drain) = await SessionEventLog.watch(session)

        let id = await session.send(Self.firstPrompt)
        let ended = await Self.answersEnd(1, in: log)
        drain.cancel()

        #expect(ended)
        let events = await log.events
        let reason = AnswerFailure.Reason.error(String(describing: SessionMessagePumpTests.PumpProbeError.refused))
        #expect(events.answerFailures == [AnswerFailure(messageIds: [id], reason: reason)])
        #expect(events.answers.isEmpty)
        withExtendedLifetime(profile) {}
    }
}
