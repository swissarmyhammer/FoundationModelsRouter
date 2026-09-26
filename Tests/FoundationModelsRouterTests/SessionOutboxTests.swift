import FoundationModels
import Testing

@testable import FoundationModelsRouter

/// Exercises task 8cwwvaj: the `SessionOutbox` actor's storage, kinds, ids,
/// coalescing policy, and the take primitives of the pump (task ^3qx0mpt) —
/// in isolation from any ``RoutedSession``/``LanguageModelSession`` wiring
/// (that wiring is exercised separately in `SessionOutboxToolWiringTests`).
@Suite("SessionOutbox: storage, coalescing, take, wakeup")
struct SessionOutboxTests {
    /// Builds a canned ``OperationEvent`` for a given tool/correlation/kind, so
    /// tests can focus on the outbox's own bookkeeping rather than restating
    /// event field boilerplate.
    private static func event(
        tool: String = "shell",
        op: String = "run command",
        correlationID: String = "1",
        kind: OperationEventKind,
        detail: String = "detail"
    ) -> OperationEvent {
        OperationEvent(tool: tool, op: op, correlationID: correlationID, kind: kind, detail: detail)
    }

    // MARK: - Coalescing

    @Test("N .progress posts for one correlationID pend as exactly 1 — the latest")
    func progressCoalescesToLatestPerCorrelation() async {
        let outbox = SessionOutbox()
        await outbox.post(event: Self.event(correlationID: "c1", kind: .progress, detail: "10%"))
        await outbox.post(event: Self.event(correlationID: "c1", kind: .progress, detail: "50%"))
        await outbox.post(event: Self.event(correlationID: "c1", kind: .progress, detail: "90%"))

        let pending = await outbox.pending()
        #expect(pending.events.count == 1)
        #expect(pending.events.first?.event.detail == "90%")
    }

    @Test("progress coalescing is scoped per (tool, correlationID) — distinct correlations pend separately")
    func progressCoalescesOnlyWithinSameCorrelation() async {
        let outbox = SessionOutbox()
        await outbox.post(event: Self.event(correlationID: "c1", kind: .progress, detail: "c1-a"))
        await outbox.post(event: Self.event(correlationID: "c2", kind: .progress, detail: "c2-a"))
        await outbox.post(event: Self.event(correlationID: "c1", kind: .progress, detail: "c1-b"))

        let pending = await outbox.pending()
        #expect(pending.events.count == 2)
        let details = Set(pending.events.map(\.event.detail))
        #expect(details == ["c1-b", "c2-a"])
    }

    @Test("progress coalescing is scoped per tool — same correlationID, different tool, pend separately")
    func progressCoalescesOnlyWithinSameTool() async {
        let outbox = SessionOutbox()
        await outbox.post(event: Self.event(tool: "shell", correlationID: "c1", kind: .progress, detail: "shell-a"))
        await outbox.post(event: Self.event(tool: "notes", correlationID: "c1", kind: .progress, detail: "notes-a"))

        let pending = await outbox.pending()
        #expect(pending.events.count == 2)
    }

    @Test("interleaved .completed events all survive, in post order")
    func completedEventsAllSurviveInOrder() async {
        let outbox = SessionOutbox()
        await outbox.post(event: Self.event(correlationID: "c1", kind: .progress, detail: "c1-progress"))
        await outbox.post(event: Self.event(correlationID: "c1", kind: .completed, detail: "c1-done"))
        await outbox.post(event: Self.event(correlationID: "c2", kind: .progress, detail: "c2-progress"))
        await outbox.post(event: Self.event(correlationID: "c2", kind: .completed, detail: "c2-done"))

        let pending = await outbox.pending()
        // Every .completed is kept, plus each correlation's still-pending
        // .progress collapses to its own single latest entry — none of the
        // completed events are coalesced away or reordered.
        #expect(pending.events.map(\.event.detail) == ["c1-progress", "c1-done", "c2-progress", "c2-done"])
    }

    @Test("a .completed after a coalesced .progress for the same correlation does not replace it")
    func completedDoesNotCoalesceWithPriorProgress() async {
        let outbox = SessionOutbox()
        await outbox.post(event: Self.event(correlationID: "c1", kind: .progress, detail: "in flight"))
        await outbox.post(event: Self.event(correlationID: "c1", kind: .completed, detail: "finished"))

        let pending = await outbox.pending()
        #expect(pending.events.count == 2)
        #expect(pending.events.map(\.event.kind) == [.progress, .completed])
    }

