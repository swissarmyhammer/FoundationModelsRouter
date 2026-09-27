import FoundationModelsExtras
import Synchronization

/// The cancel marks of the messages and the caller compactions that the
/// running work of a session carries (``RoutedSessionActor/cancelMarks``).
///
/// A cancel of such an item does not take it out of its mailbox: the work
/// stops cooperatively, and the item gets the result of its work, as each
/// other item of the work does. The mark tells the work of the cancel at
/// once. The stop of the work needs the session actor, and the pump can get
/// the actor first (``RoutedSessionActor/isWorkCancelled``). The set is
/// behind a lock, so the cancellation handler of a caller task, which does
/// not run on the actor, writes it with no suspension point.
final class CancelMarks: Sendable {
    /// The ids of the marked items.
    private let ids = Mutex<Set<MessageID>>([])

    /// Marks the item `id`.
    ///
    /// - Parameter id: The id of the message or of the compaction request.
    func mark(_ id: MessageID) {
        _ = ids.withLock { $0.insert(id) }
    }

    /// Whether the item `id` is marked.
    ///
    /// - Parameter id: The id of the message or of the compaction request.
    /// - Returns: `true` when a mark names it.
    func isMarked(_ id: MessageID) -> Bool {
        ids.withLock { $0.contains(id) }
    }

    /// Whether one of `items` is marked.
    ///
    /// - Parameter items: The ids to look for.
    /// - Returns: `true` when a mark names one of them.
    func marksAny(of items: [MessageID]) -> Bool {
        ids.withLock { marked in items.contains { marked.contains($0) } }
    }

    /// Removes every mark. The pump calls this when a work ends: a mark
    /// names an item of the work that ran, so no later work reads it.
    func clear() {
        ids.withLock { $0.removeAll() }
    }
}

/// ``RoutedSessionActor``'s cancellation: the cancel of the work the pump
/// runs, and the withdrawal of the caller messages that wait
/// (`generation-queue.md`, section 5.6).
extension RoutedSessionActor {
    /// See ``RoutedSession/cancel()``. Stops the work the pump runs
    /// (``requestCancelOfRunningWork()``), and withdraws every caller
    /// message that waits in ``SessionOutbox/messages``: each of their
    /// callers gets `CancellationError`. The mail stays in ``outbox`` for a
    /// later submission, because a run terminal must not be lost. It is held
    /// (``SessionOutbox/holdPendingMail()``): a cancel stops the session, so
    /// mail that waited does not start a submission of its own at once. It
    /// rides the next submission that new mail or a new message starts.
    ///
    /// - Returns: ``CancellationResult/requested`` when work ran or a caller
    ///   message waited, and ``CancellationResult/nothingToCancel`` otherwise.
    @discardableResult
    func cancel() async -> CancellationResult {
        // The mail is held first, so the pump cannot deliver it between the
        // stop of the work and the hold.
        await outbox.holdPendingMail()
        let stoppedWork = requestCancelOfRunningWork()
        let withdrawn = outbox.withdrawMessages()
        releasePumpAwaitingLetter()
        return stoppedWork || !withdrawn.isEmpty ? .requested : .nothingToCancel
    }

    /// Records a cancel of the work the pump runs, and cancels its model
    /// call. A model call that waits for the worker of the model leaves the
    /// queue at once; a running one gets the cancel on the task that runs it.
    /// A cancel that lands between two model calls of the work stops the
    /// next one before it starts (``isWorkCancelled``).
    ///
    /// A pump that waits in a mailbox for a letter (``pumpAwaitsLetter``)
    /// runs no work: the answer that its next letter starts is not cancelled.
    ///
    /// - Returns: `true` when the pump ran work.
    @discardableResult
    func requestCancelOfRunningWork() -> Bool {
        guard !pumpAwaitsLetter, let workId = pumpWork?.id else { return false }
        cancelRequestedWorkId = workId
        inFlightModelCall?.cancel()
        return true
    }

