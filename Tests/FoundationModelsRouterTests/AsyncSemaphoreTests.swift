import Testing

@testable import FoundationModelsRouter

/// Tests for ``AsyncSemaphore``, the fair (FIFO) await-based concurrency
/// primitive that ``CancellableWait`` is built on. A session, the generation
/// queue of a model and the admission queue of the model pool take no
/// semaphore (task ^3qx0mpt).
///
/// The suite uses no sleep and no poll. Each semaphore under test observes
/// its waiters (``AsyncSemaphore/waiterChanges``), so a test waits for the
/// change that puts a caller in the queue. Concurrency is observed through an
/// actor counter, which signals each change, and a test waits for that
/// signal. The capacity and serialization assertions are safety invariants
/// the semaphore must uphold regardless of scheduling.
@Suite("AsyncSemaphore")
struct AsyncSemaphoreTests {
    /// An actor that tracks how many bodies are concurrently active and the
    /// high-water mark, so tests can assert observed concurrency bounds.
    ///
    /// Each entry and each exit is a change of ``changes``, so a test waits
    /// for a count with no clock.
    private actor ConcurrencyCounter {
        /// How many bodies are active now.
        private(set) var active = 0

        /// The most bodies that were active at one time.
        private(set) var maxActive = 0

        /// The signal that each entry and each exit sends.
        nonisolated let changes = ChangeSignal()

        /// Records that one body entered, and signals ``changes``.
        func enter() {
            active += 1
            maxActive = max(maxActive, active)
            changes.signal()
        }

        /// Records that one body exited, and signals ``changes``.
        func exit() {
            active -= 1
            changes.signal()
        }
    }

    /// Records the order in which waiters resume, for the FIFO assertion.
    private actor OrderProbe {
        private(set) var order: [Int] = []

        func record(_ index: Int) {
            order.append(index)
        }
    }

    /// Makes a semaphore under test, which reports each change of its
    /// waiters.
    ///
    /// - Parameter value: The initial permit count.
    /// - Returns: The semaphore.
    private static func observedSemaphore(value: Int) -> AsyncSemaphore {
        AsyncSemaphore(value: value, observingWaiters: true)
    }

    /// Waits until `count` callers or more wait in the queue of `semaphore`.
    ///
    /// - Parameters:
    ///   - count: How many waiting callers to wait for.
    ///   - semaphore: A semaphore from ``observedSemaphore(value:)``.
    /// - Throws: An issue when the semaphore does not observe its waiters,
    ///   or ``ConditionNeverHeld`` when the test task was cancelled first.
    private static func waitForWaiters(_ count: Int, on semaphore: AsyncSemaphore) async throws {
        let changes = try #require(semaphore.waiterChanges)
        try await changes.wait(until: { semaphore.waiterCount >= count })
    }

    /// Starts a task that takes a permit of `semaphore` with a plain
    /// ``AsyncSemaphore/wait()``, records `index` in `probe`, and gives the
    /// permit back. Waits until the task waits in the queue.
    ///
    /// - Parameters:
    ///   - semaphore: A semaphore from ``observedSemaphore(value:)``, whose
    ///     only permit the test holds.
    ///   - index: The value that the task records.
    ///   - probe: The probe that records the order.
    /// - Returns: The task.
    /// - Throws: What ``waitForWaiters(_:on:)`` throws.
    private static func startQueuedWaiter(
        on semaphore: AsyncSemaphore, recording index: Int, into probe: OrderProbe
    ) async throws -> Task<Void, Never> {
        let waitersBefore = semaphore.waiterCount
        let waiter = Task {
            await semaphore.wait()
            await probe.record(index)
            semaphore.signal()
        }
        try await waitForWaiters(waitersBefore + 1, on: semaphore)
        return waiter
    }

