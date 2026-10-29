import Testing

@testable import FoundationModelsRouter

/// Collects the events that a session stream delivered, so the test task can
/// read them while the answer that makes them is still in flight.
///
/// ``watch(_:)`` drains the session-wide feed of one session into a new log,
/// and ``collect(_:)`` drains the stream of one answer into a new log. Each
/// returns the task that drains, which the test cancels or awaits when it is
/// done.
///
/// Each append is a change of ``changes``, so a test waits for an event with
/// ``wait(until:)`` and with no clock.
actor SessionEventLog {
    /// Every event delivered so far, in delivery order.
    private(set) var events: [SessionEvent] = []

    /// The signal that ``append(_:)`` sends after each event.
    nonisolated let changes = ChangeSignal()

    /// Appends one delivered event, and signals ``changes``.
    ///
    /// - Parameter event: The event just delivered.
    func append(_ event: SessionEvent) {
        events.append(event)
        changes.signal()
    }

    /// Waits until the events delivered so far satisfy `condition`.
    ///
    /// - Parameter condition: Tells whether the events are the events that
    ///   the test waits for.
    /// - Throws: ``ConditionNeverHeld`` when the waiting task was cancelled
    ///   first.
    nonisolated func wait(until condition: @Sendable ([SessionEvent]) -> Bool) async throws {
        try await changes.wait(until: { condition(await self.events) })
    }

    /// Waits until the events delivered so far satisfy `condition`, or until
    /// `drain` ended (rule T1). When `drain` ended and the events do not
    /// satisfy `condition`, the wait throws ``FailureEventCameFirst``.
    ///
    /// `drain` is the task of ``watch(_:)`` or ``collect(_:)``. It ends when
    /// its stream ends, after it appended the last event. The close of a
    /// session ends its feed. So a test that closes the session after the work
    /// that makes the events ended has a failure event that comes after each
    /// event of that work in every run.
    ///
    /// - Parameters:
    ///   - condition: Tells whether the events are the events that the test
    ///     waits for.
    ///   - drain: The task that drains the stream into this log.
    ///   - sourceLocation: The place of the call, for the failure.
    /// - Throws: ``FailureEventCameFirst`` when `drain` ended first, or
    ///   ``ConditionNeverHeld`` when the waiting task was cancelled first.
    nonisolated func wait<Failure: Error>(
        until condition: @Sendable ([SessionEvent]) -> Bool, endingOnEndOf drain: Task<Void, Failure>,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        try await changes.wait(
            until: { condition(await self.events) }, endingOnEndOf: drain, sourceLocation: sourceLocation)
    }

    /// Every stall report delivered so far, in delivery order.
    var stalls: [GenerationStall] {
        events.compactMap { event in
            guard case .generationStalled(let stall) = event else { return nil }
            return stall
        }
    }

    /// Subscribes to the session-wide feed of `session` and drains it into a
    /// new log.
    ///
    /// - Parameter session: The session to watch.
    /// - Returns: The log, and the draining task to cancel once the test is
    ///   done reading it.
    static func watch(_ session: any RoutedSession) async -> (log: SessionEventLog, drain: Task<Void, Never>) {
        let log = SessionEventLog()
        let stream = await session.streamSessionEvents().events
        let drain = Task {
            for await event in stream {
                await log.append(event)
            }
        }
        return (log, drain)
    }

    /// Drains the stream of one answer into a new log.
    ///
    /// - Parameter stream: The stream of the answer.
    /// - Returns: The log, and the draining task. The task ends when the answer
    ///   ends, and throws what the answer throws.
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
