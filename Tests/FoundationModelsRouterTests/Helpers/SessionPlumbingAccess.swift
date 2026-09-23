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

    /// Whether a ``RoutedSession/respond(to:maxTokens:)`` call on this session
    /// is suspended on a wait of its own run plane — see
    /// ``RoutedSessionActor/isSuspendedOnRunPlaneDrainWait``.
    var isSuspendedOnRunPlaneDrainWait: Bool {
        get async { await (self as! RoutedSessionActor).isSuspendedOnRunPlaneDrainWait }
    }

    /// The stall report interval the session holds now — see
    /// ``RoutedSessionActor/generationStallReportInterval``.
    var installedGenerationStallReportInterval: Duration {
        get async { await (self as! RoutedSessionActor).generationStallReportInterval }
    }
}