    /// Starts a task that takes a permit of `semaphore` with
    /// `waitUnlessCancelled()`, records `index` in `probe`, and gives the
    /// permit back. Waits until the task waits in the queue.
    ///
    /// - Parameters:
    ///   - semaphore: A semaphore from ``observedSemaphore(value:)``, whose
    ///     only permit the test holds.
    ///   - index: The value that the task records.
    ///   - probe: The probe that records the order.
    /// - Returns: The task.
    /// - Throws: What ``waitForWaiters(_:on:)`` throws.
    private static func startQueuedCancellableWaiter(
        on semaphore: AsyncSemaphore, recording index: Int, into probe: OrderProbe
    ) async throws -> Task<Void, any Error> {
        let waitersBefore = semaphore.waiterCount
        let waiter = Task {
            try await semaphore.waitUnlessCancelled()
            await probe.record(index)
            semaphore.signal()
        }
        try await waitForWaiters(waitersBefore + 1, on: semaphore)
        return waiter
    }

    /// How many bodies the serialization test starts.
    private static let serializedBodies = 10

    @Test("value 1 serializes: two concurrent bodies never overlap")
    func valueOneSerializes() async throws {
        let semaphore = Self.observedSemaphore(value: 1)
        let counter = ConcurrencyCounter()
        // Each body holds its permit until the test signals `hold`, so the
        // test sees the steady state: one body inside, each other body in the
        // queue.
        let hold = AsyncSemaphore(value: 0)

        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<Self.serializedBodies {
                group.addTask {
                    await semaphore.withPermit {
                        await counter.enter()
                        await hold.wait()
                        await counter.exit()
                    }
                }
            }

            try await counter.changes.wait(until: { await counter.active >= 1 })
            try await Self.waitForWaiters(Self.serializedBodies - 1, on: semaphore)
            #expect(await counter.active == 1)

            for _ in 0..<Self.serializedBodies { hold.signal() }
            try await group.waitForAll()
        }

