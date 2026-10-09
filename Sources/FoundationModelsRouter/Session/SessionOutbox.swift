import FoundationModels
import FoundationModelsExtras

/// A per-``RoutedSession`` staging area for the messages that wait for the
/// pump of the session (`generation-queue.md`, section 5.4).
///
/// The outbox holds two kinds of item, never mixed:
///
/// - Mail (``PendingEvent``): ``OperationEvent``s posted through the
///   ``OperationEventSink`` conformance. The next submission of the pump puts
///   them into its prompt preamble. Only ``OperationEventKind/progress``
///   coalesces, to the latest pending one per `(tool, correlationID)` and
///   per plan id (`nil` for a text progress), in place. Every posted event
///   is also recorded in the transcript through the attached
///   ``OperationEventJournal``, uncoalesced.
///   A posted run terminal (``OperationEventKind/completed``) or run message
///   (``OperationEventKind/message``) tells the attached
///   ``SessionMailObserver``, so the pump can deliver it.
/// - Caller messages (``SessionMessage``): the prompts of
///   ``RoutedSession/send(_:)-(Transcript.Prompt)``,
///   ``RoutedSession/respond(to:maxTokens:)`` and the two stream methods.
///   They wait in the Extras mailbox ``messages``, which gives each one its
///   ``MessageID`` and its answer. The pump takes them in FIFO order, one
///   batch of the mailbox for each answer.
///
/// A staged event gets a stable ``EventID`` at post time.
///
/// The actor itself is internal. An app reaches the caller messages through
/// ``RoutedSession``'s methods; a session never exposes its outbox.
///
/// The outbox is also the session's `ToolCallReportSink` (an Extras
/// protocol): a tool decorator of FoundationModelsExtras finds it through a
/// dynamic cast when a call closes with attachments, and ``post(report:)``
/// forwards the report to the attached observer.
///
/// The outbox is also a `StagedEventWithdrawing` sink (an Extras protocol): a
/// background run that settled inside its settle period
/// (``SessionConfiguration/inlineSettleGrace``) answers with its own result,
/// so the Extras runner withdraws the staged copy of that run's events, and
/// it does not also ride in front of the next prompt. The journal
/// keeps its own copy, and the host still gets its
/// ``SessionEvent/runSettled(_:)``, because neither reads the staged events.
///
/// The outbox also forwards each ``ToolDisplayEvent`` of a tool through
/// ``post(display:)``. A display event is for the client of the host only: it
/// is never mail, never combined and never journaled, and a withdraw never
/// removes it.

/// The observer that a ``SessionOutbox`` tells when mail that the pump can
/// deliver arrives: a run terminal (``OperationEventKind/completed``) or a
/// run message (``OperationEventKind/message``).
///
/// A ``RoutedSessionActor`` is the one conformer. It starts its pump when no
/// pump runs.
protocol SessionMailObserver: AnyObject, Sendable {
    /// A run terminal or a run message was posted to the outbox.
    func mailArrived() async
}

/// The completion tokens of the background runs of a session, as the run
/// plane of the session gives them. The pump and the idle check read them to
/// find the mail that starts a submission with no caller message
/// (``SessionOutbox/canStartASubmission(_:runTokens:)``).
struct BackgroundRunTokens: Sendable, Equatable {
    /// The tokens of the background runs that are open.
    var open: Set<String> = []

    /// The tokens of the background runs that settled.
    var settled: Set<String> = []

    /// Whether `token` is the token of a background run, open or settled.
    ///
    /// - Parameter token: The completion token.
    /// - Returns: `true` when `token` is in ``open`` or in ``settled``.
    func contains(_ token: String) -> Bool {
        open.contains(token) || settled.contains(token)
    }
}

