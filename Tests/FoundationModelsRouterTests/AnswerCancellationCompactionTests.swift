import Foundation
import FoundationModels
import FoundationModelsRouterTestSupport
import Synchronization
import Testing

@testable import FoundationModelsRouter

/// The tests of ``AnswerCancellationTests`` for a stop that lands during a
/// compaction: a proactive one, a reactive compact-and-retry-once one, and
/// a caller-driven `compact()`.
extension AnswerCancellationTests {
    // MARK: - A stop lands during a compaction too

    @Test(
        "cancelling an answer suspended inside its proactive compaction's summarizer call stops the compaction instead of waiting it out",
        arguments: CancellationRoute.answerRoutes)
    @MainActor
    func cancellingAProactiveCompactionStopsIt(route: CancellationRoute) async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let fixture = try await Self.makeFixture(cacheDir: dir)
        let session = try await Self.makeCompactionTriggeredSession(fixture, budget: Self.summarizingCompactionBudget)

        let insideSummarizer = AsyncSemaphore(value: 0)
        let sawCancellation = Self.suspendInsideCancellationAwareTool(
            fixture, suspendingOn: Self.firstSummarizerCall(), insideTool: insideSummarizer)

        let answerTask = Task { try await session.respond(to: "compacts-first") }
        await insideSummarizer.wait()

        let stop = await Self.requestStop(of: session, by: route, callerTask: answerTask)

        // The summarizer call of a compaction is a model call as each other
        // model call is. So each route reaches the work inside it, and the
        // answer unwinds with the `CancellationError` of a stopped generation.
        try await Self.awaitCancelledUnwind(answerTask, sawCancellation: sawCancellation)
        #expect(await fixture.observer.toolSawCancellation)
        try await Self.expectStopEnds(stop)

        // No further model call is *entered* while unwinding: the stop costs no more
        // model work than the call it landed in. Deliberately not read as a guard on
        // the tier-degrading rule itself — `runCancellableModelCall`'s pre-flight
        // check refuses a later tier's call before the hook is ever reached, so this
        // count stays `1` either way. `cancelledProactiveCompactionReportsNoCompaction` is
        // what pins the rule.
        #expect(await fixture.observer.entered.filter(Self.isSummarizerCall).count == 1)

