@testable import FoundationModelsRouter

/// Collects the events that a session stream delivered, so the test task can
/// read them while the turn that makes them is still in flight.
///
/// ``watch(_:)`` drains the session-wide feed of one session into a new log,
/// and ``collect(_:)`` drains the stream of one turn into a new log. Each
/// returns the task that drains, which the test cancels or awaits when it is
/// done.
actor SessionEventLog {
    /// Every event delivered so far, in delivery order.
    private(set) var events: [SessionEvent] = []

    /// Appends one delivered event.
    ///
    /// - Parameter event: The event just delivered.
    func append(_ event: SessionEvent) {
        events.append(event)
    }

    /// Every stall report delivered so far, in delivery order.
    var stalls: [GenerationStall] {
        events.compactMap { event in
            guard case .generationStalled(let stall) = event else { return nil }
            return stall
        }
    }

    /// Whether `event` was delivered.
    ///
    /// - Parameter event: The event to look for.
    /// - Returns: `true` when the log holds an event equal to `event`.
    func contains(_ event: SessionEvent) -> Bool {
        events.contains(event)
    }

    /// Subscribes to the session-wide feed of `session` and drains it into a
    /// new log.
    ///
    /// - Parameter session: The session to watch.
    /// - Returns: The log, and the draining task to cancel once the test is
    ///   done reading it.
    static func watch(_ session: RoutedSession) async -> (log: SessionEventLog, drain: Task<Void, Never>) {
        let log = SessionEventLog()
        let stream = await session.streamSessionEvents()
        let drain = Task {
            for await event in stream {
                await log.append(event)
            }
        }
        return (log, drain)
    }

    /// Drains the stream of one turn into a new log.
    ///
    /// - Parameter stream: The stream of the turn.
    /// - Returns: The log, and the draining task. The task ends when the turn
    ///   ends, and throws what the turn throws.
    static func collect(
        _ stream: AsyncThrowingStream<SessionEvent, Error>
    ) -> (log: SessionEventLog, drain: Task<Void, Error>) {
        let log = SessionEventLog()
        let drain = Task {
            for try await event in stream {
                await log.append(event)
            }
        }
        return (log, drain)
    }
}
