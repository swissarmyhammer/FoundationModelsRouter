import FoundationModelsExtras

/// How much mail work one session carries (``RoutedSession/mailQueueDepth()``):
/// the mail that waits in the mail queue, by kind, and the mail of the running
/// answer.
public struct MailQueueDepth: Sendable, Equatable {
    /// The count of all queued mail, of all kinds. It is the sum of the values
    /// of ``depthByKind``.
    public let waiting: Int

    /// The count of the queued mail of each ``MailKind``. A kind with no
    /// queued mail has no key.
    public let depthByKind: [MailKind: Int]

    /// The ids of all mail of the running answer, user-type mail and run
    /// mail, in delivery order. A mail that joined a continuation of the
    /// answer is in it too. Empty when no answer runs.
    public let running: [MailID]

    /// The count of the queued mail and of the mail of the running answer.
    public var total: Int {
        waiting + running.count
    }

    /// Makes a depth.
    ///
    /// - Parameters:
    ///   - waiting: The count of all queued mail, of all kinds.
    ///   - depthByKind: The count of the queued mail of each kind, with no
    ///     key for a kind with no queued mail.
    ///   - running: The ids of all mail of the running answer, in delivery
    ///     order.
    public init(waiting: Int, depthByKind: [MailKind: Int], running: [MailID]) {
        self.waiting = waiting
        self.depthByKind = depthByKind
        self.running = running
    }
}
