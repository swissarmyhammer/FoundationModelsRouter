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
/// Task ^44y6ba4 removed the permit loan: a tool body, a nested turn and a
/// background run hold nothing, so each generates through the queue alone.
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

    /// A tool whose body asks a child session for a whole turn and answers
    /// with the answer of the child: the shape of an agent tool.
    private struct ChildTurnTool: Tool {
        let name = "child_turn_tool"
        let description = "asks a child session for a turn, and answers with its answer"

        /// The session the body asks for a turn.
        let child: any RoutedSession

        func call(arguments: MountArguments) async throws -> String {
            try await child.respond(to: GenerationQueueTurnTests.secondPrompt)
        }
    }

    /// A declared background tool whose body waits on a latch, and then asks
    /// a child session for a whole turn.
    private struct BackgroundChildTurnTool: Tool, BackgroundTool {
        let name = "background_child_turn_tool"
        let description = "in the background, waits for its latch, then asks a child session for a turn"

        /// The session the body asks for a turn.
        let child: any RoutedSession

        /// The latch the body waits on before it asks for the turn.
        let start: RunLatch

        /// Every call goes to the background at once.
        var mount: ToolMount? { ToolMount(mode: .background) }

        func call(arguments: MountArguments) async throws -> String {
            await start.waitUntilOpen()
            return try await child.respond(to: GenerationQueueTurnTests.secondPrompt)
        }
    }

    /// The prompt of the first session of a test.
    private static let firstPrompt = "a"

    /// The prompt of the second session of a test.
    private static let secondPrompt = "b"

    /// The upper bound a background run is allowed before it settles. The run
    /// makes one stubbed pass, so only a real stall reaches it, and the bound
    /// makes such a stall fail the test instead of hanging it.
    private static let runSettlementSeconds: TimeInterval = 30

    /// How many passes of one turn call a tool in the alternation test.
    private static let alternatingToolRounds = 3

    /// How many sessions run a tool loop in the alternation test.
    private static let loopingSessionCount = 2

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

    /// The text of each response in the transcript of `session`, in order.
    ///
    /// - Parameter session: The session to read. No turn of it may be in
    ///   flight, so the read does not wait.
    /// - Returns: The response texts.
    private static func responseTexts(of session: any RoutedSession) async -> [String] {
        Array(await session.transcript).compactMap { entry in
            if case .response(let response) = entry {
                return WatchedText.text(of: response.segments)
            }
            return nil
        }
    }

    @Test("a session waiting in a tool body holds no place, so another session over the same model completes a turn")
    func aToolBodyThatWaitsLetsAnotherSessionCompleteATurn() async throws {
        let dir = RouterTestFixtures.makeTempDir(prefix: "GenerationQueueTurnTests")
        defer { try? FileManager.default.removeItem(at: dir) }
        let fixture = PassObservingFixture(toolRounds: 1)
        await fixture.latch.open()
        let resolved = try await RouterTestFixtures.resolveStandardProfile(over: fixture.container, cacheDir: dir)
        let entered = AsyncSemaphore(value: 0)
        let toolLatch = RunLatch()
        let waiting = resolved.profile.standard.makeSession(tools: [WaitingTool(entered: entered, latch: toolLatch)])
        let other = resolved.profile.standard.makeSession()

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

        await toolLatch.open()
        let otherAnswer = try await otherTurn.value
        let waitingAnswer = try await waitingTurn.value

        #expect(toolStarted)
        #expect(otherEndedDuringTheWait)
        #expect(otherAnswer == PassObservingModel.answer(to: Self.secondPrompt))
        #expect(waitingAnswer == PassObservingModel.answer(to: Self.firstPrompt))
        #expect(fixture.passes.recorded.map(\.prompt) == [Self.firstPrompt, Self.secondPrompt, Self.firstPrompt])
        #expect(await BoundedWait.signalArrived(waitingFinished, named: "the end of the waiting turn"))
        #expect(await fixture.queue.isRunning == false)
        withExtendedLifetime(resolved) {}
    }

    @Test("two sessions with long tool loops over one model take alternate passes, first in first out")
    func twoToolLoopsTakeAlternatePasses() async throws {
        let dir = RouterTestFixtures.makeTempDir(prefix: "GenerationQueueTurnTests")
        defer { try? FileManager.default.removeItem(at: dir) }
        let step = AsyncSemaphore(value: 0)
        let fixture = PassObservingFixture(toolRounds: Self.alternatingToolRounds, step: step)
        await fixture.latch.open()
        let passes = fixture.passes
        let queue = fixture.queue
        let resolved = try await RouterTestFixtures.resolveStandardProfile(over: fixture.container, cacheDir: dir)
        let first = resolved.profile.standard.makeSession(tools: [MountFixtures.FastTool()])
        let second = resolved.profile.standard.makeSession(tools: [MountFixtures.FastTool()])
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
            await queue.waitingCount == 1
        }

        // Release one pass at a time. The next pass to start is the one the
        // queue admits, and the session that just ran a pass joins the queue
        // again after its tool body, behind the other session.
        var everyStepWasObserved = firstInside && secondQueued
        for released in 1..<totalPasses where everyStepWasObserved {
            step.signal()
            let isLastPass = released + 1 == totalPasses
            everyStepWasObserved = await BoundedWait.conditionReached("pass \(released + 1) started") {
                let waitingCount = await queue.waitingCount
                return passes.recorded.count == released + 1 && (isLastPass || waitingCount == 1)
            }
        }
        for _ in passes.recorded.count...totalPasses { step.signal() }
        let firstAnswer = try await firstTurn.value
        let secondAnswer = try await secondTurn.value

        let alternating = (0..<passesPerTurn).flatMap { _ in [Self.firstPrompt, Self.secondPrompt] }
        #expect(everyStepWasObserved)
        #expect(passes.recorded.map(\.prompt) == alternating)
        #expect(firstAnswer == PassObservingModel.answer(to: Self.firstPrompt))
        #expect(secondAnswer == PassObservingModel.answer(to: Self.secondPrompt))
        #expect(await BoundedWait.signalArrived(firstFinished, named: "the end of the first loop"))
        #expect(await BoundedWait.signalArrived(secondFinished, named: "the end of the second loop"))
        #expect(await queue.isRunning == false)
        withExtendedLifetime(resolved) {}
    }

    @Test("a parent waits in a tool body for a child turn on the same model: the child completes, then the parent")
    func aParentWaitsInAToolBodyForAChildTurnOnTheSameModel() async throws {
        let dir = RouterTestFixtures.makeTempDir(prefix: "GenerationQueueTurnTests")
        defer { try? FileManager.default.removeItem(at: dir) }
        let fixture = PassObservingFixture(toolRounds: 1)
        await fixture.latch.open()
        let resolved = try await RouterTestFixtures.resolveStandardProfile(over: fixture.container, cacheDir: dir)
        let child = resolved.profile.standard.makeSession()
        let parent = resolved.profile.standard.makeSession(tools: [ChildTurnTool(child: child)])

        let parentFinished = AsyncSemaphore(value: 0)
        let parentTurn = Self.startTurn(signalling: parentFinished) {
            try await parent.respond(to: Self.firstPrompt)
        }
        // Bounded, so a regression that parks the child fails here and does
        // not hang the run.
        try #require(
            await BoundedWait.signalArrived(
                parentFinished, named: "the parent turn, after the child turn in its tool body"))
        let parentAnswer = try await parentTurn.value

        // The pass of the child runs between the two passes of the parent: the
        // child turn completes inside the tool body, then the parent answers.
        #expect(fixture.passes.recorded.map(\.prompt) == [Self.firstPrompt, Self.secondPrompt, Self.firstPrompt])
        #expect(await Self.responseTexts(of: child) == [PassObservingModel.answer(to: Self.secondPrompt)])
        #expect(parentAnswer == PassObservingModel.answer(to: Self.firstPrompt))
        #expect(await fixture.queue.isRunning == false)
        withExtendedLifetime(resolved) {}
    }

    @Test("a background run generates on the same model after the turn that started it ended")
    func aBackgroundRunGeneratesOnTheSameModelAfterItsTurnEnded() async throws {
        let dir = RouterTestFixtures.makeTempDir(prefix: "GenerationQueueTurnTests")
        defer { try? FileManager.default.removeItem(at: dir) }
        let fixture = PassObservingFixture(toolRounds: 1)
        await fixture.latch.open()
        let resolved = try await RouterTestFixtures.resolveStandardProfile(over: fixture.container, cacheDir: dir)
        let runStart = RunLatch()
        let child = resolved.profile.standard.makeSession()
        let parent = resolved.profile.standard.makeSession(
            tools: [BackgroundChildTurnTool(child: child, start: runStart)])

        // A stream of events ends with its turn, and does not wait for the
        // background runs of that turn.
        let parentFinished = AsyncSemaphore(value: 0)
        let parentTurn = Task {
            defer { parentFinished.signal() }
            for try await _ in await parent.streamEvents(to: Self.firstPrompt) {}
        }
        let turnEndedBeforeTheRun = await BoundedWait.signalArrived(
            parentFinished, named: "the end of the turn that started the run")
        let runs = await parent.mailbox.backgroundRuns()

        // Only now does the run ask the child for a turn.
        await runStart.open()
        #expect(turnEndedBeforeTheRun)
        #expect(runs.count == 1)
        let token = try #require(runs.first?.completionToken)
        let outcome = await parent.mailbox.wait(completionToken: token, seconds: Self.runSettlementSeconds)
        try await parentTurn.value

        var terminal: OperationEvent?
        if case .settled(let settled) = outcome {
            terminal = settled
        }
        #expect(terminal?.outcome == .succeeded)
        #expect(terminal?.detail == PassObservingModel.answer(to: Self.secondPrompt))
        // The two passes of the ended turn, then the pass of the run on the
        // child.
        #expect(fixture.passes.recorded.map(\.prompt) == [Self.firstPrompt, Self.firstPrompt, Self.secondPrompt])
        #expect(await fixture.queue.isRunning == false)
        withExtendedLifetime(resolved) {}
    }
}
