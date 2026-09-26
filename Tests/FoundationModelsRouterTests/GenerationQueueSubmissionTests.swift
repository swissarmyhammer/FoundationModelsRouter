import Foundation
import FoundationModels
import FoundationModelsRouterTestSupport
import Synchronization
import Testing

@testable import FoundationModelsRouter

/// Task ^1psqdm9: the item of the generation queue of a model is one
/// submission to Foundation, one whole SDK call with all of its passes and
/// tool bodies (`generation-queue.md`, sections 5.1 and 5.5).
///
/// Each session is a routed session over one ``LiveBackendContainer``, so each
/// answer goes through the production backend and submits its SDK call to the
/// one queue of that container. A tool body runs inside the submission, so it
/// holds the worker of the model for every other session on that model. An
/// in-band tool body that asks a session on the same model for an answer is
/// refused at once. The background shape of that wait is the spike
/// `SubmissionQueueSpikeTests`. The cancellation of an answer whose submission
/// waits is held by `NestedGenerationReentryTests`.
///
/// No wait here is a bare `await` on an answer that can stay suspended. Each
/// answer signals a semaphore when it ends, and the test observes that signal
/// under the bound of ``BoundedWait``. A test then opens every latch and
/// releases every step before it awaits an answer, so a regression fails the
/// test and does not hang the run.
@Suite("The item of the generation queue is one whole submission (task ^1psqdm9)")
struct GenerationQueueSubmissionTests {
    /// A tool whose body signals that it started, and then waits on a latch:
    /// the shape of a tool that waits for a person or for other work.
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

    /// A tool whose body asks a child session for a whole answer, in band:
    /// the shape of an agent tool that waits inside its submission. It keeps
    /// the error the child throws, and answers with a fixed text, so the
    /// parent ends whatever the child does.
    private struct ChildAnswerTool: Tool {
        let name = "child_answer_tool"
        let description = "asks a child session for an answer, and keeps the error it throws"

        /// The session the body asks for an answer.
        let child: any RoutedSession

        /// Where the body keeps the error of the child.
        let refusal: ErrorBox

        func call(arguments: MountArguments) async throws -> String {
            do {
                return try await child.respond(to: GenerationQueueSubmissionTests.secondPrompt)
            } catch {
                refusal.store(error)
                return GenerationQueueSubmissionTests.refusedAnswer
            }
        }
    }

    /// Keeps one error that a tool body caught, so the test reads it after the
    /// answer ends.
    private final class ErrorBox: Sendable {
        /// The error, or `nil` while no body stored one.
        private let stored = Mutex<(any Error)?>(nil)

        /// The error, or `nil` while no body stored one.
        var error: (any Error)? { stored.withLock { $0 } }

        /// Keeps `error`.
        ///
        /// - Parameter error: The error the body caught.
        func store(_ error: any Error) {
            stored.withLock { $0 = error }
        }
    }

    /// What ``ChildAnswerTool`` answers when the child throws.
    private static let refusedAnswer = "the child refused"

    /// A declared background tool whose body waits on a latch, and then asks
    /// a child session for a whole answer.
    private struct BackgroundChildAnswerTool: Tool, BackgroundTool {
        let name = "background_child_answer_tool"
        let description = "in the background, waits for its latch, then asks a child session for an answer"

        /// The session the body asks for an answer.
        let child: any RoutedSession

        /// The latch the body waits on before it asks for the answer.
        let start: RunLatch

        /// Taken by the first call, which asks the child for the answer.
        let firstCall = FirstCallFlag()

        /// Every call goes to the background.
        var mount: ToolMount? { ToolMount(mode: .background) }

        /// A later call starts nothing and settles at once, inside this grace,
        /// so its result goes back in its own envelope and is no mail. Without
        /// it, the scripted model calls the tool again in each delivery
        /// submission, and each call would start one more delivery.
        var inlineSettleGrace: TimeInterval? { GenerationQueueSubmissionTests.laterCallSettleGrace }

