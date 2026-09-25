/// ``RoutedSessionActor``'s turn gating: the turn lock, turn cancellation, and
/// the refusal of a turn that a tool of the same session's own turn asks for.
extension RoutedSessionActor {
    /// See ``RoutedSession/awaitingUser(_:)``. Runs `body` and takes or
    /// releases nothing for it. Inside a tool body, the submission of that
    /// tool body keeps the worker of the model for the whole wait.
    func awaitingUser<T: Sendable>(_ body: @Sendable () async throws -> T) async rethrows -> T {
        try await body()
    }

    /// See ``RoutedSession/cancelCurrentTurn()``. A turn is in flight when
    /// ``currentTurnId`` is set. The request is recorded and the outstanding
    /// model call is cancelled. With no turn in flight, a run-plane drain in
    /// progress is cancelled instead.
    @discardableResult
    func cancelCurrentTurn() -> TurnCancellationResult {
        guard let turnId = currentTurnId else {
            guard runPlaneDrainCount > 0 else { return .noTurnInFlight }
            cancelRequestCount += 1
            endRunPlaneDrainWaits()
            return .requested
        }
        cancelRequestedTurnId = turnId
        // The monotonic count outlives this turn, so a caller whose work spans
        // the turn's end — ``respond(to:maxTokens:)``'s run-plane drain — can
        // still tell that this request landed. See ``cancelRequestCount``.
        cancelRequestCount += 1
        inFlightModelCall?.cancel()
        return .requested
    }

    /// Admits a turn through ``turnLock``, which the turn keeps until its
    /// ``endTurn()``. The turn submits nothing here: each model call of the
    /// turn is one submission to the model's ``GenerationQueue``.
    ///
    /// - Returns: The identity of the turn that just began. See ``TurnID``.
    /// - Throws: ``SessionReentryError/sameSessionTurnInFlight(sessionID:)``
    ///   when this call came from inside a tool of this session's own turn,
    ///   or ``GenerationQueueError/waitInsideOpenSubmission(model:)`` when it
    ///   came from an in-band tool body of a submission on the queue of this
    ///   session's model. That turn could run only after the submission of the
    ///   tool body ends, so the refusal comes before the wait for the turn
    ///   lock.
    @discardableResult
    func beginTurn() async throws -> TurnID {
        try refuseReentryOntoThisSession()
        try backend.generationQueue?.refuseWaitInsideOpenSubmission()
        await turnLock.wait()
        await attachOutboxJournalIfNeeded()
        // Minted once this turn holds the turn lock. A submission of this turn
        // that then waits for the worker of the queue thus belongs to a turn
        // with an identity, and ``cancelCurrentTurn()`` cancels
        // ``inFlightModelCall``, which removes that submission at once.
        lastTurnId += 1
        currentTurnId = lastTurnId
        // A new turn may compact inside the turn again, at a tool result or
        // at a ceiling stop, whatever the last turn's compaction did (see
        // ``compactionYieldsStopped``).
        compactionYieldsStopped = false
        // Each turn has its own count of recoveries after a repetition stop
        // (see ``RepetitionDetection/recoveriesPerTurn``).
        repetitionWatch.recoveriesThisTurn = 0
        return TurnID(lastTurnId)
    }

    /// Refuses a turn asked for from a task of a model call of this session:
    /// a tool of this session's own turn, or a background run that such a
    /// tool started. See ``ModelCallMark``.
    ///
    /// - Throws: ``SessionReentryError/sameSessionTurnInFlight(sessionID:)``.
    private func refuseReentryOntoThisSession() throws {
        guard let mark = ModelCallMark.current, mark.sessionID == id else { return }
        throw SessionReentryError.sameSessionTurnInFlight(sessionID: id)
    }

    /// Whether this call arrived from inside a tool call of this session's own
    /// turn, which holds ``turnLock``: a task of the open model call of this
    /// session. Every site that would take the lock asks this first. See
    /// ``ModelCallMark/isOpenModelCall(of:)``.
    nonisolated var isInsideOwnTurnToolCall: Bool {
        ModelCallMark.current?.isOpenModelCall(of: id) ?? false
    }

    /// Releases the ``turnLock`` that ``beginTurn()`` took. Synchronous, so it
    /// can run from a `defer`.
    func endTurn() {
        currentTurnId = nil
        // The request only ever applied to the turn now ending, and turn ids are
        // monotonic, so this is belt-and-braces rather than load-bearing — but it
        // keeps "is a cancellation outstanding?" answerable without also knowing
        // which turn is in flight.
        cancelRequestedTurnId = nil
        turnLock.signal()
    }
}
