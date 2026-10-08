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

    @Test("a plan progress and a text progress of one (tool, correlationID) do not replace each other (task ^mq1js23)")
    func planAndTextProgressPendSeparately() async {
        let outbox = SessionOutbox()
        let text = PlanFixtures.textProgress("shell output")
        let plan = PlanFixtures.planProgress()
        await outbox.post(event: text)
        await outbox.post(event: plan)

        #expect(await outbox.pending().events.map(\.event) == [text, plan])
    }

    @Test("a plan progress replaces only the older plan progress of the same plan id, and a text progress only the older text progress")
    func planReplacesPlanAndTextReplacesText() async {
        let outbox = SessionOutbox()
        await outbox.post(event: PlanFixtures.textProgress("first output"))
        await outbox.post(event: PlanFixtures.planProgress(PlanFixtures.plan(firstStatus: .inProgress)))
        let newerText = PlanFixtures.textProgress("second output")
        let newerPlan = PlanFixtures.planProgress(PlanFixtures.plan(firstStatus: .completed))
        await outbox.post(event: newerText)
        await outbox.post(event: newerPlan)

        #expect(await outbox.pending().events.map(\.event) == [newerText, newerPlan])
    }

    @Test("two plans of different ids posted before one submission both reach that submission")
    func plansOfDifferentIdsPendSeparately() async {
        let outbox = SessionOutbox()
        let firstPlan = PlanFixtures.planProgress()
        let secondPlan = PlanFixtures.planProgress(PlanFixtures.plan(id: PlanFixtures.secondPlanID))
        await outbox.post(event: firstPlan)
        await outbox.post(event: secondPlan)

        #expect(await outbox.takeEvents().map(\.event) == [firstPlan, secondPlan])
    }

    @Test("a plan replaces the pending plan that has the same id, and keeps the pending plan of a different id")
    func planReplacesOnlyThePlanOfTheSameId() async {
        let outbox = SessionOutbox()
        await outbox.post(event: PlanFixtures.planProgress(PlanFixtures.plan(firstStatus: .inProgress)))
        let otherPlan = PlanFixtures.planProgress(PlanFixtures.plan(id: PlanFixtures.secondPlanID))
        await outbox.post(event: otherPlan)
        let newerPlan = PlanFixtures.planProgress(PlanFixtures.plan(firstStatus: .completed))
        await outbox.post(event: newerPlan)

        #expect(await outbox.takeEvents().map(\.event) == [newerPlan, otherPlan])
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

        let taken = await outbox.takeEvents()
        #expect(taken.map(\.event.detail) == ["first question", "second question"])
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
        _ = outbox.messages.post(Self.message("first"))
        _ = outbox.messages.post(Self.message("second"))
        _ = outbox.messages.post(Self.message("third"))

        let pending = await outbox.pending()
        #expect(pending.messages.count == 3)
        #expect(pending.messages.map { Self.text(of: $0.message.prompt) } == ["first", "second", "third"])
    }

    @Test("each caller message keeps its own distinct, stable id in the outbox")
    func callerMessagesKeepDistinctIds() async {
        let outbox = SessionOutbox()
        let first = outbox.messages.post(Self.message("first")).id
        let second = outbox.messages.post(Self.message("second")).id
        #expect(first != second)

        let pending = await outbox.pending()
        #expect(pending.messages.map(\.id) == [first, second])
    }

    // MARK: - The take of the pump: commits and empties exactly what it returns

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
            prompt: .plainText(text), requestedMaxTokens: requestedMaxTokens, reader: reader, serviceContext: nil)
    }

    /// What one take of the pump gave: the mail events and the caller
    /// messages of one submission.
    private struct TakenBatch {
        /// The mail events that the take committed.
        let events: [SessionOutbox.PendingEvent]

        /// The caller messages of the batch, in FIFO order. Empty for a take
        /// of mail only.
        let messages: [SessionMessage]
    }

    /// Takes the next submission from `outbox` as the pump does.
    ///
    /// When a caller message waits, the mailbox runs the next batch: the
    /// first waiting message, and each later message that can share its
    /// submission. The body of the batch takes every pending mail event, as
    /// the pump does, and gives an empty answer to the messages. When no
    /// caller message waits, only mail can start a submission: the take
    /// commits all pending events when the terminal of a settled run is
    /// among them.
    ///
    /// - Parameters:
    ///   - outbox: The outbox to take from.
    ///   - settledRunTokens: The tokens of the settled background runs.
    /// - Returns: What the take committed, or `nil` when nothing can start a
    ///   submission. Then nothing was taken.
    private static func takeBatch(
        from outbox: SessionOutbox, deliveringRunsOf settledRunTokens: Set<String>
    ) async -> TakenBatch? {
        guard outbox.messages.pending.isEmpty else {
            var taken: TakenBatch?
            await outbox.messages.answerNextBatch(joining: SessionMessage.sharesSubmission(_:with:)) { letters in
                taken = TakenBatch(events: await outbox.takeEvents(), messages: letters.map(\.message))
                return ""
            }
            return taken
        }
        let runTokens = BackgroundRunTokens(settled: settledRunTokens)
        guard let events = await outbox.takeMailStartingASubmission(deliveringRunsOf: runTokens) else {
            return nil
        }
        return TakenBatch(events: events, messages: [])
    }

    @Test("the take of the pump commits and empties every pending event when a settled run's terminal can start a submission")
    func takeOfThePumpEmptiesEvents() async {
        let outbox = SessionOutbox()
        await outbox.post(event: Self.event(correlationID: "c1", kind: .completed, detail: "one"))
        await outbox.post(event: Self.event(correlationID: "c2", kind: .completed, detail: "two"))

        let taken = await Self.takeBatch(from: outbox, deliveringRunsOf: ["c1"])
        #expect(taken?.events.map(\.event.detail) == ["one", "two"])
        #expect(taken?.messages.isEmpty == true)

        // Committed items are gone.
        let pending = await outbox.pending()
        #expect(pending.events.isEmpty)
    }

    @Test("replace changes the prompt of a waiting caller message in place: it keeps its id and its place")
    func replaceChangesAWaitingMessageInPlace() async {
        let outbox = SessionOutbox()
        let first = outbox.messages.post(Self.message("first")).id
        let second = outbox.messages.post(Self.message("second")).id

        #expect(outbox.replace(id: first, prompt: Self.prompt("edited")) == .applied)

        let pending = await outbox.pending()
        #expect(pending.messages.map(\.id) == [first, second])
        #expect(pending.messages.map(\.message.text) == ["edited", "second"])
    }

    @Test("replace of an id that names no waiting message changes nothing, and leaves the mail pending")
    func replaceOfAnUnknownIdChangesNothing() async {
        let outbox = SessionOutbox()
        await outbox.post(event: Self.event(correlationID: "c1", kind: .completed, detail: "one"))

        #expect(outbox.replace(id: MessageID.unposted(), prompt: Self.prompt("lost")) == .alreadySent)
        #expect(await outbox.pending().events.count == 1)
        #expect(await outbox.pending().messages.isEmpty)
    }

    @Test("a second take of the pump with nothing new pending takes nothing")
    func secondTakeWithNothingNewTakesNothing() async {
        let outbox = SessionOutbox()
        await outbox.post(event: Self.event(correlationID: "c1", kind: .completed, detail: "one"))
        _ = await Self.takeBatch(from: outbox, deliveringRunsOf: ["c1"])

        #expect(await Self.takeBatch(from: outbox, deliveringRunsOf: ["c1"]) == nil)
    }

    @Test("progress mail, the terminal of a run that is no settled background run, and held mail start no submission and stay pending")
    func mailThatCannotStartASubmissionStaysPending() async {
        let outbox = SessionOutbox()
        await outbox.post(event: Self.event(correlationID: "c1", kind: .progress, detail: "10%"))
        #expect(await Self.takeBatch(from: outbox, deliveringRunsOf: ["c1"]) == nil)

        await outbox.post(event: Self.event(correlationID: "c2", kind: .completed, detail: "in-band run failed"))
        #expect(await Self.takeBatch(from: outbox, deliveringRunsOf: ["c1"]) == nil)
        #expect(await Self.takeBatch(from: outbox, deliveringRunsOf: []) == nil)
        #expect(await outbox.pending().events.count == 2)
    }

    // MARK: - Which mail can start a submission

    /// The token of a background run that is open in ``runTokens``.
    private static let openToken = "open-run"

    /// The token of a background run that settled in ``runTokens``.
    private static let settledToken = "settled-run"

    /// The token of a run that is no background run, such as an in-band run.
    private static let unknownToken = "in-band-run"

    /// The run tokens of the tests below: one open run and one settled run.
    private static let runTokens = BackgroundRunTokens(open: [openToken], settled: [settledToken])

    /// Whether one mail event of `kind` on `token` starts a submission with
    /// no caller message, with ``runTokens``.
    ///
    /// - Parameters:
    ///   - kind: The kind of the event.
    ///   - token: The completion token of the event.
    ///   - held: Whether the event is held.
    /// - Returns: The result of ``SessionOutbox/canStartASubmission(_:runTokens:)``.
    private static func canStart(_ kind: OperationEventKind, on token: String, held: Bool = false) async -> Bool {
        let outbox = SessionOutbox()
        let event = Self.event(correlationID: token, kind: kind)
        if held {
            await outbox.requeue(event: event)
        } else {
            await outbox.post(event: event)
        }
        return SessionOutbox.canStartASubmission(await outbox.pending().events, runTokens: runTokens)
    }

    @Test("a run message of an open background run starts a submission")
    func aMessageOfAnOpenRunStartsASubmission() async {
        #expect(await Self.canStart(.message, on: Self.openToken))
    }

    @Test("a run message of a settled background run starts a submission")
    func aMessageOfASettledRunStartsASubmission() async {
        #expect(await Self.canStart(.message, on: Self.settledToken))
    }

    @Test("a run message of a run that is no background run starts no submission")
    func aMessageOfAnUnknownRunStartsNoSubmission() async {
        #expect(await Self.canStart(.message, on: Self.unknownToken) == false)
    }

    @Test("a held run message starts no submission")
    func aHeldMessageStartsNoSubmission() async {
        #expect(await Self.canStart(.message, on: Self.openToken, held: true) == false)
    }

    @Test("the terminal of a background run that is still open starts no submission")
    func aTerminalOfAnOpenRunStartsNoSubmission() async {
        #expect(await Self.canStart(.completed, on: Self.openToken) == false)
    }

    @Test("the terminal of a settled background run starts a submission")
    func aTerminalOfASettledRunStartsASubmission() async {
        #expect(await Self.canStart(.completed, on: Self.settledToken))
    }

    @Test("progress and elicitation mail of a background run start no submission")
    func progressAndElicitationStartNoSubmission() async {
        #expect(await Self.canStart(.progress, on: Self.openToken) == false)
        #expect(await Self.canStart(.elicitation, on: Self.settledToken) == false)
    }

    @Test("two run messages of one run both stay pending, in post order")
    func runMessagesNeverCoalesce() async {
        let outbox = SessionOutbox()
        await outbox.post(event: Self.event(correlationID: "c1", kind: .message, detail: "first"))
        await outbox.post(event: Self.event(correlationID: "c1", kind: .message, detail: "second"))

        #expect(await outbox.pending().events.map(\.event.detail) == ["first", "second"])
    }

    @Test("a held terminal — given back by a failed submission, or held by a cancel — starts no submission by itself, and rides the next caller message")
    func aHeldTerminalStartsNoSubmission() async {
        let outbox = SessionOutbox()
        let givenBack = Self.event(correlationID: "c1", kind: .completed, detail: "given back")
        await outbox.requeue(event: givenBack)
        #expect(await Self.takeBatch(from: outbox, deliveringRunsOf: ["c1", "c2"]) == nil)

        _ = outbox.messages.post(Self.message("first"))
        let first = await Self.takeBatch(from: outbox, deliveringRunsOf: ["c1", "c2"])
        #expect(first?.messages.map(\.text) == ["first"])
        #expect(first?.events.map(\.event) == [givenBack])

        let held = Self.event(correlationID: "c2", kind: .completed, detail: "held by a cancel")
        await outbox.post(event: held)
        await outbox.holdPendingMail()
        #expect(await Self.takeBatch(from: outbox, deliveringRunsOf: ["c1", "c2"]) == nil)

        _ = outbox.messages.post(Self.message("next"))
        let taken = await Self.takeBatch(from: outbox, deliveringRunsOf: [])
        #expect(taken?.messages.map(\.text) == ["next"])
        #expect(taken?.events.map(\.event) == [held])
    }

    @Test("putBack returns untouched events in front of newer ones, each with its own id and hold")
    func putBackKeepsOrderIdsAndHolds() async {
        let outbox = SessionOutbox()
        await outbox.requeue(event: Self.event(correlationID: "c1", kind: .completed, detail: "held"))
        await outbox.post(event: Self.event(correlationID: "c2", kind: .progress, detail: "10%"))
        let taken = await outbox.takeEvents()
        await outbox.post(event: Self.event(correlationID: "c3", kind: .completed, detail: "newer"))

        await outbox.putBack(untouched: taken)

        let pending = await outbox.pending().events
        #expect(pending.map(\.event.detail) == ["held", "10%", "newer"])
        #expect(pending.prefix(taken.count).map(\.id) == taken.map(\.id))
        #expect(pending.map(\.isHeld) == [true, false, false])
    }

    @Test("the first caller message decides the batch: every waiting message with the same ceiling comes with it, in FIFO order, with all the mail")
    func takeOfThePumpTakesEveryMessageThatCanShareTheSubmission() async {
        let outbox = SessionOutbox()
        await outbox.post(event: Self.event(correlationID: "c1", kind: .progress, detail: "10%"))
        _ = outbox.messages.post(Self.message("a"))
        _ = outbox.messages.post(Self.message("b", requestedMaxTokens: 64))
        _ = outbox.messages.post(Self.message("c"))

        let taken = await Self.takeBatch(from: outbox, deliveringRunsOf: [])
        #expect(taken?.messages.map(\.text) == ["a", "c"])
        #expect(taken?.events.count == 1)

        // The message with its own ceiling waits for a submission of its own.
        let next = await Self.takeBatch(from: outbox, deliveringRunsOf: [])
        #expect(next?.messages.map(\.text) == ["b"])
        #expect(outbox.messages.depth.waiting == 0)
    }

    @Test("a stream message goes alone in its submission, and a reply message never joins it")
    func aStreamMessageGoesAlone() async {
        let outbox = SessionOutbox()
        let (_, continuation) = AsyncThrowingStream<String, any Error>.makeStream()
        _ = outbox.messages.post(Self.message("stream", reader: .textStream(continuation)))
        _ = outbox.messages.post(Self.message("reply"))

        // The take of the stream batch and the join attempt occur while the
        // stream batch runs, because a join is possible only in that time.
        var taken: [SessionMessage]?
        var joining: [SessionLetter] = []
        var waitingWhileTheStreamRuns: Int?
        await outbox.messages.answerNextBatch(joining: SessionMessage.sharesSubmission(_:with:)) { letters in
            taken = letters.map(\.message)
            joining = outbox.messages.takeJoining(
                admitting: SubmissionOptions(isStream: true, requestedMaxTokens: nil).admits)
            waitingWhileTheStreamRuns = outbox.messages.depth.waiting
            return ""
        }
        #expect(taken?.map(\.text) == ["stream"])
        #expect(joining.isEmpty)
        #expect(waitingWhileTheStreamRuns == 1)
        continuation.finish()
    }

    @Test("withdrawMessages empties the caller messages and leaves the mail pending")
    func withdrawMessagesKeepsTheMail() async {
        let outbox = SessionOutbox()
        await outbox.post(event: Self.event(correlationID: "c1", kind: .completed, detail: "done"))
        _ = outbox.messages.post(Self.message("a"))
        _ = outbox.messages.post(Self.message("b"))

        let withdrawn = outbox.withdrawMessages()
        #expect(withdrawn.map(\.text) == ["a", "b"])
        #expect(outbox.messages.depth.waiting == 0)
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
            guard let taken = await Self.takeBatch(from: outbox, deliveringRunsOf: settledRunTokens) else {
                emptied = true
                break
            }
            for pendingEvent in taken.events {
                #expect(!seen.contains(pendingEvent.event.detail), "duplicate take of \(pendingEvent.event.detail)")
                seen.insert(pendingEvent.event.detail)
            }
        }
        #expect(emptied, "the take of the pump never emptied the outbox in \(takeLimit) takes")
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

    @Test("a posted run message tells the attached mail observer")
    func postedRunMessageTellsTheMailObserver() async {
        let outbox = SessionOutbox()
        let counter = MailArrivalCounter()
        await outbox.attach(mailObserver: counter)

        await outbox.post(event: Self.event(correlationID: "c1", kind: .message, detail: "halfway"))

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

        _ = outbox.messages.post(Self.message("hello"))

        #expect(await counter.arrivals == 0)
        #expect(await outbox.pending().messages.map(\.message.text) == ["hello"])
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
