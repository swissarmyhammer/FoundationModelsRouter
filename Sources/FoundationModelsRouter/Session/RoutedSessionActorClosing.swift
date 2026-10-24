import Foundation
import FoundationModels
import FoundationModelsExtras

/// ``RoutedSessionActor``'s session-lifetime boundary: closing a session down.
extension RoutedSessionActor {
    /// The session directory of the router that resolved ``profile``, reached
    /// through the handle of this session's ``slot``, or `nil` for a
    /// hand-built profile that no router resolved.
    private nonisolated var sessionDirectory: RouterSessionDirectory? {
        switch slot {
        case .standard: profile.standard.sessionDirectory
        case .flash: profile.flash.sessionDirectory
        case .embedding: profile.embedding.sessionDirectory
        }
    }

    /// See ``RoutedSession/close()``.
    ///
    /// Closes the queue, runs the work of ``cancelAll()`` directly
    /// (``performCancelAll()``, out of the order of the signals), and then waits for the end of
    /// all work (``startDrainIfNeeded()``) with no regard to a cancel of the
    /// caller: the end of the sweep, the pump and the body of each run. The
    /// end of all work runs ``runPlane``'s `RunPlane.sweep()`, journals each
    /// terminal event it produced through
    /// `SessionOutbox.journalWithoutStaging(event:)` — reaching the same
    /// ``record(event:)``, and so the same ``makeRunEventPartial(toolName:events:)``, a
    /// run's own reports take when they are journaled live. The journal is
    /// complete before this method returns: exactly one terminal event per
    /// background run, no orphans, no holes. The end of all work then waits
    /// until the pump, the body of each run, each generation pass of the
    /// session (``GenerationPassObserver/awaitNoOpenPass()``), the task of
    /// each signal (``SignalExecutor/awaitNoTask()``) and each helper task of
    /// the session (``HelperTaskTracker/awaitNoLiveTask()``) ended, so when
    /// this method returns, no work of the session runs and no task of the
    /// session keeps the profile. Each queued mail gets its terminal event
    /// ``SessionEvent/cancelled(_:)``, and later mail is refused with
    /// ``MailRefusal/closed``.
    ///
    /// **Why through the outbox rather than straight to the recorder.**
    /// Every other journal write is ordered by `SessionOutbox`'s one FIFO
    /// chain, and position in the transcript is the record. Appending a swept
    /// terminal directly would put it outside that order, so it could land
    /// ahead of an earlier posted event still draining on the chain — the
    /// transcript would then say a run ended before it reported the progress
    /// it in fact reported first. Routing through the outbox puts the
    /// teardown write in the same queue as everything else; it stages
    /// nothing, because there is no next submission for a teardown terminal to
    /// ride.
    ///
    /// **A run's ending is recorded once, even though three writers can
    /// produce it.** The run's own funnel writes its terminal live through the
    /// outbox. The run plane forwards the same terminal at settlement, through
    /// ``deliver(settledTerminal:)``; that is the write that reaches the
    /// journal for a run mounted inside another run, whose funnel copy is
    /// dropped. The sweep's write here is the third. A sweep synthesizes a
    /// terminal only for runs still running, but that does not make one
    /// writer per run: `sweep()` suspends across each run's canceler, so a run
    /// can settle naturally in that window and reach the journal through the
    /// two earlier writers before the sweep hands the same retained event
    /// back; and cancelling a `RunKind.swiftTask` run is cooperative, so a
    /// run swept here can still finish afterwards and post its own terminal
    /// with a *different* outcome. Every later write is refused by
    /// ``claimJournalWrite(for:)``, which lets the first write of a run's
    /// ending stand and appends no second one — the record is append-only, so
    /// nothing already written is ever revised away.
    ///
    /// **Restore-time decision, stated deliberately:** these `.toolOutput`
    /// events are entry-kind, so ``TranscriptTree/effectiveTranscript(forSession:view:)``
    /// rebuilds each one into the restored transcript as a
    /// `Transcript.Entry.toolOutput` (with no paired `.toolCalls` — the run
    /// was backgrounded, not model-invoked). That is intended: a restored
    /// session's model sees how the background runs it left behind actually
    /// ended. ``OperationEventSegment`` rebuilds from its own persisted
    /// schema name, so restoring a closed session succeeds with no caller
    /// setup. The one journal entry that the restored transcript leaves out
    /// is a question that a relay sent up from a child
    /// (``OperationEventSegment/removingRelayedQuestions(from:)``, rule R5).
    ///
    /// Journaling brings the session meta line with it: a close that
    /// journals anything first records the `.session` meta event (exactly as
    /// every answer path does via `recordSessionMetaIfNeeded()`), so the
    /// journal never opens with a bare `.toolOutput` line. A close with
    /// nothing swept journals nothing at all — a session that never
    /// generated and never backgrounded a run still writes no file, preserving
    /// `generate(grammar:prompt:_:)`'s "writes no file at all until it
    /// generates" invariant.
    ///
    /// **The prompt cache of the session** (task ^cc2tezn). Each close
    /// releases the key of this session on its model
    /// (``releasePromptCache()``), whether or not the sweep gave a terminal
    /// event. The close of a child session releases the key of the child
    /// only: the child has its own ULID, so the key of its open parent stays.
    /// A session that is dropped with no close keeps its entry in the cache
    /// of the model until the byte LRU and the disk budget of the cache
    /// remove it, so the cache stays in its limits. The release comes after
    /// the end of all work, so no pass of this session writes the entry again
    /// after the close. A pass that the session does not observe (a backend
    /// with no pass report) can write the entry again, and the same limits
    /// remove it.
    ///
    /// **A running compaction.** No signal affects a running compaction, and
    /// close is the one exception to that rule. Close cancels its summarizer
    /// call (``cancelActiveCompaction()``), and the compaction ends with
    /// ``SessionEvent/compactionFailed(_:)`` before the feeds finish. Nothing
    /// is lost: the transcript keeps no compacted value, and a restore uses
    /// the full transcript.
    ///
    /// **A close from the own work of this session** (task ^3jpewc9). The end
    /// of all work waits for each tool call and each run body of this
    /// session. So when the caller is such work (``SessionOwnWork``), also a
    /// tool of another session whose answer delivers mail that this session
    /// sent (task ^hrkxav5), this call starts the close in a detached task
    /// (``closeFromOwnWork``) and returns at once, and the close ends after
    /// that work returns. The task
    /// is detached for the same reason as the pump (``wakePump()``): the
    /// close then has no task-local of the caller, so no origin of the tool
    /// reaches the events of the close. A close from outside the session
    /// first waits for that close, so the two do not run at the same time,
    /// and then runs the close itself, which finds each step done.
    ///
    /// **The live list of the directory.** Each close first takes this
    /// session off the live list of its router's directory
    /// (``RouterSessionDirectory/unregister(_:)``), before any wait, so a
    /// query after the call no longer finds the session, also while a host
    /// still holds it, and also for a close from the own work of this
    /// session, which returns at once.
    func close() async {
        sessionDirectory?.unregister(id)
        guard !SessionOwnWork.current.contains(id) else {
            startCloseFromOwnWork()
            return
        }
        await closeFromOwnWork?.value
        await closeAndAwaitTheEnd()
    }