        // And the submission the compaction was running for never ran: with nothing under way
        // once the compaction is gone, its own model call is never made.
        #expect(await fixture.observer.entered.contains("compacts-first") == false)
    }

    @Test("a summarizer that raises CancellationError with no stop outstanding is an ordinary failure, and still degrades")
    @MainActor
    func summarizerCancellationErrorWithNoStopOutstandingStillDegrades() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let fixture = try await Self.makeFixture(cacheDir: dir)
        let session = try await Self.makeCompactionTriggeredSession(fixture, budget: Self.summarizingCompactionBudget)

        // `LanguageModelSessionBackend` is a public protocol, and a conformer is free
        // to surface `CancellationError` from internals of its own — a timeout, a
        // task group it manages — with nothing cancelled on this side at all. That is
        // an ordinary summarizer failure, so the compaction must degrade to the next tier
        // exactly as it does for any other one, rather than reading the error's
        // *type* as a stop and killing an answer nobody asked to stop.
        let summarizerCalls = Mutex(0)
        fixture.hook.midAnswer = { prompt in
            guard Self.isSummarizerCall(prompt) else { return }
            let isFirstCall = summarizerCalls.withLock { calls -> Bool in
                calls += 1
                return calls == 1
            }
            guard isFirstCall else { return }
            throw CancellationError()
        }

        // No cancel anywhere in this test, so this answer cannot suspend: it either compacts
        // and answers, or fails.
        #expect(try await session.respond(to: "compacts-first") == "ok-compacts-first")

        // Two summarizer calls: the flash tier's failure, then the own-model tier
        // that actually produced the summary.
        #expect(await fixture.observer.entered.filter(Self.isSummarizerCall).count == 2)
    }

    @Test("a genuine summarizer fault that coincides with a stop ends the answer as cancelled, and still does not degrade")
    @MainActor
    func summarizerFaultCoincidingWithAStopIsAbandonedAsCancelled() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let fixture = try await Self.makeFixture(cacheDir: dir)
        let session = try await Self.makeCompactionTriggeredSession(fixture, budget: Self.summarizingCompactionBudget)

        // The race this pins is the inverse of
        // ``summarizerCancellationErrorWithNoStopOutstandingStillDegrades()``: there a
        // cancellation-shaped error arrives with no stop outstanding, here a plainly
        // unrelated fault arrives with one. The stop wins — the caller is told its answer
        // was cancelled rather than handed a compaction failure it never asked about, and the
        // compaction is still not degraded to the next tier. What becomes of the discarded
        // fault is a log line rather than a rethrow, which is the one part of this no
        // test can observe (see ``RoutedSessionActor``'s abandoned-compaction report).
        let insideSummarizer = AsyncSemaphore(value: 0)
        let release = AsyncSemaphore(value: 0)
        let suspendsOn = Self.firstSummarizerCall()
        fixture.hook.midAnswer = { prompt in
            guard suspendsOn(prompt) else { return }
            insideSummarizer.signal()
            await release.wait()
            throw ProbeError.summarizerFailed
        }

        // Streamed, because the *only* observable difference between abandoning this
        // compaction and letting it finish is the ``SessionEvent/compaction(_:)``
        // a finished compaction would deliver — see the assertion below.
        let delivered = DeliveredEvents()
        let answerTask = Task {
            for try await event in await session.streamEvents(to: "compacts-first") {
                await delivered.append(event)
            }
        }
        await insideSummarizer.wait()
        #expect(await session.stopRunningWork())
        // Released by the test rather than by the cancellation, so this answer unwinds
        // through the fault's path and not through the suspended tool's own.
        release.signal()

        await #expect(throws: CancellationError.self) {
            try await answerTask.value
        }
        // Not degraded: a fault is no licence to answer the stop by compaction anyway.
        // This is the assertion that pins the rule — the summarizer-call count below
        // cannot, because a degraded tier's call is refused by
        // `runCancellableModelCall`'s pre-flight check before the hook is ever
        // reached, so it stays `1` either way (the same caveat
        // ``cancellingAProactiveCompactionStopsIt(route:)`` records).
        let compactions = await delivered.events.compactMap { event -> CompactionResult? in
            guard case .compaction(let result) = event else { return nil }
            return result
        }
        #expect(compactions.isEmpty)
        #expect(await fixture.observer.entered.filter(Self.isSummarizerCall).count == 1)
        #expect(await fixture.observer.entered.contains("compacts-first") == false)

        // And this path stranded nothing either, fault and stop together.
        fixture.hook.midAnswer = nil
        #expect(await Self.followUpAnswerCompletes(on: session, observer: fixture.observer))
    }

    @Test(
        "cancelling a caller-driven compact() stops it too, by the stop of the running work and by the caller task",
        arguments: [CancellationRoute.stopRunningWork, .callerTask])
    @MainActor
    func cancellingACallerDrivenCompactStopsIt(route: CancellationRoute) async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let fixture = try await Self.makeFixture(cacheDir: dir)
        // Warmed up for its transcript alone here: a manual compaction needs no trigger,
        // just enough content for the summarizer call to have work to do.
        let session = try await Self.makeCompactionTriggeredSession(fixture, budget: Self.summarizingCompactionBudget)

        let insideSummarizer = AsyncSemaphore(value: 0)
        let sawCancellation = Self.suspendInsideCancellationAwareTool(
            fixture, suspendingOn: Self.firstSummarizerCall(), insideTool: insideSummarizer)

        let compactTask = Task {
            try await session.compact(prompt: Self.compactionSummarizerPrompt, budget: Self.summarizingCompactionBudget)
        }
        await insideSummarizer.wait()

        // A manual compaction is not an answer, but the pump runs it as its
        // work, and it runs real model work. So a stop of the running work
        // reaches it as it reaches an answer. ``RoutedSession/cancelAll()``
        // does not stop a caller compaction:
        // ``cancelAllLeavesARunningCallerCompactToItsCaller()`` proves that.
        //
        // The caller route too: a cancel of the caller task of a caller
        // compaction still stops that compaction. The summarizer runs in the
        // cancellable model call of the session, an unstructured task, so the
        // cancel of the caller must get there through
        // `withTaskCancellationHandler` and the pre-flight check.
        _ = await Self.requestStop(of: session, by: route, callerTask: compactTask)
        try await Self.awaitCancelledUnwind(compactTask, sawCancellation: sawCancellation)
        #expect(await fixture.observer.toolSawCancellation)

        // And it stranded nothing on the way out, so the session still generates.
        fixture.hook.midAnswer = nil
        #expect(await Self.followUpAnswerCompletes(on: session, observer: fixture.observer))
    }

    @Test("cancelAll() does not stop a running caller-driven compact(): only its caller or the stop of the running work does")
    @MainActor
    func cancelAllLeavesARunningCallerCompactToItsCaller() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let fixture = try await Self.makeFixture(cacheDir: dir)
        let session = try await Self.makeCompactionTriggeredSession(fixture, budget: Self.summarizingCompactionBudget)

        let insideSummarizer = AsyncSemaphore(value: 0)
        let sawCancellation = Self.suspendInsideCancellationAwareTool(
            fixture, suspendingOn: Self.firstSummarizerCall(), insideTool: insideSummarizer)

        let compactTask = Task {
            try await session.compact(prompt: Self.compactionSummarizerPrompt, budget: Self.summarizingCompactionBudget)
        }
        await insideSummarizer.wait()

        // The signal ends after all its work. The compaction is not mail and
        // not an answer, so the signal does not stop it: the summarizer does
        // not see a cancel.
        try await Self.expectSignalEnds(session.cancelAll(), on: session)
        #expect(await fixture.observer.toolSawCancellation == false)
        #expect(await session.isPumpRunning)

        // The caller still owns the compaction, and its cancel stops it.
        compactTask.cancel()
        try await Self.awaitCancelledUnwind(compactTask, sawCancellation: sawCancellation)

        fixture.hook.midAnswer = nil
        #expect(await Self.followUpAnswerCompletes(on: session, observer: fixture.observer))
    }

    @Test("a summarizer fault in a caller-driven compact() that coincides with a stop ends it as cancelled, not as the fault")
    @MainActor
    func callerCompactFaultCoincidingWithAStopIsCancelled() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let fixture = try await Self.makeFixture(cacheDir: dir)
        let session = try await Self.makeCompactionTriggeredSession(fixture, budget: Self.summarizingCompactionBudget)

        // A caller compaction offers one tier only: the own model. So no later
        // tier refuses the work at its pre-flight check. Only the abandon rule
        // of the compaction can change the fault into the stop.
        let insideSummarizer = AsyncSemaphore(value: 0)
        let release = AsyncSemaphore(value: 0)
        let suspendsOn = Self.firstSummarizerCall()
        fixture.hook.midAnswer = { prompt in
            guard suspendsOn(prompt) else { return }
            insideSummarizer.signal()
            await release.wait()
            throw ProbeError.summarizerFailed
        }

        let compactTask = Task {
            try await session.compact(prompt: Self.compactionSummarizerPrompt, budget: Self.summarizingCompactionBudget)
        }
        await insideSummarizer.wait()
        #expect(await session.stopRunningWork())
        // Released by the test, so the summarizer ends with its own fault while
        // the stop is outstanding.
        release.signal()

        await #expect(throws: CancellationError.self) {
            try await compactTask.value
        }

        fixture.hook.midAnswer = nil
        #expect(await Self.followUpAnswerCompletes(on: session, observer: fixture.observer))
    }

    @Test("cancelling a caller-driven compact() that waits behind a running answer withdraws it at once, and no summarizer runs")
    @MainActor
    func cancellingAWaitingCallerCompactWithdrawsIt() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let fixture = try await Self.makeFixture(cacheDir: dir)
        // Not metered over the trigger, so the answer that holds the pump runs no
        // proactive compaction of its own.
        let session = try await Self.makeCompactionTriggeredSession(
            fixture, budget: Self.summarizingCompactionBudget, metersTriggeringFill: false)
        let actor = try #require(session as? RoutedSessionActor)

        // The pump runs this answer, so the compaction below waits in the list of
        // the pump until the answer ends.
        let holdingPrompt = "holds-the-pump"
        let insideTool = AsyncSemaphore(value: 0)
        let sawCancellation = Self.suspendInsideCancellationAwareTool(
            fixture, prompt: holdingPrompt, insideTool: insideTool)
        let answerTask = Task { try await session.respond(to: holdingPrompt) }
        await insideTool.wait()

        let compactTask = Task {
            try await session.compact(prompt: Self.compactionSummarizerPrompt, budget: Self.summarizingCompactionBudget)
        }
        // No event tells that the request joined the list of the pump, or that
        // it left it, so the test reads the list until it holds. Neither wait
        // has a wall clock (task ^v4zh807): a loaded machine only delays the
        // change. The answer still holds the pump during both waits, so a
        // request that stays in the list until the answer ends never lets the
        // second wait end, and the `.timeLimit` of the suite fails the test.
        try await AwaitedCondition.wait(until: { await actor.pendingCompactions.count == 1 })

        // The cancel of the caller must take the request out of the list while
        // the answer still runs. The caller does not wait for the end of the answer.
        compactTask.cancel()
        try await AwaitedCondition.wait(until: { await actor.pendingCompactions.isEmpty })
        #expect(await actor.isPumpRunning)

        #expect(await session.stopRunningWork())
        try await Self.awaitCancelledUnwind(answerTask, sawCancellation: sawCancellation)
        await #expect(throws: CancellationError.self) {
            try await compactTask.value
        }
        #expect(await fixture.observer.entered.filter(Self.isSummarizerCall).isEmpty)

        fixture.hook.midAnswer = nil
        #expect(await Self.followUpAnswerCompletes(on: session, observer: fixture.observer))
    }

    @Test(
        "an answer cancelled inside its own proactive compaction loses no run mail it took: queued again, or ended with the answer by cancelAll()",
        arguments: CancellationRoute.answerRoutes)
    @MainActor
    func cancelledProactiveCompactionRequeuesItsTakenEvents(route: CancellationRoute) async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let fixture = try await Self.makeFixture(cacheDir: dir)
        let session = try await Self.makeCompactionTriggeredSession(fixture, budget: Self.summarizingCompactionBudget)

        // Posted after the warm-up, so this answer is the answer that takes it.
        let posted = OperationEvent(
            tool: "shell", op: "run command", correlationID: "1", kind: .completed, detail: "exit 0")
        await session.outbox.post(event: posted)
        let postedId = try #require(await session.outbox.pending().events.first?.id)

        let insideSummarizer = AsyncSemaphore(value: 0)
        let sawCancellation = Self.suspendInsideCancellationAwareTool(
            fixture, suspendingOn: Self.firstSummarizerCall(), insideTool: insideSummarizer)

        let answerTask = Task { try await session.respond(to: "compacts-first") }
        await insideSummarizer.wait()
        let stop = await Self.requestStop(of: session, by: route, callerTask: answerTask)
        try await Self.awaitCancelledUnwind(answerTask, sawCancellation: sawCancellation)
        try await Self.expectStopEnds(stop)

        // The compaction threw before the answer reached the model, so the
        // model did not see the run mail that the answer took. The run mail
        // must not be lost: that is the reason for the requeue in this window.
        let pending = await session.outbox.pending()
        switch route {
        case .cancelAll:
            // cancelAll ends the stopped answer at once, with the run mail
            // in it: the run mail gets the `answerFailed(.cancelled)` of the
            // answer as its terminal event. Thus the stopped answer does not
            // put it back in the queue.
            #expect(pending.events.isEmpty)
            let terminal = try await session.awaitTerminal(of: postedId)
            #expect([terminal].answerFailures.map(\.reason) == [.cancelled])
            #expect([terminal].answerFailures.first?.mailIds.contains(postedId) == true)
        case .stopRunningWork, .callerTask:
            // The mail waits in the queue again, with its own id.
            #expect(pending.events.map(\.event) == [posted])
            #expect(pending.events.map(\.id) == [postedId])
        }
    }

    @Test(
        "an answer cancelled inside its own proactive compaction reports no compaction, because none happened",
        arguments: CancellationRoute.answerRoutes)
    @MainActor
    func cancelledProactiveCompactionReportsNoCompaction(route: CancellationRoute) async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let fixture = try await Self.makeFixture(cacheDir: dir)
        let session = try await Self.makeCompactionTriggeredSession(fixture, budget: Self.summarizingCompactionBudget)

        let insideSummarizer = AsyncSemaphore(value: 0)
        let sawCancellation = Self.suspendInsideCancellationAwareTool(
            fixture, suspendingOn: Self.firstSummarizerCall(), insideTool: insideSummarizer)

        let recordedBefore = await fixture.recorder.events.count

        // Streamed, because only a consumer of the events of this answer sees a
        // ``SessionEvent/compaction(_:)``.
        let delivered = DeliveredEvents()
        let answerTask = Task {
            for try await event in await session.streamEvents(to: "compacts-first") {
                await delivered.append(event)
            }
        }
        await insideSummarizer.wait()
        // Each route, because a predicate that reads each route decides the
        // rule — a cancelled compaction is abandoned, not degraded. The rule
        // for one route tells nothing about the other route. The consumer is
        // not what was cancelled, so it reads each event: the stream ends with
        // the `CancellationError` of the answer. After cancelAll, the stream
        // ends at once, and the output drops the later events of the answer.
        let stop = await Self.requestStop(of: session, by: route, callerTask: answerTask)
        try await Self.awaitCancelledUnwind(answerTask, sawCancellation: sawCancellation)
        try await Self.expectStopEnds(stop)

        // A cancelled compaction is abandoned. It does not degrade to the next
        // summarizer tier as a broken summarizer does. So the consumer never
        // gets a compaction, and each `.compaction` of this session is real work.
        let compactions = await delivered.events.compactMap { event -> CompactionResult? in
            guard case .compaction(let result) = event else { return nil }
            return result
        }
        #expect(compactions.isEmpty)

        // The session records the stopped answer as each other failed answer:
        // one close with no body. The session records before the work sends
        // its own terminal event. cancelAll sends the terminal event before
        // the work ends, so ``expectStopEnds(_:)`` waits for the end of the
        // pump: then the record is complete for each route.
        let recorded = await fixture.recorder.events
        #expect(recorded.count == recordedBefore + 1)
        #expect(recorded.last?.kind == .response)
        #expect(recorded.last?.text == nil)
    }

    @Test(
        "an answer cancelled inside its own proactive compaction leaves the transcript exactly as it was, plus one close",
        arguments: CancellationRoute.answerRoutes)
    @MainActor
    func cancelledProactiveCompactionLeavesTheTranscriptUntouched(route: CancellationRoute) async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let fixture = try await Self.makeFixture(cacheDir: dir)
        let session = try await Self.makeCompactionTriggeredSession(fixture, budget: Self.summarizingCompactionBudget)

        let fillBefore = await session.contextFill
        let recordedBefore = await fixture.recorder.events.count

        let insideSummarizer = AsyncSemaphore(value: 0)
        let sawCancellation = Self.suspendInsideCancellationAwareTool(
            fixture, suspendingOn: Self.firstSummarizerCall(), insideTool: insideSummarizer)

        let answerTask = Task { try await session.respond(to: "compacts-first") }
        await insideSummarizer.wait()
        // Each route, because of the record and transcript assertions below:
        // cancelAll also cancels the queued mail and sweeps the runs, and none
        // of that may touch the transcript. ``expectStopEnds(_:)`` waits for
        // the end of the pump, so the record is complete before the test
        // reads it.
        let stop = await Self.requestStop(of: session, by: route, callerTask: answerTask)
        try await Self.awaitCancelledUnwind(answerTask, sawCancellation: sawCancellation)
        try await Self.expectStopEnds(stop)

        // Never a half-applied compaction: a compaction records its new entries, swaps
        // `backend`, and reports its own post-compaction size as this session's fill —
        // all of it only once the summarizer has returned. An abandoned compaction does
        // none of it, so measured fill is byte-identical to what it was before.
        #expect(await session.contextFill == fillBefore)

        // Recorded like every other failed answer, and no differently for having
        // been cut short in a compaction: exactly one close, bodyless, with no `.prompt`
        // of its own because the model was never called.
        let recorded = await fixture.recorder.events
        #expect(recorded.count == recordedBefore + 1)
        #expect(recorded.last?.kind == .response)
        #expect(recorded.last?.text == nil)

        // The session keeps working, and the abandoned compaction left the transcript it
        // was compacting alone: the *next* answer compacts for real, and its compaction measures
        // exactly the untouched warm-up transcript. Had the cancelled compaction swapped
        // `backend` for a compacted one, this would measure the smaller, compacted size —
        // which is what makes this an assertion about `backend` itself and not only
        // about the ordering inside `compaction`. The hook is cleared first, or that next
        // compaction would suspend in the summarizer all over again.
        fixture.hook.midAnswer = nil
        let followUp = try #require(await Self.followUpAnswerEvents(on: session, observer: fixture.observer))
        let untouchedSize = try characterTokenCounter.count(Transcript(entries: Self.warmUpEntries()))
        let compactions = followUp.compactMap { event -> CompactionResult? in
            guard case .compaction(let result) = event else { return nil }
            return result
        }
        #expect(compactions.map(\.tokensBefore) == [untouchedSize])
    }

    @Test("cancelling an answer inside its reactive compact-and-retry-once compaction stops the retry, leaving one close")
    @MainActor
    func cancellingTheReactiveCompactionStopsTheRetry() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let fixture = try await Self.makeFixture(cacheDir: dir)
        // Unmetered, so the proactive gate never fires and the only compaction in play is
        // the one the own context overflow of this answer triggers.
        let session = try await Self.makeCompactionTriggeredSession(
            fixture, budget: Self.summarizingCompactionBudget, metersTriggeringFill: false)

        let recordedBefore = await fixture.recorder.events.count
        let insideSummarizer = AsyncSemaphore(value: 0)
        let sawCancellation = Self.suspendInsideCancellationAwareTool(
            fixture, suspendingOn: Self.firstSummarizerCall(), insideTool: insideSummarizer)
        // Composed on top of the summarizer suspension rather than replacing it: this answer
        // has to overflow *and then* suspend inside the compaction that overflow triggers.
        let suspendInSummarizer = fixture.hook.midAnswer
        // The summarizer call renders the whole live context, the own prompt of
        // the failed submission last, so its prompt also ends with the prompt of
        // the answer. Only a call that is not the summarizer's is the own call of
        // the answer.
        fixture.hook.midAnswer = { prompt in
            guard !Self.isSummarizerCall(prompt), prompt.hasSuffix(Self.overflowingCompactionPrompt) else {
                try await suspendInSummarizer?(prompt)
                return
            }
            throw Self.makeStubContextOverflow()
        }

        let answerTask = Task {
            try await session.respond(to: Self.overflowingCompactionPrompt)
        }
        await insideSummarizer.wait()
        #expect(await session.stopRunningWork())
        try await Self.awaitCancelledUnwind(answerTask, sawCancellation: sawCancellation)

        // The retry never ran: the model saw this answer exactly once, and what the
        // caller gets is the cancellation rather than the overflow it was recovering
        // from.
        #expect(
            await fixture.observer.entered.filter {
                !Self.isSummarizerCall($0) && $0.hasSuffix(Self.overflowingCompactionPrompt)
            }.count == 1)

        // One close, not two: the failed attempt's own, recorded before the compaction
        // started. The retry that would have written the second never happened, and
        // the cancelled compaction adds none of its own.
        let recorded = await fixture.recorder.events
        #expect(recorded.count == recordedBefore + 2)
        #expect(Array(recorded.map(\.kind).suffix(2)) == [.prompt, .response])
        #expect(recorded.last?.text == nil)
    }

    // MARK: - The events of a compaction that does not complete (task ^k1gepqc)

    @Test("a summarizer failure inside an automatic compaction ends it with compactionFailed(.failed), and no compaction")
    @MainActor
    func failedAutomaticCompactionReportsItsFailure() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let fixture = try await Self.makeFixture(cacheDir: dir)
        let session = try await Self.makeCompactionTriggeredSession(fixture, budget: Self.summarizingCompactionBudget)

        // Each tier fails, and no stop is outstanding: the compaction fails.
        fixture.hook.midAnswer = { prompt in
            guard Self.isSummarizerCall(prompt) else { return }
            throw ProbeError.summarizerFailed
        }

        let delivered = DeliveredEvents()
        await #expect(throws: ProbeError.self) {
            for try await event in await session.streamEvents(to: "compacts-first") {
                await delivered.append(event)
            }
        }

        let events = await delivered.events
        let start = try #require(events.compactionStarts.first)
        #expect(events.compactionStarts.count == 1)
        #expect(start.reason == .triggerReached)
        #expect(
            events.compactionFailures
                == [
                    CompactionFailure(
                        id: start.id, reason: .triggerReached,
                        outcome: .failed(String(describing: ProbeError.summarizerFailed)))
                ])
        #expect(events.compactionResults.isEmpty)
        #expect(events.compactionLifecycleIsOrdered)
    }

    @Test("a cancel inside an automatic compaction ends it with compactionFailed(.cancelled), and no compaction")
    @MainActor
    func cancelledAutomaticCompactionReportsTheCancel() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let fixture = try await Self.makeFixture(cacheDir: dir)
        let session = try await Self.makeCompactionTriggeredSession(fixture, budget: Self.summarizingCompactionBudget)

        let insideSummarizer = AsyncSemaphore(value: 0)
        let sawCancellation = Self.suspendInsideCancellationAwareTool(
            fixture, suspendingOn: Self.firstSummarizerCall(), insideTool: insideSummarizer)

        // The stop of the running work: the consumer is not what is cancelled,
        // so it reads each event up to the end of the answer.
        let delivered = DeliveredEvents()
        let answerTask = Task {
            for try await event in await session.streamEvents(to: "compacts-first") {
                await delivered.append(event)
            }
        }
        await insideSummarizer.wait()
        #expect(await session.stopRunningWork())
        try await Self.awaitCancelledUnwind(answerTask, sawCancellation: sawCancellation)

        let events = await delivered.events
        let start = try #require(events.compactionStarts.first)
        #expect(events.compactionStarts.count == 1)
        #expect(
            events.compactionFailures
                == [CompactionFailure(id: start.id, reason: .triggerReached, outcome: .cancelled)])
        #expect(events.compactionResults.isEmpty)
        #expect(events.compactionLifecycleIsOrdered)
    }

    @Test("a compaction with no cancellation outstanding makes its one call and runs its answer exactly as before")
    @MainActor
    func compactionWithNoStopOutstandingIsUnaffected() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let fixture = try await Self.makeFixture(cacheDir: dir)
        let session = try await Self.makeCompactionTriggeredSession(fixture, budget: Self.summarizingCompactionBudget)

        // No hook installed and no stop requested: the cancellation boundary around
        // the summarizer call must cost the compaction nothing.
        var collected: [SessionEvent] = []
        for try await event in await session.streamEvents(to: "compacts-uncancelled") {
            collected.append(event)
        }
        let events = eventsInsideAnswerFrame(collected)
        #expect(collected.answers.count == 1)
        #expect(collected.answerFailures.isEmpty)

        let result = try #require(
            events.leadingCompaction,
            "expected the answer to open with one compaction, got \(Array(events.prefix(2)))")
        let untouchedSize = try characterTokenCounter.count(Transcript(entries: Self.warmUpEntries()))
        #expect(result.tokensBefore == untouchedSize)
        #expect(await fixture.observer.entered.filter(Self.isSummarizerCall).count == 1)

        // And the own work of the answer ran normally straight after the compaction.
        let streamedText = events.compactMap { event -> String? in
            guard case .textDelta(let text) = event else { return nil }
            return text
        }.joined()
        #expect(streamedText == "ok-compacts-uncancelled")
    }
}
