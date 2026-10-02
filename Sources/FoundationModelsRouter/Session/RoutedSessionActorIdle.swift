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
    /// The call first installs the settlement observer of ``mailbox``
    /// (``attachOutboxJournalIfNeeded()``), so the settlement of each run
    /// reports a change (``deliver(settledTerminal:)``).
    ///
    /// - Returns: `true` when the session is idle, and `false` when the
    ///   calling task was cancelled or ``close()`` started before that.
    @discardableResult
    func awaitIdle() async -> Bool {
        await attachOutboxJournalIfNeeded()
        while !Task.isCancelled {
            let seen = idleChanges.changeCount
            if await isIdle() {
                return true
            }
            guard !isClosed, await idleChanges.waitForChange(after: seen) else {
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

    /// Ends each ``awaitIdle()`` call that waits, and stops each later call
    /// from waiting. ``close()`` calls it before its drain, so no wait waits
    /// for the drain.
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
    /// ``mailbox`` and ``outbox`` are actors of their own, so their reads
    /// suspend. The order of the reads follows the order in which a run
    /// ends: its funnel stages its terminal in ``outbox`` before ``mailbox``
    /// settles it. A run that is not open when ``mailbox`` is read thus has
    /// its token in the settled tokens, and its terminal, when it is still
    /// staged, in the mail. That pair starts a submission
    /// (``SessionOutbox/canStartASubmission(_:settledRunTokens:)``), so the
    /// check says not idle until the pump takes the mail.
    ///
    /// The reads of this actor come last, with no suspension point between
    /// them and the result. Only pump work starts a run, and each answer and
    /// each caller compaction takes a new ``lastWorkId``. So no pump at the
    /// start and at the end, and the same ``lastWorkId``, prove that no run
    /// started while the reads of the other actors suspended.
    ///
    /// - Returns: `true` when the session has no work now.
    private func isIdle() async -> Bool {
        guard hasNoPumpWork else { return false }
        let workId = lastWorkId
        let openRuns = await mailbox.backgroundRuns()
        let settledRunTokens = await mailbox.settledRunTokens()
        let mail = await outbox.pending().events
        guard hasNoPumpWork, lastWorkId == workId else { return false }
        return openRuns.isEmpty && !SessionOutbox.canStartASubmission(mail, settledRunTokens: settledRunTokens)
    }

    /// Whether no pump work runs or waits: no pump and no drain runs, and no
    /// caller message and no caller compaction waits for the pump.
    private var hasNoPumpWork: Bool {
        pumpTask == nil && drainTask == nil && outbox.messages.pending.isEmpty && pendingCompactions.isEmpty
    }
}
