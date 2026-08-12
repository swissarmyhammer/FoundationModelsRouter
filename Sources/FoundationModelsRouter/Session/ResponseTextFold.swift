/// The one home of the ``SessionEvent/textReset`` accumulation rule — the
/// shared reducer both response-text consumers fold through, so the rule
/// exists exactly once (task ^1s8p8qt).
///
/// The rule: a reset supersedes every fragment accumulated so far — the model
/// abandoned the response it was writing and began another — so the reply is
/// cleared and the next fragment starts a new response. A consumer that
/// applies it holds, character for character, the string
/// ``RoutedSession/respond(to:maxTokens:)`` returns for the same turn (see
/// ``SessionEvent/textReset``).
///
/// Two consumers share it: ``SessionProjection`` asks ``append(_:)`` whether a
/// fragment begins a new response, which is what splits the superseded text
/// into its own transcript row; ``TurnOutcomeFold`` reads ``reply`` as the
/// turn's final answer. Neither re-implements the rule.
struct ResponseTextFold: Sendable, Equatable {
    /// The current response's accumulated text — the reply the reset rule
    /// leaves standing, empty immediately after a ``reset()``.
    private(set) var reply = ""

    /// Whether a ``reset()`` superseded the current response, so the next
    /// fragment begins a new one. Set by ``reset()``, cleared by the
    /// ``append(_:)`` that consumes it.
    private var supersededCurrent = false

    /// Applies ``SessionEvent/textReset``: everything accumulated so far is
    /// superseded, and the next fragment begins a new response.
    mutating func reset() {
        reply = ""
        supersededCurrent = true
    }

    /// Applies one ``SessionEvent/textDelta(_:)`` fragment.
    ///
    /// - Parameter fragment: The new text to accumulate.
    /// - Returns: Whether this fragment began a new response — `true` exactly
    ///   when a ``reset()`` preceded it.
    @discardableResult
    mutating func append(_ fragment: String) -> Bool {
        let beganNewResponse = supersededCurrent
        supersededCurrent = false
        reply += fragment
        return beganNewResponse
    }
}
