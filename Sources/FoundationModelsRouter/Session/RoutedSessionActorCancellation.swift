import FoundationModelsExtras
import Synchronization

/// The ids of the mail of the open answer of a session
/// (``RoutedSessionActor/openAnswerMail``), in delivery order.
///
/// The pump writes it on the session actor. ``RoutedSessionActor/mail(_:)``
/// reads it from any task, with no suspension point, to refuse a mail whose
/// id the open answer already carries. The ids are behind a lock for that
/// reason.
final class OpenAnswerMail: Sendable {
    /// The ids, in delivery order.
    private let ids = Mutex<[MailID]>([])

    /// The ids, in delivery order.
    var all: [MailID] {
        ids.withLock { $0 }
    }

    /// Whether the open answer carries the mail `id`.
    ///
    /// - Parameter id: The id of a mail.
    /// - Returns: `true` when the id is in the open answer.
    func contains(_ id: MailID) -> Bool {
        ids.withLock { $0.contains(id) }
    }

    /// Adds `delivered` at the end, in order.
    ///
    /// - Parameter delivered: The ids of the mail that the answer delivers.
    func append(_ delivered: [MailID]) {
        ids.withLock { $0 += delivered }
    }

    /// Removes each id of `given` back to the queue.
    ///
    /// - Parameter given: The ids of the mail that a failed submission gave
    ///   back.
    func remove(_ given: [MailID]) {
        let given = Set(given)
        ids.withLock { $0.removeAll { given.contains($0) } }
    }

    /// Removes every id. The pump calls it after the terminal event of the
    /// answer. The next answer starts not silenced.
    func removeAll() {
        ids.withLock { $0.removeAll() }
        silenced.withLock { $0 = false }
    }

    /// Whether ``RoutedSession/cancelAll()`` stopped the open answer.
    private let silenced = Mutex(false)

    /// Whether the open answer is the answer that
    /// ``RoutedSession/cancelAll()`` stopped. Its output is dropped. A
    /// requeue and a join of that answer do nothing.
    var isSilenced: Bool {
        silenced.withLock { $0 }
    }

    /// Marks the open answer as the answer that ``RoutedSession/cancelAll()``
    /// stopped. Its output is dropped. A requeue and a join of that answer do
    /// nothing.
    func silence() {
        silenced.withLock { $0 = true }
    }
}

/// ``RoutedSessionActor``'s signals (`mailbox.md`, section 5): the cancel of
/// one queued mail, the stop of all work, and the replace of one queued
/// mail. Each signal call makes a ``SignalID``, gives the work of the signal
/// to ``signals``, and returns the id at once. The work of each signal is one
/// internal function (``performCancel(_:)``, ``performCancelAll()``,
/// ``performReplace(_:with:)``), and each signal ends with its terminal event
/// ``SessionEvent/signalDone(_:)``, after all its other events.
///
/// ``compact(prompt:budget:)`` is one more signal of the session. Its work is
/// in `RoutedSessionActorCompaction.swift`, and its terminal event is
/// ``SessionEvent/compaction(_:)`` or ``SessionEvent/compactionFailed(_:)``,
/// not ``SessionEvent/signalDone(_:)``.
extension RoutedSessionActor {
    /// See ``RoutedSession/cancel(_:)``.
    ///
    /// - Parameter id: The id of the mail.
    /// - Returns: The id of the signal.
    @discardableResult
    nonisolated func cancel(_ id: MailID) -> SignalID {
        runSignal { session in session.performCancel(id) }
    }

    /// The work of one signal on this actor: `work` with the session that
    /// runs it, isolated to that session.
    typealias SignalWork = @Sendable (isolated RoutedSessionActor) async -> Void

    /// Gives the work of the signal `id` to ``signals``. Each signal call
    /// (``cancel(_:)``, ``cancelAll()``, ``replace(_:with:)``,
    /// ``compact(prompt:budget:)``, and the automatic compaction of an
    /// answer) comes here, so its work comes to this actor only through
    /// ``runSignalWork(_:skipped:)``.
    ///
    /// The id is pending in the output (``SessionOutputHub/beginPending(_:)``)
    /// before the signal call returns it, so a wait for the id waits while
    /// the work of the signal waits or runs. The terminal event that the work
    /// sends ends the pending record. When the work ends, the record ends in
    /// any case (``SessionOutputHub/endPending(_:)``): an automatic
    /// compaction whose answer stopped before it started sends no event, and
    /// its id must not stay pending. A signal that the close skips stays
    /// pending until the output closes, so a wait for it ends with
    /// ``MailRefusal/closed``.
    ///
    /// - Parameters:
    ///   - id: The id of the signal.
    ///   - work: The work of the signal.
    ///   - skipped: What runs in place of `work` when the session closed
    ///     before the work started. The default does nothing.
    nonisolated func submitSignal(
        _ id: SignalID, _ work: @escaping SignalWork, skipped: @escaping @Sendable () -> Void = {}
    ) {
        let key = SessionOutputHub.TerminalKey.signal(id.description)
        outputHub.beginPending(key)
        let pendingWork: SignalWork = { session in
            await work(session)
            session.outputHub.endPending(key)
        }
        signals.run(id, { [self] in await runSignalWork(pendingWork, skipped: skipped) }, skipped: skipped)
    }

