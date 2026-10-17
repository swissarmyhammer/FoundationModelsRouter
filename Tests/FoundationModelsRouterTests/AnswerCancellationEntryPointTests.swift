import Foundation
import FoundationModels
import Testing

@testable import FoundationModelsRouter

/// The tests of ``AnswerCancellationTests`` for the streaming and
/// queue-dispatch entry points, the no-op cases, a stop between the
/// submissions of one answer, and the queue-side cancel.
extension AnswerCancellationTests {
    // MARK: - The streaming and queue-dispatch entry points

    @Test(
        "cancelAll() finishes a streamEvents answer with CancellationError, and the consumer keeps what it already received"
    )
    @MainActor
    func cancellingAStreamingAnswerFinishesTheStreamWithCancellationError() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let fixture = try await Self.makeFixture(cacheDir: dir)
        let session = fixture.model.makeSession()
        defer { await session.close() }

        let insideTool = AsyncSemaphore(value: 0)
        let sawCancellation = Self.suspendInsideCancellationAwareTool(fixture, prompt: "stream-cancel", insideTool: insideTool)

        // The stream is drained into `delivered` as it arrives, so what the consumer
        // had already been handed survives the error the stream finishes with.
        let delivered = DeliveredEvents()
        // The consumer sends this event after it appended the first chunk to
        // `delivered`, so a test that the event resumes finds the chunk there.
        let firstChunkAtConsumer = AwaitedEvent()
        let answerTask = Task { () throws -> Int in
            for try await event in await session.streamEvents(to: "stream-cancel") {
                await delivered.append(event)
                if event == .textDelta(HookedSessionBackend.firstStreamedChunk) {
                    firstChunkAtConsumer.signal()
                }
            }
            return await delivered.events.count
        }
        try await RecordedWaitResult.wait(forPermitOf: insideTool, endingOnEndOf: answerTask)
        // The backend yields the first chunk before the tool runs, but the
        // signal of the tool does not tell that the consumer has the chunk.
        // The session reads the backend stream through an unfolding stream,
        // which ends at once when its task is cancelled, so a chunk that is
        // still in the buffer of the backend stream is not delivered. The
        // test must stop the answer only after the consumer received the chunk.
        //
        // The wait is on the event of the consumer, not on a wall-clock
        // bound. Nothing on the path of the chunk waits for the tool, so the
        // chunk always arrives; a loaded machine only delays it. A bound of
        // some seconds failed under parallel stress (task ^7w145zc) while the
        // chunk was still on its way. The wait ends when the chunk arrives.
        // The consumer sends the event in the answer task, so the wait also
        // ends on the end of that task (rule T1).
        try await RecordedWaitResult.wait(for: firstChunkAtConsumer, endingOnEndOf: answerTask)

        let stop = await Self.requestStop(of: session, by: .cancelAll)
        try await Self.awaitCancelledUnwind(answerTask, sawCancellation: sawCancellation)
        // The signal does not wait for the pump. The check of the recording
        // needs the end of the stopped work, so the test waits for the pump.
        try await Self.expectStopEnds(stop)

        // Everything the answer produced before the cancellation is still the
        // consumer's — a cancelled stream is truncated, not retracted.
        #expect(await delivered.events.contains(.textDelta(HookedSessionBackend.firstStreamedChunk)))
        #expect(await fixture.recorder.events.withoutMailRecords.map(\.kind) == [.session, .prompt, .response])

