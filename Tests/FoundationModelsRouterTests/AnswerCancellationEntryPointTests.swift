import Foundation
import FoundationModels
import FoundationModelsRouterTestSupport
import Testing

@testable import FoundationModelsRouter

/// The tests of ``AnswerCancellationTests`` for the streaming and
/// queue-dispatch entry points, the no-op cases, a cancellation between the
/// submissions of one answer, and the queue-side cancel.
extension AnswerCancellationTests {
    // MARK: - The streaming and queue-dispatch entry points

    @Test("cancel() finishes a streamEvents answer with CancellationError, leaving the consumer what it already received")
    @MainActor
    func cancellingAStreamingAnswerFinishesTheStreamWithCancellationError() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let fixture = try await Self.makeFixture(cacheDir: dir)
        let session = fixture.model.makeSession()

        let insideTool = AsyncSemaphore(value: 0)
        let sawCancellation = Self.suspendInsideCancellationAwareTool(fixture, prompt: "stream-cancel", insideTool: insideTool)

        // The stream is drained into `delivered` as it arrives, so what the consumer
        // had already been handed survives the error the stream finishes with.
        let delivered = DeliveredEvents()
        let answerTask = Task { () throws -> Int in
            for try await event in await session.streamEvents(to: "stream-cancel") {
                await delivered.append(event)
            }
            return await delivered.events.count
        }
        await insideTool.wait()

        #expect(await session.cancel() == .requested)
        try await Self.awaitCancelledUnwind(answerTask, sawCancellation: sawCancellation)

        // Everything the answer produced before the cancellation is still the
        // consumer's — a cancelled stream is truncated, not retracted.
        #expect(await delivered.events.contains(.textDelta(HookedSessionBackend.firstStreamedChunk)))
        #expect(await fixture.recorder.events.map(\.kind) == [.session, .prompt, .response])

