import Foundation
import FoundationModels
import FoundationModelsRouterTestSupport
import Testing

@testable import FoundationModelsRouter

/// Task ^93kjn94: a turn holds its session's turn lock, and a place of the
/// generation queue only for each of its passes (`generation-queue.md`,
/// section 2).
///
/// Each session is a routed session over one ``LiveBackendContainer``, so each
/// pass of a turn goes through the production backend and takes the one queue
/// of that container. A tool body runs between two passes, where the turn
/// holds no place. The cancellation of a turn whose pass waits for a place is
/// held by `NestedGenerationReentryTests`.
///
/// No wait here is a bare `await` on a turn that can stay suspended. Each turn
/// signals a semaphore when it ends, and the test observes that signal under
/// the bound of ``BoundedWait``. A test then opens every latch and releases
/// every step before it awaits a turn, so a regression fails the test and does
/// not hang the run.
@Suite("A turn holds a generation place only for its passes (task ^93kjn94)")
struct GenerationQueueTurnTests {
    /// A tool whose body signals that it started, and then waits on a latch:
    /// the shape of a tool that waits for a person or for a child session.
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

    /// A router over `container`, and the standard test profile it resolved.
    private struct Fixture {
        /// The router the profile came from. Kept alive for the whole test.
        let router: Router

        /// The resolved profile sessions are vended from.
        let profile: LanguageModelProfile
    }

    /// The prompt of the first session of a test.
    private static let firstPrompt = "a"

    /// The prompt of the second session of a test.
    private static let secondPrompt = "b"

    /// How many passes of one turn call a tool in the alternation test.
    private static let alternatingToolRounds = 3

    /// How many sessions run a tool loop in the alternation test.
    private static let loopingSessionCount = 2

    /// Builds a router whose loader vends `container`, and resolves the
    /// standard test profile.
    ///
    /// - Parameters:
    ///   - container: The container every generation slot resolves to.
    ///   - dir: The temporary directory the router caches under.
    /// - Returns: The router and its profile.
    /// - Throws: What the resolve throws.
    private static func makeFixture(container: any LoadedLLMContainer, dir: URL) async throws -> Fixture {
        let router = RouterTestFixtures.makeRouter(
            cacheDir: dir,
            loader: StubModelLoader(container: container, dimension: RouterTestFixtures.stubDimension))
        let profile = try await router.resolve(profile: RouterTestFixtures.profile(), reporting: ResolutionProgress())
        return Fixture(router: router, profile: profile)
    }

    /// Starts `turn` in a task of its own that signals `finished` when it ends,
    /// however it ends.
    ///
    /// - Parameters:
    ///   - finished: The semaphore to signal when the turn ends.
    ///   - turn: The turn to run.
    /// - Returns: The task that runs the turn.
    private static func startTurn(
        signalling finished: AsyncSemaphore,
        _ turn: @escaping @Sendable () async throws -> String
    ) -> Task<String, Error> {
        Task {
            defer { finished.signal() }
            return try await turn()
        }
    }

    @Test("a session waiting in a tool body holds no place, so another session over the same model completes a turn")
    func aToolBodyThatWaitsLetsAnotherSessionCompleteATurn() async throws {
        let dir = RouterTestFixtures.makeTempDir(prefix: "GenerationQueueTurnTests")
        defer { try? FileManager.default.removeItem(at: dir) }
        let passes = ObservedPassLog()
        let container = LiveBackendContainer(model: ToolLoopPassModel(toolRounds: 1, passes: passes, step: nil))
        let fixture = try await Self.makeFixture(container: container, dir: dir)
        let entered = AsyncSemaphore(value: 0)
        let latch = RunLatch()
        let waiting = fixture.profile.standard.makeSession(tools: [WaitingTool(entered: entered, latch: latch)])
        let other = fixture.profile.standard.makeSession()

        let waitingFinished = AsyncSemaphore(value: 0)
        let waitingTurn = Self.startTurn(signalling: waitingFinished) {
            try await waiting.respond(to: Self.firstPrompt)
        }
        let toolStarted = await BoundedWait.signalArrived(entered, named: "the tool body of the waiting session")

        let otherFinished = AsyncSemaphore(value: 0)
        let otherTurn = Self.startTurn(signalling: otherFinished) {
            try await other.respond(to: Self.secondPrompt)
        }
        let otherEndedDuringTheWait = await BoundedWait.signalArrived(
            otherFinished, named: "the whole turn of the other session, while the tool body waits")

        await latch.open()
        let otherAnswer = try await otherTurn.value
        let waitingAnswer = try await waitingTurn.value

        #expect(toolStarted)
        #expect(otherEndedDuringTheWait)
        #expect(otherAnswer == ToolLoopPassModel.answer(to: Self.secondPrompt))
        #expect(waitingAnswer == ToolLoopPassModel.answer(to: Self.firstPrompt))
        #expect(passes.recorded.map(\.prompt) == [Self.firstPrompt, Self.secondPrompt, Self.firstPrompt])
        #expect(await BoundedWait.signalArrived(waitingFinished, named: "the end of the waiting turn"))
        #expect(container.generationQueue.availablePlaces == 1)
        withExtendedLifetime(fixture) {}
    }

