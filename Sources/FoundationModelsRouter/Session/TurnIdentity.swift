/// One turn's identity on one session — the correlation key that ties a
/// submitted prompt to the events the turn it started produced.
///
/// Minted by the pump of the session from the monotonic counter of its work
/// (``RoutedSessionActor/lastWorkId``), so a session has one identity space
/// rather than a second one invented for reporting. Unique within its session
/// and never reused; pair it with ``RoutedSession/id`` for an identity unique
/// across sessions.
///
/// Consecutive turns need not take consecutive ids. Every work of the pump
/// takes one, including ``RoutedSession/compact(prompt:budget:)``, which runs
/// no generation and therefore reports no ``SessionEvent/turnStarted(_:)`` of
/// its own.
///
/// Opaque on purpose: comparing two of these, and printing one, is the whole of
/// what a client does with it.
public struct TurnID: Hashable, Sendable, CustomStringConvertible {
    /// The session's own monotonic turn number.
    private let value: UInt64

    /// Wraps one raw turn number.
    ///
    /// `internal`, deliberately: only the pump of the session mints these,
    /// which is what keeps the handle opaque to clients.
    ///
    /// - Parameter value: The session's own monotonic turn number.
    internal init(_ value: UInt64) {
        self.value = value
    }

    /// This turn number, rendered for display.
    public var description: String { String(value) }
}

/// The record that a turn began: the turn's own identity and, when the turn
/// carries a message that ``RoutedSession/send(_:)-(Transcript.Prompt)`` sent,
/// the id of that message.
///
/// Carried by ``SessionEvent/turnStarted(_:)``, which opens the frame every
/// later event of that turn belongs to — see that case for the framing rule and
/// why the identity travels in a frame rather than on each event.
public struct TurnStart: Sendable, Equatable {
    /// The turn that just began.
    public let turnId: TurnID

    /// The first message of this turn that
    /// ``RoutedSession/send(_:)-(Transcript.Prompt)`` sent — the id it
    /// returned — or `nil` for a turn that carries no such message: a turn
    /// whose caller waits for its answer (``RoutedSession/respond(to:maxTokens:)``,
    /// ``RoutedSession/streamResponse(to:maxTokens:)``,
    /// ``RoutedSession/streamEvents(to:maxTokens:)``), or a turn that only mail
    /// started.
    public let messageId: MessageID?

    /// Creates a turn-start record.
    ///
    /// The pump of the session makes one for each turn. A consumer can make
    /// one again from the ids of a record it received, for example for a fake
    /// event stream in its own tests.
    ///
    /// - Parameters:
    ///   - turnId: The turn that just began.
    ///   - messageId: The first sent message of this turn, or `nil`.
    public init(turnId: TurnID, messageId: MessageID?) {
        self.turnId = turnId
        self.messageId = messageId
    }
}
