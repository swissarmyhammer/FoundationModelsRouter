/// What ``RoutedSession/respond(elicitationId:response:)`` did with a delivered answer.
public enum ElicitationAnswerDelivery: Sendable, Equatable {
    /// The answer resumed the awaiting run and closed the entry.
    case delivered

    /// A URL-mode accept was recorded. The run resumes when
    /// ``RoutedSession/complete(elicitationId:)`` arrives.
    case acceptedAwaitingCompletion

    /// No pending elicitation matches the id. A safe no-op.
    case noPendingElicitation
}

/// What ``RoutedSession/complete(elicitationId:)`` did.
public enum ElicitationCompletionDelivery: Sendable, Equatable {
    /// The completion resumed the accepted URL-mode entry and closed it.
    case completed

    /// No accepted pending elicitation matches the id. A safe no-op.
    case noPendingElicitation
}