        func call(arguments: MountArguments) async throws -> String {
            guard firstCall.take() else { return GenerationQueueSubmissionTests.nothingStarted }
            await start.waitUntilOpen()
            return try await child.respond(to: GenerationQueueSubmissionTests.secondPrompt)
        }
    }

    /// How long a call of ``BackgroundChildAnswerTool`` waits for its run to
    /// settle inline. Long enough for a run that starts nothing, and short,
    /// because the wait holds the model.
    private static let laterCallSettleGrace: TimeInterval = 0.5

    /// The answer of each later call of ``BackgroundChildAnswerTool``.
    private static let nothingStarted = "nothing new started"

    /// The passes before the delivery submission of the parent: the two
    /// passes of its first submission (the tool call, then the answer), and
    /// the one pass of the run on the child.
    private static let passesBeforeDelivery = 3

    /// The prompt of the first session of a test.
    private static let firstPrompt = "a"

    /// The prompt of the second session of a test.
    private static let secondPrompt = "b"

    /// The upper bound a background run is allowed before it settles. The run
    /// makes one stubbed pass, so only a real stall reaches it, and the bound
    /// makes such a stall fail the test instead of hanging it.
    private static let runSettlementSeconds: TimeInterval = 30

    /// How many passes of one submission call a tool in the FIFO test.
    private static let loopingToolRounds = 3

    /// The temp-directory prefix of this suite.
    private static let tempDirPrefix = "GenerationQueueSubmissionTests"

    /// Starts `answer` in a task of its own that signals `finished` when it
    /// ends, however it ends.
    ///
    /// - Parameters:
    ///   - finished: The semaphore to signal when the answer ends.
    ///   - answer: The answer to run.
    /// - Returns: The task that runs the answer.
    private static func startAnswer(
        signalling finished: AsyncSemaphore,
        _ answer: @escaping @Sendable () async throws -> String
    ) -> Task<String, Error> {
        Task {
            defer { finished.signal() }
            return try await answer()
        }
    }

    /// The text of each response in the transcript of `session`, in order.
    ///
    /// - Parameter session: The session to read. No submission of it may run,
    ///   so the read does not wait.
    /// - Returns: The response texts.
    private static func responseTexts(of session: any RoutedSession) async -> [String] {
        Array(await session.transcript).compactMap { entry in
            if case .response(let response) = entry {
                return WatchedText.text(of: response.segments)
            }
            return nil
        }
    }

    @Test("a tool body that waits holds its submission, so another session over the same model runs after it")
    func aToolBodyThatWaitsHoldsTheModelUntilItsSubmissionEnds() async throws {
        let dir = RouterTestFixtures.makeTempDir(prefix: Self.tempDirPrefix)
        defer { try? FileManager.default.removeItem(at: dir) }
        let fixture = PassObservingFixture(toolRounds: 1)
        await fixture.latch.open()
        let resolved = try await RouterTestFixtures.resolveStandardProfile(over: fixture.container, cacheDir: dir)
        let entered = AsyncSemaphore(value: 0)
        let toolLatch = RunLatch()
        let waiting = resolved.profile.standard.makeSession(tools: [WaitingTool(entered: entered, latch: toolLatch)])
        let other = resolved.profile.standard.makeSession()

        let waitingFinished = AsyncSemaphore(value: 0)
        let waitingAnswerTask = Self.startAnswer(signalling: waitingFinished) {
            try await waiting.respond(to: Self.firstPrompt)
        }
        let toolStarted = await BoundedWait.signalArrived(entered, named: "the tool body of the waiting session")

        // The other submission waits behind the submission whose tool body
        // waits: the tool body is a step of that submission.
        let otherFinished = AsyncSemaphore(value: 0)
        let otherAnswerTask = Self.startAnswer(signalling: otherFinished) {
            try await other.respond(to: Self.secondPrompt)
        }
        let otherWaitsDuringTheToolBody = await BoundedWait.conditionReached(
            "the submission of the other session waiting while the tool body runs"
        ) {
            await fixture.queue.waitingCount == 1
        }
        let passesDuringTheToolBody = fixture.passes.recorded.map(\.prompt)

        await toolLatch.open()
        let otherAnswer = try await otherAnswerTask.value
        let waitingAnswer = try await waitingAnswerTask.value

        #expect(toolStarted)
        #expect(otherWaitsDuringTheToolBody)
        #expect(passesDuringTheToolBody == [Self.firstPrompt])
        #expect(otherAnswer == PassObservingModel.answer(to: Self.secondPrompt))
        #expect(waitingAnswer == PassObservingModel.answer(to: Self.firstPrompt))
        #expect(fixture.passes.recorded.map(\.prompt) == [Self.firstPrompt, Self.firstPrompt, Self.secondPrompt])
        #expect(await BoundedWait.signalArrived(waitingFinished, named: "the end of the waiting answer"))
        #expect(await BoundedWait.signalArrived(otherFinished, named: "the end of the other answer"))
        #expect(await fixture.queue.isRunning == false)
        withExtendedLifetime(resolved) {}
    }