    @Test("two .elicitation events for the same (tool, correlationID) both survive a take")
    func elicitationEventsNeverCoalesce() async {
        let outbox = SessionOutbox()
        await outbox.post(event: Self.event(correlationID: "c1", kind: .elicitation, detail: "first question"))
        await outbox.post(event: Self.event(correlationID: "c1", kind: .elicitation, detail: "second question"))

        let taken = await outbox.takeJoiningBatch(options: .mailDelivery)
        #expect(taken.events.map(\.event.detail) == ["first question", "second question"])
    }

    @Test("interleaved .progress still coalesces while .elicitation events are all kept, in post order")
    func progressCoalescesAroundElicitationEvents() async {
        let outbox = SessionOutbox()
        await outbox.post(event: Self.event(correlationID: "c1", kind: .progress, detail: "10%"))
        await outbox.post(event: Self.event(correlationID: "c1", kind: .elicitation, detail: "question A"))
        await outbox.post(event: Self.event(correlationID: "c1", kind: .progress, detail: "50%"))
        await outbox.post(event: Self.event(correlationID: "c1", kind: .elicitation, detail: "question B"))

        let pending = await outbox.pending()
        // The two .progress posts coalesce into the first one's slot; both
        // elicitations are kept in post order, never replaced.
        #expect(pending.events.map(\.event.detail) == ["50%", "question A", "question B"])
        #expect(pending.events.map(\.event.kind) == [.progress, .elicitation, .elicitation])
    }

    @Test("an .elicitation never replaces a pending .progress for the same (tool, correlationID)")
    func elicitationDoesNotCoalesceWithPriorProgress() async {
        let outbox = SessionOutbox()
        await outbox.post(event: Self.event(correlationID: "c1", kind: .progress, detail: "in flight"))
        await outbox.post(event: Self.event(correlationID: "c1", kind: .elicitation, detail: "question"))

        let pending = await outbox.pending()
        #expect(pending.events.count == 2)
        #expect(pending.events.map(\.event.kind) == [.progress, .elicitation])
    }

    // MARK: - Stable ids

    @Test("pending() reports items with stable ids and kinds")
    func pendingReportsStableIdsAndKinds() async {
        let outbox = SessionOutbox()
        await outbox.post(event: Self.event(correlationID: "c1", kind: .progress, detail: "first"))
        let firstPending = await outbox.pending()
        let idAfterFirstPost = try! #require(firstPending.events.first?.id)

        // A second .progress for the same correlation coalesces in place — the
        // stable id assigned at first enqueue does not change.
        await outbox.post(event: Self.event(correlationID: "c1", kind: .progress, detail: "second"))
        let secondPending = await outbox.pending()
        #expect(secondPending.events.first?.id == idAfterFirstPost)
        #expect(secondPending.events.first?.event.detail == "second")
    }

    @Test("every posted event gets a distinct id from every other pending item")
    func distinctEventsGetDistinctIds() async {
        let outbox = SessionOutbox()
        await outbox.post(event: Self.event(correlationID: "c1", kind: .completed, detail: "one"))
        await outbox.post(event: Self.event(correlationID: "c2", kind: .completed, detail: "two"))

        let pending = await outbox.pending()
        let ids = Set(pending.events.map(\.id))
        #expect(ids.count == 2)
    }

    // MARK: - Queued prompts: never coalesced, FIFO

    @Test("queued prompts never coalesce and preserve enqueue order")
    func queuedPromptsPreserveEnqueueOrderAndNeverCoalesce() async {
        let outbox = SessionOutbox()
        _ = await outbox.enqueue(prompt: Self.prompt("first"))
        _ = await outbox.enqueue(prompt: Self.prompt("second"))
        _ = await outbox.enqueue(prompt: Self.prompt("third"))

        let pending = await outbox.pending()
        #expect(pending.prompts.count == 3)
        #expect(pending.prompts.map { Self.text(of: $0.prompt) } == ["first", "second", "third"])
    }

    @Test("each enqueued prompt gets its own distinct, stable id")
    func enqueuedPromptsGetDistinctIds() async {
        let outbox = SessionOutbox()
        let id1 = await outbox.enqueue(prompt: Self.prompt("first"))
        let id2 = await outbox.enqueue(prompt: Self.prompt("second"))
        #expect(id1 != id2)

        let pending = await outbox.pending()
        #expect(pending.prompts.map(\.id) == [id1, id2])
    }

