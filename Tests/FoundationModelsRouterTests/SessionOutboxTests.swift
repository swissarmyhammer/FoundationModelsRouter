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

        #expect(Self.takeRunEvents(from: outbox) == [firstPlan, secondPlan])
    }

    @Test("a plan replaces the pending plan that has the same id, and keeps the pending plan of a different id")
    func planReplacesOnlyThePlanOfTheSameId() async {
        let outbox = SessionOutbox()
        await outbox.post(event: PlanFixtures.planProgress(PlanFixtures.plan(firstStatus: .inProgress)))
        let otherPlan = PlanFixtures.planProgress(PlanFixtures.plan(id: PlanFixtures.secondPlanID))
        await outbox.post(event: otherPlan)
        let newerPlan = PlanFixtures.planProgress(PlanFixtures.plan(firstStatus: .completed))
        await outbox.post(event: newerPlan)

        #expect(Self.takeRunEvents(from: outbox) == [newerPlan, otherPlan])
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

        let taken = Self.takeRunEvents(from: outbox)
        #expect(taken.map(\.detail) == ["first question", "second question"])
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

    // MARK: - User-type mail: never coalesced, FIFO

    @Test("user messages in the queue never coalesce and keep the order they arrived in")
    func userMailKeepsItsOrderAndNeverCoalesces() async throws {
        let outbox = SessionOutbox()
        try outbox.queue.put(Self.userMail("first"))
        try outbox.queue.put(Self.userMail("second"))
        try outbox.queue.put(Self.userMail("third"))

        #expect(outbox.queue.pending.compactMap(\.promptText) == ["first", "second", "third"])
        // User-type mail is no run mail, so the snapshot of the run mail is empty.
        #expect(await outbox.pending().events.isEmpty)
    }

    @Test("each user message keeps its own distinct, stable id in the queue")
    func userMailKeepsDistinctIds() throws {
        let outbox = SessionOutbox()
        let first = Self.userMail("first")
        let second = Self.userMail("second")
        try outbox.queue.put(first)
        try outbox.queue.put(second)
        #expect(first.id != second.id)

        #expect(outbox.queue.pending.map(\.id) == [first.id, second.id])
    }

    // MARK: - The take of the pump: commits and empties exactly what it returns

    /// What one take of the pump gave: the run mail and the user-type mail of
    /// one batch.
    private struct TakenBatch {
        /// The run mail that the take committed, with the hold that each one
        /// had before the take.
        let events: [SessionOutbox.PendingEvent]

        /// The user-type mail of the batch, in queue order. Empty for a batch
        /// of run mail only.
        let userMail: [Mail]

        /// The prompt text of each user-type mail of the batch, in queue order.
        var texts: [String] {
            userMail.compactMap(\.promptText)
        }
    }

    /// Takes the next batch from `outbox` as the pump does
    /// (`RoutedSessionActor.takeNextBatch(runTokens:)`).
    ///
    /// When user-type mail waits, or when the run mail can start a submission,
    /// the take uses the batch rule of the pump
    /// (``RoutedSessionActor/joinsNewBatch(_:_:isGuided:)``): the first
    /// user-type mail is the leader, each later user-type mail that its
    /// options admit comes with it, and all run mail rides the batch. The take
    /// then forgets the hold of each taken mail, as the delivery of the pump
    /// does.
    ///
    /// - Parameters:
    ///   - outbox: The outbox to take from.
    ///   - settledRunTokens: The tokens of the settled background runs.
    ///   - isGuided: Whether the session has a grammar.
    /// - Returns: What the take committed, or `nil` when nothing can start a
    ///   submission. Then nothing was taken.
    private static func takeBatch(
        from outbox: SessionOutbox, deliveringRunsOf settledRunTokens: Set<String>, isGuided: Bool = false
    ) -> TakenBatch? {
        let runTokens = BackgroundRunTokens(settled: settledRunTokens)
        let held = outbox.heldMailIDs
        let pending = outbox.queue.pending
        let runMailCanStart = SessionOutbox.canStartASubmission(
            SessionOutbox.pendingEvents(of: pending, held: held), runTokens: runTokens)
        guard pending.contains(where: { !$0.isRunMail }) || runMailCanStart else { return nil }
        let mail = outbox.queue.take { RoutedSessionActor.joinsNewBatch($0, $1, isGuided: isGuided) }
        guard !mail.isEmpty else { return nil }
        outbox.forget(mail.map(\.id))
        return TakenBatch(
            events: SessionOutbox.pendingEvents(of: mail, held: held), userMail: mail.filter { !$0.isRunMail })
    }

    @Test("the take of the pump commits and empties every pending event when a settled run's terminal can start a submission")
    func takeOfThePumpEmptiesEvents() async {
        let outbox = SessionOutbox()
        await outbox.post(event: Self.event(correlationID: "c1", kind: .completed, detail: "one"))
        await outbox.post(event: Self.event(correlationID: "c2", kind: .completed, detail: "two"))

        let taken = Self.takeBatch(from: outbox, deliveringRunsOf: ["c1"])
        #expect(taken?.events.map(\.event.detail) == ["one", "two"])
        #expect(taken?.userMail.isEmpty == true)

        // Committed items are gone.
        let pending = await outbox.pending()
        #expect(pending.events.isEmpty)
    }

    @Test("replace changes the body of a waiting user message in place: it keeps its id and its place")
    func replaceChangesAWaitingMessageInPlace() throws {
        let outbox = SessionOutbox()
        let first = Self.userMail("first")
        let second = Self.userMail("second")
        try outbox.queue.put(first)
        try outbox.queue.put(second)

        #expect(outbox.queue.replace(first.id, with: Self.userMail("edited").body))

        #expect(outbox.queue.pending.map(\.id) == [first.id, second.id])
        #expect(outbox.queue.pending.compactMap(\.promptText) == ["edited", "second"])
    }

    @Test("replace of an id that names no waiting mail changes nothing, and leaves the run mail pending")
    func replaceOfAnUnknownIdChangesNothing() async {
        let outbox = SessionOutbox()
        await outbox.post(event: Self.event(correlationID: "c1", kind: .completed, detail: "one"))

        #expect(outbox.queue.replace(MailID(), with: Self.userMail("lost").body) == false)
        #expect(await outbox.pending().events.map(\.event.detail) == ["one"])
        let isAllRunMail = outbox.queue.pending.allSatisfy { $0.isRunMail }
        #expect(isAllRunMail)
    }

    @Test("a second take of the pump with nothing new pending takes nothing")
    func secondTakeWithNothingNewTakesNothing() async {
        let outbox = SessionOutbox()
        await outbox.post(event: Self.event(correlationID: "c1", kind: .completed, detail: "one"))
        _ = Self.takeBatch(from: outbox, deliveringRunsOf: ["c1"])

        #expect(Self.takeBatch(from: outbox, deliveringRunsOf: ["c1"]) == nil)
    }

    @Test("progress mail, the terminal of a run that is no settled background run, and held mail start no submission and stay pending")
    func mailThatCannotStartASubmissionStaysPending() async {
        let outbox = SessionOutbox()
        await outbox.post(event: Self.event(correlationID: "c1", kind: .progress, detail: "10%"))
        #expect(Self.takeBatch(from: outbox, deliveringRunsOf: ["c1"]) == nil)

        await outbox.post(event: Self.event(correlationID: "c2", kind: .completed, detail: "in-band run failed"))
        #expect(Self.takeBatch(from: outbox, deliveringRunsOf: ["c1"]) == nil)
        #expect(Self.takeBatch(from: outbox, deliveringRunsOf: []) == nil)
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

    /// Whether one run mail of `kind` on `token` starts a submission with
    /// no user-type mail, with ``runTokens``.
    ///
    /// - Parameters:
    ///   - kind: The kind of the event.
    ///   - token: The completion token of the event.
    ///   - held: Whether the mail is held.
    /// - Returns: The result of ``SessionOutbox/canStartASubmission(_:runTokens:)``.
    private static func canStart(_ kind: OperationEventKind, on token: String, held: Bool = false) async -> Bool {
        let outbox = SessionOutbox()
        let event = Self.event(correlationID: token, kind: kind)
        if held {
            #expect(outbox.requeue([Self.runMail(event)]).isEmpty)
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

    @Test("a held terminal — given back by a failed submission, or held by the bound on mail-only answers — starts no submission by itself, and rides the next user message")
    func aHeldTerminalStartsNoSubmission() async throws {
        let outbox = SessionOutbox()
        let givenBack = Self.event(correlationID: "c1", kind: .completed, detail: "given back")
        #expect(outbox.requeue([Self.runMail(givenBack)]).isEmpty)
        #expect(Self.takeBatch(from: outbox, deliveringRunsOf: ["c1", "c2"]) == nil)

        try outbox.queue.put(Self.userMail("first"))
        let first = Self.takeBatch(from: outbox, deliveringRunsOf: ["c1", "c2"])
        #expect(first?.texts == ["first"])
        #expect(first?.events.map(\.event) == [givenBack])
        #expect(first?.events.map(\.isHeld) == [true])

        let held = Self.event(correlationID: "c2", kind: .completed, detail: "held by the bound")
        await outbox.post(event: held)
        let taken = Self.takeRunMail(from: outbox)
        #expect(outbox.putBack(holding: taken).isEmpty)
        #expect(Self.takeBatch(from: outbox, deliveringRunsOf: ["c1", "c2"]) == nil)

        try outbox.queue.put(Self.userMail("next"))
        let next = Self.takeBatch(from: outbox, deliveringRunsOf: [])
        #expect(next?.texts == ["next"])
        #expect(next?.events.map(\.event) == [held])
        // The delivery forgets each hold, so the set does not grow.
        #expect(outbox.heldMailIDs.isEmpty)
    }

    @Test("putBack returns untouched mail in front of newer mail, each with its own id and hold")
    func putBackKeepsOrderIdsAndHolds() async {
        let outbox = SessionOutbox()
        #expect(outbox.requeue([Self.runMail(Self.event(correlationID: "c1", kind: .completed, detail: "held"))]).isEmpty)
        await outbox.post(event: Self.event(correlationID: "c2", kind: .progress, detail: "10%"))
        let taken = Self.takeRunMail(from: outbox)
        await outbox.post(event: Self.event(correlationID: "c3", kind: .completed, detail: "newer"))

        #expect(outbox.putBack(untouched: taken).isEmpty)

        let pending = await outbox.pending().events
        #expect(pending.map(\.event.detail) == ["held", "10%", "newer"])
        #expect(pending.prefix(taken.count).map(\.id) == taken.map(\.id))
        #expect(pending.map(\.isHeld) == [true, false, false])
    }

    @Test("requeue holds each mail and puts it in front of newer mail, with the same id")
    func requeueHoldsTheMailInFront() async {
        let outbox = SessionOutbox()
        await outbox.post(event: Self.event(correlationID: "c1", kind: .completed, detail: "given back"))
        let taken = Self.takeRunMail(from: outbox)
        await outbox.post(event: Self.event(correlationID: "c2", kind: .completed, detail: "newer"))

        #expect(outbox.requeue(taken).isEmpty)

        let pending = await outbox.pending().events
        #expect(pending.map(\.event.detail) == ["given back", "newer"])
        #expect(pending.first?.id == taken.first?.id)
        #expect(pending.map(\.isHeld) == [true, false])
        #expect(outbox.heldMailIDs == Set(taken.map(\.id)))
    }

    @Test("requeue and putBack into a closed queue give back all the mail, and keep no hold")
    func putBackIntoAClosedQueueRefusesTheMail() async {
        let outbox = SessionOutbox()
        await outbox.post(event: Self.event(correlationID: "c1", kind: .completed, detail: "one"))
        await outbox.post(event: Self.event(correlationID: "c2", kind: .completed, detail: "two"))
        let taken = Self.takeRunMail(from: outbox)
        _ = outbox.queue.close()

        #expect(outbox.requeue(taken).map(\.id) == taken.map(\.id))
        #expect(outbox.putBack(holding: taken).map(\.id) == taken.map(\.id))
        #expect(outbox.putBack(untouched: taken).map(\.id) == taken.map(\.id))
        #expect(outbox.heldMailIDs.isEmpty)
        #expect(outbox.queue.pending.isEmpty)
    }

    @Test("requeue and putBack write nothing to the journal: each event is in the journal once, in post order")
    func requeueWritesNoJournalEntry() async {
        let outbox = SessionOutbox()
        let journal = RecordingJournal()
        await outbox.attach(journal: journal)
        await outbox.post(event: Self.event(correlationID: "c1", kind: .completed, detail: "first"))
        await outbox.post(event: Self.event(correlationID: "c2", kind: .progress, detail: "second"))
        let taken = Self.takeRunMail(from: outbox)

        #expect(outbox.requeue(taken).isEmpty)
        let again = Self.takeRunMail(from: outbox)
        #expect(outbox.putBack(untouched: again).isEmpty)
        // The positive control: a new post after them does reach the journal.
        await outbox.post(event: Self.event(correlationID: "c3", kind: .completed, detail: "third"))

        #expect(await journal.recorded.map(\.detail) == ["first", "second", "third"])
    }

    @Test("the first user message decides the batch: every waiting message with the same ceiling comes with it, in FIFO order, with all the run mail")
    func takeOfThePumpTakesEveryMessageThatCanShareTheSubmission() async throws {
        let outbox = SessionOutbox()
        await outbox.post(event: Self.event(correlationID: "c1", kind: .progress, detail: "10%"))
        try outbox.queue.put(Self.userMail("a"))
        try outbox.queue.put(Self.userMail("b", maxTokens: 64))
        try outbox.queue.put(Self.userMail("c"))

        let taken = Self.takeBatch(from: outbox, deliveringRunsOf: [])
        #expect(taken?.texts == ["a", "c"])
        #expect(taken?.events.count == 1)

        // The message with its own ceiling waits for a submission of its own.
        let next = Self.takeBatch(from: outbox, deliveringRunsOf: [])
        #expect(next?.texts == ["b"])
        #expect(outbox.queue.pending.isEmpty)
    }

    @Test("a stream message goes alone in its submission, and a reply message never joins it")
    func aStreamMessageGoesAlone() throws {
        let outbox = SessionOutbox()
        try outbox.queue.put(Self.userMail("stream", mode: .stream))
        try outbox.queue.put(Self.userMail("reply"))

        let taken = Self.takeBatch(from: outbox, deliveringRunsOf: [])
        #expect(taken?.texts == ["stream"])

        // A join is possible only while the stream answer runs: the join rule
        // of that answer admits no user-type mail.
        let streamOptions = SubmissionOptions(isStream: true, requestedMaxTokens: nil)
        let joining = outbox.queue.take { candidate, _ in
            RoutedSessionActor.joinsRunningAnswer(candidate, options: streamOptions, isGuided: false)
        }
        #expect(joining.isEmpty)
        #expect(outbox.queue.pending.compactMap(\.promptText) == ["reply"])
    }

    @Test("in a guided session a stream message runs as a reply, so a reply message shares its batch")
    func aGuidedStreamMessageSharesItsBatch() throws {
        let outbox = SessionOutbox()
        try outbox.queue.put(Self.userMail("stream", mode: .stream))
        try outbox.queue.put(Self.userMail("reply"))

        let taken = Self.takeBatch(from: outbox, deliveringRunsOf: [], isGuided: true)
        #expect(taken?.texts == ["stream", "reply"])
        #expect(outbox.queue.pending.isEmpty)
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
        // `swift test` run. Every take
        // that does not end the loop takes at least one event, so `totalEvents`
        // takes empty the outbox and one further take sees nothing; a take
        // that never empties would otherwise spin here forever.
        let takeLimit = totalEvents + 1
        let settledRunTokens = Set((0..<totalEvents).map { "c\($0)" })
        var seen: Set<String> = []
        var emptied = false
        for _ in 0..<takeLimit {
            let next = Self.takeBatch(from: outbox, deliveringRunsOf: settledRunTokens)
            emptied = next == nil
            if emptied {
                break
            }
            for pendingEvent in next?.events ?? [] {
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
    /// see which outbox writes wake the session pump. It also keeps the ids of
    /// each ``SessionMailObserver/runMailWithdrawn(_:)`` call.
    private actor MailArrivalCounter: SessionMailObserver {
        /// The number of `mailArrived()` calls.
        private(set) var arrivals = 0

        /// The ids of the withdrawn mail, in the order the outbox told them.
        private(set) var withdrawn: [MailID] = []

        func mailArrived() {
            arrivals += 1
        }

        func runMailWithdrawn(_ ids: [MailID]) {
            withdrawn += ids
        }
    }

    // These tests restate the old `nextEvent()` wakeup tests. The outbox has
    // no driver wait now. A posted run terminal tells the attached observer,
    // and the session wakes its own pump for user-type mail.

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

    @Test("a user message does not tell the mail observer — the session wakes its own pump")
    func callerMessageDoesNotTellTheMailObserver() async throws {
        let outbox = SessionOutbox()
        let counter = MailArrivalCounter()
        await outbox.attach(mailObserver: counter)

        try outbox.queue.put(Self.userMail("hello"))

        #expect(await counter.arrivals == 0)
        #expect(outbox.queue.pending.compactMap(\.promptText) == ["hello"])
    }

    @Test("withdrawStagedEvents cancels only the queued run mail of its run, drops its holds, and tells the observer the ids in queue order")
    func withdrawStagedEventsCancelsTheMailOfItsRun() async throws {
        let outbox = SessionOutbox()
        let counter = MailArrivalCounter()
        await outbox.attach(mailObserver: counter)
        let heldTerminal = Self.runMail(Self.event(correlationID: "c1", kind: .completed, detail: "c1-done"))
        #expect(outbox.requeue([heldTerminal]).isEmpty)
        await outbox.post(event: Self.event(correlationID: "c2", kind: .completed, detail: "c2-done"))
        await outbox.post(event: Self.event(correlationID: "c1", kind: .progress, detail: "c1-progress"))
        try outbox.queue.put(Self.userMail("hello"))
        let c1Ids = outbox.queue.pending.filter { $0.runEvent?.correlationID == "c1" }.map(\.id)

        await outbox.withdrawStagedEvents(correlationID: "c1")

        #expect(await counter.withdrawn == c1Ids)
        #expect(await outbox.pending().events.map(\.event.detail) == ["c2-done"])
        #expect(outbox.queue.pending.compactMap(\.promptText) == ["hello"])
        #expect(outbox.heldMailIDs.isEmpty)
    }

    @Test("withdrawStagedEvents of a run with no queued mail tells the observer nothing")
    func withdrawStagedEventsOfNoMailTellsNothing() async {
        let outbox = SessionOutbox()
        let counter = MailArrivalCounter()
        await outbox.attach(mailObserver: counter)
        await outbox.post(event: Self.event(correlationID: "c2", kind: .progress, detail: "c2-progress"))

        await outbox.withdrawStagedEvents(correlationID: "c1")

        #expect(await counter.withdrawn.isEmpty)
        #expect(await outbox.pending().events.count == 1)
    }

    // MARK: - post(report:): forwarded to the observer, never staged, never journaled

    /// Keeps every ``ToolCallReport`` and every ``ToolDisplayEvent`` the
    /// outbox forwards to it, so a test can compare what arrived with what
    /// was posted.
    private actor DeliveryRecordingObserver: ToolInvocationObserver {
        /// Every forwarded report, in delivery order.
        private(set) var reports: [ToolCallReport] = []

        /// Every forwarded display event, in delivery order.
        private(set) var displays: [ToolDisplayEvent] = []

        func deliver(invocation record: ToolInvocationRecord) {}

        func deliver(report: ToolCallReport) {
            reports.append(report)
        }

        func deliver(display event: ToolDisplayEvent) {
            displays.append(event)
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
        let observer = DeliveryRecordingObserver()
        await outbox.attach(invocationObserver: observer)
        let report = Self.report()

        await outbox.post(report: report)

        #expect(await observer.reports == [report])
    }

    @Test("post(report:) stages nothing and writes nothing to the journal")
    func postReportStagesNothingAndJournalsNothing() async {
        let outbox = SessionOutbox()
        let observer = DeliveryRecordingObserver()
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

    // MARK: - post(display:): forwarded to the observer, never staged, never combined, never journaled

    /// Builds a display event that adds `text` to the output of the call with
    /// the completion token `correlationID`.
    ///
    /// - Parameters:
    ///   - text: The text of the chunk.
    ///   - correlationID: The completion token of the run.
    /// - Returns: The display event.
    private static func display(_ text: String, correlationID: String = "1") -> ToolDisplayEvent {
        ToolDisplayEvent(
            tool: "shell", op: "run command", correlationID: correlationID, kind: .contentChunk(.text(text)))
    }

    @Test("post(display:) hands the same display event to the attached observer")
    func postDisplayReachesTheObserver() async {
        let outbox = SessionOutbox()
        let observer = DeliveryRecordingObserver()
        await outbox.attach(invocationObserver: observer)
        let display = Self.display("first line")

        await outbox.post(display: display)

        #expect(await observer.displays == [display])
    }

    @Test("each display event of one run reaches the observer in post order, and none is combined")
    func displayEventsOfOneRunAreNotCombined() async {
        let outbox = SessionOutbox()
        let observer = DeliveryRecordingObserver()
        await outbox.attach(invocationObserver: observer)
        let displays = [Self.display("first line"), Self.display("second line"), Self.display("third line")]

        for display in displays {
            await outbox.post(display: display)
        }

        #expect(await observer.displays == displays)
    }

    @Test("post(display:) stages nothing and writes nothing to the journal")
    func postDisplayStagesNothingAndJournalsNothing() async {
        let outbox = SessionOutbox()
        let observer = DeliveryRecordingObserver()
        let journal = RecordingJournal()
        await outbox.attach(invocationObserver: observer)
        await outbox.attach(journal: journal)

        await outbox.post(display: Self.display("first line"))
        // The positive control: a plain event posted after the display event
        // does reach the journal, so an empty journal is not a stalled chain.
        await outbox.post(event: Self.event(correlationID: "c1", kind: .completed, detail: "control"))

        let pending = await outbox.pending()
        #expect(pending.events.map(\.event.detail) == ["control"])
        #expect(await journal.recorded.map(\.detail) == ["control"])
    }


    // MARK: - Helpers

    /// A user message with `text`, as ``RoutedSession/send(_:)`` makes it.
    ///
    /// - Parameters:
    ///   - text: The prompt text.
    ///   - maxTokens: The ceiling the caller named, or `nil`.
    ///   - mode: The output mode: a reply or a stream.
    /// - Returns: The mail.
    private static func userMail(
        _ text: String, maxTokens: Int? = nil, mode: UserMessageOptions.Mode = .reply
    ) -> Mail {
        Mail(
            sender: .user,
            body: .userMessage(prompt: text, options: UserMessageOptions(maxTokens: maxTokens, mode: mode)))
    }

    /// The run mail of `event`, as the outbox makes it for a post.
    ///
    /// - Parameter event: The run event.
    /// - Returns: The mail.
    private static func runMail(_ event: OperationEvent) -> Mail {
        Mail(sender: .run(correlationID: event.correlationID), body: .runEvent(event))
    }

    /// Takes all queued run mail of `outbox`, as a submission does, and
    /// leaves the user-type mail in the queue.
    ///
    /// - Parameter outbox: The outbox to take from.
    /// - Returns: The taken run mail, in queue order.
    private static func takeRunMail(from outbox: SessionOutbox) -> [Mail] {
        outbox.queue.take { candidate, _ in candidate.isRunMail }
    }

    /// Takes all queued run mail of `outbox`, and gives its events.
    ///
    /// - Parameter outbox: The outbox to take from.
    /// - Returns: The events of the taken run mail, in queue order.
    private static func takeRunEvents(from outbox: SessionOutbox) -> [OperationEvent] {
        takeRunMail(from: outbox).compactMap(\.runEvent)
    }
}
