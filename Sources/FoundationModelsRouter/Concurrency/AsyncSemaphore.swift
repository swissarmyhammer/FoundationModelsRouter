import Synchronization

/// A fair (FIFO), `await`-based counting semaphore. It never blocks a thread:
/// a caller with no permit suspends its task and resumes in arrival order.
///
/// Two acquires are offered, and the difference between them is cancellation.
///
/// ``wait()`` is non-throwing, so acquisition runs to completion even when
/// the task is cancelled while suspended. Cancellation is observed at the
/// surrounding `await` boundaries and by the body of ``withPermit(_:)``. Every
/// session gate — the turn lock, the per-model generation gate, fork admission
/// — takes this acquire, because a cancelled waiter that walked away from those
/// queues would leave a gate count that no later release ever balances.
///
/// ``waitUnlessCancelled()`` throws `CancellationError` instead, and a caller
/// the user cancels leaves the queue at once. ``Router/resolve(profile:reporting:)``
/// takes this acquire for the pool lock, where a queued resolve holds nothing
/// yet and can be abandoned safely.
///
/// One arrival order serves both kinds of waiter, so the queue stays fair
/// whichever acquire each caller took, and each continuation is resumed
/// exactly once.
public final class AsyncSemaphore: Sendable {
    /// A suspended waiter's continuation, of whichever kind its acquire made.
    private enum Resumption {
        /// A ``wait()`` caller, which cannot fail.
        case nonCancellable(CheckedContinuation<Void, Never>)
        /// A ``waitUnlessCancelled()`` caller, which fails on cancellation.
        case cancellable(CheckedContinuation<Void, any Error>)

        /// Resumes the waiter with the permit it was queued for.
        func resumeAcquired() {
            switch self {
            case .nonCancellable(let continuation):
                continuation.resume()
            case .cancellable(let continuation):
                continuation.resume()
            }
        }
    }

    /// All mutable state, guarded as a unit so check-and-suspend is atomic.
    private struct State {
        /// Permits currently available for immediate acquisition.
        var permits: Int

        /// Suspended waiters in FIFO arrival order, by ticket; the front
        /// resumes first. One order covers both acquires.
        var order: [Int] = []

        /// The continuation of each suspended ``wait()`` caller, by ticket.
        var nonCancellable: [Int: CheckedContinuation<Void, Never>] = [:]

        /// The continuation of each suspended ``waitUnlessCancelled()`` caller,
        /// by ticket.
        var cancellable: [Int: CheckedContinuation<Void, any Error>] = [:]

        /// Tickets of ``waitUnlessCancelled()`` callers that have taken a ticket
        /// and not yet reached their suspension point. A cancellation that
        /// arrives inside that window has no continuation to resume yet.
        var arriving: Set<Int> = []

        /// Tickets cancelled inside that window, which their own suspension
        /// point reads and answers with `CancellationError`.
        var cancelledOnArrival: Set<Int> = []

        /// The next ticket to hand out.
        var nextTicket = 0

        /// Takes the next ticket, which identifies one acquire for its whole life.
        mutating func takeTicket() -> Int {
            defer { nextTicket += 1 }
            return nextTicket
        }

        /// Removes and returns the continuation queued under `ticket`.
        ///
        /// - Parameter ticket: A ticket standing in ``order``.
        /// - Returns: That waiter's continuation.
        mutating func takeResumption(ticket: Int) -> Resumption {
            if let continuation = nonCancellable.removeValue(forKey: ticket) {
                return .nonCancellable(continuation)
            }
            guard let continuation = cancellable.removeValue(forKey: ticket) else {
                preconditionFailure("a queued ticket keeps its continuation until it is resumed")
            }
            return .cancellable(continuation)
        }
    }

    /// What a cancellable acquire found when it reached its suspension point.
    private enum Arrival {
        /// A permit was free and this caller took it.
        case acquired
        /// The caller was cancelled before it reached the suspension point.
        case cancelled
        /// The caller joined the FIFO queue.
        case queued
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
    /// Returns once a permit has been acquired. Cancelling the calling task
    /// does not interrupt the acquire: the waiter keeps its place and is served
    /// in turn, so the gate this semaphore stands over stays balanced. Use
    /// ``waitUnlessCancelled()`` where the caller must be able to walk away.
    ///
    /// The check-and-suspend is atomic: the permit is either taken immediately
    /// or the caller is enqueued, never both, so the continuation is resumed
    /// exactly once.
    public func wait() async {
        let ticket = state.withLock { $0.takeTicket() }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let acquired = state.withLock { state -> Bool in
                if state.permits > 0 {
                    state.permits -= 1
                    return true
                }
                state.order.append(ticket)
                state.nonCancellable[ticket] = continuation
                return false
            }
            if acquired {
                continuation.resume()
            }
        }
    }

    /// Acquires a permit, suspending in FIFO order while none is available, and
    /// gives up the acquire when the calling task is cancelled.
    ///
    /// A cancelled waiter leaves the FIFO queue at once rather than waiting for
    /// a ``signal()`` that would otherwise be spent on a caller that no longer
    /// wants it: the next signal goes to the caller that still waits. A caller
    /// that throws never held a permit, so it owes no ``signal()``.
    ///
    /// - Throws: `CancellationError` when the calling task is cancelled before
    ///   the permit is acquired.
    package func waitUnlessCancelled() async throws {
        try Task.checkCancellation()
        let ticket = state.withLock { state -> Int in
            let ticket = state.takeTicket()
            state.arriving.insert(ticket)
            return ticket
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, any Error>) in
                let arrival = state.withLock { state -> Arrival in
                    state.arriving.remove(ticket)
                    if state.cancelledOnArrival.remove(ticket) != nil {
                        return .cancelled
                    }
                    if state.permits > 0 {
                        state.permits -= 1
                        return .acquired
                    }
                    state.order.append(ticket)
                    state.cancellable[ticket] = continuation
                    return .queued
                }
                switch arrival {
                case .acquired:
                    continuation.resume()
                case .cancelled:
                    continuation.resume(throwing: CancellationError())
                case .queued:
                    break
                }
            }
        } onCancel: {
            let continuation = state.withLock { state -> CheckedContinuation<Void, any Error>? in
                if let index = state.order.firstIndex(of: ticket) {
                    state.order.remove(at: index)
                    return state.cancellable.removeValue(forKey: ticket)
                }
                // The acquire has taken its ticket but has not reached its
                // suspension point yet, so the answer is left for it to read.
                // Any other ticket has already settled, and cancelling a
                // settled acquire is a no-op.
                if state.arriving.contains(ticket) {
                    state.cancelledOnArrival.insert(ticket)
                }
                return nil
            }
            continuation?.resume(throwing: CancellationError())
        }
    }

    /// Releases one permit, resuming the longest-waiting suspended caller if any.
    ///
    /// When a waiter is present the freed permit is handed directly to the front
    /// of the FIFO queue (the permit count is unchanged); otherwise the count is
    /// incremented for a future ``wait()``.
    public func signal() {
        let next = state.withLock { state -> Resumption? in
            guard let ticket = state.order.first else {
                state.permits += 1
                return nil
            }
            state.order.removeFirst()
            return state.takeResumption(ticket: ticket)
        }
        next?.resumeAcquired()
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
        state.withLock { $0.order.count }
    }
}
