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
    /// 4. The run plane ends each open question now
    ///    (`RunPlane.cancelOpenElicitations()`). It takes the questions off in
    ///    one step: an answer or a completion that came before that step wins,
    ///    and one that comes after it finds no question. Then, for each
    ///    question, it posts the end, and only then gives the run the cancel.
    ///    The journal sends the ``SessionEvent/elicitationEnded(_:)`` of each
    ///    end (``record(elicitationEnded:response:poster:)``), with the origin
    ///    of the work that runs this call: the signal, or ``Origin/system``
    ///    for ``close()``. The call returns when each end post returned, so
    ///    each end comes before the ``SessionEvent/signalDone(_:)`` of the
    ///    signal, although the sweep comes later. A question whose completion
    ///    post is on its way (`RunPlane.completingElicitations()`) is not open:
    ///    it gets no end, and its post sends its
    ///    ``SessionEvent/elicitationCompleted(_:)``.
    /// 5. The call reads the end posts and the completion posts that are on
    ///    their way now (``questionPostsOnTheirWay()``): a completion of the
    ///    client or of a tool that came before step 4, or an end of a cancel
    ///    of a run.
    /// 6. The sweep starts (``startSweep()``): each background run gets a
    ///    cancel, and each question that a run asked after step 4 ends. The
    ///    call does not wait for the sweep, because the canceler of a run can
    ///    be slow. Each run gets its terminal event when its cancel ends.
    /// 7. The call waits until the journal handled each post of step 5
    ///    (``awaitQuestionPosts(of:)``). Thus each such end and each such
    ///    completion also comes before the ``SessionEvent/signalDone(_:)``.
    ///
    /// The waits of this call are bounded by sink posts only, never by a
    /// canceler or a tool: step 4 waits for the end posts of the run plane,
    /// and step 7 waits for posts that are in progress. The run plane runs
    /// no canceler before its end posts, and this call does not wait for the
    /// sweep, which runs the cancelers.
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
        _ = await runPlane.cancelOpenElicitations()
        let postsOnTheirWay = await questionPostsOnTheirWay()
        startSweep()
        await awaitQuestionPosts(of: postsOnTheirWay)
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
    ///
    /// The sweep settles the runs with no settlement forward
    /// (``deliver(settledTerminal:)``), so its end is a change of the work of
    /// the session of its own (``workDidChange()``).
    private func startSweep() {
        let earlier = sweepTask
        sweepTask = Task {
            await earlier?.value
            await self.sweepBackgroundRuns()
            await self.workDidChange()
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
    /// (``activeCompaction``), waits for the pump, then waits until no
    /// generation pass of the session is open
    /// (``GenerationPassObserver/awaitNoOpenPass()``), then waits until the
    /// task of each signal ended (``SignalExecutor/awaitNoTask()``), and then
    /// waits until each helper task of the session ended
    /// (``HelperTaskTracker/awaitNoLiveTask()``). ``close()`` cancelled the
    /// running compaction before (``cancelActiveCompaction()``), so that wait
    /// is short. The work can start a background run before the cancel
    /// reaches it, so the cycle runs again until no pump runs, no compaction
    /// runs, and no run is open. The end is a change of the work of the
    /// session (``signalWorkChange()``).
    ///
    /// The wait for the passes is necessary because the framework resumes a
    /// cancelled model call before the pass of its generation ends. The pump
    /// then ends, but the pass runs on, on a task of the framework, and keeps
    /// the model handles of the session. A pass runs no tool body and waits
    /// for no close, so this wait cannot wait for a close.
    ///
    /// The wait for the signal tasks is necessary because the task of a
    /// signal keeps this session, and it runs on after the work that the
    /// drain waits for: after a compaction, the task ends the count of the
    /// requested compaction and runs the idle actions of the executor, and
    /// the task of a signal that waits runs after the close of the executor.
    /// The work of a signal does not call ``close()`` and does not wait for
    /// the drain, and ``close()`` closed the executor, so no new work starts:
    /// this wait cannot wait for a close.
    ///
    /// The wait for the helper tasks is necessary because the session does
    /// not wait for them, and each of them keeps this session, and thus its
    /// profile and the model handles of the profile. A model call cancels its
    /// stall watchdog, its reader of the pass reports and its repetition
    /// watch, and does not wait for them. A mail and the end of a compaction
    /// wake the pump from a helper task. The wait comes after the wait for
    /// the signal tasks, because the idle action of a compaction starts its
    /// wake of the pump in the task of a signal. A helper task ends at its
    /// cancel or by itself and waits for no close, so this wait cannot wait
    /// for a close.
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
            await generationPassObserver.awaitNoOpenPass()
            await signals.awaitNoTask()
            await helperTasks.awaitNoLiveTask()
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
