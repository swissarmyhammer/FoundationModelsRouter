import Foundation
import FoundationModels
@testable import FoundationModelsRouter
import MLXLMCommon
import Testing

/// Task ^naqfcqj: a rejected tool call goes back to the model, and the turn
/// continues.
///
/// When the model writes a tool call that the parser cannot accept,
/// `MLXLanguageModel` throws `RejectedToolCallError`. Router tells the model
/// why the call was rejected and runs the attempt again, so the model can
/// write the call again. The retries have a bound, so a model that rejects
/// every time still ends the turn with the rejection error.
///
/// Each test drives the production backend and a real `LanguageModelSession`
/// over a ``RejectingLanguageModel``, so no GPU is in the loop.
@Suite("A rejected tool call goes back to the model as a tool error")
struct RejectedToolCallRetryTests {
    /// The suite's temp-directory prefix, handed to
    /// ``RouterTestFixtures/makeTempDir(prefix:)``.
    private static let tempDirPrefix = "RejectedToolCallRetryTests"

    /// The prompt every turn of this suite is driven with.
    private static let prompt = "run the code and tell me the result"

    /// The generation calls of a turn whose first call is rejected once: the
    /// rejected attempt, and the one retry that answers.
    private static let attemptsWithOneRetry = 2

    /// A rejection count no turn can reach, so the model rejects every
    /// generation call the turn makes.
    private static let rejectsEveryCall = Int.max

    /// A routed session over a ``RejectingLanguageModel``, with the log its
    /// model writes into and the directory the router cached into.
    private struct Fixture {
        /// The vended session a test drives its turn on.
        let session: RoutedSession

        /// The log of the transcript of each generation call.
        let log: RejectingModelLog

        /// The temp directory the router cached into, which the caller must remove.
        let directory: URL
    }

    /// Builds a router and a session over a model that rejects its first
    /// `rejectionCount` generation calls.
    ///
    /// - Parameter rejectionCount: How many calls end with a rejected tool call.
    /// - Returns: The session, its log, and the temp directory.
    /// - Throws: Whatever profile resolution throws.
    private static func makeFixture(rejectionCount: Int) async throws -> Fixture {
        let directory = RouterTestFixtures.makeTempDir(prefix: tempDirPrefix)
        let log = RejectingModelLog()
        let container = LiveBackendContainer(
            model: RejectingLanguageModel(rejectionCount: rejectionCount, log: log)
        )
        let router = RouterTestFixtures.makeRouter(
            cacheDir: directory,
            loader: StubModelLoader(container: container, dimension: RouterTestFixtures.stubDimension)
        )
        let profile = try await router.resolve(
            profile: RouterTestFixtures.profile(), reporting: ResolutionProgress()
        )
        return Fixture(session: profile.standard.makeSession(), log: log, directory: directory)
    }

    @Test("the retry attempt sees why the call was rejected, and the turn ends with the answer")
    func retryAttemptSeesTheRejection() async throws {
        let fixture = try await Self.makeFixture(rejectionCount: 1)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let answer = try await fixture.session.respond(to: Self.prompt)

        #expect(answer == RejectingLanguageModel.Executor.answerText)
        let transcripts = fixture.log.transcriptTexts
        #expect(transcripts.count == Self.attemptsWithOneRetry)
        let retried = try #require(transcripts.last).joined(separator: "\n")
        #expect(retried.contains(Self.prompt))
        #expect(retried.contains(RejectedToolCall.Reason.invalidArguments.rawValue))
        #expect(retried.contains(RejectingLanguageModel.Executor.rejectedToolName))
        #expect(!retried.contains(RejectingLanguageModel.Executor.rejectedRawText))
    }

    @Test("the retries stop at the bound, and the turn then fails with the rejection error")
    func retriesStopAtTheBound() async throws {
        let fixture = try await Self.makeFixture(rejectionCount: Self.rejectsEveryCall)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let error = await #expect(throws: RejectedToolCallError.self) {
            _ = try await fixture.session.respond(to: Self.prompt)
        }

        #expect(error?.rejection == RejectingLanguageModel.Executor.rejection)
        let transcripts = fixture.log.transcriptTexts
        #expect(transcripts.count == RejectedToolCallRetry.limit + 1)
        let lastRetry = try #require(transcripts.last).joined(separator: "\n")
        #expect(lastRetry.contains(Self.prompt))
        #expect(!lastRetry.contains(RejectingLanguageModel.Executor.rejectedRawText))
    }
}
