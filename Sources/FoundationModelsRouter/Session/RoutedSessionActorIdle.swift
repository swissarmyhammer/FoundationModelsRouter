import FoundationModelsExtras
import Synchronization

/// ``RoutedSessionActor``'s idle wait: a host waits until the session has no
/// more work (``RoutedSession/awaitIdle()``).
extension RoutedSessionActor {
    /// See ``RoutedSession/awaitIdle()``.
    ///
    /// The wait is ``ChangeSignal/waitUntil(isolation:_:)`` on
    /// ``idleChanges``: each cycle checks the session (``isIdle()``), and
    /// waits for the next change when the session is not idle. A change that
    /// comes during the check is not lost: the wait then returns at once, and
    /// the next cycle checks again.
    ///
    /// A session that is closed, or that closes, has no idle state to wait
    /// for: ``close()`` (``endIdleWaits()``) sets ``isClosed``. The call then
    /// returns `false` at its start, after each check, and after each wait.
    /// The check after the last read of a cycle has no suspension point
    /// before the result, so a close that starts during the reads of a
    /// check also gives `false`. A cancel of the calling task gives `false`
    /// at the start of each cycle and during each wait.
    ///
    /// The call first installs the settlement observer of ``runPlane``
    /// (``attachOutboxJournalIfNeeded()``), so the settlement of each run
    /// reports a change (``deliver(settledTerminal:)``).
    ///
    /// - Returns: `true` when the session is idle, and `false` when the
    ///   calling task was cancelled, or ``close()`` started, before that.
    @discardableResult
    func awaitIdle() async -> Bool {
        guard !isClosed else { return false }
        await attachOutboxJournalIfNeeded()
        var foundIdle = false
        let waitEnded = await idleChanges.waitUntil {
            guard !Task.isCancelled, !isClosed else { return true }
            foundIdle = await isIdle()
            return foundIdle
        }
        return waitEnded && foundIdle && !isClosed
    }

    /// Reports one change of the work of this session to each
    /// ``awaitIdle()`` call that waits: the pump ended, a background run
    /// settled, a requested compaction ended, a sweep ended, a run asked a
    /// question, an answer of the user did not resume a run, or the end of
    /// all work of ``close()`` ended. Each change but the close also goes to
    /// the work events (``workDidChange()``).
    func signalWorkChange() {
        idleChanges.signal()
    }

    /// Ends each ``awaitIdle()`` call that waits with `false`, and makes each
    /// later call return `false` at once. ``close()`` calls it before it
    /// waits for the end of all work, so no wait waits for the end of all
    /// work. The work events of the session stop too (``endWorkEvents()``),
    /// and the work registry of the session closes (``workRegistry``): it
    /// gives no transition any more, and a lease after this call is no work.
    func endIdleWaits() {
        isClosed = true
        endWorkEvents()
        workRegistry.close()
        signalWorkChange()
    }

    /// Whether the session has no work now: no background run is open that
    /// does not wait only for the user, no pump work runs or waits, no child
    /// of a relay works, and no waiting mail can start a submission by
    /// itself. Held mail
    /// (``SessionOutbox/PendingEvent/isHeld``), for example mail that
    /// ``SessionConfiguration/mailOnlyAnswerLimit`` holds, starts no
    /// submission, so it counts as idle.
    ///
    /// A run that waits only for the user (an open question of
    /// `ToolContext.elicit(_:)`, see `RunPlane.runsWaitingOnlyForUser()`) is
    /// no work: only the user can move it. ``hasPendingOperation()`` still
    /// counts that run, because its result comes to the model later.
    ///
    /// The check reads the session state two times. The first read comes
    /// before the reads of ``runPlane`` and ``outbox``
    /// (``readIdleState()``), and the second read comes after them
    /// (``isIdle(startedAt:reading:)``).
    ///
    /// - Returns: `true` when the session has no work now.
    func isIdle() async -> Bool {
        guard let snapshot = await readIdleState() else { return false }
        return isIdle(startedAt: snapshot.workId, reading: snapshot.reads)
    }

    /// The reads of ``isIdle()`` before its last check: the first read of the
    /// session state, and then the reads of ``runPlane`` and ``outbox``
    /// (``readRunsAndMail()``).
    ///
    /// - Returns: The ``lastWorkId`` of the first read and the reads, or
    ///   `nil` when pump work runs or waits at the first read. Then the
    ///   session is not idle.
    func readIdleState() async -> (workId: UInt64, reads: IdleReads)? {
        guard hasNoPumpWork else { return nil }
        let workId = lastWorkId
        let reads = await readRunsAndMail()
        return (workId, reads)
    }

