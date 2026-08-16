/// ``RoutedSessionActor``'s turn gating: the turn lock one turn at a time holds,
/// the cancellation a client lands on the turn in flight, the generation permit
/// a wait on a person hands back for the duration of that wait, and the same
/// permit a turn lends to a turn started from inside one of its tool calls.
extension RoutedSessionActor {
    /// See ``RoutedSession/awaitingUser(_:)``.
    ///
    /// Hands the generation permit back around `body` and re-acquires it on
    /// every exit — normal return, throw, or cancellation — so the pairing holds
    /// whatever `body` does; ``AsyncSemaphore/wait()`` is non-throwing and
    /// completes even for a cancelled task, so a cancelled human wait still
    /// leaves the gate counts balanced. `body` runs with this actor reentrant
    /// (it suspends at its own awaits, exactly as the model call it was invoked
    /// from does), which is what lets a second turn arrive and park on
    /// ``turnLock`` while a person is being waited on.
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

    /// See ``RoutedSession/cancelCurrentTurn()``.
    ///
    /// Synchronous here even though the protocol declares it `async`, exactly
    /// like ``contextFill``: it runs on this actor's own executor and touches
    /// only actor-isolated state, so every call from outside still crosses
    /// isolation through an implicit `await` at the call site.
    ///
    /// ``currentTurnId`` — set from the moment a turn is through *both* of its
    /// gates until it ends — is what "a turn is in flight" means here, so this
    /// reports honestly for a session with nothing running, for one whose next
    /// turn is still parked on the turn lock, and for one still waiting on a
    /// generation permit. That last case used to answer
    /// ``TurnCancellationResult/requested`` and then cancel a model call that
    /// did not exist yet: a cancellation the caller believed had landed and
    /// which did nothing at all. The request is recorded *and* the outstanding model call
    /// cancelled, rather than one or the other: the task covers a turn that is
    /// generating right now, and the recorded id covers a turn that is between
    /// model calls (see ``cancelRequestedTurnId``).
    ///
    /// A turn is not the only thing a caller can be waiting on, though.
    /// ``respond(to:maxTokens:)`` drains the run plane *between* its turns, so a
    /// call can be suspended on a parked run with `currentTurnId` already `nil`
    /// — nothing to cancel, and a caller with no way out (task ^h3efdrc). That
    /// drain is what this reaches when no turn is in flight: ``runPlaneDrainCount``
    /// says such a call exists, the request is counted so the drain's own checks
    /// see it, and every wait already parked is resumed
    /// (``endRunPlaneDrainWaits()``) rather than left to the run plane's day-long
    /// ceiling. Only when there is no turn *and* no drain is there nothing to
    /// cancel.
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

    /// Admits a turn through both of its gates: this session's ``turnLock``
    /// first, then the ``generationGate`` — on a permit of its own, or on the
    /// one an enclosing turn lends it (see ``admitToGenerationGate()``).
    ///
    /// Always in that order, and never the reverse: every other holder of the
    /// turn lock (``fork(workingDirectory:)``) takes it without ever wanting the
    /// generation gate, so a single acquisition order is what keeps the pair
    /// deadlock-free. Paired with exactly one ``endTurn()``.
    ///
    /// Also where this session installs itself as ``outbox``'s run journal
    /// (``attachOutboxJournalIfNeeded()``): both turn entry points reach here,
    /// and a tool is only ever invoked from inside a turn's model call, so
    /// every event a run of this session posts is journaled the moment it is
    /// posted.
    ///
    /// - Returns: The identity of the turn that just began — the same monotonic
    ///   id ``currentTurnId`` now holds, handed back so a caller can correlate
    ///   what the turn produces without re-reading actor state after an
    ///   `await`. See ``TurnID``.
    /// - Throws: ``SessionReentryError/sameSessionTurnInFlight(sessionID:)``
    ///   when this call came from inside a tool of this same session's own turn
    ///   — refused before either gate is touched, so nothing is acquired and
    ///   nothing has to be unwound.
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
    /// ``turnLock`` is not lent to anybody: it is what keeps one session's
    /// transcript written by one turn at a time, and a turn started from inside
    /// the turn that holds it would simply park on it and never come back.
    /// ``GenerationPermitLoan`` is only published to a turn's own model call, so
    /// finding one that names this session is exactly "this session is already
    /// mid-turn, on this very task".
    ///
    /// - Throws: ``SessionReentryError/sameSessionTurnInFlight(sessionID:)``.
    private func refuseReentryOntoThisSession() throws {
        guard let loan = GenerationPermitLoan.current, loan.sessionID == id else { return }
        throw SessionReentryError.sameSessionTurnInFlight(sessionID: id)
    }

