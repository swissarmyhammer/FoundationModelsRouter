import FoundationModelsExtras

/// The stable identifier a session gives a message when the message arrives
/// (`generation-queue.md`, section 5.4). `FoundationModelsExtras` owns the
/// type: the ``SessionOutbox`` of the session keeps its caller messages in an
/// Extras `Mailbox`, and only the mailbox makes an id. This alias keeps the
/// router name, so a router user needs no `import FoundationModelsExtras`.
///
/// ``RoutedSession/send(_:)-(Transcript.Prompt)`` returns one, and
/// ``RoutedSession/cancel(message:)``, ``RoutedSession/replace(id:prompt:)``,
/// ``RoutedSession/pendingMessages()`` and ``RoutedSession/messageQueueDepth()``
/// name a message by it. The id names the message for as long as the session
/// owes it an answer. Comparing two of these, and printing one, is the whole
/// of what a client does with it.
public typealias MessageID = FoundationModelsExtras.MessageID

/// The outcome of ``RoutedSession/replace(id:prompt:)``:
/// `.applied` when the message still waited and the change applied, and
/// `.alreadySent` when no waiting message has the id. `FoundationModelsExtras`
/// owns the type. This alias keeps the router name, so a router user needs no
/// `import FoundationModelsExtras`.
public typealias MessageQueueMutationResult = FoundationModelsExtras.MessageQueueMutationResult

/// How much caller-message work a session carries, as
/// ``RoutedSession/messageQueueDepth()`` reports it: the count of the waiting
/// caller messages, and the ids of the messages the running answer carries.
/// `FoundationModelsExtras` owns the type. This alias keeps the router name,
/// so a router user needs no `import FoundationModelsExtras`.
public typealias MessageQueueDepth = FoundationModelsExtras.MessageQueueDepth

/// The outcome of ``RoutedSession/cancel(message:)``. `FoundationModelsExtras`
/// owns the type. This alias keeps the router name, so a router user needs no
/// `import FoundationModelsExtras`.
///
/// - `.withdrawn`: the message waited and was withdrawn. It never reaches a
///   prompt, and a caller that waits for its answer gets `CancellationError`.
/// - `.cancelledInSubmission`: a submission carries the message, so that
///   submission was cancelled as ``RoutedSession/cancel()`` cancels it. The
///   answer of the submission is the answer of every message it carries.
///   Cancellation is cooperative: this reports that the request was
///   recorded, not that the model or a tool stopped.
/// - `.alreadyAnswered`: the message has no open answer, or the id names no
///   message of this session.
public typealias MessageCancellationResult = FoundationModelsExtras.MessageCancellationResult
