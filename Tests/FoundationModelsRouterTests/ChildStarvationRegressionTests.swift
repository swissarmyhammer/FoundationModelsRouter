import Foundation
import FoundationModels
import FoundationModelsRouterTestSupport
import Testing

@testable import FoundationModelsRouter

/// Task ^qhgfajc: a lock must not cross over a tool call, only over the call
/// into the model.
///
/// bench24-1023b, django__django-14999: the root session started a diagnose
/// child. The first generation of the child started 23 minutes later, after
/// the one SDK call of the root ended, because that whole call was one job of
/// the queue of the model. Here a parent session runs one SDK call whose tool
/// body waits for the test. A child session over the same model generates
/// during that wait. The stub model gives one generation at a time, first in
/// first out, as MLX does (``FIFOGenerationLock``).
///
/// Each wait waits for an event, inside the limit of ``BoundedWait``.
@Suite("A child session generates while a tool body of its parent waits (task ^qhgfajc)")
struct ChildStarvationRegressionTests {
    /// A tool whose body signals that it started, and then waits on a latch:
    /// the shape of a tool that waits for a child agent.
    private struct WaitingTool: Tool {
        let name = "waiting_tool"
        let description = "signals that it started, then waits until its latch opens"

        /// Signalled once when the body starts.
        let entered: AsyncSemaphore

        /// The latch the body waits on.
        let latch: RunLatch

        func call(arguments: MountArguments) async throws -> String {
            entered.signal()
            await latch.waitUntilOpen()
            return arguments.value
        }
    }

    /// The prompt of the parent.
    private static let parentPrompt = "parent"

    /// The prompt of the child.
    private static let childPrompt = "child"

    /// The temp-directory prefix of this suite.
    private static let tempDirPrefix = "ChildStarvationRegressionTests"

    @Test("a child session on the same model ends its first generation before the SDK call of its parent ends")
    func aChildGeneratesWhileTheToolBodyOfItsParentWaits() async throws {
        let dir = RouterTestFixtures.makeTempDir(prefix: Self.tempDirPrefix)
        defer { try? FileManager.default.removeItem(at: dir) }
        let fixture = PassObservingFixture(toolRounds: 1)
        await fixture.latch.open()
        let resolved = try await RouterTestFixtures.resolveStandardProfile(over: fixture.container, cacheDir: dir)
        let entered = AsyncSemaphore(value: 0)
        let toolLatch = RunLatch()
        let parent = resolved.profile.standard.makeSession(tools: [WaitingTool(entered: entered, latch: toolLatch)])
        let child = resolved.profile.standard.makeSession()
        // The tool latch opens before the closes, also when the test throws:
        // a close waits for the held tool body.
        defer { await SessionFixtureLifecycle.close([parent, child], opening: [toolLatch]) }

        let parentAnswerTask = Task { try await parent.respond(to: Self.parentPrompt) }
        try await BoundedWait.run {
            try await RecordedWaitResult.wait(forPermitOf: entered, endingOnEndOf: parentAnswerTask)
        }

        // The tool body of the parent waits now, inside the SDK call of the
        // parent. The child generates and answers in that wait.
        let childAnswer = try await BoundedWait.value(of: Task { try await child.respond(to: Self.childPrompt) })
        let passesDuringTheToolBody = fixture.passes.recorded.map(\.prompt)

        await toolLatch.open()
        let parentAnswer = try await BoundedWait.value(of: parentAnswerTask)

        #expect(childAnswer == PassObservingModel.answer(to: Self.childPrompt))
        #expect(passesDuringTheToolBody == [Self.parentPrompt, Self.childPrompt])
        #expect(parentAnswer == PassObservingModel.answer(to: Self.parentPrompt))
        #expect(
            fixture.passes.recorded.map(\.prompt) == [Self.parentPrompt, Self.childPrompt, Self.parentPrompt])
        withExtendedLifetime(resolved) {}
    }
}