    @Test("two sessions with long tool loops over one model run whole submissions, first in first out")
    func twoToolLoopsRunWholeSubmissionsInOrder() async throws {
        let dir = RouterTestFixtures.makeTempDir(prefix: Self.tempDirPrefix)
        defer { try? FileManager.default.removeItem(at: dir) }
        let step = AsyncSemaphore(value: 0)
        let fixture = PassObservingFixture(toolRounds: Self.loopingToolRounds, step: step)
        await fixture.latch.open()
        let passes = fixture.passes
        let queue = fixture.queue
        let resolved = try await RouterTestFixtures.resolveStandardProfile(over: fixture.container, cacheDir: dir)
        let first = resolved.profile.standard.makeSession(tools: [MountFixtures.FastTool()])
        let second = resolved.profile.standard.makeSession(tools: [MountFixtures.FastTool()])
        let passesPerSubmission = Self.loopingToolRounds + 1

        let firstFinished = AsyncSemaphore(value: 0)
        let firstAnswerTask = Self.startAnswer(signalling: firstFinished) { try await first.respond(to: Self.firstPrompt) }
        let firstInside = await BoundedWait.conditionReached("the first pass of the first session") {
            passes.recorded.count == 1
        }
        let secondFinished = AsyncSemaphore(value: 0)
        let secondAnswerTask = Self.startAnswer(signalling: secondFinished) { try await second.respond(to: Self.secondPrompt) }
        let secondQueued = await BoundedWait.conditionReached("the submission of the second session in the queue") {
            await queue.waitingCount == 1
        }

        // Release one pass at a time. Each pass of the first submission
        // starts while the second submission still waits: its tool bodies do
        // not give the worker to the other session.
        var everyStepWasObserved = firstInside && secondQueued
        var stepsReleased = 0
        for released in 1..<passesPerSubmission where everyStepWasObserved {
            step.signal()
            stepsReleased += 1
            everyStepWasObserved = await BoundedWait.conditionReached("pass \(released + 1) of the first submission") {
                let waitingCount = await queue.waitingCount
                return passes.recorded.count == released + 1 && waitingCount == 1
            }
        }
        // One step for each pass not yet released, so a regression that
        // interleaves the passes still ends both answers.
        for _ in stepsReleased..<(passesPerSubmission * 2) { step.signal() }
        let firstAnswer = try await firstAnswerTask.value
        let secondAnswer = try await secondAnswerTask.value

        let wholeSubmissions =
            Array(repeating: Self.firstPrompt, count: passesPerSubmission)
            + Array(repeating: Self.secondPrompt, count: passesPerSubmission)
        #expect(everyStepWasObserved)
        #expect(passes.recorded.map(\.prompt) == wholeSubmissions)
        #expect(firstAnswer == PassObservingModel.answer(to: Self.firstPrompt))
        #expect(secondAnswer == PassObservingModel.answer(to: Self.secondPrompt))
        #expect(await BoundedWait.signalArrived(firstFinished, named: "the end of the first loop"))
        #expect(await BoundedWait.signalArrived(secondFinished, named: "the end of the second loop"))
        #expect(await queue.isRunning == false)
        withExtendedLifetime(resolved) {}
    }

