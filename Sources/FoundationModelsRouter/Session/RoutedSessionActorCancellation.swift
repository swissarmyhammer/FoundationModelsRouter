/// ``RoutedSessionActor``'s cancellation: the cancel of the work the pump
/// runs, the withdrawal of the caller messages that wait, and the wait on a
/// person inside a tool body (`generation-queue.md`, section 5.6).
extension RoutedSessionActor {
    /// See ``RoutedSession/awaitingUser(_:)``. Runs `body` and takes or
    /// releases nothing for it. Inside a tool body, the submission of that
    /// tool body keeps the worker of the model for the whole wait.
    func awaitingUser<T: Sendable>(_ body: @Sendable () async throws -> T) async rethrows -> T {
        try await body()
    }

    /// See ``RoutedSession/cancelCurrentTurn()``. Stops the work the pump
    /// runs (``requestCancelOfRunningWork()``), and withdraws every caller
    /// message that waits in ``outbox``: each of their callers gets
    /// `CancellationError`. The mail stays in ``outbox`` for a later
    /// submission, because a run terminal must not be lost. It is held
    /// (``SessionOutbox/holdPendingMail()``): a cancel stops the session, so
    /// mail that waited does not start a submission of its own at once. It
    /// rides the next submission that new mail or a new message starts.
    ///
    /// - Returns: ``TurnCancellationResult/requested`` when work ran or a
    ///   caller message waited, and ``TurnCancellationResult/noTurnInFlight``
    ///   otherwise.
    @discardableResult
    func cancelCurrentTurn() async -> TurnCancellationResult {
        // The mail is held first, so the pump cannot deliver it between the
        // stop of the work and the hold.
        await outbox.holdPendingMail()
        let stoppedWork = requestCancelOfRunningWork()
        let withdrawn = await outbox.withdrawMessages()
        await resolve(withdrawn, with: .failure(CancellationError()), startedByMailOnly: false)
        return stoppedWork || !withdrawn.isEmpty ? .requested : .noTurnInFlight
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

    /// Cancels `message`, whose caller was cancelled: a message that waits
    /// leaves ``outbox`` and gets `CancellationError`; the answer that carries
    /// it is stopped.
    ///
    /// The caller marked the message before this call
    /// (``PumpAnswer/requestCancel()``). So a message that the pump takes
    /// while this call runs is still cancelled: the pump reads the mark when
    /// it makes the message part of its work.
    ///
    /// - Parameter message: The message of the cancelled caller.
    func cancel(message: SessionMessage) async {
        if let withdrawn = await outbox.withdrawMessage(id: message.id) {
            await resolve([withdrawn], with: .failure(CancellationError()), startedByMailOnly: false)
            return
        }
        guard case .answer(_, let messages) = pumpWork?.kind, messages.contains(where: { $0.id == message.id })
        else { return }
        requestCancelOfRunningWork()
    }
}
