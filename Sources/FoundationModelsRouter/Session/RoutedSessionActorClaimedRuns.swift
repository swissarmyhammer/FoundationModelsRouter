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
    /// The claim leaves ``openClaims`` before the first suspension, so two
    /// calls for one key post one terminal event. The terminal goes through
    /// the outbox, as the terminal of any run does. The lease of the claim
    /// ends after the post, so the mail of the terminal holds its own lease
    /// before the work of the claim ends, and the session has no idle moment
    /// between the two.
    func completeClaimedRun(_ key: RunKey, outcome: OperationOutcome, detail: String?) async -> Bool {
        guard let claim = openClaims.removeValue(forKey: key) else { return false }
        await attachOutboxJournalIfNeeded()
        let terminal = claim.lostTerminal
        await outbox.post(
            event: OperationEvent(
                tool: terminal.tool, op: terminal.op, correlationID: terminal.correlationID, kind: .completed,
                detail: detail ?? "", outcome: outcome))
        claim.lease.end()
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
    /// no mail: the queue is closed.
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
