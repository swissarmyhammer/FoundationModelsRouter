import FoundationModels
import Synchronization
import Tracing

/// The answer of one item that waits for the pump of a session: a caller
/// message, or a caller compaction (`generation-queue.md`, section 5.4).
///
/// The pump resolves it one time, with the result of the work that carried
/// the item. The caller waits only for this answer. It waits for no
/// permission. The first resolve wins, and each later resolve does nothing.
///
/// A caller that is cancelled marks the answer (``requestCancel()``) before
/// it asks the session to withdraw the item. The pump reads the mark when it
/// takes the item, so a cancel that arrives while the pump takes the item is
/// not lost.
final class PumpAnswer<Value: Sendable>: Sendable {
    /// The one-time rendezvous of the result and its one waiter.
    private let gate = RaceGate<Result<Value, any Error>>()

    /// Whether the caller of the item was cancelled.
    private let cancelRequested = Atomic<Bool>(false)

    /// Gives `result` to the waiter. Only the first call has an effect.
    ///
    /// - Parameter result: The result of the work that carried the item.
    func resolve(_ result: Result<Value, any Error>) {
        gate.resume(with: result)
    }

    /// Waits for the result of the item.
    ///
    /// - Returns: The value of the result.
    /// - Throws: The error of the result.
    func value() async throws -> Value {
        try await withCheckedContinuation { gate.register(continuation: $0) }.get()
    }

    /// Marks that the caller of the item was cancelled.
    func requestCancel() {
        cancelRequested.store(true, ordering: .releasing)
    }

    /// Whether the caller of the item was cancelled.
    var isCancelRequested: Bool {
        cancelRequested.load(ordering: .acquiring)
    }
}

/// Who reads the output of the submission that carries a caller message.
enum MessageReader: Sendable {
    /// The caller waits for the whole reply text.
    case reply

    /// The caller reads each text fragment from this stream
    /// (``RoutedSession/streamResponse(to:maxTokens:)``).
    case textStream(AsyncThrowingStream<String, any Error>.Continuation)

    /// The caller reads each event from this stream
    /// (``RoutedSession/streamEvents(to:maxTokens:)``).
    case eventStream(AsyncThrowingStream<SessionEvent, any Error>.Continuation)

    /// Whether the submission gives its output as a stream. A stream message
    /// goes alone in its submission: the SDK fixes the call at its start, and
    /// the fragments of the call belong to one reader.
    var isStream: Bool {
        switch self {
        case .reply:
            return false
        case .textStream, .eventStream:
            return true
        }
    }
}

/// One caller message that waits in the ``SessionOutbox`` of a session for
/// the pump (`generation-queue.md`, section 5.4).
///
/// ``RoutedSession/respond(to:maxTokens:)``, the two stream methods, and
/// ``RoutedSession/dispatchNextPrompt()`` each add one message and wait for
/// its answer. The pump puts the text of the message into the `.prompt`
/// entry of the next submission that can carry it.
struct SessionMessage: Sendable {
    /// The id of the message. A queued prompt keeps the id that
    /// ``RoutedSession/enqueue(prompt:)-(Transcript.Prompt)`` gave it.
    let id: PromptID

    /// The prompt text of the message.
    let text: String

    /// The token ceiling the caller named, or `nil`.
    let requestedMaxTokens: Int?

    /// Who reads the output of the submission.
    let reader: MessageReader

    /// The surface the caller used, which the span of the submission reports.
    let entryPoint: RouterTracing.TurnEntryPoint

    /// The tracing context of the caller, so the span of the submission is a
    /// child of the span of the caller. The pump task inherits no task-local
    /// of the caller.
    let serviceContext: ServiceContext?

    /// The answer the caller waits for.
    let answer: PumpAnswer<String>

    /// The options that the submission of this message fixes at its start.
    var options: SubmissionOptions {
        SubmissionOptions(isStream: reader.isStream, requestedMaxTokens: requestedMaxTokens)
    }
}

/// The options that one submission fixes at its start, which decide which
/// caller messages can share it (`generation-queue.md`, section 5.4).
///
/// The SDK fixes the options of a call at its start. A stream goes alone,
/// because the fragments of the call belong to one reader. Two reply
/// messages share a submission when they name the same token ceiling. The
/// grammar of the session is the same for every reply message.
struct SubmissionOptions: Sendable, Equatable {
    /// The options of a submission that only mail started: a reply, with the
    /// resolved context of the model as the ceiling.
    static let mailDelivery = SubmissionOptions(isStream: false, requestedMaxTokens: nil)

    /// Whether the submission gives its output as a stream.
    let isStream: Bool

    /// The token ceiling the callers named, or `nil`.
    let requestedMaxTokens: Int?

    /// Whether `message` can go in a submission with these options.
    ///
    /// - Parameter message: A waiting caller message.
    /// - Returns: `true` when neither is a stream and both name the same
    ///   token ceiling.
    func admits(_ message: SessionMessage) -> Bool {
        !isStream && message.options == self
    }
}

/// What the pump takes from the ``SessionOutbox`` for one submission: every
/// waiting mail event, and the caller messages that can share the submission.
struct SubmissionBatch: Sendable {
    /// The mail events, in outbox order.
    let events: [SessionOutbox.PendingEvent]

    /// The caller messages, in the order they arrived.
    let messages: [SessionMessage]
}