    @Test("two sessions with long tool loops over one model take alternate passes, first in first out")
    func twoToolLoopsTakeAlternatePasses() async throws {
        let dir = RouterTestFixtures.makeTempDir(prefix: "GenerationQueueTurnTests")
        defer { try? FileManager.default.removeItem(at: dir) }
        let passes = ObservedPassLog()
        let step = AsyncSemaphore(value: 0)
        let container = LiveBackendContainer(
            model: ToolLoopPassModel(toolRounds: Self.alternatingToolRounds, passes: passes, step: step))
        let queue = container.generationQueue
        let fixture = try await Self.makeFixture(container: container, dir: dir)
        let first = fixture.profile.standard.makeSession(tools: [MountFixtures.FastTool()])
        let second = fixture.profile.standard.makeSession(tools: [MountFixtures.FastTool()])
        let passesPerTurn = Self.alternatingToolRounds + 1
        let totalPasses = Self.loopingSessionCount * passesPerTurn

        let firstFinished = AsyncSemaphore(value: 0)
        let firstTurn = Self.startTurn(signalling: firstFinished) { try await first.respond(to: Self.firstPrompt) }
        let firstInside = await BoundedWait.conditionReached("the first pass of the first session") {
            passes.recorded.count == 1
        }
        let secondFinished = AsyncSemaphore(value: 0)
        let secondTurn = Self.startTurn(signalling: secondFinished) { try await second.respond(to: Self.secondPrompt) }
        let secondQueued = await BoundedWait.conditionReached("the first pass of the second session in the queue") {
            queue.waiterCount == 1
        }

        // Release one pass at a time. The next pass to start is the one the
        // queue admits, and the session that just ran a pass joins the queue
        // again after its tool body, behind the other session.
        var everyStepWasObserved = firstInside && secondQueued
        for released in 1..<totalPasses where everyStepWasObserved {
            step.signal()
            let isLastPass = released + 1 == totalPasses
            everyStepWasObserved = await BoundedWait.conditionReached("pass \(released + 1) started") {
                passes.recorded.count == released + 1 && (isLastPass || queue.waiterCount == 1)
            }
        }
        for _ in passes.recorded.count...totalPasses { step.signal() }
        let firstAnswer = try await firstTurn.value
        let secondAnswer = try await secondTurn.value

        let alternating = (0..<passesPerTurn).flatMap { _ in [Self.firstPrompt, Self.secondPrompt] }
        #expect(everyStepWasObserved)
        #expect(passes.recorded.map(\.prompt) == alternating)
        #expect(firstAnswer == ToolLoopPassModel.answer(to: Self.firstPrompt))
        #expect(secondAnswer == ToolLoopPassModel.answer(to: Self.secondPrompt))
        #expect(await BoundedWait.signalArrived(firstFinished, named: "the end of the first loop"))
        #expect(await BoundedWait.signalArrived(secondFinished, named: "the end of the second loop"))
        #expect(queue.availablePlaces == 1)
        withExtendedLifetime(fixture) {}
    }
}
