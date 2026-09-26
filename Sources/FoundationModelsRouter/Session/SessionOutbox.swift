import FoundationModels

/// A per-``RoutedSession`` staging area for the messages that wait for the
/// pump of the session (`generation-queue.md`, section 5.4).
///
/// The outbox holds two kinds of item, never mixed:
///
/// - Mail (``PendingEvent``): ``OperationEvent``s posted through the
///   ``OperationEventSink`` conformance. The next submission of the pump puts
///   them into its prompt preamble. Only ``OperationEventKind/progress``
///   coalesces, to the latest pending one per `(tool, correlationID)`, in
///   place. Every posted event is also recorded in the transcript through the
///   attached ``OperationEventJournal``, uncoalesced. A posted run terminal
///   (``OperationEventKind/completed``) tells the attached
///   ``SessionMailObserver``, so the pump can deliver it.
/// - Caller messages (``SessionMessage``): the prompts of
///   ``RoutedSession/send(_:)-(Transcript.Prompt)``,
///   ``RoutedSession/respond(to:maxTokens:)`` and the two stream methods.
///   The pump takes them in FIFO order
///   (``takeSubmissionBatch(deliveringRunsOf:)``).
///
/// A staged event gets a stable ``EventID`` at post time, and a caller
/// message carries the ``MessageID`` its sender got.
///
/// The actor itself is internal. An app reaches the caller messages through
/// ``RoutedSession``'s methods; a session never exposes its outbox.
///
/// The outbox is also the session's ``ToolCallReportSink``: a tool decorator
/// finds it through a dynamic cast when a call closes with attachments, and
/// ``post(report:)`` forwards the report to the attached observer.
/// A sink that can take back an event it staged for a later prompt.
///
/// ``BackgroundToolRunner`` uses it for one case: a background run that
/// settled inside its tool's ``BackgroundTool/inlineSettleGrace`` answers with
/// the result in its own envelope, so the staged copy of that run's events
/// must not also ride in front of the next prompt. The journal keeps its own
/// copy, and the host still gets its ``SessionEvent/runSettled(_:)``, because
/// neither reads the staged events.
///
/// A sink that stages nothing, such as the sink of a mounted inner run, does
/// not conform, and the runner then withdraws nothing.
protocol StagedEventWithdrawing: Sendable {
    /// Removes every event staged under `correlationID`.
    ///
    /// - Parameter correlationID: The run's completion token.
    func withdrawStagedEvents(correlationID: String) async
}

