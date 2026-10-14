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
/// one queue of the pool entry of the model. A tool body runs inside the submission, so it
/// holds the worker of the model for every other session on that model. An
/// in-band tool body that asks a session on the same model for an answer is
/// refused at once. The background shape of that wait is the spike
/// `SubmissionQueueSpikeTests`. The cancellation of an answer whose submission
/// waits is held by `NestedGenerationReentryTests`.
///
/// Each wait here waits for an event: a semaphore that a tool body signals, a
/// pass that the model records, or the ``SessionEvent/submissionQueued(_:)``
/// of a session whose submission must wait. No wait has a clock or a limit. A
/// test opens every latch and releases every step before it awaits an answer.
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
        /// so the call answers with its own output and is no mail. Without
        /// it, the scripted model calls the tool again in each delivery
        /// submission, and each call would start one more delivery.
        var inlineSettleGrace: TimeInterval { GenerationQueueSubmissionTests.laterCallSettleGrace }

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

    /// How many passes of one submission call a tool in the FIFO test.
    private static let loopingToolRounds = 3

    /// The temp-directory prefix of this suite.
    private static let tempDirPrefix = "GenerationQueueSubmissionTests"

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
        let queue = try #require(resolved.profile.standard.backendQueue)
        let entered = AsyncSemaphore(value: 0)
        let toolLatch = RunLatch()
        let waiting = resolved.profile.standard.makeSession(tools: [WaitingTool(entered: entered, latch: toolLatch)])
        let other = resolved.profile.standard.makeSession()

        let otherFeed = await SessionEventLog.watch(other)
        defer { otherFeed.drain.cancel() }

        let waitingAnswerTask = Task { try await waiting.respond(to: Self.firstPrompt) }
        await entered.wait()

        // The other submission waits behind the submission whose tool body
        // waits: the tool body is a step of that submission.
        let otherAnswerTask = Task { try await other.respond(to: Self.secondPrompt) }
        try await otherFeed.log.waitForQueuedSubmissions(1)
        let passesDuringTheToolBody = fixture.passes.recorded.map(\.prompt)

        await toolLatch.open()
        let otherAnswer = try await otherAnswerTask.value
        let waitingAnswer = try await waitingAnswerTask.value

        #expect(passesDuringTheToolBody == [Self.firstPrompt])
        #expect(otherAnswer == PassObservingModel.answer(to: Self.secondPrompt))
        #expect(waitingAnswer == PassObservingModel.answer(to: Self.firstPrompt))
        #expect(fixture.passes.recorded.map(\.prompt) == [Self.firstPrompt, Self.firstPrompt, Self.secondPrompt])
        #expect(await queue.isRunning == false)
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
        let resolved = try await RouterTestFixtures.resolveStandardProfile(over: fixture.container, cacheDir: dir)
        let queue = try #require(resolved.profile.standard.backendQueue)
        let first = resolved.profile.standard.makeSession(tools: [MountFixtures.FastTool()])
        let second = resolved.profile.standard.makeSession(tools: [MountFixtures.FastTool()])
        let passesPerSubmission = Self.loopingToolRounds + 1

        let secondFeed = await SessionEventLog.watch(second)
        defer { secondFeed.drain.cancel() }

        let firstAnswerTask = Task { try await first.respond(to: Self.firstPrompt) }
        try await passes.waitForPasses(1)
        let secondAnswerTask = Task { try await second.respond(to: Self.secondPrompt) }
        try await secondFeed.log.waitForQueuedSubmissions(1)

        // Release one pass at a time. Each pass of the first submission
        // starts while the second submission still waits: its tool bodies do
        // not give the worker to the other session. A pass holds on its step,
        // so the count of the passes is exact at each read.
        let releasedOneAtATime = passesPerSubmission - 1
        for released in 1...releasedOneAtATime {
            step.signal()
            try await passes.waitForPasses(released + 1)
            #expect(passes.recorded.count == released + 1)
            #expect(await queue.waitingCount == 1)
        }
        // One step for each pass not yet released, so a regression that
        // interleaves the passes still ends both answers.
        for _ in releasedOneAtATime..<(passesPerSubmission * 2) { step.signal() }
        let firstAnswer = try await firstAnswerTask.value
        let secondAnswer = try await secondAnswerTask.value

        let wholeSubmissions =
            Array(repeating: Self.firstPrompt, count: passesPerSubmission)
            + Array(repeating: Self.secondPrompt, count: passesPerSubmission)
        #expect(passes.recorded.map(\.prompt) == wholeSubmissions)
        #expect(firstAnswer == PassObservingModel.answer(to: Self.firstPrompt))
        #expect(secondAnswer == PassObservingModel.answer(to: Self.secondPrompt))
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
        let queue = try #require(resolved.profile.standard.backendQueue)
        let refusal = ErrorBox()
        let child = resolved.profile.standard.makeSession()
        let parent = resolved.profile.standard.makeSession(tools: [ChildAnswerTool(child: child, refusal: refusal)])

        // The refusal in the tool body ends the answer of the parent. A
        // regression that parks the child behind the submission of its
        // parent keeps this wait open.
        let parentAnswer = try await parent.respond(to: Self.firstPrompt)

        let refused = try #require(refusal.error as? GenerationQueueError)
        #expect(refused == .waitInsideOpenSubmission(model: resolved.profile.standard.chosen))
        // The child never generated: the only passes are the two of the parent.
        #expect(fixture.passes.recorded.map(\.prompt) == [Self.firstPrompt, Self.firstPrompt])
        #expect(await Self.responseTexts(of: child).isEmpty)
        #expect(parentAnswer == PassObservingModel.answer(to: Self.firstPrompt))
        #expect(await queue.isRunning == false)
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
        let queue = try #require(resolved.profile.standard.backendQueue)
        let refusal = ErrorBox()
        let child = resolved.profile.standard.makeSession()
        let parent = resolved.profile.standard.makeSession(tools: [ChildAnswerTool(child: child, refusal: refusal)])

        let childFeed = await SessionEventLog.watch(child)
        defer { childFeed.drain.cancel() }

        // The parent's submission runs, and its first pass holds on its step.
        let parentAnswerTask = Task { try await parent.respond(to: Self.firstPrompt) }
        try await fixture.passes.waitForPasses(1)
        // The pump of the child runs its answer, and its submission waits
        // behind the parent's.
        let childAnswerTask = Task { try await child.respond(to: Self.childOwnPrompt) }
        try await childFeed.log.waitForQueuedSubmissions(1)

        // The tool body of the parent now asks the busy child for an answer.
        // A wait for an answer of the busy child would never end.
        for _ in 0..<Self.busyChildPassCount { step.signal() }
        let parentAnswer = try await parentAnswerTask.value
        let childAnswer = try await childAnswerTask.value

        let refused = try #require(refusal.error as? GenerationQueueError)
        #expect(refused == .waitInsideOpenSubmission(model: resolved.profile.standard.chosen))
        #expect(
            fixture.passes.recorded.map(\.prompt) == [Self.firstPrompt, Self.firstPrompt, Self.childOwnPrompt])
        #expect(parentAnswer == PassObservingModel.answer(to: Self.firstPrompt))
        #expect(childAnswer == PassObservingModel.answer(to: Self.childOwnPrompt))
        #expect(await queue.isRunning == false)
        withExtendedLifetime(resolved) {}
    }

    @Test("a background run generates on the same model after the answer that started it ended")
    func aBackgroundRunGeneratesOnTheSameModelAfterItsAnswerEnded() async throws {
        let dir = RouterTestFixtures.makeTempDir(prefix: Self.tempDirPrefix)
        defer { try? FileManager.default.removeItem(at: dir) }
        let fixture = PassObservingFixture(toolRounds: 1)
        await fixture.latch.open()
        let resolved = try await RouterTestFixtures.resolveStandardProfile(over: fixture.container, cacheDir: dir)
        let queue = try #require(resolved.profile.standard.backendQueue)
        let runStart = RunLatch()
        let child = resolved.profile.standard.makeSession()
        let parent = resolved.profile.standard.makeSession(
            tools: [BackgroundChildAnswerTool(child: child, start: runStart)])

        // A stream of events ends with its answer, and does not wait for the
        // background runs of that answer. The run waits on its latch, so the
        // answer ends before the run asks the child for an answer.
        for try await _ in await parent.streamEvents(to: Self.firstPrompt) {}
        let runs = await parent.runPlane.backgroundRuns()

        // Only now does the run ask the child for an answer.
        await runStart.open()
        #expect(runs.count == 1)
        let token = try #require(runs.first?.completionToken)
        let outcome = await parent.runPlane.wait(completionToken: token, seconds: nil)

        var terminal: OperationEvent?
        if case .settled(let settled) = outcome {
            terminal = settled
        }
        #expect(terminal?.outcome == .succeeded)
        #expect(terminal?.detail == PassObservingModel.answer(to: Self.secondPrompt))

        // The terminal is mail: the pump of the parent delivers it in one
        // more submission, with no caller call, and then ends.
        try await fixture.passes.waitForPasses(Self.passesBeforeDelivery + 1)
        #expect(await parent.becomesIdle())
        // The pump of the parent ended, so its last submission ended. The
        // queue releases the count of a job before its submitter resumes, and
        // the answer of the child ended before the run settled. Thus no job
        // runs or waits now.
        #expect(await queue.isRunning == false)
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