    /// Starts the close for a caller that is the own work of this session,
    /// when no such close started before, and does not wait. See ``close()``.
    private func startCloseFromOwnWork() {
        guard closeFromOwnWork == nil else { return }
        closeFromOwnWork = Task.detached { await self.closeAndAwaitTheEnd() }
    }

    /// The work of ``close()``: stops all work of this session, waits until
    /// it ended, and then closes the output, the progress row, the mail
    /// records and the prompt cache. A second run finds each step done.
    private func closeAndAwaitTheEnd() async {
        // The signals that wait behind the work that runs now do not run
        // after close. They send no event, and a wait for their terminal
        // event ends with ``MailRefusal/closed``.
        signals.close()

        // The queue closes first: each queued mail gets its terminal event
        // ``SessionEvent/cancelled(_:)`` while the feeds still read, and
        // ``mail(_:)`` refuses new mail with ``MailRefusal/closed`` from now
        // on. The close of the queue does not suspend.
        settleCancelledMail(outbox.queue.close().map(\.id))

        // Before the drain: no ``awaitIdle()`` call waits for the drain,
        // which waits for each run body to end. From here on, the work of no
        // signal starts (``isClosed``, ``runSignalWork(_:skipped:)``): the
        // work of a signal that read ``signals`` before its close does not
        // start when it comes to this actor. No suspension point comes
        // between this call and the cancel of the running compaction below.
        endIdleWaits()

        // Close is the one exception to the rule that no signal affects a
        // running compaction. It does not wait in the order of the signals:
        // it cancels the summarizer call, and the compaction ends with
        // ``SessionEvent/compactionFailed(_:)`` (cancelled) before the feeds
        // finish. Nothing is lost, because the transcript keeps no compacted
        // value and a restore uses the full transcript.
        await cancelActiveCompaction()

        // The stop of all work: the running answer ends at once, the run
        // plane ends each open question, and the sweep of the runs starts.
        // Close runs the work of ``cancelAll()`` directly: it does not wait
        // in the order of the signals, and it sends no
        // ``SessionEvent/signalDone(_:)``. It comes before the end of the
        // feeds, so a feed also gets the terminal event of the stopped
        // answer, the end of each question that the run plane ended, and
        // each end and each completion that was on its way. The work runs
        // with the origin ``Origin/system``, so each end of a question that
        // close ends has that origin. Its waits are bounded by sink posts
        // only, so they end, also when the caller of close is cancelled.
        //
        // Then the feeds finish (``finishFeedsAfterTheirQuestionsEnded()``),
        // before anything that can return early: a consumer looping over
        // ``streamSessionEvents()`` must end when the session does, whether or
        // not this close has anything to journal. A run can ask a new
        // question while ``performCancelAll()`` waits, for example a question
        // that a subagent relay sends up. That call first ends each question
        // that went out on the feeds, with the same origin, so each question
        // on a feed gets its end on that feed before the feed ends (rule R3).
        await OriginContext.$current.withValue(.system) {
            await performCancelAll()
            await finishFeedsAfterTheirQuestionsEnded()
        }

        // The drain sweeps and journals the background runs, and waits until
        // no work of the session runs, also until the generation pass of a
        // stopped model call, the task of each signal and each helper task
        // of the session ended. A cancel of the caller does not end this
        // wait: when close returns, the session holds no work, and no task of
        // the session keeps the profile.
        await startDrainIfNeeded().value
        // ``performCancelAll()`` and the end of all work ended the open answer, so each delivered mail has its
        // terminal event. The output closes: each mail subscription that is
        // left finishes, and each wait for a terminal event that never came
        // ends with ``MailRefusal/closed``.
        outputHub.close()
        // The drain journals the terminal of each run, and a terminal closes
        // the merged progress row of its run. A row can still be open when a
        // run posted progress and no terminal reached the journal, so write it
        // here: the output text of the row is not lost.
        await closeOpenProgressRow()
        // Each terminal record of the mail (the answer end, each cancel) is on
        // disk when close returns, so a restore finds no open mail of a
        // session that closed (``flushMailRecords()``).
        await flushMailRecords()
        await releasePromptCache()
        // Last: nothing in this session records or settles a relayed
        // question any more, so each relay that still waits for one reads
        // on (``endRelayWaits()``).
        endRelayWaits()
        // After all work of the session ended: the `SessionEnd` of the hooks.
        // A second close finds the hooks ended, so it sends no second one.
        hooks?.end()
    }
}
