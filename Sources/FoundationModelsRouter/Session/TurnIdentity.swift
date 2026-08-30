/// One turn's identity on one session — the correlation key that ties a
/// submitted prompt to the events the turn it started produced.
///
/// Minted by ``RoutedSessionActor/beginTurn()`` from the monotonic counter the
/// session already keeps for its human-wait bookkeeping, so a session has one
/// turn-identity space rather than a second one invented for reporting. Unique
/// within its session and never reused; pair it with ``RoutedSession/id`` for an
/// identity unique across sessions.
///
/// Consecutive turns need not take consecutive ids. Every holder of the turn
/// lock takes one, including ``RoutedSession/compact(prompt:budget:)``, which
/// runs no generation and therefore reports no ``SessionEvent/turnStarted(_:)``
/// of its own.
///
/// Opaque on purpose: comparing two of these, and printing one, is the whole of
/// what a client does with it.
public struct TurnID: Hashable, Sendable, CustomStringConvertible {
    /// The session's own monotonic turn number.
    private let value: UInt64

    /// Wraps one raw turn number.
    ///
    /// `internal`, deliberately: only ``RoutedSessionActor/beginTurn()`` mints
    /// these, which is what keeps the handle opaque to clients.
    ///
    /// - Parameter value: The session's own monotonic turn number.
    internal init(_ value: UInt64) {
        self.value = value
    }

    /// This turn number, rendered for display.
    public var description: String { String(value) }
}

/// The record that a turn began: the turn's own identity and, when the turn came
/// off the prompt queue, the id of the prompt that caused it.
///
/// Carried by ``SessionEvent/turnStarted(_:)``, which opens the frame every
/// later event of that turn belongs to — see that case for the framing rule and
/// why the identity travels in a frame rather than on each event.
public struct TurnStart: Sendable, Equatable {
    /// The turn that just began.
    public let turnId: TurnID

    /// The queued prompt this turn dispatched — the id
    /// ``RoutedSession/enqueue(prompt:)-(Transcript.Prompt)`` returned — or
    /// `nil` for a turn whose prompt came straight from its caller
    /// (``RoutedSession/respond(to:maxTokens:)``,
    /// ``RoutedSession/streamResponse(to:maxTokens:)``,
    /// ``RoutedSession/streamEvents(to:maxTokens:)``).
    let promptId: PromptID?

    /// Creates a turn-start record.
    ///
    /// - Parameters:
    ///   - turnId: The turn that just began.
    ///   - promptId: The queued prompt this turn dispatched, or `nil` when the
    ///     turn's prompt came straight from its caller.
    init(turnId: TurnID, promptId: PromptID?) {
        self.turnId = turnId
        self.promptId = promptId
    }
}
