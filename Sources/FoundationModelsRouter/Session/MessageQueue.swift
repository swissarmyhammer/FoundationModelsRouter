/// The stable identifier a session gives a message when the message arrives
/// (`generation-queue.md`, section 5.4).
///
/// ``RoutedSession/send(_:)-(Transcript.Prompt)`` returns one, and
/// ``RoutedSession/cancel(message:)``, ``RoutedSession/replace(id:prompt:)``,
/// ``RoutedSession/pendingMessages()`` and ``RoutedSession/messageQueueDepth()``
/// name a message by it. The id names the message for as long as the session
/// owes it an answer.
///
/// Opaque on purpose: comparing two of these, and printing one, is the whole of
/// what a client does with it.
public struct MessageID: Hashable, Sendable, CustomStringConvertible {
    /// The generated value that carries this id's identity.
    private let value: ULID

    /// Mints a fresh message id.
    ///
    /// `internal`, deliberately: only the session mints these, which is what
    /// keeps the handle opaque to clients.
    internal init() {
        self.value = ULID.generate()
    }

    /// This message id, rendered for display.
    public var description: String { value.description }
}

/// The outcome of ``RoutedSession/replace(id:prompt:)``.
public enum MessageQueueMutationResult: Sendable, Equatable {
    /// The message still waited and the change applied.
    case applied

    /// No waiting message has this id. A submission already took the message,
    /// or the id never named a waiting message. The change did not apply.
    case alreadySent
}

/// How much caller-message work a session carries, as
/// ``RoutedSession/messageQueueDepth()`` reports it.
public struct MessageQueueDepth: Sendable, Equatable {
    /// How many caller messages wait for a submission.
    public let waiting: Int

    /// The messages the running answer delivered, in the order they arrived,
    /// or none when no answer runs. An answer is the running submission and
    /// each continuation of it.
    public let running: [MessageID]

    /// Every message this session still owes an answer.
    public var total: Int { waiting + running.count }

    /// Creates a queue-depth snapshot.
    ///
    /// - Parameters:
    ///   - waiting: How many caller messages wait.
    ///   - running: The ids of the messages of the running answer.
    init(waiting: Int, running: [MessageID]) {
        self.waiting = waiting
        self.running = running
    }
}

/// The outcome of ``RoutedSession/cancel(message:)``.
public enum MessageCancellationResult: Sendable, Equatable {
    /// The message waited and was withdrawn. It never reaches a prompt, and a
    /// caller that waits for its answer gets `CancellationError`.
    case withdrawn

    /// A submission carries the message, so that submission was cancelled as
    /// ``RoutedSession/cancel()`` cancels it. The answer of the submission is
    /// the answer of every message it carries. Cancellation is cooperative:
    /// this reports that the request was recorded, not that the model or a
    /// tool stopped.
    case cancelledInSubmission

    /// The message has no open answer: its answer ended (answered, failed or
    /// cancelled), or the id names no message of this session.
    case alreadyAnswered
}