    /// Releases what ``beginTurn()`` acquired, innermost first.
    ///
    /// Synchronous, so it can run from a `defer` on every exit path a turn has.
    ///
    /// A turn whose own tool waited on a person always arrives here holding its
    /// permit again — ``endHumanWait()`` re-acquires before `body`'s caller
    /// resumes, on the throwing path as much as the returning one. A wait that
    /// broke ``RoutedSession/awaitingUser(_:)``'s precondition can nonetheless
    /// have taken this turn's permit and still be outstanding (it was started
    /// from outside the turn, or outlives the tool call). Signalling anyway would
    /// return a permit *twice* for one acquisition, and `AsyncSemaphore` has no
    /// ceiling to absorb that: the gate would admit two concurrent generations
    /// and stay inflated. So the permit is released only if this turn still holds
    /// it; clearing ``currentTurnId`` is what tells the outstanding wait, when it
    /// finally gets a permit, that its lender is gone and the permit is not its
    /// to keep.
    ///
    /// A turn that ran on a *borrowed* permit (``borrowsGenerationPermit``)
    /// signals nothing at all: it never took one, and the turn it borrowed from
    /// still holds the only one there is. See ``GenerationPermitLoan``.
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

    /// Admits a turn that is starting to the ``generationGate``: on the permit
    /// an enclosing turn already holds when there is one to borrow, otherwise on
    /// one of its own.
    ///
    /// The borrow is what lets a tool body generate on a second session over one
    /// resident container. It takes no permit and returns none, so the gate's
    /// count is untouched by the whole nested turn. See
    /// ``GenerationPermitLoan`` for the two conditions a loan has to meet, and
    /// for the one window this does not close.
    private func admitToGenerationGate() async {
        if let loan = GenerationPermitLoan.current, loan.lends(generationGate) {
            borrowsGenerationPermit = true
            return
        }
        await acquireGenerationPermit()
    }

    /// Takes a ``generationGate`` permit and records that this session holds it.
    ///
    /// Also tells the model call in flight, if there is one, that its turn is
    /// holding a permit again — the re-acquire at the end of a wait on a person
    /// reaches here, and until it lands the turn has nothing to lend.
    private func acquireGenerationPermit() async {
        await generationGate.wait()
        holdsGenerationPermit = true
        currentPermitLoan?.setHoldsPermit(true)
    }

    /// Hands this session's ``generationGate`` permit back.
    ///
    /// Also tells the model call in flight, if there is one, that its turn has
    /// no permit to lend while the permit is away.
    private func releaseGenerationPermit() {
        holdsGenerationPermit = false
        currentPermitLoan?.setHoldsPermit(false)
        generationGate.signal()
    }

    /// Enters a human wait, releasing the generation permit when this is the
    /// outermost one *and* a turn actually holds a permit to release.
    ///
    /// With no turn in flight there is no permit to give back, and signalling
    /// anyway would mint one this session never acquired — so it releases nothing
    /// and records no lender, which is what makes ``endHumanWait()`` symmetric.
    private func beginHumanWait() {
        humanWaitDepth += 1
        guard humanWaitDepth == 1 else { return }
        guard holdsGenerationPermit, let lender = currentTurnId else { return }
        humanWaitLenderTurnId = lender
        releaseGenerationPermit()
    }

    /// Leaves a human wait, re-acquiring the permit the outermost wait released
    /// and keeping it only if the turn that lent it is still the one in flight.
    ///
    /// The re-acquire is a real suspension point — it is a contended gate, that
    /// is the whole point — so this actor is reentrant across it and the lending
    /// turn can finish *inside* that window. Re-checking only before the acquire
    /// would then leave this session holding a permit no turn will ever release,
    /// parking every later turn on every session and fork over the model forever:
    /// worse than the drifted count the check exists to prevent. So the lender is
    /// re-validated after the acquire, and an orphaned permit is handed straight
    /// back to whoever is next in the gate's queue.
    ///
    /// The depth drops back to zero only after all of that, deliberately: a
    /// nested wait arriving mid-re-acquire would otherwise see depth `0`, mistake
    /// itself for the outermost one, and release a permit this session does not
    /// yet hold.
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
