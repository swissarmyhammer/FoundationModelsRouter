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
extension RoutedSessionActor {
    /// See ``RoutedSession/cancel(_:)``.
    ///
    /// - Parameter id: The id of the mail.
    /// - Returns: The id of the signal.
    @discardableResult
    nonisolated func cancel(_ id: MailID) -> SignalID {
        runSignal { session in session.performCancel(id) }
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
        runSignal { session in await session.performReplace(id, with: body) }
    }

    /// Makes a new signal id, gives `work` and then the terminal event
    /// ``SessionEvent/signalDone(_:)`` to ``signals``, and returns the id at
    /// once.
    ///
    /// - Parameter work: The work of the signal.
    /// - Returns: The id of the signal.
    private nonisolated func runSignal(
        _ work: @escaping @Sendable (RoutedSessionActor) async -> Void
    ) -> SignalID {
        let id = SignalID()
        signals.run(id) { [self] in
            await work(self)
            emitSessionScopedEvent(.signalDone(id))
        }
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
    /// change. The pump wakes, because the new body can start an answer.
    /// Mail that is not queued does not change.
    ///
    /// - Parameters:
    ///   - id: The id of the mail.
    ///   - body: The new body.
    func performReplace(_ id: MailID, with body: MailBody) {
        guard outbox.queue.replace(id, with: body) else { return }
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
    ///
    /// A pump that waits in ``compactionRequests`` for a request
    /// (``pumpAwaitsCompaction``) runs no work: the compaction that its next
    /// request starts is not cancelled.
    ///
    /// - Returns: `true` when the pump ran work.
    @discardableResult
    func requestCancelOfRunningWork() -> Bool {
        guard !pumpAwaitsCompaction, let workId = pumpWork?.id else { return false }
        cancelRequestedWorkId = workId
        inFlightModelCall?.cancel()
        return true
    }

    // MARK: - Caller compactions

    /// Waits for `answer`, the answer of the caller compaction `id` that the
    /// caller just posted to ``compactionRequests``. A cancel of the caller
    /// cancels the compaction at once (``cancelCompactionFromCallerTask(_:)``).
    ///
    /// The caller posts the request and calls this with no suspension point
    /// between the two, and this installs the cancel handler before its
    /// first suspension point. The pump takes a request only on this actor,
    /// so the pump cannot take it before the handler is in place.
    ///
    /// - Parameters:
    ///   - id: The id that ``compactionRequests`` gave the request.
    ///   - answer: The answer that ``compactionRequests`` gave the request.
    /// - Returns: The result of the compaction.
    /// - Throws: What the compaction throws, or `CancellationError`.
    func awaitCompactionAnswer(
        id: FoundationModelsExtras.MessageID, answer: MailboxAnswer<CompactionResult>
    ) async throws -> CompactionResult {
        try await withTaskCancellationHandler {
            try await answer.value
        } onCancel: {
            cancelCompactionFromCallerTask(id)
        }
    }

    /// Cancels the caller compaction `id` from the cancellation handler of a
    /// caller task, which does not run on this actor. A waiting request is
    /// withdrawn at once. The rest needs this actor, so it runs in a task of
    /// its own: a pump that waits for the withdrawn request is released, and
    /// a running compaction is stopped.
    ///
    /// - Parameter id: The id that ``compactionRequests`` gave the request.
    nonisolated func cancelCompactionFromCallerTask(_ id: FoundationModelsExtras.MessageID) {
        let result: MessageCancellationResult =
            compactionRequests.depth.running.contains(id) ? .cancelledInSubmission : compactionRequests.cancel(id)
        guard result != .alreadyAnswered else { return }
        Task { await self.settleCompactionCancel(of: id, result) }
    }

    /// The second half of a cancel of the caller compaction `id`, after the
    /// first half gave `result`.
    ///
    /// - ``MessageCancellationResult/withdrawn``: the pump can wait for that
    ///   request, so it is released (``releasePumpAwaitingCompaction()``).
    /// - ``MessageCancellationResult/cancelledInSubmission``: the compaction
    ///   is stopped (``requestCancelOfRunningWork()``) when it still runs.
    /// - ``MessageCancellationResult/alreadyAnswered``: nothing to do.
    ///
    /// - Parameters:
    ///   - id: The id of the compaction request.
    ///   - result: What the first half did.
    private func settleCompactionCancel(
        of id: FoundationModelsExtras.MessageID, _ result: MessageCancellationResult
    ) {
        switch result {
        case .withdrawn:
            releasePumpAwaitingCompaction()
        case .cancelledInSubmission:
            guard case .compaction(id) = pumpWork?.kind else { return }
            requestCancelOfRunningWork()
        case .alreadyAnswered:
            return
        }
    }
}
