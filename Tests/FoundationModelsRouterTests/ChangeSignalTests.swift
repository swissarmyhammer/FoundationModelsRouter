import Testing

@testable import FoundationModelsRouter

/// Exercises ``ChangeSignal/waitForChange(after:)``, one test for each path
/// of the wait: a change that came first, a cancel before the wait registers,
/// a cancel after it registers, and one signal that resumes several waits.
/// After each path, no wait stays registered (``ChangeSignal/waiterCount``).
/// One more test exercises ``ChangeSignal/waiterChanges``, which reports each
/// change of ``ChangeSignal/waiterCount``.
///
/// Each test reads the order of the steps, not a clock. A wait that runs in a
/// task of its own gives its result through a ``RecordedWaitResult``, which
/// signals ``ChangeSignal/waiterChanges`` of the signal under test. So one
/// wait of the test sees a registration and a result alike.
@Suite("A change signal wakes each task that waits for the next change")
struct ChangeSignalTests {
    /// One wait that runs in a task of its own.
    struct StartedWait {
        /// The task of the wait.
        let task: Task<Void, Never>

        /// Gets the result of the wait.
        let result: RecordedWaitResult
    }

    /// How many tasks wait at the same time in the test of one signal that
    /// resumes several waits.
    private static let concurrentWaiterCount = 3

    /// Makes a signal that reports each change of its waiters, and gives
    /// that report.
    ///
    /// - Returns: The signal, and its ``ChangeSignal/waiterChanges``.
    /// - Throws: When the signal reports no change of its waiters.
    private static func makeObservedSignal() throws -> (signal: ChangeSignal, waiters: ChangeSignal) {
        let signal = ChangeSignal(observingWaiters: true)
        return (signal, try #require(signal.waiterChanges))
    }

    /// Starts one wait for a change after `seen` in a task of its own.
    ///
    /// - Parameters:
    ///   - signal: The signal to wait on.
    ///   - seen: The change count that the wait starts from.
    ///   - waiters: The signal that the result of the wait reports to.
    ///   - cancelledFirst: Whether the task cancels itself before the wait.
    /// - Returns: The wait.
    private static func startWait(
        on signal: ChangeSignal, after seen: UInt64, reportingTo waiters: ChangeSignal, cancelledFirst: Bool = false
    ) -> StartedWait {
        let result = RecordedWaitResult(reportingTo: waiters)
        let task = Task {
            if cancelledFirst {
                withUnsafeCurrentTask { $0?.cancel() }
            }
            result.record(await signal.waitForChange(after: seen))
        }
        return StartedWait(task: task, result: result)
    }

    /// Starts one wait for a change after `seen` in a task of its own, and
    /// returns when the wait is registered.
    ///
    /// - Parameters:
    ///   - signal: The signal to wait on.
    ///   - waiters: The ``ChangeSignal/waiterChanges`` of `signal`.
    ///   - seen: The change count that the wait starts from.
    ///   - registered: How many waits are registered when this wait is.
    /// - Returns: The wait.
    /// - Throws: ``ConditionNeverHeld`` when the test task is cancelled
    ///   before the wait is registered.
    private static func startRegisteredWait(
        on signal: ChangeSignal, observedBy waiters: ChangeSignal, after seen: UInt64, registered: Int = 1
    ) async throws -> StartedWait {
        let wait = startWait(on: signal, after: seen, reportingTo: waiters)
        try await waiters.wait(until: { signal.waiterCount == registered })
        return wait
    }

    @Test("a change between the read of the count and the wait ends the wait at once with true")
    func aChangeBeforeTheWaitEndsItAtOnce() async {
        let signal = ChangeSignal()
        let seen = signal.changeCount
        signal.signal()

        #expect(await signal.waitForChange(after: seen))

        #expect(signal.waiterCount == 0)
    }

    @Test("a cancel before the wait registers ends the wait at once with false")
    func aCancelBeforeTheRegistrationEndsTheWait() async throws {
        let (signal, waiters) = try Self.makeObservedSignal()
        let seen = signal.changeCount

        let wait = Self.startWait(on: signal, after: seen, reportingTo: waiters, cancelledFirst: true)
        try await waiters.wait(until: { wait.result.value != nil || signal.waiterCount > 0 })

        #expect(signal.waiterCount == 0)
        #expect(signal.changeCount == seen)
        // Ends a wait that registered in spite of its cancel, so the test
        // ends also when the expectation above failed.
        signal.signal()
        try await waiters.wait(until: { wait.result.value != nil })
        #expect(wait.result.value == false)
    }

    @Test("a cancel after the wait registers removes the wait and ends it with false")
    func aCancelAfterTheRegistrationRemovesTheWait() async throws {
        let (signal, waiters) = try Self.makeObservedSignal()
        let seen = signal.changeCount
        let wait = try await Self.startRegisteredWait(on: signal, observedBy: waiters, after: seen)

        wait.task.cancel()
        try await waiters.wait(until: { wait.result.value != nil })

        #expect(wait.result.value == false)
        #expect(signal.waiterCount == 0)
        #expect(signal.changeCount == seen)
    }

    @Test("one signal resumes each wait that is registered with true")
    func oneSignalResumesEachWait() async throws {
        let (signal, waiters) = try Self.makeObservedSignal()
        let seen = signal.changeCount
        var registeredWaits: [StartedWait] = []
        for registered in 1...Self.concurrentWaiterCount {
            registeredWaits.append(
                try await Self.startRegisteredWait(on: signal, observedBy: waiters, after: seen, registered: registered))
        }
        let waits = registeredWaits

        signal.signal()
        try await waiters.wait(until: { waits.allSatisfy { $0.result.value != nil } })

        #expect(waits.allSatisfy { $0.result.value == true })
        #expect(signal.waiterCount == 0)
    }

    @Test("a registration, a signal and a cancel of a wait each report a change of the waiters")
    func eachChangeOfTheWaitersIsReported() async throws {
        let (signal, waiters) = try Self.makeObservedSignal()
        // The results report to a signal of their own, so each report that
        // `waiters` counts is a change of the waiters.
        let results = ChangeSignal()

        let resumed = Self.startWait(on: signal, after: signal.changeCount, reportingTo: results)
        try await waiters.wait(until: { waiters.changeCount == 1 && signal.waiterCount == 1 })
        signal.signal()
        #expect(waiters.changeCount == 2)
        try await results.wait(until: { resumed.result.value != nil })

        let cancelled = Self.startWait(on: signal, after: signal.changeCount, reportingTo: results)
        try await waiters.wait(until: { waiters.changeCount == 3 && signal.waiterCount == 1 })
        cancelled.task.cancel()
        try await results.wait(until: { cancelled.result.value != nil })

        #expect(resumed.result.value == true)
        #expect(cancelled.result.value == false)
        #expect(waiters.changeCount == 4)
        #expect(signal.waiterCount == 0)
    }

    @Test("a signal that observes no waiters reports no change of its waiters")
    func aSignalWithNoObservationHasNoWaiterChanges() {
        #expect(ChangeSignal().waiterChanges == nil)
    }
}
