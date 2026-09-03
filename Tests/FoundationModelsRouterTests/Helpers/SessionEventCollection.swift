@testable import FoundationModelsRouter

/// Drains `stream` into an array, in order.
///
/// The one place a test that reads a whole event stream states that loop, so
/// the loop lives once instead of at each site.
///
/// - Parameter stream: The stream to drain.
/// - Returns: Every event the stream yielded, in order.
/// - Throws: Whatever the stream throws.
func collect(_ stream: AsyncThrowingStream<SessionEvent, Error>) async throws -> [SessionEvent] {
    var events: [SessionEvent] = []
    for try await event in stream {
        events.append(event)
    }
    return events
}

/// Drains a session-scoped `stream` into an array, in order.
///
/// ``RoutedSession/close()`` finishes the stream, so a caller drains it after
/// it closes the session the stream came from.
///
/// - Parameter stream: The stream to drain.
/// - Returns: Every event the stream yielded, in order.
func collect(_ stream: AsyncStream<SessionEvent>) async -> [SessionEvent] {
    await stream.reduce(into: []) { $0.append($1) }
}

/// Drains `session`'s `streamEvents(to:)` for one turn into an array, in
/// production order.
///
/// - Parameters:
///   - session: The session to drive one turn on.
///   - prompt: The prompt the turn answers.
/// - Returns: The turn's events, in order.
/// - Throws: Whatever the turn throws.
func collectEvents(_ session: RoutedSession, prompt: String) async throws -> [SessionEvent] {
    try await collect(session.streamEvents(to: prompt))
}

extension SessionEvent {
    /// Whether this event is an open ``ToolInvocationRecord``.
    var isOpenInvocation: Bool {
        carriedInvocation.map { $0.closedAt == nil } ?? false
    }

    /// Whether this event is a close ``ToolInvocationRecord``.
    var isCloseInvocation: Bool {
        carriedInvocation.map { $0.closedAt != nil } ?? false
    }

    /// The ``ToolInvocationRecord`` this event carries, or `nil` for any other event.
    var carriedInvocation: ToolInvocationRecord? {
        if case .toolInvocation(let record) = self { return record }
        return nil
    }

    /// The ``ToolCallReport`` this event carries, or `nil` for any other event.
    var carriedReport: ToolCallReport? {
        if case .toolCallReport(let report) = self { return report }
        return nil
    }
}
