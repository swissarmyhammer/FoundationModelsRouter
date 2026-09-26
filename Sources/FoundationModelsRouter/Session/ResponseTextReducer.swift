/// The shared reducer for the ``SessionEvent/textReset`` accumulation rule.
///
/// The rule: a reset supersedes every fragment accumulated so far — the model
/// abandoned the response it was writing and began another — so the reply is
/// cleared and the next fragment starts a new response. A consumer that
/// applies it holds, character for character, the string
/// ``RoutedSession/respond(to:maxTokens:)`` returns for the same submission
/// (see ``SessionEvent/textReset``).
///
/// ``SessionProjection`` uses it: it asks ``append(_:)`` whether a fragment
/// starts a new response, and so it puts the superseded text into its own
/// transcript row. The projection does not write the rule again.
struct ResponseTextReducer: Sendable, Equatable {
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
