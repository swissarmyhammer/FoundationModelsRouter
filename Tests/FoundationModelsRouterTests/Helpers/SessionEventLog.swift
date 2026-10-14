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

    /// Waits until the feed sent `count` ``SessionEvent/submissionQueued(_:)``
    /// events.
    ///
    /// The session sends the event when its submission joins the queue of its
    /// model behind another job. Thus the event replaces a read of the count
    /// of the waiting jobs of the queue.
    ///
    /// - Parameter count: How many such events to wait for.
    /// - Throws: ``ConditionNeverHeld`` when the waiting task was cancelled
    ///   first.
    nonisolated func waitForQueuedSubmissions(_ count: Int) async throws {
        try await wait(until: { events in
            events.count(where: { event in
                if case .submissionQueued = event { return true }
                return false
            }) >= count
        })
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
