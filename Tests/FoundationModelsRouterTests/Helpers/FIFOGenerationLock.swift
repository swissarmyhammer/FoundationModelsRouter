@testable import FoundationModelsRouter

/// The lock of one stub model: it gives one generation at a time, first in
/// first out, as the `AsyncMutex` of the `SerialAccessContainer` of MLX does.
///
/// A waiter does not see a cancel: the MLX lock has no cancel handler, so a
/// cancelled caller keeps its place and leaves at its turn. Thus a stub model
/// over this lock serializes its generations as an MLX model does. A tool
/// body runs between two generations, so it holds no lock.
///
/// Each change of the count of the waiters signals ``changes``, so a test
/// waits for a waiter with no clock (``waitForWaiters(_:)``).
actor FIFOGenerationLock {
    /// Whether a generation holds the lock.
    private var isLocked = false

    /// The waiters, in the order they came.
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// The signal of each change of ``waitingCount``.
    nonisolated let changes = ChangeSignal()

    /// The count of the callers that wait for the lock now.
    var waitingCount: Int { waiters.count }

    /// Runs `body` while it holds the lock. A caller that comes while the
    /// lock is held waits behind each caller that came before it.
    ///
    /// - Parameter body: One generation.
    /// - Returns: What `body` returns.
    /// - Throws: What `body` throws.
    func withLock<T: Sendable>(_ body: @Sendable () async throws -> T) async rethrows -> T {
        await lock()
        defer { unlock() }
        return try await body()
    }

    /// Waits until at least `count` callers wait for the lock.
    ///
    /// - Parameter count: How many waiters to wait for.
    /// - Throws: ``ConditionNeverHeld`` when the waiting task was cancelled
    ///   first.
    nonisolated func waitForWaiters(_ count: Int) async throws {
        try await changes.wait(untilAtLeast: count, of: { await self.waitingCount })
    }

    /// Takes the lock, or waits at the end of the line.
    private func lock() async {
        guard isLocked else {
            isLocked = true
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
            changes.signal()
        }
    }

    /// Gives the lock to the first waiter, or frees it.
    private func unlock() {
        guard !waiters.isEmpty else {
            isLocked = false
            return
        }
        waiters.removeFirst().resume()
        changes.signal()
    }
}
