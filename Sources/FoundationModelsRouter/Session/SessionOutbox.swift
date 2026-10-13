import FoundationModels
import FoundationModelsExtras
import Synchronization
import Tracing

/// A per-``RoutedSession`` staging area for the mail that waits for the pump
/// of the session (`mailbox.md`, sections 4 and 5).
///
/// All mail waits in one Extras ``MailQueue``, ``queue``:
///
/// - Run mail: each ``OperationEvent`` posted through the
///   ``OperationEventSink`` conformance becomes one ``MailBody/runEvent(_:)``
///   mail, with the sender ``MailSender/run(correlationID:)``. The next
///   submission of the pump puts it into its prompt preamble. Only
///   ``OperationEventKind/progress`` coalesces: a new progress event replaces
///   the body of the queued progress mail with the same key, `(tool,
///   correlationID)` and the plan id (`nil` for a text progress), in place.
///   The new event makes no new mail. Every posted event is also recorded in
///   the transcript through the attached ``OperationEventJournal``,
///   uncoalesced. A posted run terminal (``OperationEventKind/completed``) or
///   run message (``OperationEventKind/message``) tells the attached
///   ``SessionMailObserver``, so the pump can deliver it.
/// - User-type mail: the mail of ``RoutedSession/mail(_:)``, and of each
///   helper on top of it. The session puts it into the queue itself.
///
/// The outbox also keeps the ids of the held mail (``heldMailIDs``): run
/// mail that waits for a submission that something else starts. The bound
/// on answers that mail alone starts holds mail
/// (``SessionConfiguration/mailOnlyAnswerLimit``), and a submission that gave
/// its mail back holds it (``requeue(_:)``). An id leaves the set when its
/// mail is delivered, cancelled, drained or closed (``forget(_:)``), so the
/// set never grows without limit. It also keeps the completion tokens of the
/// runs that ``RoutedSession/cancelAll()`` stopped (``ignoreRunMail(of:)``):
/// a later event of such a run makes no mail.
///
/// The actor itself is internal. An app reaches the mail through
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
/// so the Extras runner withdraws the queued run mail of that run, and it
/// does not also ride in front of the next prompt. Each withdrawn mail gets
/// its terminal event ``SessionEvent/cancelled(_:)``. The journal keeps its
/// own copy, and the host still gets its ``SessionEvent/runSettled(_:)``,
/// because neither reads the queue.
///
/// The outbox also forwards each ``ToolDisplayEvent`` of a tool through
/// ``post(display:)``. A display event is for the client of the host only: it
/// is never mail, never combined and never journaled, and a withdraw never
/// removes it.

/// The observer that a ``SessionOutbox`` tells about its run mail.
///
/// A ``RoutedSessionActor`` is the one conformer. It starts its pump when no
/// pump runs, and it sends the terminal event of each withdrawn mail.
protocol SessionMailObserver: AnyObject, Sendable {
    /// A run terminal or a run message was posted to the outbox.
    func mailArrived() async

    /// The outbox withdrew queued run mail
    /// (``SessionOutbox/withdrawStagedEvents(correlationID:)``). Each id must
    /// get its terminal event ``SessionEvent/cancelled(_:)``.
    ///
    /// - Parameter ids: The ids of the withdrawn mail, in queue order.
    func runMailWithdrawn(_ ids: [MailID]) async
}

