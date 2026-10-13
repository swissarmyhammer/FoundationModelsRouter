import FoundationModelsExtras

/// How much mail work one session carries (``RoutedSession/mailQueueDepth()``):
/// the mail that waits for the pump, by kind, and the caller messages of the
/// running answer.
///
/// The letter that the pump posts to start an answer that only mail starts is
/// no mail, so it is never in the depth.
public struct MailQueueDepth: Sendable, Equatable {
    /// The count of the mail that waits for the pump: the caller messages
    /// that wait, and the run events that wait in the outbox. It is the sum
    /// of the values of ``depthByKind``.
    public let waiting: Int

    /// The count of the waiting mail of each kind. The waiting caller
    /// messages are ``MailKind/userMessage``, and the waiting run events are
    /// ``MailKind/runEvent``. A kind with no waiting mail has no key.
    public let depthByKind: [MailKind: Int]

    /// The ids of the caller messages of the running answer, in delivery
    /// order. A message that joined a continuation of the answer is in it
    /// too. Empty when no answer runs.
    public let running: [MailID]

    /// The count of the waiting mail and of the caller messages of the
    /// running answer.
    public var total: Int {
        waiting + running.count
    }

    /// Makes a depth.
    ///
    /// - Parameters:
    ///   - waiting: The count of the waiting mail.
    ///   - depthByKind: The count of the waiting mail of each kind, with no
    ///     key for a kind with no waiting mail.
    ///   - running: The ids of the caller messages of the running answer.
    public init(waiting: Int, depthByKind: [MailKind: Int], running: [MailID]) {
        self.waiting = waiting
        self.depthByKind = depthByKind
        self.running = running
    }
}
