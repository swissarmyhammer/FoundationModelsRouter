import Testing

@testable import FoundationModelsRouter

/// Exercises the waits for an ``AwaitedEvent`` and for a permit of an
/// ``AsyncSemaphore`` that also end on the end of a task (rule T1). The task
/// is the work that must send the event. When it ends first, the test fails
/// by an assertion. The suite needs no session, no network and no GPU.
@Suite("The waits for an event and for a permit also end on the end of a task")
struct TaskEndEventWaitTests {
    /// The production change that makes this test fail: a wait that reads
    /// only the event. That wait does not end when the task ends, so it
    /// records no issue.
    @Test("a wait for an event fails the test and returns when the task ended and no event came")
    func anEventWaitEndsOnTheEndOfTheTask() async {
        let event = AwaitedEvent()
        let ended = Task {}
        defer { ended.cancel() }

        await withKnownIssue("the task ended before the event came") {
            try await RecordedWaitResult.wait(for: event, endingOnEndOf: ended)
        }
        #expect(!event.hasArrived)
    }

    /// The production change that makes this test fail: a wait that reads
    /// only the result of a wait task of its own after the end. The end is
    /// then recorded before that wait task ran, and the test fails although
    /// the event came before the end.
    @Test("a wait for an event returns with no issue when the task sent the event and then ended")
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
    @Test("a wait for an event returns with no issue when the event came while the task runs")
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

    /// The production change that makes this test fail: a wait for a permit
    /// through `AsyncSemaphore.wait()`. That wait does not end when the task
    /// ends, and a cancel does not take it out of the queue: it takes the
    /// next permit later.
    @Test("a wait for a permit fails the test, leaves no waiter and takes no later permit when the task ended first")
    func aPermitWaitEndsOnTheEndOfTheTask() async {
        let semaphore = AsyncSemaphore(value: 0)
        let ended = Task {}
        defer { ended.cancel() }

        await withKnownIssue("the task ended before the semaphore got a permit") {
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
    @Test("a wait for a permit takes the permit with no issue when the task gave it and then ended")
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
    @Test("a wait for a permit takes the permit with no issue when the permit came while the task runs")
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