    /// Reads the open runs, the settled run tokens and the open questions of
    /// ``runPlane``, and then the mail of ``outbox``, for ``isIdle()``.
    ///
    /// ``runPlane`` and ``outbox`` are actors of their own, so these reads
    /// suspend. The order of the reads follows the order in which a run
    /// ends. This invariant makes the order correct: the funnel of a run
    /// stages the terminal of the run in ``outbox`` before ``runPlane``
    /// settles the run. So a run that is not open when ``runPlane`` is read
    /// has its token in the settled tokens, and its terminal, when it is
    /// still staged, in the mail. That pair starts a submission
    /// (``SessionOutbox/canStartASubmission(_:runTokens:)``), so the
    /// check says not idle until the pump takes the mail.
    ///
    /// A sweep (of ``cancelAll()`` or of the end of all work of ``close()``)
    /// is the one case where a terminal comes after the settlement: the sweep
    /// settles the run, and the body of the run posts its own terminal when
    /// it ends later. A stopped run makes no mail
    /// (``SessionOutbox/ignoreRunMail(of:)``), so that terminal is not staged.
    /// The end of all work of ``close()`` waits for that body. While it runs,
    /// ``drainTask`` is set, so the check says not idle.
    ///
    /// The open questions (`RunPlane.openElicitations()`) are read after the
    /// open runs. A run waits only for the user when one or more of its
    /// questions are open (`RunPlane.runsWaitingOnlyForUser()`), so one read
    /// of the questions gives those runs with no second read that can
    /// disagree. A run that asks its question after this read counts as
    /// work, and the journal of its question then reports a change of the
    /// work (``noteQuestionAsked(_:mailID:)``), so a check that missed it runs
    /// again. A run whose question gets its answer after this read counts
    /// as no work, so an answer counts a start of work before it goes to the
    /// run plane (``noteWorkStart(answering:with:)``).
    ///
    /// - Returns: The reads, in the order above.
    func readRunsAndMail() async -> IdleReads {
        let runs = await readBackgroundRuns()
        let openQuestions = await runPlane.openElicitations()
        let mail = await outbox.pending().events
        return IdleReads(openRuns: runs.open, runTokens: runs.tokens, openQuestions: openQuestions, mail: mail)
    }

    /// Reads the completion tokens of the background runs of ``runPlane``:
    /// the open runs first, and then the settled runs.
    ///
    /// ``runPlane`` is an actor of its own, so the two reads suspend, and a
    /// run can settle between them. A run leaves the open runs and joins the
    /// settled runs in one step of ``runPlane``, so a run that settles between
    /// the two reads is in the settled runs of the second read. Each run that
    /// was open at the first read is in one of the two sets.
    ///
    /// - Returns: The tokens of the open runs and of the settled runs.
    func readBackgroundRunTokens() async -> BackgroundRunTokens {
        await readBackgroundRuns().tokens
    }

    /// Reads the open runs of ``runPlane``, and then its settled run tokens,
    /// in the order that ``readBackgroundRunTokens()`` gives.
    ///
    /// - Returns: The open runs, and the tokens of the open runs and of the
    ///   settled runs.
    private func readBackgroundRuns() async -> (open: [BackgroundRun], tokens: BackgroundRunTokens) {
        let openRuns = await runPlane.backgroundRuns()
        let settledRunTokens = await runPlane.settledRunTokens()
        let tokens = BackgroundRunTokens(open: Set(openRuns.map(\.completionToken)), settled: settledRunTokens)
        return (openRuns, tokens)
    }

    /// The end of ``isIdle()``: the second read of the session state, and
    /// the result. It has no suspension point.
    ///
    /// Only pump work starts a run, and each answer takes a new
    /// ``lastWorkId``. A compaction starts no run. So no pump work at the first
    /// read and at this read, and the same ``lastWorkId``, prove that no run
    /// started while the reads of ``runPlane`` and ``outbox`` suspended.
    ///
    /// An open run is no work only when it waits only for the user and the
    /// journal recorded one of its open questions (``askedQuestions``): the
    /// question is then on the output, so a work-end event never comes
    /// before the question that ends the work. Such a run that has other
    /// work besides counts as no work, as `RunPlane.runsWaitingOnlyForUser()`
    /// does.
    ///
    /// The working child of a relay is work of this session
    /// (``RelayedQuestions/hasWorkingChild``), whatever the state of the run
    /// that drives the child. The run can wait only for the user, but the
    /// child can still ask, answer or end its own run. The sweep of
    /// ``cancelAll()`` can settle that run while its body, the relay and the
    /// child still run. The child then keeps this session working until the
    /// child stops or the relay closes, so this session sends no
    /// ``SessionEvent/workEnded`` and then a ``SessionEvent/workStarted``
    /// with no new input.
    ///
    /// - Parameters:
    ///   - workId: The ``lastWorkId`` of the first read.
    ///   - reads: What ``readRunsAndMail()`` read after the first read.
    /// - Returns: `true` when the session has no work now.
    func isIdle(startedAt workId: UInt64, reading reads: IdleReads) -> Bool {
        guard hasNoPumpWork, lastWorkId == workId, !relayedQuestions.hasWorkingChild else { return false }
        let userWaitRunTokens = Set(
            reads.openQuestions.filter { askedQuestions.wasAsked($0.elicitationId) }.map(\.runToken))
        return reads.openRuns.allSatisfy { userWaitRunTokens.contains($0.completionToken) }
            && !SessionOutbox.canStartASubmission(reads.mail, runTokens: reads.runTokens)
    }

    /// Whether no pump work runs or waits: no pump and no drain runs, no
    /// user-type mail waits for the pump, and no requested compaction waits
    /// or runs (``openRequestedCompactions``). Queued run mail is no pump
    /// work by itself: ``isIdle(startedAt:reading:)`` checks whether it can
    /// start an answer.
    private var hasNoPumpWork: Bool {
        pumpTask == nil && drainTask == nil && !outbox.queue.pending.contains { !$0.isRunMail }
            && openRequestedCompactions.withLock { $0 } == 0
    }
}

/// What the idle check of a session (``RoutedSessionActor/isIdle()``) reads
/// from the run plane and the outbox of the session
/// (``RoutedSessionActor/readRunsAndMail()``).
struct IdleReads: Sendable {
    /// The background runs that are open.
    let openRuns: [BackgroundRun]

    /// The completion tokens of the background runs that are open and of the
    /// background runs that settled.
    let runTokens: BackgroundRunTokens

    /// The open questions of the runs, each with the token of the run that
    /// asks it (`RunPlane.openElicitations()`), read after ``openRuns``.
    let openQuestions: [OpenElicitation]

    /// The mail that waits in the outbox.
    let mail: [SessionOutbox.PendingEvent]
}
