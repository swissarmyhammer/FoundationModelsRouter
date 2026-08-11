/// ``RoutedSessionActor``'s turn gating: the turn lock one turn at a time holds,
/// the cancellation a client lands on the turn in flight, and the generation
/// permit a wait on a person hands back for the duration of that wait.
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
    /// ``currentTurnId`` — set for exactly as long as a turn holds ``turnLock``
    /// — is what "a turn is in flight" means here, so this reports honestly for a
    /// session with nothing running and for one whose next turn is still parked
    /// on the lock. The request is recorded *and* the outstanding model call
    /// cancelled, rather than one or the other: the task covers a turn that is
    /// generating right now, and the recorded id covers a turn that is between
    /// model calls (see ``cancelRequestedTurnId``).
    @discardableResult
    func cancelCurrentTurn() -> TurnCancellationResult {
        guard let turnId = currentTurnId else { return .noTurnInFlight }
        cancelRequestedTurnId = turnId
        inFlightModelCall?.cancel()
        return .requested
    }

    /// Acquires both of a turn's gates: this session's ``turnLock`` first, then
    /// a ``generationGate`` permit.
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
    func beginTurn() async {
        await turnLock.wait()
        lastTurnId += 1
        currentTurnId = lastTurnId
        await attachOutboxJournalIfNeeded()
        await acquireGenerationPermit()
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
    func endTurn() {
        currentTurnId = nil
        // The request only ever applied to the turn now ending, and turn ids are
        // monotonic, so this is belt-and-braces rather than load-bearing — but it
        // keeps "is a cancellation outstanding?" answerable without also knowing
        // which turn is in flight.
        cancelRequestedTurnId = nil
        if holdsGenerationPermit {
            releaseGenerationPermit()
        }
        turnLock.signal()
    }

    /// Takes a ``generationGate`` permit and records that this session holds it.
    private func acquireGenerationPermit() async {
        await generationGate.wait()
        holdsGenerationPermit = true
    }

    /// Hands this session's ``generationGate`` permit back.
    private func releaseGenerationPermit() {
        holdsGenerationPermit = false
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
