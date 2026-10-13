import Foundation
import FoundationModels
import FoundationModelsRouterTestSupport
import Synchronization
import Testing

@testable import FoundationModelsRouter

/// The tests of ``AnswerCancellationTests`` for a stop that lands during a
/// compaction: a proactive one, a reactive compact-and-retry-once one, and
/// a requested `compact()`.
///
/// No signal and no stop of the answer affects a running compaction. A stop
/// of the answer (`stopRunningWork()` or ``RoutedSession/cancelAll()``) lets
/// the compaction end, and then stops the answer. Only
/// ``RoutedSession/close()`` cancels a running compaction: the compaction
/// ends with ``SessionEvent/compactionFailed(_:)`` (cancelled), and nothing
/// of it applies.
extension AnswerCancellationTests {
    // MARK: - Helpers

    /// The first summarizer call of a compaction, held inside the call until
    /// the test releases it.
    ///
    /// No cancel ends the hold. No signal and no stop of the answer affects a
    /// running compaction, so a hold that only a cancel ends would never end
    /// in these tests.
    final class HeldSummarizerCall: Sendable {
        /// Signalled once the first summarizer call is inside the hold.
        let inside = AsyncSemaphore(value: 0)

        /// The signal that ends the hold. Only the test sends it.
        let release = AsyncSemaphore(value: 0)

        /// Whether the task of the held call was cancelled when the hold ended.
        private let cancelSeen = Mutex(false)

        /// Whether the task of the held call was cancelled when the hold ended.
        var sawCancel: Bool {
            cancelSeen.withLock { $0 }
        }

        /// Records whether the task of the held call is cancelled now.
        func noteEndOfHold() {
            let isCancelled = Task.isCancelled
            cancelSeen.withLock { $0 = isCancelled }
        }
    }

    /// Installs a mid-answer hook that holds the first summarizer call of a
    /// compaction until the test releases it. Each other model call goes to
    /// `otherwise`.
    ///
    /// - Parameters:
    ///   - fixture: The fixture whose hook to install into.
    ///   - fault: The error that the held call throws when the hold ends, or
    ///     `nil` (the default) for a call that then answers.
    ///   - otherwise: The hook of each other model call, or `nil` (the
    ///     default) for none.
    /// - Returns: The hold.
    static func holdFirstSummarizerCall(
        _ fixture: Fixture,
        throwing fault: (any Error)? = nil,
        otherwise: AnswerHook.MidAnswer? = nil
    ) -> HeldSummarizerCall {
        let held = HeldSummarizerCall()
        let isFirstSummarizerCall = firstSummarizerCall()
        fixture.hook.midAnswer = { prompt in
            guard isFirstSummarizerCall(prompt) else {
                try await otherwise?(prompt)
                return
            }
            held.inside.signal()
            await held.release.wait()
            held.noteEndOfHold()
            if let fault {
                throw fault
            }
        }
        return held
    }

    /// What a stop of an answer during its held proactive compaction gave.
    struct StopDuringCompaction {
        /// The held first summarizer call of the compaction.
        let held: HeldSummarizerCall

        /// The events of the session feed, up to and including the end of
        /// the stopped answer.
        let events: [SessionEvent]

        /// The stop request of ``CancellationRoute/cancelAll``, or `nil`.
        let stop: StopRequest?
    }