    // MARK: - takeSubmissionBatch(deliveringRunsOf:): commits and empties exactly what it returns

    /// A caller message with `text`, ready for the outbox.
    ///
    /// - Parameters:
    ///   - text: The prompt text.
    ///   - requestedMaxTokens: The ceiling the caller named, or `nil`.
    ///   - reader: Who reads the output of its submission.
    /// - Returns: The message.
    private static func message(
        _ text: String, requestedMaxTokens: Int? = nil, reader: MessageReader = .reply
    ) -> SessionMessage {
        SessionMessage(
            id: PromptID(), text: text, requestedMaxTokens: requestedMaxTokens, reader: reader,
            entryPoint: .respond, serviceContext: nil, answer: PumpAnswer())
    }

    @Test("takeSubmissionBatch commits and empties every pending event when a settled run's terminal can start a submission")
    func takeSubmissionBatchEmptiesEvents() async {
        let outbox = SessionOutbox()
        await outbox.post(event: Self.event(correlationID: "c1", kind: .completed, detail: "one"))
        await outbox.post(event: Self.event(correlationID: "c2", kind: .completed, detail: "two"))

        let taken = await outbox.takeSubmissionBatch(deliveringRunsOf: ["c1"])
        #expect(taken?.events.map(\.event.detail) == ["one", "two"])
        #expect(taken?.messages.isEmpty == true)

        // Committed items are gone.
        let pending = await outbox.pending()
        #expect(pending.events.isEmpty)
    }

    @Test("releaseFrontPrompt releases exactly one queued prompt, FIFO, as a caller message that counts as dispatched")
    func releaseFrontPromptReleasesOneQueuedPromptFIFO() async {
        let outbox = SessionOutbox()
        let firstID = await outbox.enqueue(prompt: Self.prompt("first"))
        _ = await outbox.enqueue(prompt: Self.prompt("second"))

        let released = await outbox.releaseFrontPrompt(answer: PumpAnswer(), serviceContext: nil)
        #expect(released?.id == firstID)
        #expect(released?.text == "first")
        #expect(await outbox.waitingMessageCount == 1)
        #expect(await outbox.queueDepth().dispatched == firstID)

        // Only the one released prompt left the queue; the rest remain pending.
        let pending = await outbox.pending()
        #expect(pending.prompts.count == 1)
        #expect(Self.text(of: pending.prompts[0].prompt) == "second")
    }

    @Test("releaseFrontPrompt with no queued prompt releases nothing, and leaves the mail pending")
    func releaseFrontPromptWithNoPromptsReleasesNothing() async {
        let outbox = SessionOutbox()
        await outbox.post(event: Self.event(correlationID: "c1", kind: .completed, detail: "one"))

        let released = await outbox.releaseFrontPrompt(answer: PumpAnswer(), serviceContext: nil)
        #expect(released == nil)
        #expect(await outbox.pending().events.count == 1)
    }

    @Test("a second takeSubmissionBatch with nothing new pending takes nothing")
    func secondTakeWithNothingNewTakesNothing() async {
        let outbox = SessionOutbox()
        await outbox.post(event: Self.event(correlationID: "c1", kind: .completed, detail: "one"))
        _ = await outbox.takeSubmissionBatch(deliveringRunsOf: ["c1"])

        #expect(await outbox.takeSubmissionBatch(deliveringRunsOf: ["c1"]) == nil)
    }

    @Test("progress mail, the terminal of a run that is no settled background run, and held mail start no submission and stay pending")
    func mailThatCannotStartASubmissionStaysPending() async {
        let outbox = SessionOutbox()
        await outbox.post(event: Self.event(correlationID: "c1", kind: .progress, detail: "10%"))
        #expect(await outbox.takeSubmissionBatch(deliveringRunsOf: ["c1"]) == nil)

        await outbox.post(event: Self.event(correlationID: "c2", kind: .completed, detail: "in-band run failed"))
        #expect(await outbox.takeSubmissionBatch(deliveringRunsOf: ["c1"]) == nil)
        #expect(await outbox.takeSubmissionBatch(deliveringRunsOf: []) == nil)
        #expect(await outbox.pending().events.count == 2)
    }

