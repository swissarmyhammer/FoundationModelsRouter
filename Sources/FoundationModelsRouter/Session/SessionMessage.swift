import FoundationModels
import FoundationModelsExtras
import Tracing

/// The queue of the caller messages of one session: an Extras `Mailbox` whose
/// answer is the final reply of the answer that carried the message
/// (`generation-queue.md`, section 5.4). ``SessionOutbox/messages`` is the one
/// instance of a session.
///
/// The mailbox gives each message its ``MessageID`` and its one answer. Post,
/// cancel, replace and each take occur under one lock and do not suspend, so
/// a cancel is never late for a take: the message waits, or the running batch
/// carries it, and the cancel finds it.
typealias SessionMessageMailbox = FoundationModelsExtras.Mailbox<SessionMessage, String>

/// One caller message in ``SessionOutbox/messages``, with the ``MessageID``
/// that ``SessionMessageMailbox/post(_:)`` gave it.
typealias SessionLetter = SessionMessageMailbox.Letter

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
/// ``RoutedSession/send(_:)-(Transcript.Prompt)`` posts one message and
/// returns its id. ``RoutedSession/respond(to:maxTokens:)`` and the two stream
/// methods each post one message and wait for its answer. The pump puts the
/// text of the message into the `.prompt` entry of the next submission that
/// can carry it. The mailbox keeps the id and the answer of the message
/// (``SessionLetter``).
struct SessionMessage: Sendable {
    /// The prompt of the message. ``RoutedSession/replace(id:prompt:)``
    /// changes it while the message waits.
    var prompt: Transcript.Prompt

    /// The prompt text the submission carries: the `.text` segments of
    /// ``prompt``, joined with no separator.
    var text: String {
        TranscriptEntryMapper.flattenedText(prompt)
    }

    /// The token ceiling the caller named, or `nil`.
    let requestedMaxTokens: Int?

    /// Who reads the output of the submission.
    let reader: MessageReader

    /// The tracing context of the caller, so the span of the submission is a
    /// child of the span of the caller. The pump task inherits no task-local
    /// of the caller.
    let serviceContext: ServiceContext?

    /// The options that the submission of this message fixes at its start.
    var options: SubmissionOptions {
        SubmissionOptions(isStream: reader.isStream, requestedMaxTokens: requestedMaxTokens)
    }

    /// Whether `other` can share the submission that `first` starts: the
    /// joining rule of each batch the pump takes from the mailbox.
    ///
    /// - Parameters:
    ///   - first: The message that starts the batch.
    ///   - other: A later waiting message.
    /// - Returns: `true` when the options of `first` admit `other`.
    static func sharesSubmission(_ first: SessionMessage, with other: SessionMessage) -> Bool {
        first.options.admits(other)
    }
}

extension Transcript.Prompt {
    /// A prompt of one `.text` segment: the form a plain-text message takes.
    ///
    /// - Parameter text: The text of the prompt.
    /// - Returns: The prompt.
    static func plainText(_ text: String) -> Transcript.Prompt {
        Transcript.Prompt(segments: [.text(Transcript.TextSegment(content: text))])
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
    /// The options of a submission that only mail started: a reply, with no
    /// ceiling from a caller. The resolved context of the model, bounded by
    /// the pass token limit of the session, is the ceiling.
    static let mailDelivery = SubmissionOptions(isStream: false, requestedMaxTokens: nil)

    /// Whether the submission gives its output as a stream.
    let isStream: Bool

    /// The token ceiling the callers named, or `nil`. The pump gives it to
    /// each submission of the answer, and it is part of the key that groups
    /// the messages of one submission.
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

/// What the first submission of one answer carries: the caller messages that
/// can share the submission, and every waiting mail event.
struct SubmissionBatch: Sendable {
    /// The caller messages, in the order they arrived. None when only mail
    /// starts the submission.
    let letters: [SessionLetter]

    /// The mail events, in outbox order.
    let events: [SessionOutbox.PendingEvent]
}
