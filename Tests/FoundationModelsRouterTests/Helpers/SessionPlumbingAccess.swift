import FoundationModelsExtras
import Tracing

@testable import FoundationModelsRouter

/// Test-only reach into a session's internal plumbing (task ^j0pp9yp).
///
/// The public ``RoutedSession`` protocol no longer exposes `outbox` and
/// `runPlane` — those are internal wiring on ``RoutedSessionActor``. The unit
/// suite still asserts against that wiring directly (staged events, tracked
/// runs), so these accessors bridge the protocol existential the tests hold
/// to the one concrete conformer this package ships. The force cast is safe
/// here by construction: every session a test obtains is a
/// ``RoutedSessionActor``.
extension RoutedSession {
    /// The session's internal `SessionOutbox`.
    nonisolated var outbox: SessionOutbox { (self as! RoutedSessionActor).outbox }

    /// The session's internal `RunPlane`.
    nonisolated var runPlane: RunPlane { (self as! RoutedSessionActor).runPlane }

    /// The tracer the session opens its spans through, or `nil` when it holds
    /// none — see ``RoutedSessionActor/tracer``.
    nonisolated var sessionTracer: (any Tracer)? { (self as! RoutedSessionActor).tracer }

    /// Whether the pump of this session runs now — see
    /// ``RoutedSessionActor/isPumpRunning``.
    var isPumpRunning: Bool {
        get async { await (self as! RoutedSessionActor).isPumpRunning }
    }

    /// How many ``RoutedSession/awaitIdle()`` calls wait now for the next
    /// change of the session — see ``RoutedSessionActor/idleChanges``.
    nonisolated var idleWaitCount: Int { (self as! RoutedSessionActor).idleChanges.waiterCount }

    /// The signal of each change of the work of the session: the end of the
    /// pump, the settlement of a background run, and the close — see
    /// ``RoutedSessionActor/idleChanges``.
    nonisolated var idleChanges: ChangeSignal { (self as! RoutedSessionActor).idleChanges }

    /// The signal of each change of ``idleWaitCount``: an
    /// ``RoutedSession/awaitIdle()`` call that starts to wait, or that stops.
    nonisolated var idleWaiterChanges: ChangeSignal {
        // The session makes its idle signal with the observation of its
        // waiters, so the report is always there.
        (self as! RoutedSessionActor).idleChanges.waiterChanges!
    }

    /// The signal of each change of a state that sends no event of its own:
    /// a mail that the queue got, a stop of the running work, and a cancel
    /// of the running compaction — see ``RoutedSessionActor/stateChanges``.
    nonisolated var stateChanges: ChangeSignal { (self as! RoutedSessionActor).stateChanges }

    /// Asks the session to stop the work its pump runs now, and does not
    /// wait (``RoutedSessionActor/requestCancelOfRunningWork()``). This is
    /// the first step of the stop of the running answer in
    /// ``RoutedSession/cancelAll()``. It sends no early terminal event, does
    /// not silence the output, does not cancel the queued mail, does not
    /// sweep the runs and does not wait. A tool body of the running answer
    /// can call it.
    ///
    /// - Returns: `true` when the pump ran work.
    @discardableResult
    func stopRunningWork() async -> Bool {
        await (self as! RoutedSessionActor).requestCancelOfRunningWork()
    }

    /// Attaches the session as the journal and the observers of its outbox
    /// (``RoutedSessionActor/attachOutboxJournalIfNeeded()``), as the first
    /// answer of the session does. A run event that the outbox gets after
    /// this call goes to the transcript and to the output of the session.
    func attachOutboxJournal() async {
        await (self as! RoutedSessionActor).attachOutboxJournalIfNeeded()
    }

    /// The count of the user-type mail (a user message, an agent message or
    /// an elicitation answer) that waits in the mail queue of this session.
    nonisolated var waitingUserMailCount: Int {
        outbox.queue.pending.filter { !$0.isRunMail }.count
    }

    /// Waits until this session becomes idle: no pump runs, and no user-type
    /// mail waits in its queue. The session then holds no answer, and
    /// nothing of it is stranded.
    ///
    /// The wait reads the state, and waits for the next change of
    /// ``idleChanges`` while the state does not hold. The end of each pump is
    /// such a change. A user-type mail that waits wakes a pump
    /// (``RoutedSessionActor/mail(_:)``), and that pump ends with a change,
    /// so the wait reads the state again after it. No clock ends the wait.
    ///
    /// The check reads the queue before the pump. A pump can start and take
    /// the mail between the two reads. When the pump is read first, the
    /// check can then see no pump and no mail while that pump runs. When the
    /// queue is read first, a pump that took the mail runs until it ends, so
    /// the read of the pump sees it.
    ///
    /// - Returns: `true` when the session is idle, or `false` when the
    ///   waiting task was cancelled first.
    func becomesIdle() async -> Bool {
        do {
            try await idleChanges.wait(until: {
                let noMailWaits = self.waitingUserMailCount == 0
                let pumpRunning = await self.isPumpRunning
                return noMailWaits && !pumpRunning
            })
            return true
        } catch {
            return false
        }
    }

    /// Waits until no pump of this session runs.
    ///
    /// The end of each pump is a change of ``idleChanges``, so the wait
    /// reads the state again after each end. A pump that never started also
    /// satisfies the wait: the caller first waits for an event of the pump,
    /// for example a prompt that reached the backend.
    ///
    /// - Returns: `true` when no pump runs, or `false` when the waiting task
    ///   was cancelled first.
    func pumpEnds() async -> Bool {
        do {
            try await idleChanges.wait(until: { await !self.isPumpRunning })
            return true
        } catch {
            return false
        }
    }

    /// Whether this session is idle once its pump has ended: no user-type mail
    /// waits in its queue. The session then holds no answer, and nothing of
    /// it is stranded.
    ///
    /// This waits for the end of ``RoutedSessionActor/pumpTask`` itself, and
    /// then reads the queue one time. It does not wait for a pump that a mail
    /// is about to wake: use ``becomesIdle()`` for that.
    ///
    /// - Returns: Whether no user-type mail waits after the last pump ended.
    func isIdleOnceThePumpEnds() async -> Bool {
        let session = self as! RoutedSessionActor
        while let pump = await session.pumpTask {
            await pump.value
        }
        return waitingUserMailCount == 0
    }

    /// The stall report interval the session holds now — see
    /// ``RoutedSessionActor/generationStallReportInterval``.
    var installedGenerationStallReportInterval: Duration {
        get async { await (self as! RoutedSessionActor).generationStallReportInterval }
    }
}