    @Test("a held terminal — given back by a failed submission, or held by a cancel — starts no submission until its hold ends, and rides the next caller message")
    func aHeldTerminalStartsNoSubmission() async {
        let outbox = SessionOutbox()
        let givenBack = Self.event(correlationID: "c1", kind: .completed, detail: "given back")
        await outbox.requeue(event: givenBack)
        #expect(await outbox.takeSubmissionBatch(deliveringRunsOf: ["c1", "c2"]) == nil)

        await outbox.releaseHeldMail()
        #expect(await outbox.takeSubmissionBatch(deliveringRunsOf: ["c1", "c2"])?.events.map(\.event) == [givenBack])

        let held = Self.event(correlationID: "c2", kind: .completed, detail: "held by a cancel")
        await outbox.post(event: held)
        await outbox.holdPendingMail()
        #expect(await outbox.takeSubmissionBatch(deliveringRunsOf: ["c1", "c2"]) == nil)

        await outbox.add(message: Self.message("next"))
        let taken = await outbox.takeSubmissionBatch(deliveringRunsOf: [])
        #expect(taken?.messages.map(\.text) == ["next"])
        #expect(taken?.events.map(\.event) == [held])
    }

    @Test("putBack returns untouched events in front of newer ones, each with its own id and hold")
    func putBackKeepsOrderIdsAndHolds() async {
        let outbox = SessionOutbox()
        await outbox.requeue(event: Self.event(correlationID: "c1", kind: .completed, detail: "held"))
        await outbox.post(event: Self.event(correlationID: "c2", kind: .progress, detail: "10%"))
        let taken = await outbox.takeJoiningBatch(options: .mailDelivery).events
        await outbox.post(event: Self.event(correlationID: "c3", kind: .completed, detail: "newer"))

        await outbox.putBack(untouched: taken)

        let pending = await outbox.pending().events
        #expect(pending.map(\.event.detail) == ["held", "10%", "newer"])
        #expect(pending.prefix(taken.count).map(\.id) == taken.map(\.id))
        #expect(pending.map(\.isHeld) == [true, false, false])
    }

    @Test("the first caller message decides the batch: every waiting message with the same ceiling comes with it, in FIFO order, with all the mail")
    func takeSubmissionBatchTakesEveryMessageThatCanShareTheSubmission() async {
        let outbox = SessionOutbox()
        await outbox.post(event: Self.event(correlationID: "c1", kind: .progress, detail: "10%"))
        await outbox.add(message: Self.message("a"))
        await outbox.add(message: Self.message("b", requestedMaxTokens: 64))
        await outbox.add(message: Self.message("c"))

        let taken = await outbox.takeSubmissionBatch(deliveringRunsOf: [])
        #expect(taken?.messages.map(\.text) == ["a", "c"])
        #expect(taken?.events.count == 1)

        // The message with its own ceiling waits for a submission of its own.
        let next = await outbox.takeSubmissionBatch(deliveringRunsOf: [])
        #expect(next?.messages.map(\.text) == ["b"])
        #expect(await outbox.waitingMessageCount == 0)
    }

    @Test("a stream message goes alone in its submission, and a reply message never joins it")
    func aStreamMessageGoesAlone() async {
        let outbox = SessionOutbox()
        let (_, continuation) = AsyncThrowingStream<String, any Error>.makeStream()
        await outbox.add(message: Self.message("stream", reader: .textStream(continuation)))
        await outbox.add(message: Self.message("reply"))

        let taken = await outbox.takeSubmissionBatch(deliveringRunsOf: [])
        #expect(taken?.messages.map(\.text) == ["stream"])
        let joining = await outbox.takeJoiningBatch(
            options: SubmissionOptions(isStream: true, requestedMaxTokens: nil))
        #expect(joining.messages.isEmpty)
        #expect(await outbox.waitingMessageCount == 1)
        continuation.finish()
    }

    @Test("withdrawMessages empties the caller messages and leaves the mail pending")
    func withdrawMessagesKeepsTheMail() async {
        let outbox = SessionOutbox()
        await outbox.post(event: Self.event(correlationID: "c1", kind: .completed, detail: "done"))
        await outbox.add(message: Self.message("a"))
        await outbox.add(message: Self.message("b"))

        let withdrawn = await outbox.withdrawMessages()
        #expect(withdrawn.map(\.text) == ["a", "b"])
        #expect(await outbox.waitingMessageCount == 0)
        #expect(await outbox.pending().events.count == 1)
    }

