/// ``RoutedSessionActor``'s turn gating: the turn lock, turn cancellation, and
/// the refusal of a turn that a tool of the same session's own turn asks for.
extension RoutedSessionActor {
    /// See ``RoutedSession/awaitingUser(_:)``. Runs `body` and holds nothing
    /// for it: a turn holds a generation place only for each of its passes.
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
    /// ``endTurn()``. The turn takes no generation place here: each pass of
    /// the turn takes a place of the model's ``GenerationQueue`` for that pass
    /// only.
    ///
    /// - Returns: The identity of the turn that just began. See ``TurnID``.
    /// - Throws: ``SessionReentryError/sameSessionTurnInFlight(sessionID:)``
    ///   when this call came from inside a tool of this session's own turn.
    @discardableResult
    func beginTurn() async throws -> TurnID {
        try refuseReentryOntoThisSession()
        await turnLock.wait()
        await attachOutboxJournalIfNeeded()
        // Minted once this turn holds the turn lock. A pass of this turn that
        // then waits for a queue place thus belongs to a turn with an
        // identity, and ``cancelCurrentTurn()`` cancels ``inFlightModelCall``,
        // which ends that wait at once.
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

    /// Refuses a turn asked for from inside a tool of this session's own turn.
    ///
    /// - Throws: ``SessionReentryError/sameSessionTurnInFlight(sessionID:)``.
    private func refuseReentryOntoThisSession() throws {
        guard let loan = GenerationPermitLoan.current, loan.sessionID == id else { return }
        throw SessionReentryError.sameSessionTurnInFlight(sessionID: id)
    }

    /// Whether this call arrived from inside a tool call of this session's own
    /// turn, which holds ``turnLock``. Every site that would take the lock
    /// asks this first. See
    /// ``GenerationPermitLoan/isSuspendedInToolCall(ofSession:)``.
    nonisolated var isInsideOwnTurnToolCall: Bool {
        GenerationPermitLoan.current?.isSuspendedInToolCall(ofSession: id) ?? false
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