    /// See ``RoutedSession/cancel(message:)``. A message that waits leaves
    /// the mailbox ``SessionOutbox/messages``, and its caller gets
    /// `CancellationError`. A message that the running answer carries stops
    /// that answer, and its caller gets the result of the answer
    /// (``requestCancel(of:in:)``, ``settleCancel(of:_:)``).
    ///
    /// - Parameter id: The id of the message.
    /// - Returns: What happened to the message.
    @discardableResult
    func cancel(message id: MessageID) async -> MessageCancellationResult {
        let result = requestCancel(of: id, in: outbox.messages)
        settleCancel(of: id, result)
        return result
    }

    /// Cancels the message or the caller compaction `id` from the
    /// cancellation handler of a caller task, which does not run on this
    /// actor. The first half occurs at once (``requestCancel(of:in:)``). The
    /// second half (``settleCancel(of:_:)``) needs this actor, so it runs in
    /// a task of its own.
    ///
    /// - Parameters:
    ///   - id: The id that `mailbox` gave the message.
    ///   - mailbox: ``SessionOutbox/messages`` or ``compactionRequests``.
    nonisolated func cancelFromCallerTask<Message: Sendable, Answer: Sendable>(
        _ id: MessageID, in mailbox: FoundationModelsExtras.Mailbox<Message, Answer>
    ) {
        let result = requestCancel(of: id, in: mailbox)
        guard result != .alreadyAnswered else { return }
        Task { await self.settleCancel(of: id, result) }
    }

    /// The first half of a cancel of the message or the caller compaction
    /// `id`, with no suspension point. It needs no actor.
    ///
    /// An item that the running batch of `mailbox` carries keeps its place in
    /// the batch: it gets the result of its work, which stops cooperatively.
    /// The item gets a mark (``cancelMarks``), so ``isWorkCancelled`` sees the
    /// cancel before the stop reaches the actor. Any other item is cancelled
    /// in `mailbox` in one lock step: it is withdrawn when it waits. When the
    /// pump took it between the two reads, the mailbox takes it out of the
    /// batch, and the item gets a mark too.
    ///
    /// - Parameters:
    ///   - id: The id that `mailbox` gave the item.
    ///   - mailbox: ``SessionOutbox/messages`` or ``compactionRequests``.
    /// - Returns: What happened to the item.
    nonisolated func requestCancel<Message: Sendable, Answer: Sendable>(
        of id: MessageID, in mailbox: FoundationModelsExtras.Mailbox<Message, Answer>
    ) -> MessageCancellationResult {
        let result = mailbox.depth.running.contains(id) ? .cancelledInSubmission : mailbox.cancel(id)
        if result == .cancelledInSubmission {
            cancelMarks.mark(id)
        }
        return result
    }

    /// The second half of a cancel of the message or the caller compaction
    /// `id`, after ``requestCancel(of:in:)`` gave `result`.
    ///
    /// - ``MessageCancellationResult/withdrawn``: the pump can wait for that
    ///   letter, so it is released (``releasePumpAwaitingLetter()``).
    /// - ``MessageCancellationResult/cancelledInSubmission``: the work that
    ///   carries `id` is stopped (``requestCancelOfRunningWork()``). The
    ///   mailbox does not stop the work itself. The work can have ended
    ///   before this call; then no work carries `id`, and nothing stops.
    /// - ``MessageCancellationResult/alreadyAnswered``: nothing to do.
    ///
    /// - Parameters:
    ///   - id: The id of the message or of the compaction request.
    ///   - result: What the first half did.
    func settleCancel(of id: MessageID, _ result: MessageCancellationResult) {
        switch result {
        case .withdrawn:
            releasePumpAwaitingLetter()
        case .cancelledInSubmission:
            guard runningWorkCarries(id) else { return }
            requestCancelOfRunningWork()
        case .alreadyAnswered:
            return
        }
    }
}