    /// Sends `prompt` on `session`, whose next answer compacts first, holds
    /// the first summarizer call of that compaction, stops the answer by
    /// `route`, and then releases the summarizer call.
    ///
    /// For ``CancellationRoute/cancelAll``, the own model call of the answer
    /// holds in a cancellation-aware tool. The signal runs after the
    /// compaction, and the order of the signal and of that model call is not
    /// fixed. Without the tool, the model call can end before the signal
    /// runs. With it, the signal always stops the answer.
    ///
    /// The test reads the end of the answer from the session feed, which the
    /// `.timeLimit` of the suite can end, before it waits for the answer.
    ///
    /// - Parameters:
    ///   - fixture: The fixture whose hook to install into.
    ///   - session: A session whose next answer compacts first.
    ///   - route: The route of the stop.
    ///   - prompt: The prompt of the answer.
    /// - Returns: The hold, the events of the feed, and the stop request.
    /// - Throws: When a wait that the `.timeLimit` of the suite ends fails.
    static func stopAnswerDuringItsProactiveCompaction(
        _ fixture: Fixture,
        session: any RoutedSession,
        by route: CancellationRoute,
        prompt: String = "compacts-first"
    ) async throws -> StopDuringCompaction {
        let answerInside = AsyncSemaphore(value: 0)
        let answerSawCancellation = suspendInsideCancellationAwareTool(
            fixture,
            suspendingOn: { route == .cancelAll && !isSummarizerCall($0) && $0.hasSuffix(prompt) },
            insideTool: answerInside)
        let held = holdFirstSummarizerCall(fixture, otherwise: fixture.hook.midAnswer)
        let actor = try #require(session as? RoutedSessionActor)
        let feed = await session.streamSessionEvents()

        let answerTask = Task { try await session.respond(to: prompt) }
        await held.inside.wait()
        let stop = await requestStop(of: session, by: route)
        if let stop {
            // The signal waits behind the compaction: it has no terminal event
            // while the compaction runs.
            #expect(actor.outputHub.terminal(for: .signal(stop.signal.description)) == nil)
        }
        held.release.signal()

        let events = await feed.eventsToTheFirstAnswerEnd()
        await #expect(throws: CancellationError.self) {
            try await answerTask.value
        }
        // When the own model call of the answer started, the stop reached the
        // tool inside it.
        let ownCallEntered = await fixture.observer.entered.contains { !isSummarizerCall($0) && $0.hasSuffix(prompt) }
        if ownCallEntered {
            try await answerSawCancellation.wait()
        }
        return StopDuringCompaction(held: held, events: events, stop: stop)
    }

    /// Closes `session` while a compaction runs, and reads `feed` to its end.
    ///
    /// The close cancels the compaction and waits for its end, so the test
    /// lets the compaction go on (`cancelReached`) only after the cancel
    /// reached it. The feed ends when the close finishes it, and the read of
    /// the feed stops when the `.timeLimit` of the suite cancels the test.
    ///
    /// - Parameters:
    ///   - session: The session to close.
    ///   - feed: The session feed, made before the compaction started.
    ///   - cancelReached: Waits until the cancel of the close reached the
    ///     compaction, and lets the compaction go on.
    /// - Returns: Each output of the feed, in order.
    /// - Throws: What `cancelReached` throws.
    static func close(
        _ session: any RoutedSession,
        readingTo feed: AsyncStream<SessionOutput>,
        afterTheCancelReaches cancelReached: @Sendable () async throws -> Void
    ) async throws -> [SessionOutput] {
        let closing = Task { await session.close() }
        try await cancelReached()
        var outputs: [SessionOutput] = []
        for await output in feed {
            outputs.append(output)
        }
        await closing.value
        return outputs
    }

    /// Waits until the close has cancelled the running compaction of
    /// `session`. The `.timeLimit` of the suite ends a wait for a cancel that
    /// never comes.
    ///
    /// - Parameter session: The session that closes.
    /// - Throws: ``ConditionNeverHeld`` when the `.timeLimit` of the suite
    ///   ended the wait.
    static func awaitCompactionCancelled(on session: any RoutedSession) async throws {
        let actor = try #require(session as? RoutedSessionActor)
        try await AwaitedCondition.wait(until: { await actor.activeCompaction?.isCancelled == true })
    }

    /// The count of the summarizer calls that entered the model.
    ///
    /// - Parameter fixture: The fixture whose observer to read.
    /// - Returns: The count.
    static func summarizerCallCount(_ fixture: Fixture) async -> Int {
        await fixture.observer.entered.filter(isSummarizerCall).count
    }

    /// Whether the own model call of the answer with `prompt` entered the
    /// model.
    ///
    /// - Parameters:
    ///   - fixture: The fixture whose observer to read.
    ///   - prompt: The prompt of the answer.
    /// - Returns: `true` when the call entered.
    static func ownCallEntered(_ fixture: Fixture, prompt: String) async -> Bool {
        await fixture.observer.entered.contains { !isSummarizerCall($0) && $0.hasSuffix(prompt) }
    }

    // MARK: - A stop of the answer lets a running compaction end

    /// The production change that makes this test fail: a stop of the answer
    /// that cancels the summarizer call of its running compaction, or an
    /// answer that makes its own model call after a stop.
    @Test(
        "a stop during the proactive compaction of an answer lets the compaction end, and then the answer ends cancelled",
        arguments: CancellationRoute.answerRoutes)
    @MainActor
    func aStopDuringAProactiveCompactionLetsItEndThenCancelsTheAnswer(route: CancellationRoute) async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let fixture = try await Self.makeFixture(cacheDir: dir)
        let session = try await Self.makeCompactionTriggeredSession(fixture, budget: Self.summarizingCompactionBudget)

        let stopped = try await Self.stopAnswerDuringItsProactiveCompaction(fixture, session: session, by: route)
        try await Self.expectStopEnds(stopped.stop)

        // The summarizer call saw no cancel, and the compaction ended with its
        // result before the answer ended.
        #expect(stopped.held.sawCancel == false)
        #expect(stopped.events.compactionResults.count == 1)
        #expect(stopped.events.compactionFailures.isEmpty)
        #expect(stopped.events.answerFailures.map(\.reason) == [.cancelled])
        #expect(stopped.events.answers.isEmpty)

        // One summarizer call: the compaction did not go on to an other tier.
        #expect(await Self.summarizerCallCount(fixture) == 1)

        // `stopRunningWork()` is recorded at once, so the check before the own
        // model call of the answer refuses that call. `cancelAll()` runs after
        // the compaction, so the call can start, and the stop then reaches the
        // tool inside it.
        if route == .stopRunningWork {
            #expect(await Self.ownCallEntered(fixture, prompt: "compacts-first") == false)
        }
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

    /// The production change that makes this test fail: a compaction that
    /// reads a stop of the answer as a cancel of the compaction, so that a
    /// fault of the flash tier no longer degrades to the own model while a
    /// stop is outstanding.
    @Test(
        "a summarizer fault while a stop of the answer is outstanding still degrades to the own model, and then the answer ends cancelled"
    )
    @MainActor
    func aSummarizerFaultWhileAStopIsOutstandingStillDegrades() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let fixture = try await Self.makeFixture(cacheDir: dir)
        let session = try await Self.makeCompactionTriggeredSession(fixture, budget: Self.summarizingCompactionBudget)

        // The flash tier holds until the test releases it, and then fails.
        // The own model writes a short summary, so that the summary applies
        // and the result names the tier that wrote it.
        fixture.hook.reply = { Self.isSummarizerCall($0) ? "short summary" : nil }
        let held = Self.holdFirstSummarizerCall(fixture, throwing: ProbeError.summarizerFailed)
        let feed = await session.streamSessionEvents()
        let answerTask = Task { try await session.respond(to: "compacts-first") }
        await held.inside.wait()
        #expect(await session.stopRunningWork())
        held.release.signal()

        let events = await feed.eventsToTheFirstAnswerEnd()
        await #expect(throws: CancellationError.self) {
            try await answerTask.value
        }

        // The stop did not reach the compaction, so the fault of the flash
        // tier degraded to the own model, which wrote the summary.
        #expect(held.sawCancel == false)
        #expect(await Self.summarizerCallCount(fixture) == 2)
        #expect(events.compactionResults.map(\.summarizerTier) == [.ownModel])
        #expect(events.compactionFailures.isEmpty)
        // Then the stop ended the answer before its own model call.
        #expect(events.answerFailures.map(\.reason) == [.cancelled])
        #expect(await Self.ownCallEntered(fixture, prompt: "compacts-first") == false)

        fixture.hook.midAnswer = nil
        #expect(await Self.followUpAnswerCompletes(on: session, observer: fixture.observer))
    }

    // MARK: - Only close cancels a running compaction

    /// The production change that makes this test fail: a close that does
    /// not cancel a running compaction, or a compaction that the close
    /// cancels and that goes on to the own-model tier after the fault of the
    /// flash tier.
    @Test("a summarizer fault that coincides with close ends the automatic compaction as cancelled, and the compaction does not degrade")
    @MainActor
    func aSummarizerFaultThatCoincidesWithCloseIsAbandonedAsCancelled() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let fixture = try await Self.makeFixture(cacheDir: dir)
        let session = try await Self.makeCompactionTriggeredSession(fixture, budget: Self.summarizingCompactionBudget)

        // A plainly unrelated fault arrives while the close is outstanding.
        // The close wins: the compaction ends as cancelled, and it does not
        // go on to the next tier. The discarded fault is a log line, which no
        // test can observe (see ``RoutedSessionActor``'s abandoned-compaction
        // report).
        let held = Self.holdFirstSummarizerCall(fixture, throwing: ProbeError.summarizerFailed)
        let feed = await session.streamSessionEvents()
        let answerTask = Task { try await session.respond(to: "compacts-first") }
        await held.inside.wait()

        let outputs = try await Self.close(session, readingTo: feed) {
            try await Self.awaitCompactionCancelled(on: session)
            held.release.signal()
        }
        await #expect(throws: CancellationError.self) {
            try await answerTask.value
        }

        let events = outputs.map(\.event)
        let start = try #require(events.compactionStarts.first)
        #expect(held.sawCancel)
        #expect(
            events.compactionFailures
                == [CompactionFailure(id: start.id, reason: .triggerReached, outcome: .cancelled)])
        #expect(events.compactionResults.isEmpty)
        #expect(await Self.summarizerCallCount(fixture) == 1)
        #expect(await Self.ownCallEntered(fixture, prompt: "compacts-first") == false)
    }

    /// The production change that makes this test fail: a close that does
    /// not cancel a running requested compaction, a cancelled compaction that
    /// applies its snapshot, or one that goes on to the own-model tier.
    @Test(
        "close cancels a running requested compaction: its summarizer sees the cancel, it ends with compactionFailed(.cancelled), and nothing of it applies"
    )
    @MainActor
    func closeCancelsARunningRequestedCompaction() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let fixture = try await Self.makeFixture(cacheDir: dir)
        // Warmed up for its transcript alone here: a requested compaction needs
        // no trigger, just enough content for the summarizer call to have work
        // to do.
        let session = try await Self.makeCompactionTriggeredSession(fixture, budget: Self.summarizingCompactionBudget)
        let transcriptBefore = Array(await session.transcript)
        let recordedBefore = await fixture.recorder.events.withoutMailRecords.count

        let insideSummarizer = AsyncSemaphore(value: 0)
        let sawCancellation = Self.suspendInsideCancellationAwareTool(
            fixture, suspendingOn: Self.firstSummarizerCall(), insideTool: insideSummarizer)
        let feed = await session.streamSessionEvents()

        let id = session.compact(prompt: Self.compactionSummarizerPrompt, budget: Self.summarizingCompactionBudget)
        await insideSummarizer.wait()

        // The summarizer call runs in the task of the compaction, and only
        // the close cancels that task.
        let outputs = try await Self.close(session, readingTo: feed) {
            try await sawCancellation.wait()
        }
        #expect(await fixture.observer.toolSawCancellation)

        // The terminal event of the signal is in the ledger, also after the
        // end of the session.
        let failure = CompactionFailure(id: id.description, reason: .requested, outcome: .cancelled)
        #expect(try await session.awaitTerminal(of: id) == .compactionFailed(failure))
        let compaction = outputs.filter { $0.origin == .signal(id) }.map(\.event)
        #expect(
            compaction == [
                .compactionStarted(CompactionStart(id: id.description, reason: .requested)),
                .compactionFailed(failure),
            ])

        // No own-model call after the cancel, and nothing applied.
        #expect(await Self.summarizerCallCount(fixture) == 1)
        #expect(Array(await session.transcript) == transcriptBefore)
        #expect(await fixture.recorder.events.withoutMailRecords.count == recordedBefore)
    }

    /// The production change that makes this test fail: a `cancelAll()` that
    /// stops a running compaction, or one that runs before the compaction
    /// ends.
    @Test("cancelAll() during a requested compaction runs after it: the compaction completes, and then the signal ends")
    @MainActor
    func cancelAllDuringARequestedCompactionRunsAfterIt() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let fixture = try await Self.makeFixture(cacheDir: dir)
        let session = try await Self.makeCompactionTriggeredSession(fixture, budget: Self.summarizingCompactionBudget)
        let actor = try #require(session as? RoutedSessionActor)

        let held = Self.holdFirstSummarizerCall(fixture)
        let feed = await session.streamSessionEvents()
        let id = session.compact(prompt: Self.compactionSummarizerPrompt, budget: Self.summarizingCompactionBudget)
        await held.inside.wait()

        // The signal returns at once, and its work waits behind the
        // compaction: neither has a terminal event while the summarizer holds.
        let stop = session.cancelAll()
        #expect(actor.outputHub.terminal(for: .signal(stop.description)) == nil)
        #expect(actor.outputHub.terminal(for: .signal(id.description)) == nil)

        held.release.signal()
        let terminal = try await session.awaitTerminal(of: id)
        _ = try compactionResult(of: terminal)
        try await Self.expectSignalEnds(stop, on: session)
        #expect(held.sawCancel == false)

        fixture.hook.midAnswer = nil
        #expect(await Self.followUpAnswerCompletes(on: session, observer: fixture.observer))

        // The terminal event of the compaction comes before the end of the
        // signal.
        await session.close()
        var outputs: [SessionOutput] = []
        for await output in feed {
            outputs.append(output)
        }
        let compactionEnd = try #require(outputs.firstIndex { $0.origin == .signal(id) && $0.event == terminal })
        let signalEnd = try #require(outputs.firstIndex { $0.event == .signalDone(stop) })
        #expect(compactionEnd < signalEnd)
    }

    /// The production change that makes this test fail: a close that does
    /// not cancel a running requested compaction, or a requested compaction
    /// that the close cancels and that goes on to the own-model tier after
    /// the fault of the flash tier.
    @Test(
        "a summarizer fault in a requested compaction that coincides with close ends it as cancelled, not as the fault, and the own model does not run"
    )
    @MainActor
    func aSummarizerFaultInARequestedCompactionThatCoincidesWithCloseIsCancelled() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let fixture = try await Self.makeFixture(cacheDir: dir)
        let session = try await Self.makeCompactionTriggeredSession(fixture, budget: Self.summarizingCompactionBudget)

        // A requested compaction offers the flash tier first and the own model
        // second. Only the abandon rule of the compaction keeps the fault of
        // the flash tier from going on to the own model.
        let held = Self.holdFirstSummarizerCall(fixture, throwing: ProbeError.summarizerFailed)
        let feed = await session.streamSessionEvents()
        let id = session.compact(prompt: Self.compactionSummarizerPrompt, budget: Self.summarizingCompactionBudget)
        await held.inside.wait()

        _ = try await Self.close(session, readingTo: feed) {
            try await Self.awaitCompactionCancelled(on: session)
            held.release.signal()
        }

        #expect(held.sawCancel)
        #expect(
            try await session.awaitTerminal(of: id)
                == .compactionFailed(CompactionFailure(id: id.description, reason: .requested, outcome: .cancelled)))
        #expect(await Self.summarizerCallCount(fixture) == 1)
    }

    /// The production change that makes this test fail: a requested
    /// compaction that waits behind a running answer before its summarizer
    /// call, or one that applies its snapshot while a submission is open.
    @Test(
        "a requested compaction starts while an answer runs, and applies its snapshot after the open submission closes"
    )
    @MainActor
    func aRequestedCompactionRunsBesideAnAnswerAndAppliesAfterItsSubmission() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let fixture = try await Self.makeFixture(cacheDir: dir)
        // Not metered over the trigger, so the answer that holds the pump runs no
        // proactive compaction of its own.
        let session = try await Self.makeCompactionTriggeredSession(
            fixture, budget: Self.summarizingCompactionBudget, metersTriggeringFill: false)
        let actor = try #require(session as? RoutedSessionActor)
        // A short summary, so that the compaction shrinks the live context and
        // applies its snapshot.
        fixture.hook.reply = { Self.isSummarizerCall($0) ? "short summary" : nil }

        // The answer holds its open submission in a cancellation-aware tool.
        let holdingPrompt = "holds-the-pump"
        let insideTool = AsyncSemaphore(value: 0)
        let sawCancellation = Self.suspendInsideCancellationAwareTool(
            fixture, suspendingOn: { !Self.isSummarizerCall($0) && $0.hasSuffix(holdingPrompt) },
            insideTool: insideTool)
        let answerTask = Task { try await session.respond(to: holdingPrompt) }
        await insideTool.wait()

        // The compaction does not wait for the answer: its summarizer call
        // enters and ends while the answer still holds its submission. No
        // event tells that end, so the test reads the observer until it holds.
        let id = session.compact(prompt: Self.compactionSummarizerPrompt, budget: Self.summarizingCompactionBudget)
        try await AwaitedCondition.wait(until: { await fixture.observer.exited.contains(where: Self.isSummarizerCall) })
        #expect(await fixture.observer.toolSawCancellation == false)
        // The snapshot waits until no submission is open, so the compaction
        // has no terminal event yet.
        #expect(actor.outputHub.terminal(for: .signal(id.description)) == nil)

        #expect(await session.stopRunningWork())
        try await Self.awaitCancelledUnwind(answerTask, sawCancellation: sawCancellation)

        // The open submission closed, so the compaction applied its snapshot.
        let result = try compactionResult(of: try await session.awaitTerminal(of: id))
        let summaryEntryId = try #require(result.summaryEntryId)
        #expect(Array(await session.transcript).contains { $0.id == summaryEntryId })

        fixture.hook.midAnswer = nil
        #expect(await Self.followUpAnswerCompletes(on: session, observer: fixture.observer))
    }

    /// The production change that makes this test fail: a stop during a
    /// running compaction that loses the run mail that the answer took, or
    /// that does not end it with the answer under `cancelAll()`.
    @Test(
        "an answer stopped during its own proactive compaction loses no run mail it took: queued again, or ended with the answer by cancelAll()",
        arguments: CancellationRoute.answerRoutes)
    @MainActor
    func anAnswerStoppedDuringItsProactiveCompactionLosesNoRunMail(route: CancellationRoute) async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let fixture = try await Self.makeFixture(cacheDir: dir)
        let session = try await Self.makeCompactionTriggeredSession(fixture, budget: Self.summarizingCompactionBudget)

        // Posted after the warm-up, so this answer is the answer that takes it.
        let posted = OperationEvent(
            tool: "shell", op: "run command", correlationID: "1", kind: .completed, detail: "exit 0")
        await session.outbox.post(event: posted)
        let postedId = try #require(await session.outbox.pending().events.first?.id)

        let stopped = try await Self.stopAnswerDuringItsProactiveCompaction(fixture, session: session, by: route)
        try await Self.expectStopEnds(stopped.stop)
        #expect(stopped.held.sawCancel == false)
        #expect(stopped.events.compactionResults.count == 1)

        // The run mail must not be lost: that is the reason for the requeue
        // in this window.
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
        case .stopRunningWork:
            // The check before the own model call refused the call, so the
            // model did not see the run mail. The mail waits in the queue
            // again, with its own id.
            #expect(pending.events.map(\.event) == [posted])
            #expect(pending.events.map(\.id) == [postedId])
        }
    }

    /// The production change that makes this test fail: a compaction that
    /// the close cancels and that still delivers a
    /// ``SessionEvent/compaction(_:)``, or a cancelled compaction that
    /// degrades to the next tier.
    @Test("a proactive compaction that close cancels reports no compaction, because none happened")
    @MainActor
    func aProactiveCompactionThatCloseCancelsReportsNoCompaction() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let fixture = try await Self.makeFixture(cacheDir: dir)
        let session = try await Self.makeCompactionTriggeredSession(fixture, budget: Self.summarizingCompactionBudget)

        let insideSummarizer = AsyncSemaphore(value: 0)
        let sawCancellation = Self.suspendInsideCancellationAwareTool(
            fixture, suspendingOn: Self.firstSummarizerCall(), insideTool: insideSummarizer)
        let recordedBefore = await fixture.recorder.events.withoutMailRecords.count
        let feed = await session.streamSessionEvents()

        let answerTask = Task { try await session.respond(to: "compacts-first") }
        await insideSummarizer.wait()
        let outputs = try await Self.close(session, readingTo: feed) {
            try await sawCancellation.wait()
        }
        await #expect(throws: CancellationError.self) {
            try await answerTask.value
        }

        // A cancelled compaction is abandoned. It does not degrade to the next
        // summarizer tier as a broken summarizer does. So the feed never gets
        // a compaction, and each `.compaction` of this session is real work.
        let events = outputs.map(\.event)
        #expect(events.compactionResults.isEmpty)
        #expect(events.compactionFailures.map(\.outcome) == [.cancelled])
        #expect(await Self.summarizerCallCount(fixture) == 1)

        // The session records the stopped answer as each other failed answer:
        // one close with no body.
        let recorded = await fixture.recorder.events.withoutMailRecords
        #expect(recorded.count == recordedBefore + 1)
        #expect(recorded.last?.kind == .response)
        #expect(recorded.last?.text == nil)
    }

    /// The production change that makes this test fail: a compaction that
    /// the close cancels and that still applies its snapshot, its recorded
    /// entries, or its measured fill.
    @Test("a proactive compaction that close cancels leaves the transcript and the fill exactly as they were, plus one close")
    @MainActor
    func aProactiveCompactionThatCloseCancelsLeavesTheTranscriptUntouched() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let fixture = try await Self.makeFixture(cacheDir: dir)
        let session = try await Self.makeCompactionTriggeredSession(fixture, budget: Self.summarizingCompactionBudget)
        // A short summary, so that a compaction that is not cancelled would
        // apply: the test then proves that the cancel kept it out.
        fixture.hook.reply = { Self.isSummarizerCall($0) ? "short summary" : nil }

        let fillBefore = await session.contextFill
        let transcriptBefore = Array(await session.transcript)
        let recordedBefore = await fixture.recorder.events.withoutMailRecords.count

        let insideSummarizer = AsyncSemaphore(value: 0)
        let sawCancellation = Self.suspendInsideCancellationAwareTool(
            fixture, suspendingOn: Self.firstSummarizerCall(), insideTool: insideSummarizer)
        let feed = await session.streamSessionEvents()

        let answerTask = Task { try await session.respond(to: "compacts-first") }
        await insideSummarizer.wait()
        _ = try await Self.close(session, readingTo: feed) {
            try await sawCancellation.wait()
        }
        await #expect(throws: CancellationError.self) {
            try await answerTask.value
        }

        // Never a half-applied compaction: a compaction records its new
        // entries, swaps `backend`, and reports its own post-compaction size
        // as this session's fill, all of it only once the summarizer has
        // returned. An abandoned compaction does none of it.
        #expect(await session.contextFill == fillBefore)
        #expect(Array(await session.transcript) == transcriptBefore)

        // Recorded like every other failed answer, and no differently for
        // having been cut short in a compaction: exactly one close, bodyless,
        // with no `.prompt` of its own because the model was never called.
        let recorded = await fixture.recorder.events.withoutMailRecords
        #expect(recorded.count == recordedBefore + 1)
        #expect(recorded.last?.kind == .response)
        #expect(recorded.last?.text == nil)
    }

    /// The production change that makes this test fail: a stop of the answer
    /// that cancels the summarizer call of its reactive compaction, or a
    /// retry that runs after a stop.
    @Test("a stop during the reactive compact-and-retry-once compaction lets the compaction end, and the retry never runs")
    @MainActor
    func aStopDuringTheReactiveCompactionLetsItEndAndSkipsTheRetry() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let fixture = try await Self.makeFixture(cacheDir: dir)
        // Unmetered, so the proactive gate never fires and the only compaction in play is
        // the one the own context overflow of this answer triggers.
        let session = try await Self.makeCompactionTriggeredSession(
            fixture, budget: Self.summarizingCompactionBudget, metersTriggeringFill: false)

        let recordedBefore = await fixture.recorder.events.withoutMailRecords.count
        // The summarizer call renders the whole live context, the own prompt of
        // the failed submission last, so its prompt also ends with the prompt of
        // the answer. Only a call that is not the summarizer's is the own call of
        // the answer: it overflows.
        let held = Self.holdFirstSummarizerCall(fixture) { prompt in
            guard !Self.isSummarizerCall(prompt), prompt.hasSuffix(Self.overflowingCompactionPrompt) else { return }
            throw Self.makeStubContextOverflow()
        }
        let feed = await session.streamSessionEvents()

        let answerTask = Task {
            try await session.respond(to: Self.overflowingCompactionPrompt)
        }
        await held.inside.wait()
        #expect(await session.stopRunningWork())
        held.release.signal()

        let events = await feed.eventsToTheFirstAnswerEnd()
        await #expect(throws: CancellationError.self) {
            try await answerTask.value
        }

        // The compaction ended with its result, and the summarizer saw no
        // cancel.
        #expect(held.sawCancel == false)
        #expect(events.compactionResults.count == 1)
        #expect(events.answerFailures.map(\.reason) == [.cancelled])

        // The retry never ran: the model saw the own call of this answer
        // exactly once, and what the caller gets is the cancellation rather
        // than the overflow it was recovering from.
        #expect(
            await fixture.observer.entered.filter {
                !Self.isSummarizerCall($0) && $0.hasSuffix(Self.overflowingCompactionPrompt)
            }.count == 1)

        // One prompt and two closes: the failed attempt records its prompt
        // and its close. The retry opens its submission, and the check before
        // its model call refuses it, so the retry records a close with no
        // prompt: the model never saw the retry.
        let recorded = Array(await fixture.recorder.events.withoutMailRecords.dropFirst(recordedBefore))
        #expect(recorded.filter { $0.kind == .prompt }.count == 1)
        #expect(recorded.filter { $0.kind == .response && $0.text == nil }.count == 2)
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

    /// The production change that makes this test fail: a close that does
    /// not cancel a running automatic compaction, or a cancelled compaction
    /// that sends no ``SessionEvent/compactionFailed(_:)`` before the feeds
    /// finish.
    @Test("close inside an automatic compaction ends it with compactionFailed(.cancelled), and no compaction")
    @MainActor
    func closeDuringAnAutomaticCompactionReportsTheCancel() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let fixture = try await Self.makeFixture(cacheDir: dir)
        let session = try await Self.makeCompactionTriggeredSession(fixture, budget: Self.summarizingCompactionBudget)

        let insideSummarizer = AsyncSemaphore(value: 0)
        let sawCancellation = Self.suspendInsideCancellationAwareTool(
            fixture, suspendingOn: Self.firstSummarizerCall(), insideTool: insideSummarizer)
        let feed = await session.streamSessionEvents()

        let answerTask = Task { try await session.respond(to: "compacts-first") }
        await insideSummarizer.wait()
        let outputs = try await Self.close(session, readingTo: feed) {
            try await sawCancellation.wait()
        }
        await #expect(throws: CancellationError.self) {
            try await answerTask.value
        }

        let events = outputs.map(\.event)
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
