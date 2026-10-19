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
///   submission of the pump renders it into its prompt, in take order. Only
///   ``OperationEventKind/progress`` coalesces: a new progress event replaces
///   the body of the queued progress mail with the same key, `(tool,
///   correlationID)` and the plan id (`nil` for a text progress), in place.
///   The new event makes no new mail. Every posted event is also recorded in
///   the transcript through the attached ``OperationEventJournal``,
///   uncoalesced. The output event of each posted event has the origin
///   ``Origin/mail(_:)`` with the id of its run mail (``RunEventOrigin``). A
///   posted run terminal (``OperationEventKind/completed``) or run message
///   (``OperationEventKind/message``) tells the attached
///   ``SessionMailObserver``, so the pump can deliver it. A question that a
///   ``SubagentQuestionRelay`` sent up from a subagent
///   (``ElicitationRequest/isRelayed``) makes no mail: only the level whose
///   own run asked a question puts it in the prompt of its model. The journal
///   still records it.
/// - User-type mail: the mail of ``RoutedSession/mail(_:)``, and of each
///   helper on top of it. The session puts it into the queue itself.
///
/// The outbox also keeps the ids of the held mail (``heldMailIDs``): run
/// mail that waits for a submission that something else starts. The bound
/// on answers that mail alone starts holds mail
/// (``SessionConfiguration/mailOnlyAnswerLimit``), and a submission that gave
/// its mail back holds the mail that can start a submission now
/// (``requeue(_:runTokens:)``). An id leaves the set when its
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
/// The outbox also keeps the `WorkKind.mail` lease of each queued mail that
/// can start an answer (``beginMailWork(_:)``), in the work registry of the
/// session: user-type mail, and run mail that can start a submission by
/// itself. The lease begins before the put of the mail, and ends when the
/// mail leaves the queue for good (``forget(_:)``) or goes on hold
/// (``putBack(holding:)``). Thus queued mail that can start an answer is work
/// of the session, and the end of the last such mail ends the work.
///
/// The outbox also forwards each ``ToolDisplayEvent`` of a tool through
/// ``post(display:)``. A display event is for the client of the host only: it
/// is never mail, never combined and never journaled, and a withdraw never
/// removes it.
///
/// The outbox is also a `CatalogNoticeSink` (an Extras protocol): the
/// `CatalogNoticeBoard` of a `CatalogNoticing` tool that the session mounted
/// posts each change of its catalog through ``post(catalogNotice:)``. Each
/// notice is one ``MailBody/catalogChange(_:)`` mail. It is neither
/// user-type mail nor run mail: it wakes no pump, starts no answer and holds
/// no `WorkKind.mail` lease, so a session whose only queued mail is notices
/// has no work. It rides the next submission that other mail starts.
///
/// The outbox also hands the completion of an accepted URL-mode question
/// (``post(elicitationCompleted:)``) and the end of a question that a cancel
/// of the run plane ended (``post(elicitationEnded:response:)``) to the
/// attached journal, on the same ordered chain as the run events. Neither is
/// mail.

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
/// plane of the session gives them. The pump and the outbox read them to
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

