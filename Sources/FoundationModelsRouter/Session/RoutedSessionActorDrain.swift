import FoundationModelsExtras

/// ``RoutedSessionActor``'s drain: the stop of all work of the session, and
/// the wait until that work ended (``RoutedSession/drain()``).
extension RoutedSessionActor {
    /// See ``RoutedSession/drain()``. Starts the drain when no drain runs
    /// (``startDrainIfNeeded()``), and waits for it. A cancel of the calling
    /// task ends the wait, but not the drain.
    ///
    /// - Returns: `true` when the drain ended, and `false` when the calling
    ///   task was cancelled first.
    @discardableResult
    func drain() async -> Bool {
        let drain = startDrainIfNeeded()
        do {
            try await CancellableWait.value { await drain.value }
            return true
        } catch {
            return false
        }
    }

    /// The drain that runs, or a new drain when none runs. Two callers that
    /// drain at the same time share one drain.
    ///
    /// - Returns: The task of the drain.
    func startDrainIfNeeded() -> Task<Void, Never> {
        if let drainTask {
            return drainTask
        }
        // The task needs this actor to start, so this assignment comes first:
        // ``runDrain()`` always finds ``drainTask`` set.
        let drain = Task { await self.runDrain() }
        drainTask = drain
        return drain
    }

    /// Stops all work of the session, and waits until it ended. While this
    /// runs, ``drainTask`` is set, so no pump starts (``wakePump()``).
    ///
    /// One cycle stops the running work and withdraws each waiting caller
    /// message and caller compaction (``cancel()``,
    /// ``withdrawCallerCompactions()``), sweeps the background runs
    /// (``sweepBackgroundRuns()``), waits for the body of each run
    /// (``RunPlane/joinRunBodies()``), and waits for the pump. The work can
    /// start a background run before the cancel reaches it, so the cycle
    /// runs again until no pump runs and no run is open.
    ///
    /// At the end, the mail stays in the outbox, held: a run terminal must
    /// not be lost, and it must not start an answer of its own. It rides the
    /// next caller message. A caller message or a caller compaction that
    /// arrived during the drain is withdrawn, and its caller gets
    /// `CancellationError`. The last steps have no suspension point, so no
    /// message arrives between them and the end of the drain.
    private func runDrain() async {
        var workRuns = true
        while workRuns {
            await cancel()
            withdrawCallerCompactions()
            await sweepBackgroundRuns()
            await mailbox.joinRunBodies()
            if let pumpTask {
                await pumpTask.value
            }
            let openRuns = await mailbox.backgroundRuns()
            workRuns = pumpTask != nil || !openRuns.isEmpty
        }
        await outbox.holdPendingMail()
        _ = outbox.withdrawMessages()
        withdrawCallerCompactions()
        drainTask = nil
    }

    /// Withdraws each caller compaction that waits for the pump. Its caller
    /// gets `CancellationError`.
    private func withdrawCallerCompactions() {
        for letter in compactionRequests.pending {
            compactionRequests.cancel(letter.id)
        }
    }

    /// Runs `RunPlane.sweep()`, which cancels every background run and
    /// rejects every pending elicitation, and journals the terminal events
    /// that the sweep gives. It stages nothing, because the drain ends the
    /// work of the session: no submission starts for a terminal of the
    /// sweep.
    ///
    /// Journaling brings the session meta line with it
    /// (``attachOutboxJournalIfNeeded()``), so the journal never opens with a
    /// bare `.toolOutput` line. A sweep that gives no terminal event
    /// journals nothing, so a session that never generated and never started
    /// a background run still writes no file.
    private func sweepBackgroundRuns() async {
        let terminalEvents = await mailbox.sweep()
        guard !terminalEvents.isEmpty else { return }
        // A run can only be backgrounded from inside an answer, so by here the journal
        // is normally attached already; attaching is idempotent, and doing it
        // unconditionally means this path never depends on that reasoning
        // holding for every future caller.
        await attachOutboxJournalIfNeeded()
        for event in terminalEvents {
            await outbox.journalWithoutStaging(event: event)
        }
    }
}