    /// The one entry of the work of each signal into this actor.
    ///
    /// The task of a signal reads the close of ``signals`` before it comes
    /// to this actor, so the work can come here after ``close()`` began.
    /// This function checks ``isClosed`` on the actor, and starts `work`
    /// with no suspension point after the check. ``close()`` sets
    /// ``isClosed`` before its first suspension point. Thus the work of a
    /// signal starts before close began, or it does not start: then it
    /// sends no event, `skipped` runs, and a wait for the terminal event of
    /// the signal ends with ``MailRefusal/closed``.
    ///
    /// - Parameters:
    ///   - work: The work of the signal.
    ///   - skipped: What runs in place of `work` when the session is closed.
    func runSignalWork(_ work: SignalWork, skipped: @Sendable () -> Void) async {
        guard !isClosed else {
            skipped()
            return
        }
        await work(self)
    }

    /// The work of a signal whose terminal event is
    /// ``SessionEvent/signalDone(_:)``: `work`, and then that event.
    ///
    /// - Parameters:
    ///   - id: The id of the signal.
    ///   - work: What the signal does before its terminal event.
    /// - Returns: The work of the signal.
    static func endingWithSignalDone(_ id: SignalID, _ work: @escaping SignalWork) -> SignalWork {
        { session in
            await work(session)
            session.emitSessionScopedEvent(.signalDone(id))
        }
    }

    /// See ``RoutedSession/cancelAll()``.
    ///
    /// - Returns: The id of the signal.
    @discardableResult
    nonisolated func cancelAll() -> SignalID {
        runSignal { session in await session.performCancelAll() }
    }

    /// See ``RoutedSession/replace(_:with:)``.
    ///
    /// - Parameters:
    ///   - id: The id of the mail.
    ///   - body: The new body.
    /// - Returns: The id of the signal.
    @discardableResult
    nonisolated func replace(_ id: MailID, with body: MailBody) -> SignalID {
        runSignal { session in session.performReplace(id, with: body) }
    }

    /// Makes a new signal id, gives `work` and then the terminal event
    /// ``SessionEvent/signalDone(_:)`` to ``signals``
    /// (``submitSignal(_:_:skipped:)``), and returns the id at once.
    ///
    /// - Parameter work: The work of the signal.
    /// - Returns: The id of the signal.
    private nonisolated func runSignal(_ work: @escaping SignalWork) -> SignalID {
        let id = SignalID()
        submitSignal(id, Self.endingWithSignalDone(id, work))
        return id
    }

    /// The work of the signal ``cancel(_:)``: removes the queued mail `id`
    /// and sends its terminal event ``SessionEvent/cancelled(_:)``, with the
    /// origin of the signal. Mail that is not queued (delivered or unknown)
    /// does not change: then the signal sends only its own end.
    ///
    /// - Parameter id: The id of the mail.
    nonisolated func performCancel(_ id: MailID) {
        guard outbox.queue.cancel(id) != nil else { return }
        settleCancelledMail([id])
    }

    /// The work of the signal ``replace(_:with:)``: changes the body of one
    /// queued mail. The id, the sender and the place in the queue do not
    /// change. The transcript records the new body
    /// (``MailRecord/replaced(_:body:)``), and the pump wakes, because the new
    /// body can start an answer. Mail that is not queued does not change.
    ///
    /// - Parameters:
    ///   - id: The id of the mail.
    ///   - body: The new body.
    func performReplace(_ id: MailID, with body: MailBody) {
        guard outbox.queue.replace(id, with: body) else { return }
        recordMail([.replaced(id, body: body)])
        wakePump()
    }

    /// Sends the terminal event ``SessionEvent/cancelled(_:)`` of each mail
    /// of `ids`, which left the queue for good with no delivery, and forgets
    /// its hold and its caller context.
    ///
    /// - Parameter ids: The ids of the mail, in queue order.
    nonisolated func settleCancelledMail(_ ids: [MailID]) {
        guard !ids.isEmpty else { return }
        outbox.forget(ids)
        emitCancelled(ids)
    }

    /// Cancels each queued mail of all kinds, also run mail. Each mail gets
    /// its terminal event ``SessionEvent/cancelled(_:)``.
    ///
    /// This is the one place where queued mail of all kinds, also run mail,
    /// leaves the queue for a stop of all work. ``cancelAll()`` calls it. It
    /// uses ``MailQueue/drain()``, which does not change the pause of the
    /// queue. It also cancels run mail, not only user-type mail, because
    /// ``cancelAll()`` stops all work and sweeps the runs that sent the run
    /// mail, so a later answer must not act on their results (`mailbox.md`,
    /// section 5). To change that rule, change only this function.
    ///
    /// - Returns: The ids of the cancelled mail, in queue order.
    @discardableResult
    nonisolated func cancelQueuedMail() -> [MailID] {
        let ids = outbox.queue.drain().map(\.id)
        settleCancelledMail(ids)
        return ids
    }

    /// Records a cancel of the work the pump runs, and cancels its model
    /// call. A model call that waits for the worker of the model leaves the
    /// queue at once; a running one gets the cancel on the task that runs it.
    /// A cancel that lands between two model calls of the work stops the
    /// next one before it starts (``isWorkCancelled``). Only ``cancelAll()``
    /// and ``close()`` call it: a cancel of one mail never stops the work.
    /// It never reaches a running compaction: a compaction is signal work,
    /// and its summarizer call is not ``inFlightModelCall``.
    ///
    /// The stop is a change of ``stateChanges``.
    ///
    /// - Returns: `true` when the pump ran work.
    @discardableResult
    func requestCancelOfRunningWork() -> Bool {
        guard let workId = pumpWork?.id else { return false }
        cancelRequestedWorkId = workId
        inFlightModelCall?.cancel()
        stateChanges.signal()
        return true
    }
}
