import Foundation

/// A report that the session held new mail and started no answer for it,
/// carried by ``SessionEvent/mailDeliveryPaused(_:)`` (task ^9bxas0w).
///
/// Mail causes the next submission of a session with no caller call
/// (`generation-queue.md`, section 5.4). A model that starts one more
/// background run in each answer thus gets one more answer for each run, with
/// no end. When ``SessionConfiguration/mailOnlyAnswerLimit`` answers in a row
/// had no caller message, the session holds the new mail in its queue. The
/// next caller message carries the held mail into its submission, and the
/// count starts again. The mail is never lost.
public struct MailDeliveryPause: Sendable, Equatable, CustomStringConvertible {
    /// The limit in force: the most answers in a row that mail alone starts.
    /// The session reached it when it held the mail.
    public let limit: Int

    /// The mail the session held, in queue order. The next caller message
    /// carries it, with the mail that arrives before that message.
    public let heldMail: [OperationEvent]

    /// Creates a report.
    ///
    /// - Parameters:
    ///   - limit: The limit in force.
    ///   - heldMail: The mail the session held, in queue order.
    public init(limit: Int, heldMail: [OperationEvent]) {
        self.limit = limit
        self.heldMail = heldMail
    }

    /// A one-line rendering of this report, also used as the session's log
    /// line.
    public var description: String {
        """
        the session held \(heldMail.count) mail events and started no answer for them: \
        the answers in a row with no caller message reached the mailOnlyAnswerLimit of \(limit); \
        the next caller message carries the held mail
        """
    }
}
