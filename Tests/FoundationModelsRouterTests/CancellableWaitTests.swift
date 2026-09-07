import Synchronization
import Testing

@testable import FoundationModelsRouter

/// Tests for ``CancellableWait``, the bridge that makes an `await` on work that
/// cannot itself be cancelled answer the caller's own cancellation.
///
/// The model download behind ``Router/resolve(profile:reporting:)`` is that
/// work: it runs inside an unstructured task the model cache owns, so it takes
/// no cancellation from the resolve that started it. The suite asserts both
/// halves of the bridge — the caller stops waiting, and the work runs on.
@Suite("CancellableWait")
struct CancellableWaitTests {
    private struct Boom: Error {}

    @Test("an uncancelled caller gets the work's value")
    func uncancelledCallerGetsTheValue() async throws {
        let value = try await CancellableWait.value {
            await Task.yield()
            return 7
        }
        #expect(value == 7)
    }

    @Test("the work's own error reaches the caller")
    func workErrorReachesTheCaller() async {
        await #expect(throws: Boom.self) {
            try await CancellableWait.value { throw Boom() }
        }
    }

    @Test("a cancelled caller throws while the work runs on to completion")
    func cancelledCallerStopsWaitingAndTheWorkRunsOn() async throws {
        // The work suspends on a gate the test holds, standing in for a
        // download in flight.
        let workReached = AwaitedEvent()
        let releaseWork = AwaitedEvent()
        let workFinished = AwaitedEvent()

        let caller = Task {
            try await CancellableWait.value {
                workReached.signal()
                try await releaseWork.wait()
                workFinished.signal()
                return 1
            }
        }
        try await workReached.wait()

        // The caller stops waiting although the work is still in flight.
        caller.cancel()
        await #expect(throws: CancellationError.self) { try await caller.value }

        // And the work was never cancelled: it finishes, so a download's part
        // files keep filling the cache instead of being thrown away.
        releaseWork.signal()
        try await workFinished.wait()
    }

    @Test("a caller cancelled before the call throws and never starts the work")
    func alreadyCancelledCallerNeverStartsTheWork() async {
        let started = Mutex(false)

        let caller = Task {
            while !Task.isCancelled { await Task.yield() }
            return try await CancellableWait.value {
                started.withLock { $0 = true }
                return 1
            }
        }
        caller.cancel()
        await #expect(throws: CancellationError.self) { try await caller.value }

        #expect(started.withLock { $0 } == false)
    }
}
