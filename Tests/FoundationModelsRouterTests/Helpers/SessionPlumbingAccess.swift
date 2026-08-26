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
    /// The session's internal ``SessionOutbox``.
    nonisolated var outbox: SessionOutbox { (self as! RoutedSessionActor).outbox }

    /// The session's internal ``SessionMailbox``.
    nonisolated var mailbox: SessionMailbox { (self as! RoutedSessionActor).mailbox }

    /// Whether a ``RoutedSession/respond(to:maxTokens:)`` call on this session
    /// is suspended on a wait of its own run plane — see
    /// ``RoutedSessionActor/isSuspendedOnRunPlaneDrainWait``.
    var isSuspendedOnRunPlaneDrainWait: Bool {
        get async { await (self as! RoutedSessionActor).isSuspendedOnRunPlaneDrainWait }
    }

    /// Installs how long a model call on this session may run with no
    /// observable progress before it reports a ``GenerationStall`` — see
    /// ``RoutedSessionActor/setGenerationStallReportInterval(_:)``.
    ///
    /// Named differently from the actor's own method on purpose: an extension
    /// member of this protocol that shares the name wins overload resolution
    /// against the concrete type too, and calls itself forever.
    ///
    /// - Parameter interval: The reporting interval to install.
    func installGenerationStallReportInterval(_ interval: Duration) async {
        await (self as! RoutedSessionActor).setGenerationStallReportInterval(interval)
    }
}