    @Test("a take is race-free with a concurrent post: every event lands in exactly one take")
    func takeIsRaceFreeWithConcurrentPost() async {
        let outbox = SessionOutbox()
        let totalEvents = 200

        await withTaskGroup(of: Void.self) { group in
            for i in 0..<totalEvents {
                group.addTask {
                    await outbox.post(event: Self.event(correlationID: "c\(i)", kind: .completed, detail: "e\(i)"))
                }
            }
        }

        // Take repeatedly (simulating repeated submission boundaries) until
        // nothing new is pending; every event must show up in exactly one
        // take, with no duplication and no loss.
        //
        // The iteration cap is what keeps a broken take from hanging the whole
        // `swift test` run — this target sets no `.timeLimit` trait. Every take
        // that does not end the loop takes at least one event, so `totalEvents`
        // takes empty the outbox and one further take sees nothing; a take
        // that never empties would otherwise spin here forever.
        let takeLimit = totalEvents + 1
        let settledRunTokens = Set((0..<totalEvents).map { "c\($0)" })
        var seen: Set<String> = []
        var emptied = false
        for _ in 0..<takeLimit {
            guard let taken = await outbox.takeSubmissionBatch(deliveringRunsOf: settledRunTokens) else {
                emptied = true
                break
            }
            for pendingEvent in taken.events {
                #expect(!seen.contains(pendingEvent.event.detail), "duplicate take of \(pendingEvent.event.detail)")
                seen.insert(pendingEvent.event.detail)
            }
        }
        #expect(emptied, "takeSubmissionBatch never emptied the outbox in \(takeLimit) takes")
        #expect(seen.count == totalEvents)

        let finalPending = await outbox.pending()
        #expect(finalPending.events.isEmpty)
    }

    // MARK: - nextEvent(): driver wakeup

    /// One `SessionOutbox.nextEvent()` wait, started so a test observes
    /// whether it woke instead of awaiting it.
    ///
    /// The indirection is the point: `nextEvent()` suspends on a
    /// `CheckedContinuation<Void, Never>` that only a later
    /// `SessionOutbox.post(event:)` or `SessionOutbox.enqueue(prompt:)` resumes,
    /// and nothing can break such a wait — cancelling it does not resume it. This
    /// target sets no `.timeLimit` trait, so a regression anywhere on the wakeup
    /// route would hang the whole `swift test` run rather than fail the test that
    /// caught it. ``wokeUp()`` reports through a signal ``BoundedWait`` observes
    /// under a bound, and never awaits the wait on its give-up path.
    private struct OutboxWaiter {
        /// What this wait expects to be woken by, named in the recorded issue
        /// when no wakeup arrives.
        private let label: String

        /// Signalled by ``task`` once `nextEvent()` has returned — how "woken"
        /// is observed without awaiting the wait itself.
        private let woke: AsyncSemaphore

        /// The suspended wait.
        private let task: Task<Void, Never>

        /// Starts one `SessionOutbox.nextEvent()` wait on `outbox`.
        ///
        /// - Parameters:
        ///   - outbox: The outbox to wait on.
        ///   - label: What the wait expects to be woken by — "a post", say.
        init(on outbox: SessionOutbox, waitingFor label: String) {
            let woke = AsyncSemaphore(value: 0)
            self.label = label
            self.woke = woke
            self.task = Task {
                await outbox.nextEvent()
                woke.signal()
            }
        }

        /// Whether the wait is still suspended, read without awaiting it.
        var isStillSuspended: Bool { woke.availablePermits == 0 }

        /// Whether the wait woke inside ``BoundedWait``'s bound, recording an
        /// issue and giving up when it did not.
        ///
        /// - Returns: Whether `nextEvent()` returned.
        func wokeUp() async -> Bool {
            guard await BoundedWait.signalArrived(woke, named: "the nextEvent() wait for \(label)") else {
                // Cancelling cannot resume a wait suspended in
                // `withCheckedContinuation`, but the test must not await that
                // wait either.
                task.cancel()
                return false
            }
            await task.value
            return true
        }
    }

    /// How long a test lets a fresh ``OutboxWaiter`` reach its suspension point
    /// before it posts, so the post lands on a genuinely suspended wait rather than
    /// on an outbox the wait has not looked at yet.
    private static let waiterSuspensionNanoseconds: UInt64 = 20_000_000

