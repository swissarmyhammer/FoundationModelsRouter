import Tracing

@testable import FoundationModelsRouter

/// Test-only reach into a session's internal plumbing (task ^j0pp9yp).
///
/// The public ``RoutedSession`` protocol no longer exposes `outbox` and
/// `mailbox` — those are internal wiring on ``RoutedSessionActor``. The unit
/// suite still asserts against that wiring directly (staged events, tracked
/// runs), so these accessors bridge the protocol existential the tests hold
/// to the one concrete conformer this package ships. The force cast is safe
/// here by construction: every session a test obtains is a
/// ``RoutedSessionActor``.
extension RoutedSession {
    /// The session's internal `SessionOutbox`.
    nonisolated var outbox: SessionOutbox { (self as! RoutedSessionActor).outbox }

    /// The session's internal `SessionMailbox`.
    nonisolated var mailbox: SessionMailbox { (self as! RoutedSessionActor).mailbox }

    /// The tracer the session opens its spans through, or `nil` when it holds
    /// none — see ``RoutedSessionActor/tracer``.
    nonisolated var sessionTracer: (any Tracer)? { (self as! RoutedSessionActor).tracer }

    /// Whether the pump of this session runs now — see
    /// ``RoutedSessionActor/isPumpRunning``.
    var isPumpRunning: Bool {
        get async { await (self as! RoutedSessionActor).isPumpRunning }
    }

    /// Whether this session becomes idle inside ``BoundedWait``'s bound: its
    /// pump ends, and no caller message waits in its outbox. The session then
    /// holds no answer, and nothing of it is stranded.
    ///
    /// - Returns: Whether the session became idle inside the bound.
    func becomesIdle() async -> Bool {
        await BoundedWait.conditionReached("the session becoming idle") {
            let pumpRunning = await self.isPumpRunning
            let waitingMessages = await self.outbox.waitingMessageCount
            return !pumpRunning && waitingMessages == 0
        }
    }

    /// The stall report interval the session holds now — see
    /// ``RoutedSessionActor/generationStallReportInterval``.
    var installedGenerationStallReportInterval: Duration {
        get async { await (self as! RoutedSessionActor).generationStallReportInterval }
    }
}