/// The completion tokens of the background runs of a session, as the run
/// plane of the session gives them. The pump and the idle check read them to
/// find the mail that starts a submission with no user-type mail
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
    /// One queued run mail, as the pump and the idle check read it.
    struct PendingEvent: Sendable {
        /// The id of the mail. It stays the same across the in-place
        /// updates of a coalesced progress event.
        let id: MailID

        /// The posted event, or the latest coalesced `.progress` event.
        let event: OperationEvent

        /// Whether the mail waits for a submission that something else
        /// starts: a submission gave it back (``requeue(_:)``), or the bound
        /// on answers that mail alone starts held it (``putBack(holding:)``).
        /// A held run terminal or run message starts no submission by
        /// itself, so the pump does not retry it at once; it rides the next
        /// submission.
        let isHeld: Bool
    }

    /// A snapshot of the queued run mail.
    struct Pending: Sendable {
        /// Every queued run mail, in queue order.
        let events: [PendingEvent]
    }

    /// The mail that waits for the pump, of all kinds, in queue order. Every
    /// call on it is synchronous and holds one lock, so a caller on any task
    /// reaches it at once.
    nonisolated let queue: MailQueue

    /// The ids of the held mail (``PendingEvent/isHeld``).
    private nonisolated let heldMail = Mutex<Set<MailID>>([])

    /// The tracing context of the caller of each queued user-type mail that
    /// had one, so the span of the submission that delivers the mail is a
    /// child of the span of the caller. The pump task inherits no task-local
    /// of the caller. An id leaves the map with ``forget(_:)``.
    private nonisolated let callerContexts = Mutex<[MailID: ServiceContext]>([:])

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
    ///
    /// - Parameter model: The model of the session, or `nil`. It gives the
    ///   model ref dimension of the queue metrics of ``queue``.
    init(model: ModelRef? = nil) {
        queue = MailQueue(model: model)
    }

    /// Posts one ``OperationEvent``.
    ///
    /// The event becomes run mail under the coalescing policy, and is
    /// recorded uncoalesced in the attached journal, in post order. A run
    /// terminal or a run message then tells the attached
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

    /// Cancels every queued run mail of `correlationID`, and leaves the
    /// journal and the user-type mail alone. Each cancelled mail gets its
    /// terminal event ``SessionEvent/cancelled(_:)`` through the attached
    /// ``SessionMailObserver``.
    ///
    /// A run whose result went to the model inside its own tool output calls
    /// this, so the model does not read the same result a second time in front
    /// of its next prompt. Mail a submission already took is gone from the
    /// queue, and this call then cancels nothing.
    ///
    /// - Parameter correlationID: The run's completion token.
    func withdrawStagedEvents(correlationID: String) async {
        let withdrawn = queue.pending
            .filter { $0.runEvent?.correlationID == correlationID }
            .compactMap { queue.cancel($0.id)?.id }
        guard !withdrawn.isEmpty else { return }
        forget(withdrawn)
        await mailObserver?.runMailWithdrawn(withdrawn)
    }

    /// Records one event in the journal without staging it for a future
    /// prompt. The write joins the same ordered ``journalChain``.
    ///
    /// - Parameter event: The event to record.
    internal func journalWithoutStaging(event: OperationEvent) async {
        await enqueueJournalWrite(event: event)?.value
    }

    /// Puts run mail that a submission took but did not deliver back at the
    /// front of the queue, with the same ids, without a second journal
    /// write. Each mail is held (``PendingEvent/isHeld``): a submission that
    /// could not take it would give it back again, so it waits for the next
    /// submission that something else starts. It wakes no pump: the pump
    /// itself gives the mail back.
    ///
    /// - Parameter mail: The mail to put back, in the order the pump took it.
    /// - Returns: The mail that the queue refused because it is closed. The
    ///   caller sends the terminal event of each one.
    nonisolated func requeue(_ mail: [Mail]) -> [Mail] {
        putBack(holding: mail)
    }

    /// Puts back mail that the pump took and did not use, in front of every
    /// mail posted since, each as it was: with its id and its hold. No
    /// journal write happens, and no pump wakes.
    ///
    /// - Parameter untouched: The mail, in the order the pump took it.
    /// - Returns: The mail that the queue refused because it is closed. The
    ///   caller sends the terminal event of each one.
    nonisolated func putBack(untouched: [Mail]) -> [Mail] {
        queue.putBack(untouched)
    }

    /// Puts back mail that the pump took and did not use, in front of every
    /// mail posted since, and holds each one (``PendingEvent/isHeld``). The
    /// bound on answers that mail alone starts uses it
    /// (``SessionConfiguration/mailOnlyAnswerLimit``): the mail then starts no
    /// submission by itself, and the next user-type mail carries it. Each
    /// mail keeps its id. No journal write happens, and no pump wakes.
    ///
    /// - Parameter taken: The mail, in the order the pump took it.
    /// - Returns: The mail that the queue refused because it is closed. The
    ///   caller sends the terminal event of each one.
    nonisolated func putBack(holding taken: [Mail]) -> [Mail] {
        // The hold comes first, so a reader never sees the mail in the queue
        // and not held.
        heldMail.withLock { $0.formUnion(taken.map(\.id)) }
        let refused = queue.putBack(taken)
        forget(refused.map(\.id))
        return refused
    }

    /// Records the tracing context of the caller of the user-type mail `id`.
    ///
    /// - Parameters:
    ///   - context: The tracing context of the caller, or `nil`.
    ///   - id: The id of the mail.
    nonisolated func noteCallerContext(_ context: ServiceContext?, for id: MailID) {
        guard let context else { return }
        callerContexts.withLock { $0[id] = context }
    }

    /// Takes the tracing context that ``noteCallerContext(_:for:)`` recorded
    /// for the mail `id`.
    ///
    /// - Parameter id: The id of the mail.
    /// - Returns: The tracing context, or `nil` when the caller had none.
    nonisolated func takeCallerContext(for id: MailID) -> ServiceContext? {
        callerContexts.withLock { $0.removeValue(forKey: id) }
    }

    /// Forgets the hold and the caller context of each mail of `ids`. The
    /// session calls it when each mail leaves the queue for good: it is
    /// delivered, cancelled, drained or closed.
    ///
    /// - Parameter ids: The ids of the mail.
    nonisolated func forget(_ ids: some Sequence<MailID>) {
        let ids = Set(ids)
        guard !ids.isEmpty else { return }
        heldMail.withLock { $0.subtract(ids) }
        callerContexts.withLock { contexts in
            for id in ids {
                contexts.removeValue(forKey: id)
            }
        }
    }

    /// The ids of the held mail.
    nonisolated var heldMailIDs: Set<MailID> {
        heldMail.withLock { $0 }
    }

    /// The most completion tokens of stopped runs that the outbox ignores.
    /// When the set is full, the oldest token leaves first.
    static let ignoredRunCapacity = 4096

    /// The completion tokens of the runs that make no more mail, and the
    /// order in which they came, oldest first. ``ignoreRunMail(of:)`` writes
    /// it, and ``stage(event:)`` reads it.
    private nonisolated let ignoredRuns = Mutex<(tokens: Set<String>, order: [String])>((tokens: [], order: []))

    /// Makes the runs of `tokens` make no more mail: a later event of these
    /// runs makes no mail. The journal still records it.
    /// ``RoutedSession/cancelAll()`` and the sweep call it for the runs they
    /// stop. The set keeps at most ``ignoredRunCapacity`` tokens.
    ///
    /// - Parameter tokens: The completion tokens of the runs.
    nonisolated func ignoreRunMail(of tokens: [String]) {
        ignoredRuns.withLock { ignored in
            for token in tokens where ignored.tokens.insert(token).inserted {
                ignored.order.append(token)
            }
            while ignored.order.count > Self.ignoredRunCapacity {
                ignored.tokens.remove(ignored.order.removeFirst())
            }
        }
    }

    /// The queued run mail, in queue order, with the hold of each one.
    nonisolated var pendingRunMail: [PendingEvent] {
        Self.pendingEvents(of: queue.pending, held: heldMailIDs)
    }

    /// The run mail of `mail` as the pump and the idle check read it.
    ///
    /// - Parameters:
    ///   - mail: Mail, in queue order.
    ///   - held: The ids of the held mail.
    /// - Returns: One ``PendingEvent`` for each run mail of `mail`, in order.
    static func pendingEvents(of mail: [Mail], held: Set<MailID>) -> [PendingEvent] {
        mail.compactMap { mail in
            mail.runEvent.map { PendingEvent(id: mail.id, event: $0, isHeld: held.contains(mail.id)) }
        }
    }

    /// Stages one event as run mail under the coalescing policy.
    ///
    /// - Parameter event: The event to stage.
    private func stage(event: OperationEvent) {
        // A stopped run makes no mail; the journal already has the event.
        guard !ignoredRuns.withLock({ $0.tokens.contains(event.correlationID) }) else { return }
        if event.kind == .progress,
            let older = queue.pending.first(where: { $0.runEvent.map { Self.progress(event, replaces: $0) } ?? false }),
            queue.replace(older.id, with: .runEvent(event))
        {
            return
        }
        // The queue refuses mail only after the session closed. Then no
        // submission reads the mail anymore, and the journal already holds
        // the event, so the refusal needs no other action.
        try? queue.put(Mail(sender: .run(correlationID: event.correlationID), body: .runEvent(event)))
    }

    /// Whether the progress event `newer` replaces the queued event `older`.
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
    ///   - older: A queued event.
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
    /// in post order. A withdraw of the queued run mail of a run
    /// (``withdrawStagedEvents(correlationID:)``) never touches it, because
    /// it was never mail. Before an observer is attached, the event is
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

    /// A snapshot of the queued run mail.
    func pending() -> Pending {
        Pending(events: pendingRunMail)
    }

    /// Whether `mail` holds an event that starts a submission with no
    /// user-type mail. Such an event is not held (``PendingEvent/isHeld``),
    /// and it is one of these:
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
    ///   - mail: The queued run mail.
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
}
