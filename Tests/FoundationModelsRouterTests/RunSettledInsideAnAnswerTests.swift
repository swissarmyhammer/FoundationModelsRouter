import Foundation
import FoundationModels
import FoundationModelsRouterTestSupport
import Testing

@testable import FoundationModelsRouter

/// Task ^zetnz36: a background run that settles while an answer runs its
/// tool calls reaches the model inside the same answer, with the next tool
/// result. A model that keeps calling tools in one answer would otherwise
/// learn the result only after its answer ends.
///
/// The test drives the production backend and a real `LanguageModelSession`
/// over a ``NoOpToolCallModel`` that starts the job, then makes one real
/// `runCode` call. The body of that call (``JobSettlingRunCodeTool``) lets
/// the job settle, and gives its result only after the session sent
/// ``SessionEvent/runSettled(_:)``. No GPU is in the loop.
@Suite("A run that settles inside an answer reaches the model with the next tool result", .timeLimit(.minutes(1)))
struct RunSettledInsideAnAnswerTests {
    /// The suite's temp-directory prefix.
    private static let tempDirPrefix = "RunSettledInsideAnAnswerTests"

    /// The prompt of the answer.
    private static let prompt = "do the work"

    /// The snippet of the real `runCode` call.
    private static let realCode = "tools.search()"

    /// The index of the model call after the result of the `runCode` call:
    /// the first call starts the job, the second calls `runCode`.
    private static let callAfterTheToolResult = 2

    /// Whether `event` is ``SessionEvent/runSettled(_:)``.
    ///
    /// - Parameter event: One event of the session.
    /// - Returns: `true` for a settled run.
    private static func isRunSettled(_ event: SessionEvent) -> Bool {
        guard case .runSettled = event else { return false }
        return true
    }

    @Test("the model call after the tool result reads the result of the settled job")
    func theNextModelCallReadsTheSettledJob() async throws {
        let settled = RunLatch()
        let fixture = try await NoOpToolCallSessionFixture.make(
            startsJob: true, codes: [Self.realCode],
            runCodeTool: { runs, gate in JobSettlingRunCodeTool(runs: runs, gate: gate, settled: settled) },
            tempDirPrefix: Self.tempDirPrefix)
        defer { await fixture.end() }
        let (events, drain) = await SessionEventLog.watch(fixture.session)
        defer { drain.cancel() }
        let opener = Task {
            try await events.wait(until: { $0.contains(where: Self.isRunSettled) }, endingOnEndOf: drain)
            await settled.open()
        }
        defer { opener.cancel() }

        _ = try await fixture.session.respond(to: Self.prompt)

        let next = try #require(fixture.log.renders.dropFirst(Self.callAfterTheToolResult).first)
        #expect(next.promptTexts.last?.contains(NoOpToolCallSessionFixture.jobOutput) == true)
    }
}
