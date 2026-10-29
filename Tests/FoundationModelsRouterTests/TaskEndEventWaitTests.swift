import Testing

@testable import FoundationModelsRouter

/// Exercises the waits for an ``AwaitedEvent``, for a permit of an
/// ``AsyncSemaphore`` and for a state on a ``ChangeSignal`` that also end on
/// the end of a task (rule T1). The task is the work that must send the event
/// or make the state. When it ends first, the wait throws
/// ``FailureEventCameFirst``. The suite needs no session, no network and no
/// GPU.
@Suite("The waits for an event, for a permit and for a state also end on the end of a task")
struct TaskEndEventWaitTests {
    /// The production change that makes this test fail: a wait that reads
    /// only the state. That wait does not end when the task ends, so it
    /// throws nothing.
    @Test("a wait for a state throws and returns when the task ended and the state did not come")
    func aStateWaitEndsOnTheEndOfTheTask() async {
        let state = AwaitedEvent()
        let ended = Task {}
        defer { ended.cancel() }

        await #expect(throws: FailureEventCameFirst.self) {
            try await state.changes.wait(until: { state.hasArrived }, endingOnEndOf: ended)
        }
        #expect(!state.hasArrived)
    }

    /// The production change that makes this test fail: a wait that reads
    /// the end of the task before the state. The end then fails the test
    /// although the state came before the end.
    @Test("a wait for a state returns with no error when the task made the state and then ended")
    func aStateWaitReturnsWhenTheStateCameBeforeTheEnd() async throws {
        let state = AwaitedEvent()
        let making = Task { state.signal() }
        defer { making.cancel() }
        await making.value

        try await state.changes.wait(until: { state.hasArrived }, endingOnEndOf: making)
        #expect(state.hasArrived)
    }

    /// The production change that makes this test fail: a wait that reads
    /// only the event. That wait does not end when the task ends, so it
    /// throws nothing.
    @Test("a wait for an event throws and returns when the task ended and no event came")
    func anEventWaitEndsOnTheEndOfTheTask() async {
        let event = AwaitedEvent()
        let ended = Task {}
        defer { ended.cancel() }

        await #expect(throws: FailureEventCameFirst.self) {
            try await RecordedWaitResult.wait(for: event, endingOnEndOf: ended)
        }
        #expect(!event.hasArrived)
    }

    /// The production change that makes this test fail: a wait that reads
    /// only the result of a wait task of its own after the end. The end is
    /// then recorded before that wait task ran, and the test fails although
    /// the event came before the end.
    @Test("a wait for an event returns with no error when the task sent the event and then ended")
    func anEventWaitReturnsWhenTheEventCameBeforeTheEnd() async throws {
        let event = AwaitedEvent()
        let sending = Task { event.signal() }
        defer { sending.cancel() }
        await sending.value

        try await RecordedWaitResult.wait(for: event, endingOnEndOf: sending)
        #expect(event.hasArrived)
    }

    /// The production change that makes this test fail: a wait that ends
    /// before the event came. The event is then not sent after the wait.
    @Test("a wait for an event returns with no error when the event came while the task runs")
    func anEventWaitReturnsWhenTheEventCame() async throws {
        let event = AwaitedEvent()
        let release = AwaitedEvent()
        let sending = Task {
            event.signal()
            try await release.wait()
        }
        // The defer ends the task also when the wait throws.
        defer { sending.cancel() }

        try await RecordedWaitResult.wait(for: event, endingOnEndOf: sending)
        #expect(event.hasArrived)
        release.signal()
        try await sending.value
    }

    /// The production change that makes this test fail: a wait of a log that
    /// reads only the events. The stream of the log ended with no event, and
    /// that wait does not end, so it throws nothing.
    @Test("a wait for an event of a log throws and returns when the drain ended and no event came")
    func aLogWaitEndsOnTheEndOfTheDrain() async {
        let (log, drain) = SessionEventLog.collect(AsyncThrowingStream { $0.finish() })
        defer { drain.cancel() }

        await #expect(throws: FailureEventCameFirst.self) {
            try await log.wait(until: { !$0.isEmpty }, endingOnEndOf: drain)
        }
        #expect(await log.events.isEmpty)
    }

    /// The production change that makes this test fail: a wait of a log that
    /// reads the end of the drain before the events. The end then fails the
    /// test although the event came before the end.
    @Test("a wait for an event of a log returns with no error when the stream sent the event and then ended")
    func aLogWaitReturnsWhenTheEventCameBeforeTheEnd() async throws {
        let (log, drain) = SessionEventLog.collect(
            AsyncThrowingStream { continuation in
                continuation.yield(.workStarted)
                continuation.finish()
            })
        defer { drain.cancel() }
        try await drain.value

        try await log.wait(until: { !$0.isEmpty }, endingOnEndOf: drain)
        #expect(await log.events == [.workStarted])
    }

    /// The production change that makes this test fail: a wait for a permit
    /// through `AsyncSemaphore.wait()`. That wait does not end when the task
    /// ends, and a cancel does not take it out of the queue: it takes the
    /// next permit later.
    @Test("a wait for a permit throws, leaves no waiter and takes no later permit when the task ended first")
    func aPermitWaitEndsOnTheEndOfTheTask() async {
        let semaphore = AsyncSemaphore(value: 0)
        let ended = Task {}
        defer { ended.cancel() }

        await #expect(throws: FailureEventCameFirst.self) {
            try await RecordedWaitResult.wait(forPermitOf: semaphore, endingOnEndOf: ended)
        }
        #expect(semaphore.waiterCount == 0)
        semaphore.signal()
        #expect(semaphore.availablePermits == 1)
    }

    /// The production change that makes this test fail: a wait that reads
    /// only the result of its wait task after the end, or that cancels that
    /// task and leaves the permit in the semaphore. The test then fails
    /// although the permit came before the end, or the permit stays.
    @Test("a wait for a permit takes the permit with no error when the task gave it and then ended")
    func aPermitWaitTakesThePermitThatCameBeforeTheEnd() async throws {
        let semaphore = AsyncSemaphore(value: 0)
        let signalling = Task { semaphore.signal() }
        defer { signalling.cancel() }
        await signalling.value

        try await RecordedWaitResult.wait(forPermitOf: semaphore, endingOnEndOf: signalling)
        #expect(semaphore.availablePermits == 0)
        #expect(semaphore.waiterCount == 0)
    }

    /// The production change that makes this test fail: a wait that ends
    /// before the permit came. The permit then stays in the semaphore.
    @Test("a wait for a permit takes the permit with no error when the permit came while the task runs")
    func aPermitWaitTakesThePermitThatCame() async throws {
        let semaphore = AsyncSemaphore(value: 0)
        let release = AwaitedEvent()
        let signalling = Task {
            semaphore.signal()
            try await release.wait()
        }
        // The defer ends the task also when the wait throws.
        defer { signalling.cancel() }

        try await RecordedWaitResult.wait(forPermitOf: semaphore, endingOnEndOf: signalling)
        #expect(semaphore.availablePermits == 0)
        release.signal()
        try await signalling.value
    }
}