/// The observer that a ``SessionOutbox`` tells when mail that the pump can
/// deliver arrives: a run terminal (``OperationEventKind/completed``).
///
/// A ``RoutedSessionActor`` is the one conformer. It starts its pump when no
/// pump runs.
protocol SessionMailObserver: AnyObject, Sendable {
    /// A run terminal was posted to the outbox.
    func mailArrived() async
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
        /// starts: a submission gave it back (``requeue(event:)``), or a cancel
        /// held it (``holdPendingMail()``). A held run terminal starts no
        /// submission by itself, so the pump does not retry it at once; it
        /// rides the next submission.
        let isHeld: Bool
    }

    /// A snapshot of everything currently pending, per kind.
    struct Pending: Sendable {
        /// Every pending mail event, in outbox order.
        let events: [PendingEvent]

        /// Every caller message that waits for the pump, in the order the
        /// messages arrived.
        let messages: [SessionMessage]
    }

    /// Pending mail events, in outbox order.
    private var events: [PendingEvent] = []

    /// The caller messages that wait for the pump, in the order they arrived.
    private var messages: [SessionMessage] = []

    /// The journal every posted event is recorded into, or `nil` before
    /// ``attach(journal:)``. Weak to avoid a reference cycle.
    private weak var journal: (any OperationEventJournal)?

    /// The observer a posted run terminal wakes, or `nil` before
    /// ``attach(mailObserver:)``. Weak to avoid a reference cycle.
    private weak var mailObserver: (any SessionMailObserver)?

    /// The observer every posted invocation record and tool call report goes
    /// to, or `nil` before ``attach(invocationObserver:)``. Weak to avoid a
    /// reference cycle.
    private weak var invocationObserver: (any ToolInvocationObserver)?

    /// The FIFO chain every journal write is enqueued onto.
    private var journalChain = SerialAsyncChain()

    /// Creates an empty outbox. Only session construction calls this.
    init() {}

    /// Posts one ``OperationEvent``.
    ///
    /// The event is staged for the next submission under the coalescing
    /// policy, and recorded uncoalesced in the attached journal, in post
    /// order. A run terminal then tells the attached ``SessionMailObserver``,
    /// after its journal write, so the pump delivers a terminal that the
    /// journal already holds.
    ///
    /// - Parameter event: The event to post.
    func post(event: OperationEvent) async {
        // Enqueued before the staging decision and before any suspension, so
        // the journal's order is exactly this outbox's post order.
        let journalWrite = enqueueJournalWrite(event: event)
        stage(event: event)
        await journalWrite?.value
        if event.kind == .completed {
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

    /// Holds every pending event (``PendingEvent/isHeld``), so none starts a
    /// submission by itself. A cancel of the session calls it: the mail stays
    /// for a later submission, and the cancel does not start one. Each event
    /// keeps its id and its place.
    func holdPendingMail() {
        events = events.map { PendingEvent(id: $0.id, event: $0.event, isHeld: true) }
    }

    /// Stages one event as pending under the coalescing policy.
    ///
    /// - Parameters:
    ///   - event: The event to stage.
    ///   - held: Whether the event is held (``PendingEvent/isHeld``).
    private func stage(event: OperationEvent, held: Bool = false) {
        switch event.kind {
        case .completed, .elicitation:
            appendNewPendingEvent(event: event, held: held)
        case .progress:
            if let index = events.firstIndex(where: {
                $0.event.kind == .progress && $0.event.tool == event.tool
                    && $0.event.correlationID == event.correlationID
            }) {
                events[index] = PendingEvent(id: events[index].id, event: event, isHeld: held)
            } else {
                appendNewPendingEvent(event: event, held: held)
            }
        }
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

    /// Installs the observer that a posted run terminal wakes from now on.
    ///
    /// - Parameter mailObserver: The observer to install.
    internal func attach(mailObserver: any SessionMailObserver) {
        self.mailObserver = mailObserver
    }

    /// Installs the observer that receives every ``ToolInvocationRecord`` and
    /// ``ToolCallReport`` posted from now on.
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
    /// The message keeps its place in the queue.
    ///
    /// - Parameters:
    ///   - id: The id of the message.
    ///   - prompt: The new prompt.
    /// - Returns: ``MessageQueueMutationResult/applied`` when the message
    ///   waited; ``MessageQueueMutationResult/alreadySent`` otherwise.
    @discardableResult
    func replace(id: MessageID, prompt: Transcript.Prompt) -> MessageQueueMutationResult {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return .alreadySent }
        messages[index].prompt = prompt
        return .applied
    }

    /// A snapshot of everything currently pending, per kind.
    func pending() -> Pending {
        Pending(events: events, messages: messages)
    }

    /// Adds one caller message behind every message that waits.
    ///
    /// - Parameter message: The message to add.
    func add(message: SessionMessage) {
        messages.append(message)
    }

    /// How many caller messages wait for the pump.
    var waitingMessageCount: Int {
        messages.count
    }

    /// Takes what the next submission of the pump carries, and commits
    /// exactly what it returns.
    ///
    /// When a caller message waits, the first one decides the options of the
    /// submission (``SubmissionOptions``), and every waiting message that
    /// the options admit comes with it, in FIFO order. A stream message goes
    /// alone. When no caller message waits, the terminal of a settled
    /// background run starts a submission of its own, unless it is held
    /// (``PendingEvent/isHeld``). Every pending mail event comes with the
    /// submission, held or not.
    ///
    /// Other mail — a progress report, an elicitation, or the terminal of an
    /// in-band run that ended abnormally — starts no submission. The model
    /// already read the in-band result inside its own submission, so that
    /// terminal rides the next submission instead.
    ///
    /// - Parameter settledRunTokens: The completion tokens of the background
    ///   runs that settled.
    /// - Returns: The batch, or `nil` when nothing that can start a
    ///   submission waits. Then nothing is taken.
    func takeSubmissionBatch(deliveringRunsOf settledRunTokens: Set<String>) -> SubmissionBatch? {
        if let first = messages.first {
            let options = first.options
            let taken =
                options.isStream ? takeMessages(where: { $0.id == first.id }) : takeMessages(where: options.admits)
            return SubmissionBatch(events: takeEvents(), messages: taken)
        }
        guard Self.canStartASubmission(events, settledRunTokens: settledRunTokens) else {
            return nil
        }
        return SubmissionBatch(events: takeEvents(), messages: [])
    }

    /// Whether `mail` holds the terminal of a background run that settled,
    /// and that is not held, which starts a submission with no caller
    /// message.
    ///
    /// - Parameters:
    ///   - mail: The pending mail events.
    ///   - settledRunTokens: The completion tokens of the settled background
    ///     runs.
    /// - Returns: `true` when one event of `mail` is such a terminal.
    static func canStartASubmission(_ mail: [PendingEvent], settledRunTokens: Set<String>) -> Bool {
        mail.contains {
            !$0.isHeld && $0.event.kind == .completed && settledRunTokens.contains($0.event.correlationID)
        }
    }

    /// Takes what a continuation submission of a running answer carries:
    /// every pending mail event, and every waiting caller message that
    /// `options` admit.
    ///
    /// - Parameter options: The options of the running answer.
    /// - Returns: The batch, which can be empty.
    func takeJoiningBatch(options: SubmissionOptions) -> SubmissionBatch {
        SubmissionBatch(events: takeEvents(), messages: takeMessages(where: options.admits))
    }

    /// Takes every waiting caller message for which `isTaken` is `true`. The
    /// other messages keep their order.
    ///
    /// - Parameter isTaken: Whether a message is taken.
    /// - Returns: The taken messages, in the order they arrived.
    private func takeMessages(where isTaken: (SessionMessage) -> Bool) -> [SessionMessage] {
        let taken = messages.filter(isTaken)
        messages.removeAll(where: isTaken)
        return taken
    }

    /// Takes every pending mail event.
    ///
    /// - Returns: The events, in outbox order.
    private func takeEvents() -> [PendingEvent] {
        let taken = events
        events = []
        return taken
    }

    /// Withdraws every waiting caller message.
    ///
    /// - Returns: The withdrawn messages, in the order they arrived.
    func withdrawMessages() -> [SessionMessage] {
        takeMessages { _ in true }
    }

    /// Withdraws the waiting caller message with `id`.
    ///
    /// - Parameter id: The id of the message.
    /// - Returns: The message, or `nil` when no waiting message has `id`.
    func withdrawMessage(id: MessageID) -> SessionMessage? {
        takeMessages { $0.id == id }.first
    }
}