        #expect(await counter.maxActive == 1)
    }

    @Test("value N caps concurrency at N and the extras await")
    func valueNCapsConcurrency() async throws {
        let n = 3
        let total = n + 2
        let gate = Self.observedSemaphore(value: n)
        let counter = ConcurrencyCounter()
        // Bodies suspend on `hold` (value 0) so we can observe the steady state
        // before any of them exits and frees a permit.
        let hold = AsyncSemaphore(value: 0)

        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<total {
                group.addTask {
                    await gate.withPermit {
                        await counter.enter()
                        await hold.wait()
                        await counter.exit()
                    }
                }
            }

            // Wait until N bodies are inside the gate...
            try await counter.changes.wait(until: { await counter.active >= n })
            // ...and the remaining (total - N) are suspended on the gate.
            try await Self.waitForWaiters(total - n, on: gate)

            #expect(await counter.active == n)
            #expect(await counter.maxActive == n)
            #expect(gate.waiterCount == total - n)

            // Release everyone so the group can finish.
            for _ in 0..<total { hold.signal() }
            try await group.waitForAll()
        }

        // Never exceeded the cap across the whole run.
        #expect(await counter.maxActive == n)
    }

    @Test("waiters resume in FIFO arrival order")
    func fifoReleaseOrder() async throws {
        let semaphore = Self.observedSemaphore(value: 1)
        let probe = OrderProbe()
        let n = 5

        // The test task takes the only permit; every waiter must suspend.
        await semaphore.wait()

        // Each waiter joins the queue before the test starts the next one, so
        // the arrival order is 0, 1, 2, ...
        var waiters: [Task<Void, Never>] = []
        for i in 0..<n {
            waiters.append(try await Self.startQueuedWaiter(on: semaphore, recording: i, into: probe))
        }

        // Release the chain; FIFO must resume them 0,1,2,...
        semaphore.signal()
        for waiter in waiters {
            await waiter.value
        }

        #expect(await probe.order == Array(0..<n))
    }

    @Test("a throwing body still releases its permit (no leak)")
    func throwingBodyReleasesPermit() async {
        struct Boom: Error {}
        let semaphore = AsyncSemaphore(value: 1)

        await #expect(throws: Boom.self) {
            try await semaphore.withPermit { throw Boom() }
        }

        // The permit must be back and no waiter stranded.
        #expect(semaphore.availablePermits == 1)
        #expect(semaphore.waiterCount == 0)

        // And it is actually reusable.
        await semaphore.withPermit {}
        #expect(semaphore.availablePermits == 1)
    }

    @Test("a cancelled suspended waiter still acquires in FIFO order and strands no one")
    func cancelledWaiterDoesNotLeakOrStrand() async throws {
        let semaphore = Self.observedSemaphore(value: 1)
        let probe = OrderProbe()

        // The test task takes the only permit; both waiters must suspend.
        await semaphore.wait()

        let first = try await Self.startQueuedWaiter(on: semaphore, recording: 0, into: probe)
        let second = try await Self.startQueuedWaiter(on: semaphore, recording: 1, into: probe)

        // Cancel the front waiter while it is suspended. The non-interrupting
        // acquire keeps it queued, so it must still be served in FIFO order and
        // must not strand the waiter behind it.
        first.cancel()

        // Release the chain.
        semaphore.signal()
        await first.value
        await second.value

        // FIFO held despite the cancellation, neither task was stranded, and
        // the permit accounting is exact (no leak, no over-release).
        #expect(await probe.order == [0, 1])
        #expect(semaphore.availablePermits == 1)
        #expect(semaphore.waiterCount == 0)
    }

    // MARK: - The cancellable acquire

    @Test("a cancelled waitUnlessCancelled waiter leaves the queue and throws")
    func cancellableWaiterLeavesTheQueue() async throws {
        let semaphore = Self.observedSemaphore(value: 1)
        let probe = OrderProbe()

        // The test task takes the only permit, so the waiter must suspend.
        await semaphore.wait()

        let waiter = try await Self.startQueuedCancellableWaiter(on: semaphore, recording: 0, into: probe)

        waiter.cancel()
        await #expect(throws: CancellationError.self) { try await waiter.value }

        // It left the queue rather than staying in it until a signal.
        #expect(semaphore.waiterCount == 0)

        // The permit the test task holds is still the only one outstanding.
        semaphore.signal()
        #expect(semaphore.availablePermits == 1)
        #expect(await probe.order.isEmpty)
    }

    @Test("the next signal goes to the caller that still waits, not to the cancelled one")
    func signalReachesTheRemainingWaiterAfterACancel() async throws {
        let semaphore = Self.observedSemaphore(value: 1)
        let probe = OrderProbe()

        // The test task takes the only permit; both waiters must suspend.
        await semaphore.wait()

        let cancelled = try await Self.startQueuedCancellableWaiter(on: semaphore, recording: 0, into: probe)
        let remaining = try await Self.startQueuedWaiter(on: semaphore, recording: 1, into: probe)

        // Cancel the FRONT waiter. It must leave the queue, so the queue that
        // remains holds the second waiter alone.
        cancelled.cancel()
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        #expect(semaphore.waiterCount == 1)

        semaphore.signal()
        await remaining.value

        // Only the waiter that was never cancelled ran, and the accounting is exact.
        #expect(await probe.order == [1])
        #expect(semaphore.availablePermits == 1)
        #expect(semaphore.waiterCount == 0)
    }

    @Test("an already-cancelled caller throws without taking a permit")
    func alreadyCancelledCallerTakesNoPermit() async {
        let semaphore = AsyncSemaphore(value: 1)
        let cancelled = RunLatch()

        let waiter = Task {
            // The test opens the latch only after it cancelled this task, so
            // the task is cancelled before the acquire, and the permit must
            // stay untouched.
            await cancelled.waitUntilOpen()
            try await semaphore.waitUnlessCancelled()
        }
        waiter.cancel()
        await cancelled.open()
        await #expect(throws: CancellationError.self) { try await waiter.value }

        #expect(semaphore.availablePermits == 1)
        #expect(semaphore.waiterCount == 0)
    }

    @Test("an uncancelled waitUnlessCancelled acquires in FIFO order beside plain waiters")
    func cancellableWaiterKeepsFIFOOrder() async throws {
        let semaphore = Self.observedSemaphore(value: 1)
        let probe = OrderProbe()

        await semaphore.wait()

        let first = try await Self.startQueuedWaiter(on: semaphore, recording: 0, into: probe)
        let second = try await Self.startQueuedCancellableWaiter(on: semaphore, recording: 1, into: probe)
        let third = try await Self.startQueuedWaiter(on: semaphore, recording: 2, into: probe)

        semaphore.signal()
        await first.value
        try? await second.value
        await third.value

        #expect(await probe.order == [0, 1, 2])
        #expect(semaphore.availablePermits == 1)
        #expect(semaphore.waiterCount == 0)
    }
}