        // The cancelled chain ends with one answerFailed with the reason
        // cancelled. The signal sends it at once, before the submission
        // ends, so the stream has no end of the submission. It is the last
        // event before the stream throws, and it names the one message of
        // the stream.
        let deliveredEvents = await delivered.events
        #expect(deliveredEvents.submissionStarts.count == 1)
        #expect(deliveredEvents.submissionEnds.isEmpty)
        let failure = try #require(deliveredEvents.answerFailures.first)
        #expect(deliveredEvents.answerFailures.count == 1)
        #expect(deliveredEvents.answers.isEmpty)
        #expect(failure.reason == .cancelled)
        #expect(failure.mailIds.count == 1)
        #expect(deliveredEvents.last == .answerFailed(failure))
    }

    @Test("cancel(_:) of a sent message that the running answer carries changes nothing, and the answer goes on to its end")
    @MainActor
    func cancellingASentMessageInTheRunningAnswerLeavesTheAnswerToItsEnd() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let fixture = try await Self.makeFixture(cacheDir: dir)
        let session = fixture.model.makeSession()

        // The tool does not stop on a cancel. It waits for the test, so the
        // answer can end only after the test releases the tool.
        let insideTool = AsyncSemaphore(value: 0)
        let release = AsyncSemaphore(value: 0)
        fixture.hook.midAnswer = { prompt in
            guard prompt.hasSuffix("send-cancel") else { return }
            insideTool.signal()
            await release.wait()
        }
        defer { await SessionFixtureLifecycle.close([session], releasing: [release], permits: 1) }

        // `send` starts the submission, and no other call is necessary.
        let sent = try session.send("send-cancel")
        // The mail has its terminal event only after the answer ended, so the
        // wait also ends on that event (rule T1).
        try await RecordedWaitResult.wait(forPermitOf: insideTool, endingOnTerminalOf: sent, on: session)

        // The pump took the mail into the open answer, so the mail is not in
        // the queue. A cancel of one mail acts only on queued mail: its
        // signal ends with no cancelled event, and it does not stop the
        // answer.
        #expect(await session.pendingMessages().isEmpty)
        try await Self.expectSignalEnds(session.cancel(sent), on: session)

        release.signal()
        let end = try await session.awaitTerminal(of: sent)
        #expect([end].answers.map(\.reply) == ["ok-send-cancel"])
        #expect(await fixture.observer.toolSawCancellation == false)
        // A cancel after the answer also finds nothing: the terminal event of
        // the mail is still its answer.
        try await Self.expectSignalEnds(session.cancel(sent), on: session)
        #expect(try await session.awaitTerminal(of: sent) == end)
        #expect(await session.becomesIdle())
    }

    // MARK: - No-ops and best-effort honesty

    @Test("a stop of the running work twice, and a stop after the answer has finished, are safe no-ops")
    @MainActor
    func cancellingTwiceAndAfterCompletionIsASafeNoOp() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let fixture = try await Self.makeFixture(cacheDir: dir)
        let session = fixture.model.makeSession()

        // Before any answer: no work to stop.
        #expect(await session.stopRunningWork() == false)

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
        defer { await SessionFixtureLifecycle.close([session], releasing: [release], permits: 1) }

        let answerTask = Task { try await session.respond(to: "cancel-me") }
        try await RecordedWaitResult.wait(forPermitOf: insideTool, endingOnEndOf: answerTask)

        // Twice while the same answer provably still runs: the second call
        // requests what was already requested and changes nothing.
        #expect(await session.stopRunningWork())
        #expect(await session.stopRunningWork())

        release.signal()
        await #expect(throws: CancellationError.self) {
            try await answerTask.value
        }
        #expect(await fixture.observer.toolSawCancellation)

        // After the end of the answer and of the pump: no work to stop, and
        // the request that stays cannot go into the next answer.
        // `followUpAnswerCompletes` waits for the next answer, and then
        // checks that its model call ended.
        #expect(await session.becomesIdle())
        #expect(await session.stopRunningWork() == false)
        #expect(await Self.followUpAnswerCompletes(on: session, observer: fixture.observer))
        #expect(await session.becomesIdle())
        #expect(await session.stopRunningWork() == false)
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
        defer { await SessionFixtureLifecycle.close([session], releasing: [release], permits: 1) }

        let answerTask = Task { try await session.respond(to: "stubborn") }
        try await RecordedWaitResult.wait(forPermitOf: insideTool, endingOnEndOf: answerTask)
        #expect(await session.stopRunningWork())

        // Nothing Router can do makes it stop, so the answer runs to completion
        // and is recorded as the whole submission it was.
        release.signal()
        #expect(try await answerTask.value == "ok-stubborn")
        #expect(await fixture.recorder.events.withoutMailRecords.map(\.kind) == [.session, .prompt, .response])
        #expect(await fixture.recorder.events.withoutMailRecords.last?.text == "ok-stubborn")
    }

    @Test("a respond cancelled while its message waits behind another answer withdraws the mail with cancelled, and the mail never reaches the model")
    @MainActor
    func cancellingAQueuedMessageNeverReachesTheModel() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let fixture = try await Self.makeFixture(cacheDir: dir)
        let session = fixture.model.makeSession()

        // The first submission suspends inside the model without checking
        // cancellation, so the second message provably waits in the queue
        // rather than racing to start.
        let insideFirstAnswer = AsyncSemaphore(value: 0)
        let releaseFirstAnswer = AsyncSemaphore(value: 0)
        fixture.hook.midAnswer = { prompt in
            guard prompt.hasSuffix("holds-the-lock") else { return }
            insideFirstAnswer.signal()
            await releaseFirstAnswer.wait()
        }
        defer { await SessionFixtureLifecycle.close([session], releasing: [releaseFirstAnswer], permits: 1) }

        let firstTask = Task { try await session.respond(to: "holds-the-lock") }
        try await RecordedWaitResult.wait(forPermitOf: insideFirstAnswer, endingOnEndOf: firstTask)

        let queuedTask = Task { try await session.respond(to: "queued-and-cancelled") }
        // The session signals `stateChanges` after it puts a mail in the
        // queue. The wait ends when the message is in the queue.
        try await session.stateChanges.wait(until: { session.waitingUserMailCount == 1 })
        let queuedId = try #require(session.outbox.queue.pending.first { !$0.isRunMail }?.id)

        // Cancelled while its mail waits. The mail leaves the queue, and it
        // gets its terminal event `cancelled`: it never goes into a
        // submission.
        queuedTask.cancel()
        #expect(try await session.awaitTerminal(of: queuedId) == .cancelled(queuedId))
        #expect(session.waitingUserMailCount == 0)
        releaseFirstAnswer.signal()
        #expect(try await firstTask.value == "ok-holds-the-lock")

        // It throws rather than generating: the model is never called for this
        // message at all.
        await #expect(throws: CancellationError.self) {
            try await queuedTask.value
        }
        #expect(await fixture.observer.entered == ["holds-the-lock"])

        // No submission carried the message, so the record holds only the
        // first submission's whole prompt/response pair.
        let events = await fixture.recorder.events.withoutMailRecords
        #expect(events.map(\.kind) == [.session, .prompt, .response])
        #expect(events.last?.text == "ok-holds-the-lock")
        #expect(await Self.followUpAnswerCompletes(on: session, observer: fixture.observer))
    }

    @Test("a respond whose caller is cancelled before the call gets CancellationError at once, and never reaches the model")
    @MainActor
    func aCallerCancelledBeforeTheCallNeverReachesTheModel() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let fixture = try await Self.makeFixture(cacheDir: dir)
        let session = fixture.model.makeSession()

        // The first answer holds the pump inside the model, so only the
        // cancel of the caller can resolve the second message: the pump
        // cannot take it and drop it until the test releases the first answer.
        let insideFirstAnswer = AsyncSemaphore(value: 0)
        let releaseFirstAnswer = AsyncSemaphore(value: 0)
        fixture.hook.midAnswer = { prompt in
            guard prompt.hasSuffix("holds-the-pump") else { return }
            insideFirstAnswer.signal()
            await releaseFirstAnswer.wait()
        }
        defer { await SessionFixtureLifecycle.close([session], releasing: [releaseFirstAnswer], permits: 1) }

        let firstTask = Task { try await session.respond(to: "holds-the-pump") }
        try await RecordedWaitResult.wait(forPermitOf: insideFirstAnswer, endingOnEndOf: firstTask)

        // The task cancels itself before it calls `respond`, so the cancel
        // comes before the session makes the message. The order is fixed by
        // the code of the task, not by the executor.
        let cancelledCaller = Task { () async throws -> String in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await session.respond(to: "cancelled-before-the-call")
        }

        // The caller gets CancellationError while the first answer still
        // holds the pump. If the message waited for the pump instead, this
        // wait would not end.
        await #expect(throws: CancellationError.self) {
            try await cancelledCaller.value
        }
        #expect(session.waitingUserMailCount == 0)

        releaseFirstAnswer.signal()
        #expect(try await firstTask.value == "ok-holds-the-pump")

        // The model ran for the first message only, and the record holds
        // only its prompt/response pair.
        #expect(await fixture.observer.entered == ["holds-the-pump"])
        let events = await fixture.recorder.events.withoutMailRecords
        #expect(events.map(\.kind) == [.session, .prompt, .response])
        #expect(await Self.followUpAnswerCompletes(on: session, observer: fixture.observer))
    }

    @Test("abandoning a stream while its answer runs does not stop the answer: it goes on to its end, and the session records it as complete")
    @MainActor
    func abandoningAStreamLeavesTheAnswerToItsEnd() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let fixture = try await Self.makeFixture(cacheDir: dir)
        let session = fixture.model.makeSession()

        // A tool that never checks cancellation. It waits for the test, so the
        // answer can end only after the test releases the tool.
        let insideTool = AsyncSemaphore(value: 0)
        let release = AsyncSemaphore(value: 0)
        fixture.hook.midAnswer = { prompt in
            guard prompt.hasSuffix("abandon-stream") else { return }
            insideTool.signal()
            await release.wait()
        }
        defer { await SessionFixtureLifecycle.close([session], releasing: [release], permits: 1) }

        let feed = await session.streamSessionEvents()

        // Take one fragment and walk away — a consumer that stops listening.
        var delivered: [String] = []
        for try await chunk in await session.streamResponse(to: "abandon-stream") {
            delivered.append(chunk)
            break
        }
        #expect(delivered == [HookedSessionBackend.firstStreamedChunk])

        // The mail of the stream is in the open answer. The end of the
        // consumer cancels only queued mail, so the answer still runs. The
        // pump runs the answer from before the first chunk to the end of the
        // answer, so the wait also ends on the end of the pump (rule T1).
        let pumpEnding = Task { _ = await session.pumpEnds() }
        defer { pumpEnding.cancel() }
        try await RecordedWaitResult.wait(forPermitOf: insideTool, endingOnEndOf: pumpEnding)
        #expect(await session.isPumpRunning)

        // The answer goes on to its end. The session records the full
        // submission, with its response, and not a cut-short close.
        release.signal()
        let events = await feed.eventsToTheFirstAnswerEnd()
        #expect(events.answers.map(\.reply) == ["ok-abandon-stream"])
        #expect(events.answerFailures.isEmpty)
        #expect(await fixture.observer.toolSawCancellation == false)
        let recorded = await fixture.recorder.events.withoutMailRecords
        #expect(recorded.map(\.kind) == [.session, .prompt, .response])
        #expect(recorded.last?.text == "ok-abandon-stream")
        #expect(await session.becomesIdle())
    }

    // MARK: - A stop is not forgotten between the submissions of an answer

    @Test(
        "a stop that lands during a failed attempt stops the overflow retry from re-running the model",
        arguments: CancellationRoute.answerRoutes)
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
        // The overflow comes with a stop already requested for this answer. A
        // second model call is the regression this test is for.
        Self.overflowAfterRelease(
            fixture, prompt: "overflow-then-cancel", insideTool: insideTool, release: release)
        defer { await SessionFixtureLifecycle.close([session], releasing: [release], permits: 1) }

        let answerTask = Task {
            try await session.respond(to: "overflow-then-cancel")
        }
        try await RecordedWaitResult.wait(forPermitOf: insideTool, endingOnEndOf: answerTask)
        // Each route must behave identically here: no route may let the retry
        // re-enter the model for an answer that has a stop. The tool ignores
        // the stop, so the work cannot end before the release: the wait for
        // the stop request is safe.
        let stop = await Self.requestStop(of: session, by: route)
        try await Self.awaitStopRequested(on: session)
        release.signal()

        // The retry's model call never starts: the answer ends cancelled rather
        // than silently re-running the whole submission, tool calls included.
        await #expect(throws: CancellationError.self) {
            try await answerTask.value
        }
        // cancelAll() ends the answer at once, before the work unwinds. The
        // check of the model calls needs the end of the work, so the test
        // waits for the pump first.
        try await Self.expectStopEnds(stop)
        #expect(await fixture.observer.entered == ["overflow-then-cancel"])
    }

    // MARK: - Queue-side cancellation

    @Test("cancel(_:) of a waiting message withdraws it with cancelled, produces no submission for it, and does not stop the running answer")
    @MainActor
    func withdrawingAWaitingMessageStillProducesNoSubmission() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let fixture = try await Self.makeFixture(cacheDir: dir)
        let session = fixture.model.makeSession()
        defer { await session.close() }

        // A running submission keeps the session busy, so the next message
        // waits in the queue.
        let insideTool = AsyncSemaphore(value: 0)
        let sawCancellation = Self.suspendInsideCancellationAwareTool(fixture, prompt: "busy", insideTool: insideTool)
        let answerTask = Task { try await session.respond(to: "busy") }
        try await RecordedWaitResult.wait(forPermitOf: insideTool, endingOnEndOf: answerTask)

        let id = try session.send("queued")
        try await Self.expectSignalEnds(session.cancel(id), on: session)
        #expect(try await session.awaitTerminal(of: id) == .cancelled(id))

        // The cancel of the queued mail left the running answer as it was.
        #expect(await fixture.observer.toolSawCancellation == false)

        try await Self.expectSignalEnds(session.cancelAll(), on: session)
        try await Self.awaitCancelledUnwind(answerTask, sawCancellation: sawCancellation)
        #expect(await session.becomesIdle())

        // The withdrawn message never reached the model.
        #expect(await fixture.observer.entered == ["busy"])
        #expect(await session.pendingMessages().isEmpty)
    }
}
