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

    // MARK: - Caller messages: never coalesced, FIFO

    @Test("caller messages never coalesce and keep the order they arrived in")
    func callerMessagesKeepTheirOrderAndNeverCoalesce() async {
        let outbox = SessionOutbox()
        await outbox.add(message: Self.message("first"))
        await outbox.add(message: Self.message("second"))
        await outbox.add(message: Self.message("third"))

        let pending = await outbox.pending()
        #expect(pending.messages.count == 3)
        #expect(pending.messages.map { Self.text(of: $0.prompt) } == ["first", "second", "third"])
    }

    @Test("each caller message keeps its own distinct, stable id in the outbox")
    func callerMessagesKeepDistinctIds() async {
        let outbox = SessionOutbox()
        let first = Self.message("first")
        let second = Self.message("second")
        #expect(first.id != second.id)
        await outbox.add(message: first)
        await outbox.add(message: second)

        let pending = await outbox.pending()
        #expect(pending.messages.map(\.id) == [first.id, second.id])
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
            id: MessageID(), prompt: .plainText(text), requestedMaxTokens: requestedMaxTokens, reader: reader,
            serviceContext: nil, answer: PumpAnswer())
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

    @Test("replace changes the prompt of a waiting caller message in place: it keeps its id and its place")
    func replaceChangesAWaitingMessageInPlace() async {
        let outbox = SessionOutbox()
        let first = Self.message("first")
        let second = Self.message("second")
        await outbox.add(message: first)
        await outbox.add(message: second)

        #expect(await outbox.replace(id: first.id, prompt: Self.prompt("edited")) == .applied)

        let pending = await outbox.pending()
        #expect(pending.messages.map(\.id) == [first.id, second.id])
        #expect(pending.messages.map(\.text) == ["edited", "second"])
    }

    @Test("replace of an id that names no waiting message changes nothing, and leaves the mail pending")
    func replaceOfAnUnknownIdChangesNothing() async {
        let outbox = SessionOutbox()
        await outbox.post(event: Self.event(correlationID: "c1", kind: .completed, detail: "one"))

        #expect(await outbox.replace(id: MessageID(), prompt: Self.prompt("lost")) == .alreadySent)
        #expect(await outbox.pending().events.count == 1)
        #expect(await outbox.pending().messages.isEmpty)
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

    @Test("a held terminal — given back by a failed submission, or held by a cancel — starts no submission by itself, and rides the next caller message")
    func aHeldTerminalStartsNoSubmission() async {
        let outbox = SessionOutbox()
        let givenBack = Self.event(correlationID: "c1", kind: .completed, detail: "given back")
        await outbox.requeue(event: givenBack)
        #expect(await outbox.takeSubmissionBatch(deliveringRunsOf: ["c1", "c2"]) == nil)

        await outbox.add(message: Self.message("first"))
        let first = await outbox.takeSubmissionBatch(deliveringRunsOf: ["c1", "c2"])
        #expect(first?.messages.map(\.text) == ["first"])
        #expect(first?.events.map(\.event) == [givenBack])

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

    // MARK: - Mail observer: a run terminal wakes the session pump

    /// Counts each ``SessionMailObserver/mailArrived()`` call, so a test can
    /// see which outbox writes wake the session pump.
    private actor MailArrivalCounter: SessionMailObserver {
        /// The number of `mailArrived()` calls.
        private(set) var arrivals = 0

        func mailArrived() {
            arrivals += 1
        }
    }

    // These tests restate the old `nextEvent()` wakeup tests. The outbox has
    // no driver wait now. A posted run terminal tells the attached observer,
    // and the session wakes its own pump for a caller message.

    @Test("a posted run terminal tells the attached mail observer")
    func postedTerminalTellsTheMailObserver() async {
        let outbox = SessionOutbox()
        let counter = MailArrivalCounter()
        await outbox.attach(mailObserver: counter)

        await outbox.post(event: Self.event(correlationID: "c1", kind: .completed, detail: "woke"))

        #expect(await counter.arrivals == 1)
    }

    @Test("a progress or elicitation post does not tell the mail observer")
    func nonTerminalPostDoesNotTellTheMailObserver() async {
        let outbox = SessionOutbox()
        let counter = MailArrivalCounter()
        await outbox.attach(mailObserver: counter)

        await outbox.post(event: Self.event(correlationID: "c1", kind: .progress, detail: "50%"))
        await outbox.post(event: Self.event(correlationID: "c2", kind: .elicitation, detail: "which one?"))
        // The positive control: a terminal after them does tell the observer.
        await outbox.post(event: Self.event(correlationID: "c1", kind: .completed, detail: "done"))

        #expect(await counter.arrivals == 1)
    }

    @Test("a caller message does not tell the mail observer — the session wakes its own pump")
    func callerMessageDoesNotTellTheMailObserver() async {
        let outbox = SessionOutbox()
        let counter = MailArrivalCounter()
        await outbox.attach(mailObserver: counter)

        await outbox.add(message: Self.message("hello"))

        #expect(await counter.arrivals == 0)
        #expect(await outbox.pending().messages.map(\.text) == ["hello"])
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