actor SessionOutbox: OperationEventSink, ToolCallReportSink, StagedEventWithdrawing, CatalogNoticeSink {
    /// One queued run mail, as the pump reads it.
    struct PendingEvent: Sendable {
        /// The id of the mail. It stays the same across the in-place
        /// updates of a coalesced progress event.
        let id: MailID

        /// The posted event, or the latest coalesced `.progress` event.
        let event: OperationEvent

        /// Whether the mail waits for a submission that something else
        /// starts: a submission gave it back (``requeue(_:runTokens:)``), or the bound
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

    /// The work registry of the session and the run plane of the session,
    /// or `nil` before the session binds them (``bind(workRegistry:runPlane:)``),
    /// and the `WorkKind.mail` lease of each queued mail that can start an
    /// answer, by the id of the mail.
    private nonisolated let mailWork = Mutex<MailWork>(MailWork())

    /// The state behind ``mailWork``.
    private struct MailWork: Sendable {
        /// The work registry of the session, or `nil` before the bind.
        var registry: WorkRegistry?

        /// The run plane of the session, or `nil` before the bind. A run
        /// event of a run that the run plane does not know (an in-band run)
        /// starts no submission, so its mail holds no lease.
        var runPlane: RunPlane?

        /// The open lease of each queued mail that can start an answer.
        var leases: [MailID: BackgroundWork] = [:]
    }

    /// The output of the session that owns this outbox, or `nil` before
    /// the session binds it (``bind(outputHub:)``). The stage of new run
    /// mail makes the id of the mail pending in it before the put
    /// (``stage(event:as:)``).
    private nonisolated let outputHub = Mutex<SessionOutputHub?>(nil)

    /// What the session that owns this outbox does after the put of each
    /// catalog-change mail, or `nil` before the session binds it
    /// (``bind(catalogNoticeArrival:)``).
    private nonisolated let catalogNoticeArrival = Mutex<(@Sendable (Mail) async -> Void)?>(nil)

    /// The task-locals of the caller of a queued mail that the answer that
    /// delivers the mail needs. The pump task inherits no task-local of the
    /// caller, so the mail carries them.
    struct MailCaller: Sendable {
        /// The tracing context of the caller, or `nil`. The span of the
        /// submission that delivers the mail is a child of its span.
        let serviceContext: ServiceContext?

        /// The own work of the caller (``SessionOwnWork/current``). Each
        /// submission of the answer that delivers the mail is also that own
        /// work (task ^hrkxav5).
        let ownWork: SessionOwnWork

        /// Whether the caller had no task-local that the answer needs.
        var isEmpty: Bool {
            serviceContext == nil && ownWork.isEmpty
        }
    }

    /// The task-locals of the caller of each queued mail that had one. An id
    /// leaves the map with ``takeCallers(of:)`` or ``forget(_:)``.
    private nonisolated let callers = Mutex<[MailID: MailCaller]>([:])

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
    /// The ``MailID`` of the run mail is made before the journal write, and
    /// the journal write gets the id of the mail that holds the event
    /// (``RunEventOrigin``). Thus the output event of the run event has the
    /// origin ``Origin/mail(_:)`` with that id. A progress event that
    /// replaces queued progress mail gets the id of that mail. An event that
    /// makes no mail keeps the origin of the poster.
    ///
    /// The journal write and its output event can come after the pump took
    /// the mail: the stage puts the mail into the queue at once, and the
    /// write runs later on ``journalChain``. Thus
    /// ``SessionEvent/mailDelivered(_:)`` of the mail can come before the
    /// output event of the run event.
    ///
    /// - Parameter event: The event to post.
    func post(event: OperationEvent) async {
        // Staged and enqueued before any suspension, so the journal's order
        // is exactly this outbox's post order.
        let origin = RunEventOrigin(mailID: stage(event: event, as: MailID()), poster: OriginContext.current)
        let journalWrite = enqueueJournalWrite(event: event, origin: origin)
        if Self.canStartASubmissionByItself(event), let id = origin.mailID {
            await endMailWorkOfAnInBandRun(id, event: event)
        }
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
    /// prompt. The write joins the same ordered ``journalChain``. The event
    /// makes no mail, so its output event has the origin of the caller.
    ///
    /// - Parameter event: The event to record.
    internal func journalWithoutStaging(event: OperationEvent) async {
        let origin = RunEventOrigin(mailID: nil, poster: OriginContext.current)
        await enqueueJournalWrite(event: event, origin: origin)?.value
    }

    /// Puts run mail that a submission took but did not deliver back at the
    /// front of the queue, with the same ids, without a second journal
    /// write. It wakes no pump: the pump itself gives the mail back.
    ///
    /// Only the mail that can start a submission now
    /// (``canStartASubmission(_:runTokens:)``) is held
    /// (``PendingEvent/isHeld``): a submission that could not take it would
    /// give it back again, so it waits for the next submission that something
    /// else starts. The other mail starts no submission now, so it goes back
    /// with no hold. The terminal of a run that is still open is such mail:
    /// it holds its `WorkKind.mail` lease again, and the settlement of its
    /// run lets it start a submission. Thus a terminal that a submission gave
    /// back before its run settled never waits for user-type mail.
    ///
    /// - Parameters:
    ///   - mail: The mail to put back, in the order the pump took it.
    ///   - runTokens: The completion tokens of the background runs, read
    ///     before this call.
    /// - Returns: The mail that the queue refused because it is closed. The
    ///   caller sends the terminal event of each one.
    nonisolated func requeue(_ mail: [Mail], runTokens: BackgroundRunTokens) -> [Mail] {
        let held = mail.filter { one in
            Self.canStartASubmission(Self.pendingEvents(of: [one], held: []), runTokens: runTokens)
        }
        let heldIds = Set(held.map(\.id))
        heldMail.withLock { $0.formUnion(heldIds) }
        endMailWork(heldIds)
        for one in mail where !heldIds.contains(one.id) {
            guard let event = one.runEvent, Self.canStartASubmissionByItself(event),
                runTokens.contains(event.correlationID)
            else { continue }
            beginMailWork(one.id)
        }
        let refused = queue.putBack(mail)
        forget(refused.map(\.id))
        return refused
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
        // Held mail starts no answer by itself, so it is no work.
        endMailWork(taken.map(\.id))
        let refused = queue.putBack(taken)
        forget(refused.map(\.id))
        return refused
    }

    /// Records the task-locals of the caller of the mail `id`. A caller with
    /// no task-local that the answer needs records nothing.
    ///
    /// - Parameters:
    ///   - caller: The task-locals of the caller.
    ///   - id: The id of the mail.
    nonisolated func noteCaller(_ caller: MailCaller, for id: MailID) {
        guard !caller.isEmpty else { return }
        callers.withLock { $0[id] = caller }
    }

    /// Takes the task-locals that ``noteCaller(_:for:)`` recorded for each
    /// mail of `ids`.
    ///
    /// - Parameter ids: The ids of the mail.
    /// - Returns: The task-locals of each mail whose caller had one, by id.
    nonisolated func takeCallers(of ids: some Sequence<MailID>) -> [MailID: MailCaller] {
        callers.withLock { callers in
            var taken: [MailID: MailCaller] = [:]
            for id in ids {
                taken[id] = callers.removeValue(forKey: id)
            }
            return taken
        }
    }

    /// Forgets the hold and the caller of each mail of `ids`. The session
    /// calls it when each mail leaves the queue for good: it is delivered,
    /// cancelled, drained or closed.
    ///
    /// - Parameter ids: The ids of the mail.
    nonisolated func forget(_ ids: some Sequence<MailID>) {
        let ids = Set(ids)
        guard !ids.isEmpty else { return }
        heldMail.withLock { $0.subtract(ids) }
        _ = takeCallers(of: ids)
        endMailWork(ids)
    }

    // MARK: - The leases of the mail

    /// Binds this outbox to the work registry and the run plane of the
    /// session that owns it. From now on, each queued mail that can start an
    /// answer holds a `WorkKind.mail` lease in `registry`.
    ///
    /// The session calls it one time, when it is made, before any pump or
    /// signal of the session runs.
    ///
    /// - Parameters:
    ///   - registry: The work registry of the session.
    ///   - runPlane: The run plane of the session.
    nonisolated func bind(workRegistry registry: WorkRegistry, runPlane: RunPlane) {
        mailWork.withLock { work in
            work.registry = registry
            work.runPlane = runPlane
        }
    }

    /// Begins the `WorkKind.mail` lease of the mail `id`. The caller calls it
    /// before the put of the mail, so a take of the mail always finds the
    /// lease, and ends it. A mail that holds a lease already keeps its lease:
    /// a second mail with the same id is refused by the queue.
    ///
    /// - Parameter id: The id of the mail.
    /// - Returns: `true` when this call began a lease. Before the bind, no
    ///   lease begins.
    @discardableResult
    nonisolated func beginMailWork(_ id: MailID) -> Bool {
        let registry: WorkRegistry? = mailWork.withLock { work in
            guard work.leases[id] == nil else { return nil }
            return work.registry
        }
        guard let registry else { return false }
        let lease = registry.begin(.mail, id: id.description)
        let kept = mailWork.withLock { work -> Bool in
            guard work.leases[id] == nil else { return false }
            work.leases[id] = lease
            return true
        }
        guard kept else {
            lease.end()
            return false
        }
        return true
    }

    /// Ends the `WorkKind.mail` lease of each mail of `ids` that holds one.
    ///
    /// - Parameter ids: The ids of the mail.
    nonisolated func endMailWork(_ ids: some Sequence<MailID>) {
        let leases = mailWork.withLock { work in ids.compactMap { work.leases.removeValue(forKey: $0) } }
        leases.forEach { $0.end() }
    }

    /// Ends the `WorkKind.mail` lease of the run mail `id` when `event` can
    /// never start a submission by itself: its run is not a background run
    /// of the run plane of the session (an in-band run). The post of the
    /// event calls it before it returns, thus before the run plane settles
    /// the run: an open background run is then in the open runs.
    ///
    /// - Parameters:
    ///   - id: The id of the run mail.
    ///   - event: The run event of the mail.
    private func endMailWorkOfAnInBandRun(_ id: MailID, event: OperationEvent) async {
        guard let runPlane = mailWork.withLock({ $0.leases[id] == nil ? nil : $0.runPlane }) else { return }
        guard !(await runPlane.backgroundRunTokens()).contains(event.correlationID) else { return }
        endMailWork([id])
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
    /// it, and ``stage(event:as:)`` reads it.
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

    /// The run mail of `mail` as the pump reads it.
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
    /// - Parameters:
    ///   - event: The event to stage.
    ///   - id: The id of the new run mail, made before the journal write.
    /// - Returns: The id of the run mail that holds `event`: `id` for new
    ///   mail, the id of the queued progress mail that `event` replaced, or
    ///   `nil` when `event` made no mail.
    private func stage(event: OperationEvent, as id: MailID) -> MailID? {
        // A stopped run makes no mail; the journal still records the event.
        guard !ignoredRuns.withLock({ $0.tokens.contains(event.correlationID) }) else { return nil }
        // A question that a relay sent up from a child makes no mail: only
        // the level whose own run asked the question puts it in the prompt of
        // its model. The journal still records the event.
        guard event.elicitation?.isRelayed != true else { return nil }
        if event.kind == .progress,
            let older = queue.pending.first(where: { $0.runEvent.map { Self.progress(event, replaces: $0) } ?? false }),
            queue.replace(older.id, with: .runEvent(event))
        {
            return older.id
        }
        // The id is pending before the put: from the put on, a reader of the
        // queue can get the id, and the pump can take the mail and end it.
        let hub = outputHub.withLock { $0 }
        let madePending = hub?.beginPending(.mail(id)) ?? false
        // The lease also begins before the put: a take of the mail ends it.
        // The post ends it again when the run is an in-band run.
        let leased = Self.canStartASubmissionByItself(event) && beginMailWork(id)
        do {
            try queue.put(Mail(id: id, sender: .run(correlationID: event.correlationID), body: .runEvent(event)))
            return id
        } catch {
            // The queue refuses mail only after the session closed. Then no
            // submission reads the mail anymore, and the journal still
            // records the event, so the refusal needs only the end of the
            // pending record and of the lease.
            if madePending {
                hub?.endPending(.mail(id))
            }
            if leased {
                endMailWork([id])
            }
            return nil
        }
    }

    /// Binds this outbox to the output of the session that owns it. From
    /// now on, the stage of each new run mail makes the id of the mail
    /// pending in `hub` before the put (``SessionOutputHub/beginPending(_:)``),
    /// so a wait for the id waits while the mail waits or runs. Each mail
    /// that the queue already holds becomes pending too.
    ///
    /// The session calls it one time, when it is made, before any pump or
    /// signal of the session runs.
    ///
    /// - Parameter hub: The output of the session.
    nonisolated func bind(outputHub hub: SessionOutputHub) {
        outputHub.withLock { $0 = hub }
        for mail in queue.pending {
            hub.beginPending(.mail(mail.id))
        }
    }

    /// Binds what the session that owns this outbox does after the put of
    /// each catalog-change mail: it records the arrival of the mail in its
    /// transcript.
    ///
    /// The session calls it one time, when it is made, before any tool of
    /// the session can post a notice.
    ///
    /// - Parameter arrival: The step after the put of each catalog-change
    ///   mail.
    nonisolated func bind(catalogNoticeArrival arrival: @escaping @Sendable (Mail) async -> Void) {
        catalogNoticeArrival.withLock { $0 = arrival }
    }

    /// Puts one ``MailBody/catalogChange(_:)`` mail with `notice` in the
    /// queue, and returns after the session recorded its arrival.
    ///
    /// The mail wakes no pump and holds no `WorkKind.mail` lease: it starts
    /// no answer by itself, so it is no work, and a session that waits for
    /// no work after its last prompt still gets there. The next submission
    /// carries it, a first submission or a continuation, and its prompt
    /// renders it as ``CatalogChangeNotice/text``. After the session closed,
    /// the queue refuses the mail and the notice is dropped.
    ///
    /// - Parameter notice: The notice.
    func post(catalogNotice notice: CatalogChangeNotice) async {
        let mail = Mail(catalogNotice: notice)
        // The id is pending before the put, as for run mail
        // (``stage(event:as:)``): the delivery of the mail ends it.
        let hub = outputHub.withLock { $0 }
        let madePending = hub?.beginPending(.mail(mail.id)) ?? false
        do {
            try queue.put(mail)
        } catch {
            if madePending {
                hub?.endPending(.mail(mail.id))
            }
            return
        }
        await catalogNoticeArrival.withLock({ $0 })?(mail)
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

    /// Posts the completion of the accepted URL-mode question
    /// `elicitationId` to the attached journal.
    ///
    /// The run plane of Extras posts it when the flow of the question
    /// completes, from each source: ``RoutedSession/complete(elicitationId:)``
    /// or `ToolContext.complete(elicitationId:)`. The completion is not staged
    /// and makes no mail. It joins the same ordered ``journalChain`` as the
    /// run events, so it comes after each run event that was posted before
    /// it. The journal sends ``SessionEvent/elicitationCompleted(_:)``
    /// (``OperationEventJournal/record(elicitationCompleted:poster:)``).
    /// Before a journal is attached, the completion is dropped.
    ///
    /// - Parameter elicitationId: The id of the question that completed.
    func post(elicitationCompleted elicitationId: ULID) async {
        let poster = OriginContext.current
        await enqueueJournalWork { await $0.record(elicitationCompleted: elicitationId, poster: poster) }?.value
    }

    /// Posts the end of the question `elicitationId` to the attached
    /// journal.
    ///
    /// The run plane of Extras posts it when a cancel of the run plane ends
    /// an open question: `RunPlane.cancelOpenElicitations()` of
    /// ``RoutedSession/cancelAll()`` and ``RoutedSession/close()``, a cancel
    /// of the run of the question, or a sweep. The run plane posts it after
    /// the post of the question, and the run gets `response` only after this
    /// post returns. The end is not staged and makes no mail. It joins the
    /// same ordered ``journalChain`` as the run events. The journal sends
    /// ``SessionEvent/elicitationEnded(_:)``
    /// (``OperationEventJournal/record(elicitationEnded:response:poster:)``),
    /// with the origin of the work that ended the question. Before a journal
    /// is attached, the end is dropped.
    ///
    /// - Parameters:
    ///   - elicitationId: The id of the question that ended.
    ///   - response: The answer that the run of the question gets.
    func post(elicitationEnded elicitationId: ULID, response: ElicitationResponse) async {
        let poster = OriginContext.current
        await enqueueJournalWork {
            await $0.record(elicitationEnded: elicitationId, response: response, poster: poster)
        }?.value
    }

    /// Chains one journal write onto ``journalChain``.
    ///
    /// - Parameters:
    ///   - event: The event to record.
    ///   - origin: The run mail of `event` and the work that posted it.
    /// - Returns: The chained write, or `nil` when no journal is attached.
    private func enqueueJournalWrite(event: OperationEvent, origin: RunEventOrigin) -> Task<Void, Never>? {
        enqueueJournalWork { await $0.record(event: event, origin: origin) }
    }

    /// Chains one piece of work of the attached journal onto
    /// ``journalChain``.
    ///
    /// - Parameter work: The work, given the attached journal.
    /// - Returns: The chained work, or `nil` when no journal is attached.
    private func enqueueJournalWork(
        _ work: @escaping @Sendable (any OperationEventJournal) async -> Void
    ) -> Task<Void, Never>? {
        guard let journal else { return nil }
        return journalChain.enqueue { await work(journal) }
    }

    /// Whether the kind of `event` can start a submission by itself: a
    /// terminal or a message of a run. Such mail starts a submission only
    /// for a background run (``canStartASubmission(_:runTokens:)``).
    ///
    /// - Parameter event: A run event.
    /// - Returns: `true` for ``OperationEventKind/completed`` and
    ///   ``OperationEventKind/message``.
    static func canStartASubmissionByItself(_ event: OperationEvent) -> Bool {
        event.kind == .completed || event.kind == .message
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
