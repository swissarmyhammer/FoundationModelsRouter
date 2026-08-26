import Synchronization

/// A fair (FIFO), `await`-based counting semaphore. It never blocks a thread:
/// a caller with no permit suspends its task and resumes in arrival order.
///
/// ``wait()`` is non-throwing, so acquisition runs to completion even when
/// the task is cancelled while suspended. Cancellation is observed at the
/// surrounding `await` boundaries and by the body of ``withPermit(_:)``.
public final class AsyncSemaphore: Sendable {
    /// All mutable state, guarded as a unit so check-and-suspend is atomic.
    private struct State {
        /// Permits currently available for immediate acquisition.
        var permits: Int
        /// Suspended waiters in FIFO arrival order; the front resumes first.
        var waiters: [CheckedContinuation<Void, Never>] = []
    }

    private let state: Mutex<State>

    /// Creates a semaphore with `value` permits available.
    ///
    /// - Parameter value: The initial permit count. `1` yields a serial gate;
    ///   `N` admits up to `N` concurrent holders.
    public init(value: Int) {
        precondition(value >= 0, "AsyncSemaphore value must be non-negative")
        state = Mutex(State(permits: value))
    }

    /// Acquires a permit, suspending in FIFO order while none is available.
    ///
    /// Returns once a permit has been acquired. The check-and-suspend is atomic:
    /// the permit is either taken immediately or the caller is enqueued, never
    /// both, so the continuation is resumed exactly once.
    public func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let acquired = state.withLock { state -> Bool in
                if state.permits > 0 {
                    state.permits -= 1
                    return true
                }
                state.waiters.append(continuation)
                return false
            }
            if acquired {
                continuation.resume()
            }
        }
    }

    /// Releases one permit, resuming the longest-waiting suspended caller if any.
    ///
    /// When a waiter is present the freed permit is handed directly to the front
    /// of the FIFO queue (the permit count is unchanged); otherwise the count is
    /// incremented for a future ``wait()``.
    public func signal() {
        let next = state.withLock { state -> CheckedContinuation<Void, Never>? in
            if state.waiters.isEmpty {
                state.permits += 1
                return nil
            }
            return state.waiters.removeFirst()
        }
        next?.resume()
    }

    /// Acquires a permit, runs `body`, and releases the permit on the way out.
    ///
    /// The release happens in a `defer`, so the permit is returned whether `body`
    /// returns normally, throws, or is unwound by cancellation — a permit can
    /// never leak.
    ///
    /// - Parameter body: The work to run while holding a permit.
    /// - Returns: Whatever `body` returns.
    /// - Throws: Rethrows any error thrown by `body`.
    package func withPermit<T>(_ body: () async throws -> T) async rethrows -> T {
        await wait()
        defer { signal() }
        return try await body()
    }

    /// The number of permits currently available for immediate acquisition.
    ///
    /// Exposed for observability and deterministic testing; not part of the
    /// gating contract.
    var availablePermits: Int {
        state.withLock { $0.permits }
    }

    /// The number of callers currently suspended waiting for a permit.
    ///
    /// Exposed for observability and deterministic testing; not part of the
    /// gating contract.
    var waiterCount: Int {
        state.withLock { $0.waiters.count }
    }
}
