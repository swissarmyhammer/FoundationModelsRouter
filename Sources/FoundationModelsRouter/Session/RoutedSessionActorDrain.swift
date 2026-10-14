import FoundationModelsExtras

/// ``RoutedSessionActor``'s stop of all work: the signal
/// ``RoutedSession/cancelAll()`` (`mailbox.md`, section 5, "Decision:
/// cancelAll() stops all of it"), and the wait until all work ended, which
/// only ``RoutedSession/close()`` uses.
extension RoutedSessionActor {
    /// The work of the signal ``RoutedSession/cancelAll()``: stops all work
    /// of the session now, and waits for no work that does not stop at once.
    /// ``signals`` runs it with the origin of the signal, and ``close()``
    /// runs it directly, out of the signal order.
    ///
    /// The steps, in this order:
    ///
    /// 1. Each queued mail of all kinds leaves the queue and gets its
    ///    terminal event ``SessionEvent/cancelled(_:)`` (``cancelQueuedMail()``).
    /// 2. The running answer stops (``stopRunningAnswer()``): its mail gets
    ///    ``SessionEvent/answerFailed(_:)`` with the reason
    ///    ``AnswerFailure/Reason/cancelled`` at once, the output drops each
    ///    later event of its work, and its model call gets a cancel.
    /// 3. Each open background run makes no more mail: its queued run mail
    ///    is cancelled, and a later run event of it makes no mail
    ///    (``SessionOutbox/ignoreRunMail(of:)``).
    /// 4. The sweep starts (``startSweep()``): each background run gets a
    ///    cancel, and each open elicitation is rejected. The call does not
    ///    wait for the sweep, because the canceler of a run can be slow. Each
    ///    run gets its terminal event when its cancel ends.
    ///
    /// The call never interferes with signal work:
    ///
    /// - It never pauses or resumes the mail queue, and never changes its
    ///   pause counter: step 1 uses ``MailQueue/drain()``, which removes the
    ///   mail and leaves the pause as it is.
    /// - The drop of late output covers only the stopped answer (its
    ///   ``Origin/mail(_:)`` origin) and the run events that the work of that
    ///   answer posts. Such a run event has the origin of the answer when it
    ///   makes no run mail, and else the origin of its run mail; the journal
    ///   drops it by the origin of its poster (``deliverLive(_:origin:)``).
    ///   An output with the origin ``Origin/signal(_:)`` is never dropped. A
    ///   running compaction does not stop: ``cancelAll()`` runs after it
    ///   ends, in the order of the signals.
    /// - After the call, the other signals and ``mail(_:)`` work as usual:
    ///   mail that arrives later waits in the queue, and the pump takes it
    ///   when the stopped work ended.
    func performCancelAll() async {
        cancelQueuedMail()
        stopRunningAnswer()
        let openTokens = await runPlane.backgroundRuns().map(\.completionToken)
        await ignoreRunMail(of: openTokens)
        startSweep()
    }

    /// Stops the answer that runs now, or the take of the next batch, and
    /// waits for nothing. A running compaction does not stop: it is the work
    /// of a signal.
    ///
    /// The answer ends at once for its readers: the terminal event of its
    /// mail goes out now, with the error `CancellationError` in the ledger,
    /// and the output drops each later event whose origin holds its mail
    /// (``SessionOutputHub/silence(_:)``), also the end that its work sends
    /// when it stops. Thus each mail of the answer gets exactly one terminal
    /// event. The work itself stops cooperatively
    /// (``requestCancelOfRunningWork()``), and its recording runs as usual.
    func stopRunningAnswer() {
        switch pumpWork?.kind {
        case .answer:
            endRunningAnswerAtOnce()
            requestCancelOfRunningWork()
        case .taking:
            requestCancelOfRunningWork()
        case nil:
            return
        }
    }

    /// Sends the terminal event of the mail of the running answer now, and
    /// silences the later output of that answer.
    private func endRunningAnswerAtOnce() {
        let ids = deliveredMailIds
        guard !ids.isEmpty else { return }
        let failure = AnswerFailure(mailIds: ids, reason: .cancelled)
        OriginContext.$current.withValue(.mail(Set(ids))) {
            emitSessionScopedEvent(.answerFailed(failure), failure: CancellationError())
        }
        outputHub.silence(Set(ids))
        openAnswerMail.silence()
    }

    /// Makes the runs of `tokens` send no more mail: their queued run mail is
    /// cancelled, and a later event of them makes no mail. The journal still
    /// records each event.
    ///
    /// - Parameter tokens: The completion tokens of the runs.
    private func ignoreRunMail(of tokens: [String]) async {
        guard !tokens.isEmpty else { return }
        outbox.ignoreRunMail(of: tokens)
        for token in tokens {
            await outbox.withdrawStagedEvents(correlationID: token)
        }
    }

    /// Starts one sweep of the background runs in a task of its own
    /// (``sweepTask``), after the sweep that runs now, if any. Two calls give
    /// two sweeps in order, and the second sweep finds only the runs that
    /// started since. ``close()`` waits for the last sweep.
    private func startSweep() {
        let earlier = sweepTask
        sweepTask = Task {
            await earlier?.value
            await self.sweepBackgroundRuns()
        }
    }

    /// The end of all work that ``close()`` waits for. Starts it when it does
    /// not run, and gives its task. Two callers share one.
    ///
    /// - Returns: The task of the end of all work.
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

    /// Stops all work of the session, and waits until it ended: the end of
    /// a session (``close()``). While this runs, ``drainTask`` is set, so no
    /// pump starts (``wakePump()``).
    ///
    /// One cycle stops the running work of the pump
    /// (``requestCancelOfRunningWork()``), waits for the sweep that
    /// ``cancelAll()`` started, sweeps the background runs
    /// (``sweepBackgroundRuns()``), waits for the body of each run
    /// (``RunPlane/joinRunBodies()``), waits for a compaction that runs
    /// (``activeCompaction``), and waits for the pump. ``close()`` cancelled
    /// the running compaction before (``cancelActiveCompaction()``), so that
    /// wait is short. The work can start a background run before the cancel
    /// reaches it, so the cycle runs again until no pump runs, no compaction
    /// runs, and no run is open. The end is a change of the work of the
    /// session (``signalWorkChange()``).
    private func runDrain() async {
        var workRuns = true
        while workRuns {
            requestCancelOfRunningWork()
            await sweepTask?.value
            await sweepBackgroundRuns()
            await runPlane.joinRunBodies()
            if let activeCompaction {
                _ = await activeCompaction.value
            }
            if let pumpTask {
                await pumpTask.value
            }
            let openRuns = await runPlane.backgroundRuns()
            workRuns = pumpTask != nil || activeCompaction != nil || !openRuns.isEmpty
        }
        drainTask = nil
        signalWorkChange()
    }

    /// Runs `RunPlane.sweep()`, which cancels every background run and
    /// rejects every pending elicitation, and journals the terminal events
    /// that the sweep gives. It stages nothing: a swept run makes no mail
    /// (``ignoreRunMail(of:)``).
    ///
    /// Journaling brings the session meta line with it
    /// (``attachOutboxJournalIfNeeded()``), so the journal never opens with a
    /// bare `.toolOutput` line. A sweep that gives no terminal event
    /// journals nothing, so a session that never generated and never started
    /// a background run still writes no file.
    private func sweepBackgroundRuns() async {
        let terminalEvents = await runPlane.sweep()
        guard !terminalEvents.isEmpty else { return }
        await ignoreRunMail(of: terminalEvents.map(\.correlationID))
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