    @Test("an in-band tool body that asks a session on the same model for an answer is refused at once")
    func anInBandWaitForASessionOnTheSameModelIsRefused() async throws {
        let dir = RouterTestFixtures.makeTempDir(prefix: Self.tempDirPrefix)
        defer { try? FileManager.default.removeItem(at: dir) }
        let fixture = PassObservingFixture(toolRounds: 1)
        await fixture.latch.open()
        let resolved = try await RouterTestFixtures.resolveStandardProfile(over: fixture.container, cacheDir: dir)
        let refusal = ErrorBox()
        let child = resolved.profile.standard.makeSession()
        let parent = resolved.profile.standard.makeSession(tools: [ChildAnswerTool(child: child, refusal: refusal)])

        let parentFinished = AsyncSemaphore(value: 0)
        let parentAnswerTask = Self.startAnswer(signalling: parentFinished) {
            try await parent.respond(to: Self.firstPrompt)
        }
        // Bounded, so a regression that parks the child behind the submission
        // of its parent fails here and does not hang the run.
        try #require(
            await BoundedWait.signalArrived(
                parentFinished, named: "the parent answer, after the refusal in its tool body"))
        let parentAnswer = try await parentAnswerTask.value

        let refused = try #require(refusal.error as? GenerationQueueError)
        #expect(refused == .waitInsideOpenSubmission(model: resolved.profile.standard.chosen))
        // The child never generated: the only passes are the two of the parent.
        #expect(fixture.passes.recorded.map(\.prompt) == [Self.firstPrompt, Self.firstPrompt])
        #expect(await Self.responseTexts(of: child).isEmpty)
        #expect(parentAnswer == PassObservingModel.answer(to: Self.firstPrompt))
        #expect(await fixture.queue.isRunning == false)
        withExtendedLifetime(resolved) {}
    }

    /// The prompt of the answer the child runs on its own in the busy-child
    /// test.
    private static let childOwnPrompt = "c"

    /// The passes of the busy-child test: the two of the parent, and the
    /// one of the child's own answer.
    private static let busyChildPassCount = 3

    @Test("an in-band wait for a session on the same model whose own submission waits behind the parent is refused, not parked")
    func anInBandWaitForABusySessionOnTheSameModelIsRefused() async throws {
        let dir = RouterTestFixtures.makeTempDir(prefix: Self.tempDirPrefix)
        defer { try? FileManager.default.removeItem(at: dir) }
        let step = AsyncSemaphore(value: 0)
        let fixture = PassObservingFixture(toolRounds: 1, step: step)
        await fixture.latch.open()
        let resolved = try await RouterTestFixtures.resolveStandardProfile(over: fixture.container, cacheDir: dir)
        let refusal = ErrorBox()
        let child = resolved.profile.standard.makeSession()
        let parent = resolved.profile.standard.makeSession(tools: [ChildAnswerTool(child: child, refusal: refusal)])

        // The parent's submission runs, and its first pass holds on its step.
        let parentFinished = AsyncSemaphore(value: 0)
        let parentAnswerTask = Self.startAnswer(signalling: parentFinished) {
            try await parent.respond(to: Self.firstPrompt)
        }
        let parentInside = await BoundedWait.conditionReached("the first pass of the parent") {
            fixture.passes.recorded.count == 1
        }
        // The pump of the child runs its answer, and its submission waits
        // behind the parent's.
        let childFinished = AsyncSemaphore(value: 0)
        let childAnswerTask = Self.startAnswer(signalling: childFinished) {
            try await child.respond(to: Self.childOwnPrompt)
        }
        let childWaits = await BoundedWait.conditionReached("the child's submission behind the parent's") {
            await fixture.queue.waitingCount == 1
        }

        // The tool body of the parent now asks the busy child for an answer.
        // A wait for an answer of the busy child would never end.
        for _ in 0..<Self.busyChildPassCount { step.signal() }
        try #require(
            await BoundedWait.signalArrived(
                parentFinished, named: "the parent answer, after the refusal in its tool body"))
        try #require(await BoundedWait.signalArrived(childFinished, named: "the child's own answer"))
        let parentAnswer = try await parentAnswerTask.value
        let childAnswer = try await childAnswerTask.value

        let refused = try #require(refusal.error as? GenerationQueueError)
        #expect(parentInside)
        #expect(childWaits)
        #expect(refused == .waitInsideOpenSubmission(model: resolved.profile.standard.chosen))
        #expect(
            fixture.passes.recorded.map(\.prompt) == [Self.firstPrompt, Self.firstPrompt, Self.childOwnPrompt])
        #expect(parentAnswer == PassObservingModel.answer(to: Self.firstPrompt))
        #expect(childAnswer == PassObservingModel.answer(to: Self.childOwnPrompt))
        #expect(await fixture.queue.isRunning == false)
        withExtendedLifetime(resolved) {}
    }

    @Test("a background run generates on the same model after the answer that started it ended")
    func aBackgroundRunGeneratesOnTheSameModelAfterItsAnswerEnded() async throws {
        let dir = RouterTestFixtures.makeTempDir(prefix: Self.tempDirPrefix)
        defer { try? FileManager.default.removeItem(at: dir) }
        let fixture = PassObservingFixture(toolRounds: 1)
        await fixture.latch.open()
        let resolved = try await RouterTestFixtures.resolveStandardProfile(over: fixture.container, cacheDir: dir)
        let runStart = RunLatch()
        let child = resolved.profile.standard.makeSession()
        let parent = resolved.profile.standard.makeSession(
            tools: [BackgroundChildAnswerTool(child: child, start: runStart)])

        // A stream of events ends with its answer, and does not wait for the
        // background runs of that answer.
        let parentFinished = AsyncSemaphore(value: 0)
        let parentAnswerTask = Task {
            defer { parentFinished.signal() }
            for try await _ in await parent.streamEvents(to: Self.firstPrompt) {}
        }
        let answerEndedBeforeTheRun = await BoundedWait.signalArrived(
            parentFinished, named: "the end of the answer that started the run")
        let runs = await parent.mailbox.backgroundRuns()

        // Only now does the run ask the child for an answer.
        await runStart.open()
        #expect(answerEndedBeforeTheRun)
        #expect(runs.count == 1)
        let token = try #require(runs.first?.completionToken)
        let outcome = await parent.mailbox.wait(completionToken: token, seconds: Self.runSettlementSeconds)
        try await parentAnswerTask.value

        var terminal: OperationEvent?
        if case .settled(let settled) = outcome {
            terminal = settled
        }
        #expect(terminal?.outcome == .succeeded)
        #expect(terminal?.detail == PassObservingModel.answer(to: Self.secondPrompt))

        // The terminal is mail: the pump of the parent delivers it in one
        // more submission, with no caller call, and then ends.
        #expect(
            await BoundedWait.conditionReached("the delivery submission of the parent") {
                fixture.passes.recorded.count > Self.passesBeforeDelivery
            })
        #expect(await parent.becomesIdle())
        #expect(
            await BoundedWait.conditionReached("the queue of the model ending its work") {
                await !fixture.queue.isRunning
            })
        // The two passes of the ended answer, then the pass of the run on the
        // child, then the passes of the delivery submission, which carries
        // the answer of the child.
        let prompts = fixture.passes.recorded.map(\.prompt)
        #expect(Array(prompts.prefix(Self.passesBeforeDelivery)) == [Self.firstPrompt, Self.firstPrompt, Self.secondPrompt])
        let deliveryPrompt = try #require(prompts.dropFirst(Self.passesBeforeDelivery).first)
        #expect(deliveryPrompt.contains(PassObservingModel.answer(to: Self.secondPrompt)))
        #expect(deliveryPrompt.contains(RoutedSessionActor.settledRunDeliveryPrompt))
        withExtendedLifetime(resolved) {}
    }
}
