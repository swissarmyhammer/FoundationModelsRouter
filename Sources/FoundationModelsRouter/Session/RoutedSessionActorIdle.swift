import FoundationModelsExtras

/// ``RoutedSessionActor``'s idle wait: a host waits until the session has no
/// more work (``RoutedSession/awaitIdle()``).
extension RoutedSessionActor {
    /// See ``RoutedSession/awaitIdle()``.
    ///
    /// Each cycle reads ``ChangeSignal/changeCount`` of ``idleChanges``,
    /// checks the session (``isIdle()``), and waits for the next change when
    /// the session is not idle. A change that comes during the check is not
    /// lost: the wait then returns at once, and the next cycle checks again.
    ///
    /// A session that is closed, or that closes, has no idle state to wait
    /// for: ``close()`` (``endIdleWaits()``) sets ``isClosed``. The call then
    /// returns `false` at its start, after each check, and after each wait.
    /// The check after the last read of a cycle has no suspension point
    /// before the result, so a close that starts during the reads of a
    /// check also gives `false`.
    ///
    /// The call first installs the settlement observer of ``mailbox``
    /// (``attachOutboxJournalIfNeeded()``), so the settlement of each run
    /// reports a change (``deliver(settledTerminal:)``).
    ///
    /// - Returns: `true` when the session is idle, and `false` when the
    ///   calling task was cancelled, or ``close()`` started, before that.
    @discardableResult
    func awaitIdle() async -> Bool {
        guard !isClosed else { return false }
        await attachOutboxJournalIfNeeded()
        while !Task.isCancelled, !isClosed {
            let seen = idleChanges.changeCount
            if await isIdle() {
                return !isClosed
            }
            guard await idleChanges.waitForChange(after: seen) else {
                return false
            }
        }
        return false
    }

    /// Reports one change of the work of this session to each
    /// ``awaitIdle()`` call that waits: the pump ended, a background run
    /// settled, or the drain ended.
    func signalWorkChange() {
        idleChanges.signal()
    }

    /// Ends each ``awaitIdle()`` call that waits with `false`, and makes each
    /// later call return `false` at once. ``close()`` calls it before its
    /// drain, so no wait waits for the drain.
    func endIdleWaits() {
        isClosed = true
        signalWorkChange()
    }

    /// Whether the session has no work now: no background run is open, no
    /// pump work runs or waits, and no waiting mail can start a submission
    /// by itself. Held mail (``SessionOutbox/PendingEvent/isHeld``), for
    /// example mail that ``SessionConfiguration/mailOnlyAnswerLimit`` holds,
    /// starts no submission, so it counts as idle.
    ///
    /// The check reads the session state two times. The first read comes
    /// before the reads of ``mailbox`` and ``outbox``
    /// (``readRunsAndMail()``), and the second read comes after them
    /// (``isIdle(startedAt:reading:)``).
    ///
    /// - Returns: `true` when the session has no work now.
    func isIdle() async -> Bool {
        guard hasNoPumpWork else { return false }
        let workId = lastWorkId
        let reads = await readRunsAndMail()
        return isIdle(startedAt: workId, reading: reads)
    }

    /// Reads the open runs and the settled run tokens of ``mailbox``, and
    /// then the mail of ``outbox``, for ``isIdle()``.
    ///
    /// ``mailbox`` and ``outbox`` are actors of their own, so these reads
    /// suspend. The order of the reads follows the order in which a run
    /// ends. This invariant makes the order correct: the funnel of a run
    /// stages the terminal of the run in ``outbox`` before ``mailbox``
    /// settles the run. So a run that is not open when ``mailbox`` is read
    /// has its token in the settled tokens, and its terminal, when it is
    /// still staged, in the mail. That pair starts a submission
    /// (``SessionOutbox/canStartASubmission(_:settledRunTokens:)``), so the
    /// check says not idle until the pump takes the mail.
    ///
    /// The sweep of a drain is the one case where a terminal is staged after
    /// the settlement: the sweep settles the run, and the body of the run
    /// stages its own terminal when it ends later. The drain waits for that
    /// body, and holds that mail at its end (``drain()``). While the drain
    /// runs, ``drainTask`` is set, so the check says not idle.
    ///
    /// - Returns: The reads, in the order above.
    func readRunsAndMail() async -> IdleReads {
        let openRuns = await mailbox.backgroundRuns()
        let settledRunTokens = await mailbox.settledRunTokens()
        let mail = await outbox.pending().events
        return IdleReads(openRuns: openRuns, settledRunTokens: settledRunTokens, mail: mail)
    }

    /// The end of ``isIdle()``: the second read of the session state, and
    /// the result. It has no suspension point.
    ///
    /// Only pump work starts a run, and each answer and each caller
    /// compaction takes a new ``lastWorkId``. So no pump work at the first
    /// read and at this read, and the same ``lastWorkId``, prove that no run
    /// started while the reads of ``mailbox`` and ``outbox`` suspended.
    ///
    /// - Parameters:
    ///   - workId: The ``lastWorkId`` of the first read.
    ///   - reads: What ``readRunsAndMail()`` read after the first read.
    /// - Returns: `true` when the session has no work now.
    func isIdle(startedAt workId: UInt64, reading reads: IdleReads) -> Bool {
        guard hasNoPumpWork, lastWorkId == workId else { return false }
        return reads.openRuns.isEmpty
            && !SessionOutbox.canStartASubmission(reads.mail, settledRunTokens: reads.settledRunTokens)
    }

    /// Whether no pump work runs or waits: no pump and no drain runs, and no
    /// caller message and no caller compaction waits for the pump.
    private var hasNoPumpWork: Bool {
        pumpTask == nil && drainTask == nil && outbox.messages.pending.isEmpty && pendingCompactions.isEmpty
    }
}

/// What the idle check of a session (``RoutedSessionActor/isIdle()``) reads
/// from the run plane and the outbox of the session
/// (``RoutedSessionActor/readRunsAndMail()``).
struct IdleReads: Sendable {
    /// The background runs that are open.
    let openRuns: [BackgroundRun]

    /// The completion tokens of the background runs that settled.
    let settledRunTokens: Set<String>

    /// The mail that waits in the outbox.
    let mail: [SessionOutbox.PendingEvent]
}
