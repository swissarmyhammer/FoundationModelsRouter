import FoundationModelsExtras

/// A run that the host claimed at the restore of a session, and that has no
/// terminal event yet.
struct OpenClaim {
    /// The lease of the claim in the work registry. The session is not idle
    /// while the lease is open.
    let lease: BackgroundWork

    /// The `.lost` terminal that the restore did not post for this run. It
    /// gives the `op` and the detail of the lost terminal of the close.
    let lostTerminal: OperationEvent

    /// Whether a call of ``RoutedSessionActor/completeClaimedRun(_:outcome:detail:)``
    /// took this claim and has not yet journaled the terminal event. A
    /// second call finds the claim and does nothing. A close that comes in
    /// this time still finds the claim, so it ends the run as `.lost` when
    /// the terminal of the call is not in the journal.
    var isCompleting = false
}

/// ``RoutedSessionActor``'s claimed runs: orphan runs that the host took at
/// the restore, so the restore did not end them as `.lost`.
extension RoutedSessionActor {
    /// Holds a claim for each of `lostTerminals`, and holds one work lease
    /// (`WorkKind.claimedRun`) for each. The restore calls it once, before
    /// the session goes to the host.
    ///
    /// - Parameter lostTerminals: The `.lost` terminal that the restore did
    ///   not post for each claimed run.
    func holdClaims(for lostTerminals: [OperationEvent]) {
        for terminal in lostTerminals {
            let key = RunKey(tool: terminal.tool, correlationID: terminal.correlationID)
            openClaims[key] = OpenClaim(
                lease: beginWork(.claimedRun, id: "\(key.tool)/\(key.correlationID)"), lostTerminal: terminal)
        }
    }

    /// See ``RoutedSession/completeClaimedRun(_:outcome:detail:)``.
    ///
    /// After ``suspend()`` the call posts nothing and returns `false`: the
    /// claim stays open, and the journal keeps the run as an orphan for the
    /// next restore.
    ///
    /// The claim is marked as completing before the first suspension, so two
    /// calls for one key post one terminal event. The claim stays in
    /// ``openClaims`` until the post returns, so a ``close()`` in the time of
    /// the post still finds it. The close then journals the `.lost` terminal
    /// of the run behind the post. The journal admits one terminal for each
    /// run (``claimJournalWrite(for:)``), so the run ends with one terminal
    /// event in each order, and the close waits for the post before it closes
    /// the output. The terminal goes through the outbox, as the terminal of
    /// any run does. The lease of the claim ends after the post, so the mail
    /// of the terminal holds its own lease before the work of the claim ends,
    /// and the session has no idle moment between the two.
    ///
    /// - Returns: `true` when this call took the claim. A close at the same
    ///   time can still end the run as `.lost`.
    func completeClaimedRun(_ key: RunKey, outcome: OperationOutcome, detail: String?) async -> Bool {
        guard !isSuspended.withLock({ $0 }) else { return false }
        guard let claim = openClaims[key], !claim.isCompleting else { return false }
        openClaims[key]?.isCompleting = true
        await attachOutboxJournalIfNeeded()
        let terminal = claim.lostTerminal
        await outbox.post(
            event: OperationEvent(
                tool: terminal.tool, op: terminal.op, correlationID: terminal.correlationID, kind: .completed,
                detail: detail ?? "", outcome: outcome))
        // A close that took the claim in the meantime ends the lease itself.
        openClaims.removeValue(forKey: key)?.lease.end()
        return true
    }

    /// Takes all open claims out of ``openClaims``, with no suspension. The
    /// close calls it, so a later call of
    /// ``completeClaimedRun(_:outcome:detail:)`` finds no claim.
    ///
    /// - Returns: The claims that had no terminal event.
    func takeOpenClaims() -> [OpenClaim] {
        defer { openClaims = [:] }
        return Array(openClaims.values)
    }

    /// Journals the `.lost` terminal of each of `claims`, and ends the
    /// lease of each. The close calls it after the drain. The terminal makes
    /// no mail: the queue is closed. After ``suspend()`` the journal refuses
    /// the terminal (``claimJournalWrite(for:)``), so the claim stays open in
    /// the record and only its lease ends.
    ///
    /// - Parameter claims: The claims that no call completed.
    func journalLostTerminals(of claims: [OpenClaim]) async {
        guard !claims.isEmpty else { return }
        await attachOutboxJournalIfNeeded()
        for claim in claims {
            await outbox.journalWithoutStaging(event: claim.lostTerminal)
            claim.lease.end()
        }
    }
}
