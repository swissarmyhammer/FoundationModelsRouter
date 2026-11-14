import Foundation
@testable import FoundationModelsRouter
import Testing

/// Task ^4sg1ev1: an answer that ends with a waiting status while nothing of
/// the session is pending gets one nudge to go on.
///
/// On flint4 django-13447 (2026-11-14), the root got the result of its review
/// agent as a tool output, then wrote "Waiting on the review double-check
/// agent" in the next pass. Nothing was pending, so the answer ended, and the
/// committer never ran.
@Suite("A waiting status with nothing pending gets one nudge")
struct StaleWaitNudgeTests {
    /// The suite's temp-directory prefix.
    private static let tempDirPrefix = "StaleWaitNudgeTests"

    /// The prompt the answer is driven with.
    private static let prompt = "review the change, then commit it"

    /// Answers `prompt` on a session over a ``StaleWaitLanguageModel`` whose
    /// first `waitingCalls` calls answer with the waiting status.
    ///
    /// - Parameter waitingCalls: How many calls answer with the waiting status.
    /// - Returns: The answer and the log of the model.
    /// - Throws: What the resolve or the answer throws.
    private static func answer(waitingCalls: Int) async throws -> (answer: String, log: RejectingModelLog) {
        let directory = RouterTestFixtures.makeTempDir(prefix: tempDirPrefix)
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = RejectingModelLog()
        let router = RouterTestFixtures.makeRouter(
            cacheDir: directory,
            loader: StubModelLoader(
                container: LiveBackendContainer(model: StaleWaitLanguageModel(log: log, waitingCalls: waitingCalls)),
                dimension: RouterTestFixtures.stubDimension))
        let profile = try await router.resolve(profile: RouterTestFixtures.profile(), reporting: ResolutionProgress())
        let session = profile.standard.makeSession()
        let answer = try await session.respond(to: prompt)
        await session.close()
        return (answer, log)
    }

    @Test("a waiting status with nothing pending goes on one more time, and the answer is the next reply")
    func waitingStatusWithNothingPendingGoesOn() async throws {
        let (answer, log) = try await Self.answer(waitingCalls: 1)

        #expect(answer == StaleWaitLanguageModel.Executor.answerText)
        let transcripts = log.transcriptTexts
        #expect(transcripts.count == 2)
        let nudged = try #require(transcripts.last).joined(separator: "\n")
        #expect(nudged.contains(RoutedSessionActor.staleWaitPrompt))
    }

    @Test("the nudge runs once in an answer: a second waiting status ends the answer")
    func secondWaitingStatusEndsTheAnswer() async throws {
        let (answer, log) = try await Self.answer(waitingCalls: 2)

        #expect(answer == StaleWaitLanguageModel.Executor.waitingText)
        #expect(log.transcriptTexts.count == 2)
    }
}