actor SessionOutbox: OperationEventSink, ToolCallReportSink, StagedEventWithdrawing {
    /// A stable identifier the outbox assigns to a staged event at post time.
    ///
    /// The id stays the same across a coalesced event's in-place updates.
    struct EventID: Hashable, Sendable {
        /// The generated value that carries this id's identity.
        ///
        /// Read by the synthesized `Hashable` conformance; periphery sees no caller.
        // periphery:ignore
        private let value: ULID

        /// Mints a fresh event id.
        fileprivate init() {
            self.value = ULID.generate()
        }
    }

    /// One pending mail event with its stable id.
    struct PendingEvent: Sendable {
        /// This event's stable id.
        let id: EventID

        /// The posted event, or the latest coalesced `.progress` event.
        let event: OperationEvent

        /// Whether the event waits for a submission that something else
        /// starts: a submission gave it back (``requeue(event:)``), a cancel
        /// held it (``holdPendingMail()``), or the bound on answers that mail
        /// alone starts held it (``putBack(holding:)``). A held run terminal
        /// or run message starts no submission by itself, so the pump does
        /// not retry it at once; it rides the next submission.
        let isHeld: Bool

        /// This event with its id, held (``isHeld``).
        var held: PendingEvent {
            PendingEvent(id: id, event: event, isHeld: true)
        }
    }

    /// A snapshot of everything currently pending, per kind.
    struct Pending: Sendable {
        /// Every pending mail event, in outbox order.
        let events: [PendingEvent]

        /// Every caller message that waits for the pump, in the order the
        /// messages arrived. This actor is not the session actor, so the
        /// snapshot can also show the delivery letter of the pump
        /// (``PumpWork/mailDeliveryLetter``) between its post and its take.
        /// ``RoutedSessionActor/pendingMessages()`` reads on the session
        /// actor, and never shows it.
        let messages: [SessionLetter]
    }

    /// Pending mail events, in outbox order.
    private var events: [PendingEvent] = []

    /// The caller messages that wait for the pump, and the messages of the
    /// answer that runs. Every call on it is synchronous and holds one lock,
    /// so a caller that is not on this actor or on the session actor, such
    /// as the cancellation handler of a caller task, reaches it at once.
    ///
    /// The pump also posts a letter of its own to start the batch of an
    /// answer that only mail starts (``PumpWork/mailDeliveryLetter``). It
    /// posts and takes that letter on the session actor with no suspension
    /// point between the two, so a read on the session actor never sees it
    /// wait.
    nonisolated let messages = SessionMessageMailbox()

    /// The journal every posted event is recorded into, or `nil` before
    /// ``attach(journal:)``. Weak to avoid a reference cycle.
    private weak var journal: (any OperationEventJournal)?

    /// The observer a posted run terminal or run message wakes, or `nil`
    /// before ``attach(mailObserver:)``. Weak to avoid a reference cycle.
    private weak var mailObserver: (any SessionMailObserver)?

    /// The observer every posted invocation record, tool call report and
    /// display event goes to, or `nil` before ``attach(invocationObserver:)``.
    /// Weak to avoid a reference cycle.
    private weak var invocationObserver: (any ToolInvocationObserver)?

    /// The FIFO chain every journal write is enqueued onto.
    private var journalChain = SerialAsyncChain()

    /// Creates an empty outbox. Only session construction calls this.
    init() {}

    /// Posts one ``OperationEvent``.
    ///
    /// The event is staged for the next submission under the coalescing
    /// policy, and recorded uncoalesced in the attached journal, in post
    /// order. A run terminal or a run message then tells the attached
    /// ``SessionMailObserver``, after its journal write, so the pump delivers
    /// an event that the journal already holds.
    ///
    /// - Parameter event: The event to post.
    func post(event: OperationEvent) async {
        // Enqueued before the staging decision and before any suspension, so
        // the journal's order is exactly this outbox's post order.
        let journalWrite = enqueueJournalWrite(event: event)
        stage(event: event)
        await journalWrite?.value
        if event.kind == .completed || event.kind == .message {
            await mailObserver?.mailArrived()
        }
    }

    /// Removes every event staged under `correlationID`, and leaves the
    /// journal and the caller messages alone.
    ///
    /// A run whose result went to the model inside its own tool output calls
    /// this, so the model does not read the same result a second time in front
    /// of its next prompt. An event a submission already took is gone from
    /// here, and this call then removes nothing.
    ///
    /// - Parameter correlationID: The run's completion token.
    func withdrawStagedEvents(correlationID: String) {
        events.removeAll { $0.event.correlationID == correlationID }
    }

    /// Records one event in the journal without staging it for a future
    /// prompt. The write joins the same ordered ``journalChain``.
    ///
    /// - Parameter event: The event to record.
    internal func journalWithoutStaging(event: OperationEvent) async {
        await enqueueJournalWrite(event: event)?.value
    }

    /// Restages an event a submission took but did not deliver, without a
    /// second journal write. The event is held (``PendingEvent/isHeld``): a
    /// submission that could not take it would give it back again, so it
    /// waits for the next submission that something else starts. It wakes no
    /// pump: the pump itself gives the event back.
    ///
    /// - Parameter event: The event to restage.
    internal func requeue(event: OperationEvent) {
        stage(event: event, held: true)
    }

    /// Puts back events that the pump took and did not use, in front of every
    /// event posted since, each as it was: with its id and its hold. No
    /// journal write happens, and no pump wakes.
    ///
    /// - Parameter untouched: The events, in the order the pump took them.
    func putBack(untouched: [PendingEvent]) {
        events = untouched + events
    }

    /// Puts back events that the pump took and did not use, in front of every
    /// event posted since, and holds each one (``PendingEvent/isHeld``). The
    /// bound on answers that mail alone starts uses it
    /// (``SessionConfiguration/mailOnlyAnswerLimit``): the mail then starts no
    /// submission by itself, and the next caller message carries it. Each
    /// event keeps its id. No journal write happens, and no pump wakes.
    ///
    /// - Parameter taken: The events, in the order the pump took them.
    func putBack(holding taken: [PendingEvent]) {
        events = taken.map(\.held) + events
    }

    /// Holds every pending event (``PendingEvent/isHeld``), so none starts a
    /// submission by itself. A cancel of the session calls it: the mail stays
    /// for a later submission, and the cancel does not start one. Each event
    /// keeps its id and its place.
    func holdPendingMail() {
        events = events.map(\.held)
    }

    /// Stages one event as pending under the coalescing policy.
    ///
    /// - Parameters:
    ///   - event: The event to stage.
    ///   - held: Whether the event is held (``PendingEvent/isHeld``).
    private func stage(event: OperationEvent, held: Bool = false) {
        switch event.kind {
        case .completed, .elicitation, .message:
            appendNewPendingEvent(event: event, held: held)
        case .progress:
            if let index = events.firstIndex(where: { Self.progress(event, replaces: $0.event) }) {
                events[index] = PendingEvent(id: events[index].id, event: event, isHeld: held)
            } else {
                appendNewPendingEvent(event: event, held: held)
            }
        }
    }

    /// Whether the progress event `newer` replaces the pending event `older`.
    ///
    /// The merge key is the `tool`, the `correlationID`, and the plan id
    /// (`OperationEvent.plan?.id`), which is `nil` for a text progress. Thus a
    /// plan replaces only an older plan that has the same `PlanSnapshot.id`,
    /// as the Extras contract of `PlanSnapshot` says, and a text progress
    /// replaces only an older text progress. One code-mode run posts the
    /// events of its nested `tools.*` calls under one `tool` and one
    /// `correlationID`, so it can send shell output and one or more plans
    /// (task ^mq1js23).
    ///
    /// - Parameters:
    ///   - newer: The progress event that is staged now.
    ///   - older: A pending event.
    /// - Returns: `true` when `older` is a progress event with the same merge
    ///   key as `newer`.
    private static func progress(_ newer: OperationEvent, replaces older: OperationEvent) -> Bool {
        older.kind == .progress && older.tool == newer.tool && older.correlationID == newer.correlationID
            && older.plan?.id == newer.plan?.id
    }

    /// Installs the journal that records every event posted from now on.
    ///
    /// Events staged before this call reach the transcript with the
    /// submission that takes them.
    ///
    /// - Parameter journal: The journal to install.
    internal func attach(journal: any OperationEventJournal) {
        self.journal = journal
    }

    /// Installs the observer that a posted run terminal or run message wakes
    /// from now on.
    ///
    /// - Parameter mailObserver: The observer to install.
    internal func attach(mailObserver: any SessionMailObserver) {
        self.mailObserver = mailObserver
    }

    /// Installs the observer that receives every ``ToolInvocationRecord``,
    /// ``ToolCallReport`` and ``ToolDisplayEvent`` posted from now on.
    ///
    /// - Parameter invocationObserver: The observer to install.
    internal func attach(invocationObserver: any ToolInvocationObserver) {
        self.invocationObserver = invocationObserver
    }

    /// Posts one ``ToolInvocationRecord`` to the attached observer.
    ///
    /// The record is not staged and not journaled. Before an observer is
    /// attached, the record is dropped.
    ///
    /// - Parameter record: The record to forward.
    func post(invocation record: ToolInvocationRecord) async {
        await invocationObserver?.deliver(invocation: record)
    }

    /// Posts one ``ToolCallReport`` to the attached observer.
    ///
    /// The report is not staged and not journaled. Before an observer is
    /// attached, the report is dropped.
    ///
    /// - Parameter report: The report to forward.
    func post(report: ToolCallReport) async {
        await invocationObserver?.deliver(report: report)
    }

    /// Posts one ``ToolDisplayEvent`` to the attached observer.
    ///
    /// The event is not staged, not combined with another display event and
    /// not journaled: the model never reads it, and a client shows each one
    /// in post order. A withdraw of the staged events of a run
    /// (``withdrawStagedEvents(correlationID:)``) never touches it, because
    /// it was never staged. Before an observer is attached, the event is
    /// dropped.
    ///
    /// - Parameter event: The display event to forward.
    func post(display event: ToolDisplayEvent) async {
        await invocationObserver?.deliver(display: event)
    }

    /// Chains one journal write onto ``journalChain``.
    ///
    /// - Parameter event: The event to record.
    /// - Returns: The chained write, or `nil` when no journal is attached.
    private func enqueueJournalWrite(event: OperationEvent) -> Task<Void, Never>? {
        guard let journal else { return nil }
        return journalChain.enqueue { await journal.record(event: event) }
    }

    /// Appends `event` as a new pending item with a fresh ``EventID``.
    ///
    /// - Parameters:
    ///   - event: The event to append.
    ///   - held: Whether the event is held (``PendingEvent/isHeld``).
    private func appendNewPendingEvent(event: OperationEvent, held: Bool) {
        events.append(PendingEvent(id: EventID(), event: event, isHeld: held))
    }

    /// Replaces the prompt of the waiting caller message with `id`, in place.
    /// The message keeps its id and its place in the queue.
    ///
    /// - Parameters:
    ///   - id: The id of the message.
    ///   - prompt: The new prompt.
    /// - Returns: ``MessageQueueMutationResult/applied`` when the message
    ///   waited; ``MessageQueueMutationResult/alreadySent`` otherwise.
    @discardableResult
    nonisolated func replace(id: MessageID, prompt: Transcript.Prompt) -> MessageQueueMutationResult {
        guard var message = messages.pending.first(where: { $0.id == id })?.message else { return .alreadySent }
        message.prompt = prompt
        return messages.replace(id, with: message)
    }

    /// A snapshot of everything currently pending, per kind.
    func pending() -> Pending {
        Pending(events: events, messages: messages.pending)
    }

    /// Takes the mail of a submission that no caller message starts: every
    /// pending mail event, when one of them can start a submission
    /// (``canStartASubmission(_:runTokens:)``).
    ///
    /// - Parameter runTokens: The completion tokens of the background runs.
    /// - Returns: The events, in outbox order, or `nil` when no event can
    ///   start a submission. Then nothing is taken.
    func takeMailStartingASubmission(deliveringRunsOf runTokens: BackgroundRunTokens) -> [PendingEvent]? {
        guard Self.canStartASubmission(events, runTokens: runTokens) else {
            return nil
        }
        return takeEvents()
    }

    /// Whether `mail` holds an event that starts a submission with no caller
    /// message. Such an event is not held (``PendingEvent/isHeld``), and it
    /// is one of these:
    ///
    /// - The terminal of a background run that settled.
    /// - A message of a background run (``OperationEventKind/message``). The
    ///   run is usually still open, and its terminal comes later.
    ///
    /// Other mail — a progress report, an elicitation, or the terminal or a
    /// message of an in-band run — starts no submission. The model reads the
    /// in-band result inside its own submission, so that mail rides the next
    /// submission instead.
    ///
    /// - Parameters:
    ///   - mail: The pending mail events.
    ///   - runTokens: The completion tokens of the background runs.
    /// - Returns: `true` when one event of `mail` is such an event.
    static func canStartASubmission(_ mail: [PendingEvent], runTokens: BackgroundRunTokens) -> Bool {
        mail.contains { pending in
            guard !pending.isHeld else { return false }
            switch pending.event.kind {
            case .completed:
                return runTokens.settled.contains(pending.event.correlationID)
            case .message:
                return runTokens.contains(pending.event.correlationID)
            case .progress, .elicitation:
                return false
            }
        }
    }

    /// Takes every pending mail event. A submission takes them all, held or
    /// not: the first submission of an answer that caller messages start, and
    /// each continuation submission.
    ///
    /// - Returns: The events, in outbox order.
    func takeEvents() -> [PendingEvent] {
        let taken = events
        events = []
        return taken
    }

    /// Withdraws every waiting caller message. Each caller that waits for the
    /// answer of one of them gets `CancellationError` from ``messages``.
    ///
    /// - Returns: The withdrawn messages, in the order they arrived.
    nonisolated func withdrawMessages() -> [SessionMessage] {
        messages.pending.compactMap { letter in
            messages.cancel(letter.id) == .withdrawn ? letter.message : nil
        }
    }
}
