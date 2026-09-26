/// The identity of one submission of a session: one SDK call of the chain
/// that answers the messages of the session (`generation-queue.md`, sections
/// 5.1 and 5.6).
///
/// Minted by the session from a counter of its own, one for each submission,
/// so the first submission of a session is `1`. Unique within its session and
/// never reused; pair it with ``RoutedSession/id`` for an identity unique
/// across sessions.
///
/// Opaque on purpose: to compare two of these, and to print one, is the whole
/// of what a client does with it.
public struct SubmissionID: Hashable, Sendable, CustomStringConvertible {
    /// The number of the submission in its session.
    private let value: UInt64

    /// Wraps one submission number.
    ///
    /// `internal`, deliberately: only the session mints these, which is what
    /// keeps the handle opaque to clients.
    ///
    /// - Parameter value: The number of the submission in its session.
    internal init(_ value: UInt64) {
        self.value = value
    }

    /// This submission number, rendered for display.
    public var description: String { String(value) }
}

/// The record that a submission started: its identity, the messages it
/// delivers, and why the session made it.
///
/// Carried by ``SessionEvent/submissionStarted(_:)``. Every event of the
/// submission comes after it, up to the ``SessionEvent/submissionEnded(_:)``
/// with the same ``submissionId``.
public struct SubmissionStart: Sendable, Equatable {
    /// Why the session made a submission.
    ///
    /// The raw value is the `submission.cause` attribute of the span of the
    /// submission, so it is stable API.
    public enum Cause: String, Sendable, Equatable {
        /// The submission carries at least one caller message: a message that
        /// ``RoutedSession/send(_:)-(Transcript.Prompt)``,
        /// ``RoutedSession/respond(to:maxTokens:)`` or a stream method sent.
        case message

        /// The submission carries only mail, for example the terminal of a
        /// settled background run. No caller asked for it.
        case mail

        /// The submission continues the chain of an earlier submission: after
        /// a compaction at a tool result, a stop at the output ceiling, a
        /// retry after a context overflow, a rejected tool call, or a stop for
        /// repeated lines. It carries the caller messages that joined the
        /// chain when it started.
        case continuation
    }

    /// The submission that started.
    public let submissionId: SubmissionID

    /// The caller messages this submission delivers to the model, in the
    /// order they arrived. Empty for a submission that delivers no caller
    /// message.
    public let messageIds: [MessageID]

    /// Why the session made this submission.
    public let cause: Cause

    /// Creates a submission-start record.
    ///
    /// The session makes one for each submission. A consumer can make one
    /// again from the fields of a record it received, for example for a fake
    /// event stream in its own tests.
    ///
    /// - Parameters:
    ///   - submissionId: The submission that started.
    ///   - messageIds: The caller messages the submission delivers.
    ///   - cause: Why the session made the submission.
    public init(submissionId: SubmissionID, messageIds: [MessageID], cause: Cause) {
        self.submissionId = submissionId
        self.messageIds = messageIds
        self.cause = cause
    }
}

/// The record that a submission ended: its identity, its measured usage, and
/// why it stopped.
///
/// Carried by ``SessionEvent/submissionEnded(_:)``, one time for each
/// submission, also for one that failed or was cancelled.
public struct SubmissionEnd: Sendable, Equatable {
    /// The submission that ended.
    public let submissionId: SubmissionID

    /// The measured token usage of this submission, or `nil` when the backend
    /// reports no usage.
    public let usage: TokenUsage?

    /// Why this submission stopped. It is the same value as
    /// ``TokenUsage/finishReason`` when ``usage`` is set.
    public let finishReason: FinishReason

    /// Creates a submission-end record.
    ///
    /// The session makes one for each submission. A consumer can make one
    /// again from the fields of a record it received, for example for a fake
    /// event stream in its own tests.
    ///
    /// - Parameters:
    ///   - submissionId: The submission that ended.
    ///   - usage: The measured usage of the submission, or `nil`.
    ///   - finishReason: Why the submission stopped.
    public init(submissionId: SubmissionID, usage: TokenUsage?, finishReason: FinishReason) {
        self.submissionId = submissionId
        self.usage = usage
        self.finishReason = finishReason
    }
}
