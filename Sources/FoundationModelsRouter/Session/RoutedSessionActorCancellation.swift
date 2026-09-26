/// ``RoutedSessionActor``'s cancellation: the cancel of the work the pump
/// runs, and the withdrawal of the caller messages that wait
/// (`generation-queue.md`, section 5.6).
extension RoutedSessionActor {
    /// See ``RoutedSession/cancel()``. Stops the work the pump runs
    /// (``requestCancelOfRunningWork()``), and withdraws every caller
    /// message that waits in ``outbox``: each of their callers gets
    /// `CancellationError`. The mail stays in ``outbox`` for a later
    /// submission, because a run terminal must not be lost. It is held
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
        let withdrawn = await outbox.withdrawMessages()
        resolve(withdrawn, with: .failure(CancellationError()))
        return stoppedWork || !withdrawn.isEmpty ? .requested : .nothingToCancel
    }

    /// Records a cancel of the work the pump runs, and cancels its model
    /// call. A model call that waits for the worker of the model leaves the
    /// queue at once; a running one gets the cancel on the task that runs it.
    /// A cancel that lands between two model calls of the work stops the
    /// next one before it starts (``isWorkCancelled``).
    ///
    /// - Returns: `true` when the pump ran work.
    @discardableResult
    func requestCancelOfRunningWork() -> Bool {
        guard let workId = pumpWork?.id else { return false }
        cancelRequestedWorkId = workId
        inFlightModelCall?.cancel()
        return true
    }

    /// See ``RoutedSession/cancel(message:)``. A message that the running
    /// answer carries stops that answer. Any other open message is marked
    /// (``PumpAnswer/requestCancel()``) and withdrawn from ``outbox``.
    ///
    /// The check of the running answer and the mark happen with no suspension
    /// point between them, and the pump reads the mark with no suspension
    /// point before it makes a message part of its work (``liveMessages(_:)``). So a message
    /// that the pump takes while this call waits for ``outbox`` is dropped
    /// from the work with `CancellationError`, and never reaches a prompt.
    ///
    /// - Parameter id: The id of the message.
    /// - Returns: What happened to the message.
    @discardableResult
    func cancel(message id: MessageID) async -> MessageCancellationResult {
        guard let answer = openMessages[id] else { return .alreadyAnswered }
        if deliveredMessages?.contains(where: { $0.id == id }) == true {
            requestCancelOfRunningWork()
            return .cancelledInSubmission
        }
        answer.requestCancel()
        if let withdrawn = await outbox.withdrawMessage(id: id) {
            resolve([withdrawn], with: .failure(CancellationError()))
        }
        return .withdrawn
    }
}
