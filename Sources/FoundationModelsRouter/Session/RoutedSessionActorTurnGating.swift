/// ``RoutedSessionActor``'s turn gating: the turn lock, turn cancellation,
/// the generation permit a human wait hands back, and the permit a turn lends
/// to a nested turn.
extension RoutedSessionActor {
    /// See ``RoutedSession/awaitingUser(_:)``. Hands the generation permit
    /// back around `body` and re-acquires it on every exit.
    func awaitingUser<T: Sendable>(_ body: @Sendable () async throws -> T) async rethrows -> T {
        beginHumanWait()
        do {
            let value = try await body()
            await endHumanWait()
            return value
        } catch {
            await endHumanWait()
            throw error
        }
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

    /// Admits a turn through both gates: ``turnLock`` first, then the
    /// ``generationGate``, always in that order. Paired with one ``endTurn()``.
    ///
    /// - Returns: The identity of the turn that just began. See ``TurnID``.
    /// - Throws: ``SessionReentryError/sameSessionTurnInFlight(sessionID:)``
    ///   when this call came from inside a tool of this session's own turn.
    @discardableResult
    func beginTurn() async throws -> TurnID {
        try refuseReentryOntoThisSession()
        await turnLock.wait()
        await attachOutboxJournalIfNeeded()
        await admitToGenerationGate()
        // Minted only once this turn is through both gates. A turn still
        // waiting for a permit has started nothing to cancel, and claiming an
        // identity before then made ``cancelCurrentTurn()`` answer
        // ``TurnCancellationResult/requested`` and then cancel a model call
        // that did not exist yet.
        lastTurnId += 1
        currentTurnId = lastTurnId
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

    /// Releases what ``beginTurn()`` acquired, innermost first. Synchronous,
    /// so it can run from a `defer`. The permit is released only if this turn
    /// still holds it; a turn on a borrowed permit signals nothing.
    func endTurn() {
        currentTurnId = nil
        // The request only ever applied to the turn now ending, and turn ids are
        // monotonic, so this is belt-and-braces rather than load-bearing — but it
        // keeps "is a cancellation outstanding?" answerable without also knowing
        // which turn is in flight.
        cancelRequestedTurnId = nil
        borrowsGenerationPermit = false
        if holdsGenerationPermit {
            releaseGenerationPermit()
        }
        turnLock.signal()
    }

    /// Admits a starting turn to the ``generationGate``: on a permit an
    /// enclosing turn lends, otherwise on one of its own. See
    /// ``GenerationPermitLoan``.
    private func admitToGenerationGate() async {
        if let loan = GenerationPermitLoan.current, loan.lends(over: generationGate) {
            borrowsGenerationPermit = true
            return
        }
        await acquireGenerationPermit()
    }

    /// Takes a ``generationGate`` permit and records that this session holds
    /// it. Also tells the model call in flight that its turn holds a permit.
    private func acquireGenerationPermit() async {
        await generationGate.wait()
        holdsGenerationPermit = true
        currentPermitLoan?.setHoldsPermit(to: true)
    }

    /// Hands this session's ``generationGate`` permit back. Also tells the
    /// model call in flight that its turn has no permit to lend.
    private func releaseGenerationPermit() {
        holdsGenerationPermit = false
        currentPermitLoan?.setHoldsPermit(to: false)
        generationGate.signal()
    }

    /// Enters a human wait. Releases the generation permit only when this is
    /// the outermost wait and a turn holds a permit.
    private func beginHumanWait() {
        humanWaitDepth += 1
        guard humanWaitDepth == 1 else { return }
        guard holdsGenerationPermit, let lender = currentTurnId else { return }
        humanWaitLenderTurnId = lender
        releaseGenerationPermit()
    }

    /// Leaves a human wait. Re-acquires the permit the outermost wait released
    /// and keeps it only if the lending turn is still in flight. The lender is
    /// checked after the acquire, and the depth drops only after that.
    private func endHumanWait() async {
        if humanWaitDepth == 1, let lender = humanWaitLenderTurnId {
            humanWaitLenderTurnId = nil
            await acquireGenerationPermit()
            if currentTurnId != lender {
                releaseGenerationPermit()
            }
        }
        humanWaitDepth -= 1
    }
}