    @Test("nextEvent() suspends while the outbox is empty and resumes on the next post")
    func nextEventSuspendsUntilPost() async {
        let outbox = SessionOutbox()
        let waiter = OutboxWaiter(on: outbox, waitingFor: "a post")

        // Give the waiter a chance to actually start suspending before posting.
        try? await Task.sleep(nanoseconds: Self.waiterSuspensionNanoseconds)
        #expect(waiter.isStillSuspended)

        await outbox.post(event: Self.event(correlationID: "c1", kind: .completed, detail: "woke"))

        // The waiter must complete promptly once posted.
        #expect(await waiter.wokeUp())
    }

    @Test("nextEvent() returns immediately when the outbox is already non-empty")
    func nextEventReturnsImmediatelyWhenNonEmpty() async {
        let outbox = SessionOutbox()
        await outbox.post(event: Self.event(correlationID: "c1", kind: .completed, detail: "already here"))

        // Must not hang: the outbox is already non-empty.
        let waiter = OutboxWaiter(on: outbox, waitingFor: "an outbox that is already non-empty")
        #expect(await waiter.wokeUp())
    }

    @Test("nextEvent() also resumes on an enqueued prompt")
    func nextEventResumesOnEnqueuedPrompt() async {
        let outbox = SessionOutbox()
        let waiter = OutboxWaiter(on: outbox, waitingFor: "an enqueued prompt")

        try? await Task.sleep(nanoseconds: Self.waiterSuspensionNanoseconds)
        #expect(waiter.isStillSuspended)

        _ = await outbox.enqueue(prompt: Self.prompt("hello"))

        #expect(await waiter.wokeUp())
    }

    // MARK: - post(report:): forwarded to the observer, never staged, never journaled

    /// Keeps every ``ToolCallReport`` the outbox forwards to it, so a test can
    /// compare what arrived with what was posted.
    private actor ReportRecordingObserver: ToolInvocationObserver {
        /// Every forwarded report, in delivery order.
        private(set) var reports: [ToolCallReport] = []

        func deliver(invocation record: ToolInvocationRecord) {}

        func deliver(report: ToolCallReport) {
            reports.append(report)
        }
    }

    /// Keeps every ``OperationEvent`` the outbox records into it, so a test
    /// can prove which posts entered the journal chain.
    private actor RecordingJournal: OperationEventJournal {
        /// Every recorded event, in record order.
        private(set) var recorded: [OperationEvent] = []

        func record(event: OperationEvent) {
            recorded.append(event)
        }
    }

    /// Builds a canned ``ToolCallReport`` for one call, so a test can focus on
    /// the outbox's forwarding rather than on report field boilerplate.
    private static func report() -> ToolCallReport {
        ToolCallReport(
            tool: "shell", op: "run command", correlationID: "1", sessionID: .generate(),
            attachments: [MountFixtures.firstAttachment])
    }

    @Test("post(report:) hands the same report to the attached observer")
    func postReportReachesTheObserver() async {
        let outbox = SessionOutbox()
        let observer = ReportRecordingObserver()
        await outbox.attach(invocationObserver: observer)
        let report = Self.report()

        await outbox.post(report: report)

        #expect(await observer.reports == [report])
    }

    @Test("post(report:) stages nothing and writes nothing to the journal")
    func postReportStagesNothingAndJournalsNothing() async {
        let outbox = SessionOutbox()
        let observer = ReportRecordingObserver()
        let journal = RecordingJournal()
        await outbox.attach(invocationObserver: observer)
        await outbox.attach(journal: journal)

        await outbox.post(report: Self.report())
        // The positive control: a plain event posted after the report does
        // reach the journal, so an empty journal is not a stalled chain.
        await outbox.post(event: Self.event(correlationID: "c1", kind: .completed, detail: "control"))

        let pending = await outbox.pending()
        #expect(pending.events.map(\.event.detail) == ["control"])
        #expect(await journal.recorded.map(\.detail) == ["control"])
    }

    @Test("post(report:) with no observer attached drops the report and stages nothing")
    func postReportWithNoObserverIsDropped() async {
        let outbox = SessionOutbox()

        await outbox.post(report: Self.report())

        let pending = await outbox.pending()
        #expect(pending.events.isEmpty)
    }

    // MARK: - Helpers

    private static func prompt(_ text: String) -> Transcript.Prompt {
        Transcript.Prompt(segments: [.text(Transcript.TextSegment(content: text))])
    }

    private static func text(of prompt: Transcript.Prompt) -> String {
        for segment in prompt.segments {
            if case .text(let textSegment) = segment {
                return textSegment.content
            }
        }
        return ""
    }
}
