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
        arguments: CancellationRoute.allCases)
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

        switch route {
        case .routerAPI:
            #expect(await session.cancel() == .requested)
        case .callerTask:
            answerTask.cancel()
        }

        // A compaction's summarizer call is a model call like any other, so both routes
        // reach the work running inside it and the answer unwinds with the same
        // `CancellationError` a cancelled generation gives.
        try await Self.awaitCancelledUnwind(answerTask, sawCancellation: sawCancellation)
        #expect(await fixture.observer.toolSawCancellation)

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
        #expect(await session.cancel() == .requested)
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
        "cancelling a caller-driven compact() stops it too, by either route — the pump runs it as work the same way",
        arguments: CancellationRoute.allCases)
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

        // A manual compaction is not an answer a caller ever asked to generate, but the
        // pump runs it as its work and it runs real model work, so a stop reaches it on
        // exactly the same terms — a caller no longer has to own an enclosing `Task`
        // to get out.
        //
        // Both routes, because routing the summarizer through the session's own
        // cancellable model call *changed* how the caller's route arrives here: a
        // caller's cancellation used to propagate structurally, through the very task
        // that called `compact()`, and now has to reach an unstructured task by
        // `withTaskCancellationHandler` and the pre-flight check instead. That is the
        // most-changed behavior on this path, so it is the one least safe to leave to
        // the other route's coverage.
        switch route {
        case .routerAPI:
            #expect(await session.cancel() == .requested)
        case .callerTask:
            compactTask.cancel()
        }
        try await Self.awaitCancelledUnwind(compactTask, sawCancellation: sawCancellation)
        #expect(await fixture.observer.toolSawCancellation)

        // And it stranded nothing on the way out, so the session still generates.
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
        #expect(await session.cancel() == .requested)
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
        await BoundedWait.spin(until: { await actor.pendingCompactions.count == 1 })
        #expect(await actor.pendingCompactions.count == 1)

        // The cancel of the caller must take the request out of the list while
        // the answer still runs. The caller does not wait for the end of the answer.
        compactTask.cancel()
        await BoundedWait.spin(until: { await actor.pendingCompactions.isEmpty })
        #expect(await actor.pendingCompactions.isEmpty)
        #expect(await actor.isPumpRunning)

        #expect(await session.cancel() == .requested)
        try await Self.awaitCancelledUnwind(answerTask, sawCancellation: sawCancellation)
        await #expect(throws: CancellationError.self) {
            try await compactTask.value
        }
        #expect(await fixture.observer.entered.filter(Self.isSummarizerCall).isEmpty)

        fixture.hook.midAnswer = nil
        #expect(await Self.followUpAnswerCompletes(on: session, observer: fixture.observer))
    }

    @Test(
        "an answer cancelled inside its own proactive compaction re-queues the outbox events it had drained",
        arguments: CancellationRoute.allCases)
    @MainActor
    func cancelledProactiveCompactionRequeuesItsDrainedEvents(route: CancellationRoute) async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let fixture = try await Self.makeFixture(cacheDir: dir)
        let session = try await Self.makeCompactionTriggeredSession(fixture, budget: Self.summarizingCompactionBudget)

        // Staged after the warm-up, so this answer is the one that drains it.
        let posted = OperationEvent(
            tool: "shell", op: "run command", correlationID: "1", kind: .completed, detail: "exit 0")
        await session.outbox.post(event: posted)

        let insideSummarizer = AsyncSemaphore(value: 0)
        let sawCancellation = Self.suspendInsideCancellationAwareTool(
            fixture, suspendingOn: Self.firstSummarizerCall(), insideTool: insideSummarizer)

        let answerTask = Task { try await session.respond(to: "compacts-first") }
        await insideSummarizer.wait()
        // Both routes, because losing a drained outbox is a silent data-loss bug
        // rather than a visible failure: on the caller-cancels route the re-queue
        // itself runs inside an already-cancelled task, so nothing about it may
        // depend on the task still being live.
        switch route {
        case .routerAPI:
            #expect(await session.cancel() == .requested)
        case .callerTask:
            answerTask.cancel()
        }
        try await Self.awaitCancelledUnwind(answerTask, sawCancellation: sawCancellation)

        // The compaction threw before the answer ever reached the model, so nothing this
        // answer drained was delivered — and the drain must not have destroyed it.
        // The re-queue for this window is the whole reason the compaction could not
        // simply be made to throw.
        let pending = await session.outbox.pending()
        #expect(pending.events.map(\.event) == [posted])
    }

    @Test(
        "an answer cancelled inside its own proactive compaction reports no compaction, because none happened",
        arguments: CancellationRoute.allCases)
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

        // Streamed, because ``SessionEvent/compaction(_:)`` is only observable to a
        // consumer that asked for the events of this answer.
        let delivered = DeliveredEvents()
        let answerTask = Task {
            for try await event in await session.streamEvents(to: "compacts-first") {
                await delivered.append(event)
            }
        }
        await insideSummarizer.wait()
        // Both routes, because the rule this pins — a cancelled compaction is abandoned
        // rather than degraded — is decided by a predicate that asks each route
        // separately, so its holding for one says nothing about the other.
        //
        // What the *consumer* sees is the one thing that genuinely differs by route
        // here, and it differs for a reason outside this package: cancelling a task
        // suspended in `AsyncThrowingStream.next()` **finishes** that stream rather
        // than throwing from it. So only the router-API route can be asserted with
        // ``awaitCancelledUnwind(_:sawCancellation:)``.
        switch route {
        case .routerAPI:
            #expect(await session.cancel() == .requested)
            // The consumer is not what was cancelled, so it is told: the stream ends
            // by throwing the own `CancellationError` of the answer.
            try await Self.awaitCancelledUnwind(answerTask, sawCancellation: sawCancellation)
        case .callerTask:
            // Cancelling the consumer terminates the stream, which cancels the task
            // the answer itself runs in — the abandoned-stream shape
            // ``abandoningAStreamRecordsTheSubmissionAsCancelled()`` pins from the other
            // side. What this route can therefore show is that the compaction let go and
            // the consumer came back at all, not an error it could never observe.
            //
            // The slowest crossing this suite makes, and the one this suite's own
            // doc takes its measurement from: the stop reaches the compaction only once
            // the cancelled consumer runs again on the shared main actor. Waited
            // on, never timed (task ^bqj719z).
            answerTask.cancel()
            try await sawCancellation.wait()
            // Safe to await, for ``followUpAnswerEvents(on:observer:prompt:)``'s reason:
            // a stream consumer's `next()` is cancellation-aware and always ends.
            _ = try? await answerTask.value
        }

        // A cancelled compaction is abandoned outright, not degraded down to the
        // next summarizer tier the way a broken summarizer is: so the consumer is
        // never told a compaction happened, and every `.compaction` this session reports
        // describes work it really did. Pinned by the router-API route — on the
        // caller-cancels one it holds trivially, since a consumer that cancelled itself
        // receives nothing further whatever the compaction went on to do.
        let compactions = await delivered.events.compactMap { event -> CompactionResult? in
            guard case .compaction(let result) = event else { return nil }
            return result
        }
        #expect(compactions.isEmpty)

        // What the caller-cancels route pins instead, and the reason it is worth
        // running: a streamed answer cut short inside its compaction is recorded like every
        // other one — a lone bodyless close — even though on that route the recording
        // runs inside an already-cancelled task. Spun for rather than read straight,
        // because a cancelled consumer returns before the producer behind it has
        // finished recording (the same ordering
        // ``abandoningAStreamRecordsTheSubmissionAsCancelled()`` waits on).
        await BoundedWait.spin(until: { await fixture.recorder.events.count == recordedBefore + 1 })
        let recorded = await fixture.recorder.events
        #expect(recorded.count == recordedBefore + 1)
        #expect(recorded.last?.kind == .response)
        #expect(recorded.last?.text == nil)
    }

    @Test(
        "an answer cancelled inside its own proactive compaction leaves the transcript exactly as it was, plus one close",
        arguments: CancellationRoute.allCases)
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
        // Both routes, because of the recording assertions below: on the
        // caller-cancels route the own recording of the cut-short answer runs
        // inside an already-cancelled task, which is the riskier of the two for
        // anything that must still happen on the way out.
        switch route {
        case .routerAPI:
            #expect(await session.cancel() == .requested)
        case .callerTask:
            answerTask.cancel()
        }
        try await Self.awaitCancelledUnwind(answerTask, sawCancellation: sawCancellation)

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
            throw LanguageModelError.contextSizeExceeded(
                .init(contextSize: 100, tokenCount: 150, debugDescription: "stub context overflow"))
        }

        let answerTask = Task {
            try await session.respond(to: Self.overflowingCompactionPrompt)
        }
        await insideSummarizer.wait()
        #expect(await session.cancel() == .requested)
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

        guard case .compaction(let result) = events.first else {
            Issue.record("expected the first event of the answer to be .compaction, got \(String(describing: events.first))")
            return
        }
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