        // The cancelled chain ends with one answerFailed with the reason
        // cancelled. It is the last event before the stream throws, and it
        // names the one message of the stream.
        let deliveredEvents = await delivered.events
        _ = eventsInsideAnswerFrame(deliveredEvents)
        let failure = try #require(deliveredEvents.answerFailures.first)
        #expect(deliveredEvents.answerFailures.count == 1)
        #expect(deliveredEvents.answers.isEmpty)
        #expect(failure.reason == .cancelled)
        #expect(failure.messageIds.count == 1)
        #expect(deliveredEvents.last == .answerFailed(failure))
    }

    @Test("cancelling the submission of a sent message unwinds it, and the message is then answered")
    @MainActor
    func cancellingTheSubmissionOfASentMessageAnswersIt() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let fixture = try await Self.makeFixture(cacheDir: dir)
        let session = fixture.model.makeSession()

        let insideTool = AsyncSemaphore(value: 0)
        let sawCancellation = Self.suspendInsideCancellationAwareTool(fixture, prompt: "send-cancel", insideTool: insideTool)

        // Restates the old dispatchNextPrompt() test: `send` starts the
        // submission, and no other call is necessary.
        let sent = await session.send("send-cancel")
        await insideTool.wait()

        #expect(await session.cancel() == .requested)
        try await sawCancellation.wait()
        #expect(await session.becomesIdle())

        // The pump took the message into the submission, and the cancel does
        // not put it back: the message is spent, and its id reports that its
        // answer came.
        #expect(await session.pendingMessages().isEmpty)
        #expect(await session.cancel(message: sent) == .alreadyAnswered)
    }

    // MARK: - No-ops and best-effort honesty

    @Test("cancelling twice, and cancelling after the answer has finished, are safe no-ops")
    @MainActor
    func cancellingTwiceAndAfterCompletionIsASafeNoOp() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let fixture = try await Self.makeFixture(cacheDir: dir)
        let session = fixture.model.makeSession()

        // Before any answer: nothing to cancel.
        #expect(await session.cancel() == .nothingToCancel)

        // This tool unwinds only when the test says so, rather than out of its own
        // cancellation handler: a tool that unwinds the moment cancellation lands
        // lets the whole answer finish between the two calls below, which makes
        // "twice against one running answer" a race rather than a test. It still
        // ends in a real cancellation — it checks for one once released.
        let insideTool = AsyncSemaphore(value: 0)
        let release = AsyncSemaphore(value: 0)
        let observer = fixture.observer
        fixture.hook.midAnswer = { prompt in
            guard prompt.hasSuffix("cancel-me") else { return }
            insideTool.signal()
            await release.wait()
            do {
                try Task.checkCancellation()
            } catch {
                await observer.noteToolSawCancellation()
                throw error
            }
        }

        let answerTask = Task { try await session.respond(to: "cancel-me") }
        await insideTool.wait()

        // Twice while the same answer provably still runs: the second call
        // requests what was already requested and changes nothing.
        #expect(await session.cancel() == .requested)
        #expect(await session.cancel() == .requested)

        release.signal()
        await #expect(throws: CancellationError.self) {
            try await answerTask.value
        }
        #expect(await fixture.observer.toolSawCancellation)

        // After it has finished: no answer to cancel, and the request left
        // behind cannot bleed into the next answer — which is a claim about the
        // pump too, so the follow-up answer goes through
        // `followUpAnswerCompletes` rather than being awaited directly.
        #expect(await session.cancel() == .nothingToCancel)
        #expect(await Self.followUpAnswerCompletes(on: session, observer: fixture.observer))
        #expect(await session.cancel() == .nothingToCancel)
    }

    @Test("an answer whose model work ignores cancellation still completes — Router stopped listening, the work did not stop")
    @MainActor
    func cancellationIsBestEffortWhenTheWorkIgnoresIt() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let fixture = try await Self.makeFixture(cacheDir: dir)
        let session = fixture.model.makeSession()

        // A tool that never checks cancellation — the local stand-in for an MCP
        // server that keeps working through an advisory
        // `notifications/cancelled`.
        let insideTool = AsyncSemaphore(value: 0)
        let release = AsyncSemaphore(value: 0)
        fixture.hook.midAnswer = { prompt in
            guard prompt == "stubborn" else { return }
            insideTool.signal()
            await release.wait()
        }

        let answerTask = Task { try await session.respond(to: "stubborn") }
        await insideTool.wait()
        #expect(await session.cancel() == .requested)

        // Nothing Router can do makes it stop, so the answer runs to completion
        // and is recorded as the whole submission it was.
        release.signal()
        #expect(try await answerTask.value == "ok-stubborn")
        #expect(await fixture.recorder.events.map(\.kind) == [.session, .prompt, .response])
        #expect(await fixture.recorder.events.last?.text == "ok-stubborn")
    }

    @Test("a respond cancelled while its message waits behind another submission never reaches the model, and records nothing")
    @MainActor
    func cancellingAQueuedMessageNeverReachesTheModel() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let fixture = try await Self.makeFixture(cacheDir: dir)
        let session = fixture.model.makeSession()

        // The first submission suspends inside the model without checking
        // cancellation, so the second message provably waits in the outbox
        // rather than racing to start.
        let insideFirstAnswer = AsyncSemaphore(value: 0)
        let releaseFirstAnswer = AsyncSemaphore(value: 0)
        fixture.hook.midAnswer = { prompt in
            guard prompt.hasSuffix("holds-the-lock") else { return }
            insideFirstAnswer.signal()
            await releaseFirstAnswer.wait()
        }

        let firstTask = Task { try await session.respond(to: "holds-the-lock") }
        await insideFirstAnswer.wait()

        let queuedTask = Task { try await session.respond(to: "queued-and-cancelled") }
        #expect(
            await BoundedWait.conditionReached("the second message waiting in the outbox") {
                await session.outbox.waitingMessageCount == 1
            })

        // Cancelled while its message waits. The message leaves the outbox,
        // or the pump drops it when it takes it: it never goes into a
        // submission.
        queuedTask.cancel()
        releaseFirstAnswer.signal()
        #expect(try await firstTask.value == "ok-holds-the-lock")

        // It throws rather than generating: the model is never called for this
        // message at all — which is the one case where a cancel of work that
        // ignores it still gives no response (see
        // ``RoutedSession/cancel()``).
        await #expect(throws: CancellationError.self) {
            try await queuedTask.value
        }
        #expect(await fixture.observer.entered == ["holds-the-lock"])

        // No submission carried the message, so the record holds only the
        // first submission's whole prompt/response pair.
        let events = await fixture.recorder.events
        #expect(events.map(\.kind) == [.session, .prompt, .response])
        #expect(events.last?.text == "ok-holds-the-lock")
        #expect(await Self.followUpAnswerCompletes(on: session, observer: fixture.observer))
    }

    @Test("abandoning a stream while its answer runs cancels the submission behind it, which is then recorded as cancelled rather than completed")
    @MainActor
    func abandoningAStreamRecordsTheSubmissionAsCancelled() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let fixture = try await Self.makeFixture(cacheDir: dir)
        let session = fixture.model.makeSession()

        // A tool that never checks cancellation, so what is asserted below is the
        // own outcome of the *submission* rather than the tool's cooperation.
        let insideTool = AsyncSemaphore(value: 0)
        let release = AsyncSemaphore(value: 0)
        fixture.hook.midAnswer = { prompt in
            guard prompt.hasSuffix("abandon-stream") else { return }
            insideTool.signal()
            await release.wait()
        }

        // Take one fragment and walk away — a consumer that stops listening.
        var delivered: [String] = []
        for try await chunk in await session.streamResponse(to: "abandon-stream") {
            delivered.append(chunk)
            break
        }
        #expect(delivered == [HookedSessionBackend.firstStreamedChunk])

        // Waiting for the tool to suspend first keeps the assertion below deterministic:
        // the diff of the submission must run while the backend still has no
        // `.response` entry for it, which is exactly the state a cut-short
        // submission is in.
        await insideTool.wait()
        await BoundedWait.spin(until: { await fixture.recorder.events.count == 3 })

        // Not "a submission that finished with a short response": a cancelled
        // submission, with the same lone bodyless close every other failed
        // submission gets.
        let events = await fixture.recorder.events
        #expect(events.map(\.kind) == [.session, .prompt, .response])
        #expect(events.last?.text == nil)

        // Let the abandoned producer drain rather than leaving it suspended for the
        // rest of the suite.
        release.signal()
        await BoundedWait.spin(until: { await fixture.observer.exited.contains("abandon-stream") })
        #expect(await fixture.observer.exited.contains("abandon-stream"))
    }

    // MARK: - A cancellation is not forgotten between the submissions of an answer

    @Test(
        "a cancellation landing during a failed attempt stops the overflow retry from re-running the model",
        arguments: CancellationRoute.allCases)
    @MainActor
    func cancellationSurvivesIntoTheOverflowRetry(route: CancellationRoute) async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let fixture = try await Self.makeFixture(cacheDir: dir)
        // A budget makes this session recover from context overflow by compaction
        // harder and retrying once — and that retry is the window where the pump
        // runs the answer with no model call outstanding, so a cancellation
        // arriving in it has no task to cancel and must be remembered instead.
        let session = fixture.model.makeSession(budget: Self.unreachableTriggerBudget)

        let insideTool = AsyncSemaphore(value: 0)
        let release = AsyncSemaphore(value: 0)
        let observer = fixture.observer
        fixture.hook.midAnswer = { prompt in
            guard prompt.hasSuffix("overflow-then-cancel") else { return }
            // A second call means the retry re-ran the model after the answer was
            // already cancelled — the regression this test exists for. Failing
            // here rather than suspending again keeps that a failed assertion instead
            // of a hung suite.
            guard await observer.entered.count == 1 else {
                throw ProbeError.modelReenteredAfterCancellation
            }
            insideTool.signal()
            await release.wait()
            // The one failure a budgeted answer compacts-and-retries on, raised
            // with a cancellation already outstanding against this answer.
            throw LanguageModelError.contextSizeExceeded(
                .init(contextSize: 100, tokenCount: 150, debugDescription: "stub context overflow"))
        }

        let answerTask = Task {
            try await session.respond(to: "overflow-then-cancel")
        }
        await insideTool.wait()
        // Both routes must behave identically here: neither may let the retry
        // re-enter the model on behalf of an answer already cancelled.
        switch route {
        case .routerAPI:
            #expect(await session.cancel() == .requested)
        case .callerTask:
            answerTask.cancel()
        }
        release.signal()

        // The retry's model call never starts: the answer ends cancelled rather
        // than silently re-running the whole submission, tool calls included.
        await #expect(throws: CancellationError.self) {
            try await answerTask.value
        }
        #expect(await fixture.observer.entered == ["overflow-then-cancel"])
    }

    // MARK: - Queue-side cancellation is unchanged

    @Test("cancel(message:) of a waiting message still produces no submission for it")
    @MainActor
    func withdrawingAWaitingMessageStillProducesNoSubmission() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let fixture = try await Self.makeFixture(cacheDir: dir)
        let session = fixture.model.makeSession()

        // A running submission keeps the session busy, so the next message
        // waits in the outbox.
        let insideTool = AsyncSemaphore(value: 0)
        let sawCancellation = Self.suspendInsideCancellationAwareTool(fixture, prompt: "busy", insideTool: insideTool)
        let answerTask = Task { try await session.respond(to: "busy") }
        await insideTool.wait()

        let id = await session.send("queued")
        #expect(await session.cancel(message: id) == .withdrawn)

        #expect(await session.cancel() == .requested)
        try await Self.awaitCancelledUnwind(answerTask, sawCancellation: sawCancellation)
        #expect(await session.becomesIdle())

        // The withdrawn message never reached the model: the cancel of the
        // running answer left the queue-side one as it was.
        #expect(await fixture.observer.entered == ["busy"])
        #expect(await session.pendingMessages().isEmpty)
    }
}
