/// The stable identifier a session assigns to a queued user prompt at enqueue.
///
/// ``RoutedSession/enqueue(prompt:)-(Transcript.Prompt)`` returns one, and
/// ``RoutedSession/cancel(id:)``, ``RoutedSession/replace(id:prompt:)`` and
/// ``RoutedSession/cancelPrompt(id:)`` take one back. The id names the prompt
/// for as long as the session owes it a turn.
///
/// Opaque on purpose: comparing two of these, and printing one, is the whole of
/// what a client does with it.
public struct PromptID: Hashable, Sendable, CustomStringConvertible {
    /// The generated value that carries this id's identity.
    private let value: ULID

    /// Mints a fresh prompt id.
    ///
    /// `internal`, deliberately: only the session's own prompt queue mints
    /// these, which is what keeps the handle opaque to clients.
    internal init() {
        self.value = ULID.generate()
    }

    /// This prompt id, rendered for display.
    public var description: String { value.description }
}

/// The outcome of ``RoutedSession/cancel(id:)`` or
/// ``RoutedSession/replace(id:prompt:)``.
public enum PromptQueueMutationResult: Sendable, Equatable {
    /// The prompt was still pending and the mutation applied.
    case applied

    /// No pending prompt has this id. It was already drained, or the id
    /// never named a queued prompt. The mutation was not applied.
    case alreadySent
}

/// How much queued prompt work a session carries, including the prompt whose
/// turn is running, as ``RoutedSession/promptQueueDepth()`` reports it.
public struct PromptQueueDepth: Sendable, Equatable {
    /// How many prompts are still waiting in the queue.
    public let queued: Int

    /// The dispatched prompt whose turn has not finished, or `nil`.
    public let dispatched: PromptID?

    /// Every prompt this session still owes a turn.
    public var total: Int { queued + (dispatched == nil ? 0 : 1) }

    /// Creates a queue-depth snapshot.
    ///
    /// - Parameters:
    ///   - queued: How many prompts are still waiting.
    ///   - dispatched: The dispatched prompt's id, or `nil`.
    init(queued: Int, dispatched: PromptID?) {
        self.queued = queued
        self.dispatched = dispatched
    }
}
