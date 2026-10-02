import Synchronization

/// Wakes each task that waits for the next change of a state.
///
/// The owner of the state calls ``signal()`` after each change. A task reads
/// ``changeCount``, reads the state, and calls ``waitForChange(after:)`` with
/// the count it read when the state is not the state it wants. A change that
/// comes between the read of the count and the wait is not lost: the wait then
/// returns at once.
///
/// A `Mutex` rather than an `actor`, for the reason ``AsyncSemaphore`` gives:
/// the check of the count and the suspend are one step. So the cancellation
/// handler of a waiting task resumes the wait at once, with no hop to an
/// actor.
final class ChangeSignal: Sendable {
    /// All mutable state, guarded as a unit so check-and-suspend is atomic.
    private struct State {
        /// How many changes ``signal()`` reported so far.
        var changeCount: UInt64 = 0

        /// The continuation of each waiting task, by ticket.
        var waiters: [UInt64: CheckedContinuation<Bool, Never>] = [:]

        /// The next ticket to hand out.
        var nextTicket: UInt64 = 0

        /// Takes the next ticket, which names one wait for its whole life.
        mutating func takeTicket() -> UInt64 {
            defer { nextTicket += 1 }
            return nextTicket
        }
    }

    /// The state, guarded so that check-and-suspend is atomic.
    private let state = Mutex(State())

    /// How many changes ``signal()`` reported so far.
    var changeCount: UInt64 {
        state.withLock { $0.changeCount }
    }

    /// How many tasks wait now for the next change.
    var waiterCount: Int {
        state.withLock { $0.waiters.count }
    }

    /// Reports one change, and resumes each waiting task with `true`.
    func signal() {
        let woken = state.withLock { state -> [CheckedContinuation<Bool, Never>] in
            state.changeCount += 1
            let waiters = Array(state.waiters.values)
            state.waiters = [:]
            return waiters
        }
        for waiter in woken {
            waiter.resume(returning: true)
        }
    }

    /// Waits until a change comes after the change `seen`, or until the
    /// calling task is cancelled.
    ///
    /// - Parameter seen: The ``changeCount`` the caller read before it read
    ///   the state.
    /// - Returns: `true` when a change came after `seen`, also one that came
    ///   before this call. `false` when the calling task was cancelled first.
    func waitForChange(after seen: UInt64) async -> Bool {
        let ticket = state.withLock { $0.takeTicket() }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                let outcome = state.withLock { state -> Bool? in
                    if state.changeCount != seen {
                        return true
                    }
                    // Read inside the lock, so a cancellation that races this
                    // call is answered here, or finds the continuation below.
                    if Task.isCancelled {
                        return false
                    }
                    state.waiters[ticket] = continuation
                    return nil
                }
                if let outcome {
                    continuation.resume(returning: outcome)
                }
            }
        } onCancel: {
            let waiter = state.withLock { $0.waiters.removeValue(forKey: ticket) }
            waiter?.resume(returning: false)
        }
    }
}
