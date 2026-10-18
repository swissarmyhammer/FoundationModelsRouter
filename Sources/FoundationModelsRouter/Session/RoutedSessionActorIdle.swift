import FoundationModelsExtras
import Synchronization

/// ``RoutedSessionActor``'s idle wait: a host waits until the session has no
/// more work (``RoutedSession/awaitIdle()``).
///
/// The work of the session is the set of the open leases of its work
/// registry (``workRegistry``). The idle wait waits on that registry
/// (`WorkRegistry.awaitNoWork()`), so it waits with no poll and no timer.
extension RoutedSessionActor {
    /// See ``RoutedSession/awaitIdle()``.
    ///
    /// Each cycle waits until the registry has no open lease
    /// (`WorkRegistry.awaitNoWork()`), and then does the check of the work end
    /// (``reportWorkEndIfNoWork()``). The check finds no work when the
    /// registry still has no open lease and the journal recorded each open
    /// question of the runs. Then the check sends ``SessionEvent/workEnded``
    /// when it is due, and the call returns `true`. Else the cycle waits for
    /// the next change of the work (``idleChanges``): each transition of the
    /// registry and each recorded question is such a change. A change that
    /// comes during the check is not lost: the wait then returns at once, and
    /// the next cycle checks again.
    ///
    /// A session that is closed, or that closes, has no idle state to wait
    /// for: ``close()`` (``endIdleWaits()``) sets ``isClosed`` and closes the
    /// registry, and the close of the registry ends each wait on it. The call
    /// then returns `false`. A cancel of the calling task also ends each wait,
    /// and gives `false`.
    ///
    /// The call first installs the settlement observer of ``runPlane``
    /// (``attachOutboxJournalIfNeeded()``), so the settlement of each run
    /// reaches the journal of the session (``deliver(settledTerminal:)``).
    ///
    /// - Returns: `true` when the session is idle, and `false` when the
    ///   calling task was cancelled, or ``close()`` started, before that.
    @discardableResult
    func awaitIdle() async -> Bool {
        guard !isClosed else { return false }
        idleWaits.begin()
        defer { idleWaits.end() }
        await attachOutboxJournalIfNeeded()
        var foundIdle = false
        let waitEnded = await idleChanges.waitUntil {
            guard !Task.isCancelled, !isClosed else { return true }
            await workRegistry.awaitNoWork()
            guard !Task.isCancelled, !isClosed else { return true }
            foundIdle = await reportWorkEndIfNoWork()
            return foundIdle
        }
        return waitEnded && foundIdle && !isClosed
    }

    /// Reports one change of the work of this session to each wait for a
    /// change of it (``idleChanges``): a transition of the registry, the end
    /// of the pump, a settlement of a background run, the end of a requested
    /// compaction or of a sweep, a recorded question, or the close.
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

    /// Whether the session has no work now: the work registry has no open
    /// lease, and the journal recorded each open question of the runs.
    ///
    /// The registry holds each piece of work of the session: the generation
    /// of each answer, each queued mail that can start an answer, a
    /// requested compaction, a sweep, a relayed child that works, and each
    /// lease of a tool, also each background run. Held mail
    /// (``SessionOutbox/PendingEvent/isHeld``) holds no lease: it starts no
    /// answer by itself.
    ///
    /// A run that waits only for the user (an open question of
    /// `ToolContext.elicit(_:)`, see `RunPlane.runsWaitingOnlyForUser()`) is
    /// no work: the run plane suspends its lease. Only the user can move it.
    /// The run is no work only after the journal recorded its question, so a
    /// work-end event never comes before the question that ends the work.
    /// ``hasPendingOperation()`` still counts that run, because its result
    /// comes to the model later.
    ///
    /// - Returns: `true` when the session has no work now.
    func isIdle() async -> Bool {
        guard !workRegistry.hasWork else { return false }
        let openQuestions = await runPlane.openElicitations()
        return !workRegistry.hasWork && openQuestions.allSatisfy { askedQuestions.wasAsked($0.elicitationId) }
    }

    /// Reads the completion tokens of the background runs of ``runPlane``,
    /// the open runs and the settled runs, in one step of ``runPlane``
    /// (`RunPlane/backgroundRunTokens()`). A run leaves the open runs and
    /// joins the settled runs in one step of ``runPlane``, so each run is in
    /// one of the two sets.
    ///
    /// - Returns: The tokens of the open runs and of the settled runs.
    func readBackgroundRunTokens() async -> BackgroundRunTokens {
        await runPlane.backgroundRunTokens()
    }
}

extension RunPlane {
    /// The completion tokens of the open runs and of the settled runs of
    /// this run plane, read in one step.
    ///
    /// - Returns: The tokens.
    func backgroundRunTokens() -> BackgroundRunTokens {
        BackgroundRunTokens(open: Set(backgroundRuns().map(\.completionToken)), settled: settledRunTokens())
    }
}

/// The count of the ``RoutedSession/awaitIdle()`` calls of a session that
/// run now (``RoutedSessionActor/idleWaits``).
///
/// Only the tests read it. A test waits on ``changes`` until a call waits,
/// and then makes the change that the call waits for.
final class IdleWaitCount: Sendable {
    /// The count of the calls that run now.
    private let count = Mutex(0)

    /// Reports each change of ``value``.
    let changes = ChangeSignal()

    /// The count of the calls that run now.
    var value: Int {
        count.withLock { $0 }
    }

    /// Counts one call that starts.
    func begin() {
        count.withLock { $0 += 1 }
        changes.signal()
    }

    /// Counts one call that returns.
    func end() {
        count.withLock { $0 -= 1 }
        changes.signal()
    }
}
