import Testing

@testable import FoundationModelsRouter

/// Tests for ``AsyncSemaphore``, the fair (FIFO) await-based concurrency
/// primitive both router gates are built on (per-model serial gate at value 1,
/// fork admission at value `maxConcurrentForks`).
///
/// The suite avoids sleep-based timing. Concurrency is observed through an
/// actor counter, and ordering is made deterministic by spinning on the
/// semaphore's `waiterCount`/`availablePermits` observability hooks (with
/// cooperative `Task.yield()`) until the system reaches a known state — never
/// "sleep and assume". The capacity and serialization assertions are safety
/// invariants the semaphore must uphold regardless of scheduling.
@Suite("AsyncSemaphore")
struct AsyncSemaphoreTests {
    /// An actor that tracks how many bodies are concurrently active and the
    /// high-water mark, so tests can assert observed concurrency bounds.
    private actor ConcurrencyCounter {
        private(set) var active = 0
        private(set) var maxActive = 0

        func enter() {
            active += 1
            maxActive = max(maxActive, active)
        }

        func exit() {
            active -= 1
        }
    }

    /// Records the order in which waiters resume, for the FIFO assertion.
    private actor OrderProbe {
        private(set) var order: [Int] = []

        func record(_ index: Int) {
            order.append(index)
        }
    }

    @Test("value 1 serializes: two concurrent bodies never overlap")
    func valueOneSerializes() async {
        let semaphore = AsyncSemaphore(value: 1)
        let counter = ConcurrencyCounter()

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<10 {
                group.addTask {
                    await semaphore.withPermit {
                        await counter.enter()
                        // Yield repeatedly while holding the permit: if the
                        // gate were broken another body would overlap here.
                        for _ in 0..<3 { await Task.yield() }
                        await counter.exit()
                    }
                }
            }
        }

        #expect(await counter.maxActive == 1)
    }

    @Test("value N caps concurrency at N and the extras await")
    func valueNCapsConcurrency() async {
        let n = 3
        let total = n + 2
        let gate = AsyncSemaphore(value: n)
        let counter = ConcurrencyCounter()
        // Bodies park on `hold` (value 0) so we can observe the steady state
        // before any of them exits and frees a permit.
        let hold = AsyncSemaphore(value: 0)

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<total {
                group.addTask {
                    await gate.withPermit {
                        await counter.enter()
                        await hold.wait()
                        await counter.exit()
                    }
                }
            }

            // Wait until exactly N bodies are inside the gate...
            while await counter.active < n { await Task.yield() }
            // ...and the remaining (total - N) are parked on the gate.
            while gate.waiterCount < (total - n) { await Task.yield() }

            #expect(await counter.active == n)
            #expect(await counter.maxActive == n)
            #expect(gate.waiterCount == total - n)

            // Release everyone so the group can finish.
            for _ in 0..<total { hold.signal() }
            await group.waitForAll()
        }

        // Never exceeded the cap across the whole run.
        #expect(await counter.maxActive == n)
    }

    @Test("waiters resume in FIFO arrival order")
    func fifoReleaseOrder() async {
        let semaphore = AsyncSemaphore(value: 1)
        let probe = OrderProbe()
        let n = 5

        // The test task takes the only permit; every waiter must park.
        await semaphore.wait()

        await withTaskGroup(of: Void.self) { group in
            for i in 0..<n {
                group.addTask {
                    await semaphore.wait()
                    await probe.record(i)
                    semaphore.signal()
                }
                // Deterministically establish arrival order: only launch the
                // next waiter once this one has actually parked.
                while semaphore.waiterCount < i + 1 { await Task.yield() }
            }

            // Release the chain; FIFO must resume them 0,1,2,...
            semaphore.signal()
            await group.waitForAll()
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

    @Test("a cancelled parked waiter still acquires in turn and strands no one")
    func cancelledWaiterDoesNotLeakOrStrand() async {
        let semaphore = AsyncSemaphore(value: 1)
        let probe = OrderProbe()

        // The test task takes the only permit; both waiters must park.
        await semaphore.wait()

        let first = Task {
            await semaphore.wait()
            await probe.record(0)
            semaphore.signal()
        }
        while semaphore.waiterCount < 1 { await Task.yield() }

        let second = Task {
            await semaphore.wait()
            await probe.record(1)
            semaphore.signal()
        }
        while semaphore.waiterCount < 2 { await Task.yield() }

        // Cancel the front waiter while it is parked. The non-interrupting
        // acquire keeps it queued, so it must still be served in FIFO turn and
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
}
