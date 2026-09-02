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
