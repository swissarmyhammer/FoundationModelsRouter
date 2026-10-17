import Synchronization

/// A value, and the tasks that wait until a condition holds for it, under one
/// lock.
///
/// The owner changes the value with ``update(_:)``. Each change is the event
/// that wakes the waits, so a wait needs no clock and no poll. A wait also
/// ends when its task is cancelled (rule T1), so a test that cancels a wait
/// leaves no task suspended after the test.
///
/// A `Mutex` and not an `actor`, for the reason that `ChangeSignal` of the
/// router target gives: the check of the value and the suspend are one step,
/// so a change between them is not lost, and the cancel handler of a waiting
/// task resumes the wait at once, with no hop to an actor. The router keeps
/// `ChangeSignal` internal, so this support target cannot use it.
final class ConditionWaitList<Value: Sendable>: Sendable {
    /// One task that waits until its condition holds.
    private struct Waiter {
        /// The ticket that names this wait for its whole life.
        let ticket: UInt64

        /// The condition the task waits for.
        let condition: @Sendable (Value) -> Bool

        /// Resumes the task: `true` when the condition holds, `false` when
        /// the task was cancelled first.
        let continuation: CheckedContinuation<Bool, Never>
    }

    /// The value and the waits, guarded as one unit.
    private struct State {
        /// The value that the conditions read.
        var value: Value

        /// The tasks that wait for a condition that did not hold yet, in the
        /// order they started to wait.
        var waiters: [Waiter] = []

        /// The next ticket to hand out.
        var nextTicket: UInt64 = 0

        /// Takes the next ticket, which names one wait for its whole life.
        mutating func takeTicket() -> UInt64 {
            defer { nextTicket += 1 }
            return nextTicket
        }

        /// Removes the wait of `ticket`.
        ///
        /// - Parameter ticket: The ticket of the wait.
        /// - Returns: The continuation of the wait, or `nil` when the wait
        ///   was resumed before.
        mutating func removeWaiter(_ ticket: UInt64) -> CheckedContinuation<Bool, Never>? {
            guard let index = waiters.firstIndex(where: { $0.ticket == ticket }) else { return nil }
            return waiters.remove(at: index).continuation
        }
    }

    /// The value and the waits.
    private let state: Mutex<State>

    /// Makes a list that holds `value` and no wait.
    ///
    /// - Parameter value: The first value.
    init(_ value: Value) {
        state = Mutex(State(value: value))
    }

    /// The value now.
    var value: Value { state.withLock { $0.value } }

    /// Changes the value, and resumes each wait whose condition now holds.
    ///
    /// - Parameter change: Changes the value. It runs under the lock, so it
    ///   must not suspend or call back into this list.
    func update(_ change: (inout Value) -> Void) {
        let satisfied = state.withLock { state -> [CheckedContinuation<Bool, Never>] in
            change(&state.value)
            let now = state.value
            let resumed = state.waiters.filter { $0.condition(now) }
            state.waiters.removeAll { $0.condition(now) }
            return resumed.map(\.continuation)
        }
        for continuation in satisfied {
            continuation.resume(returning: true)
        }
    }

    /// Waits until `condition` holds for the value, or until the calling task
    /// is cancelled.
    ///
    /// The wait reads the value at once, and again after each
    /// ``update(_:)``. A cancel comes first: a task that was cancelled before
    /// the call, or while it waits, throws also when the condition holds.
    /// Thus a cancelled wait never returns as if the state came.
    ///
    /// - Parameter condition: Tells whether the value is the value that the
    ///   caller waits for. It runs under the lock, so it must not suspend or
    ///   call back into this list.
    /// - Throws: `CancellationError` when the calling task was cancelled
    ///   before the condition held.
    func wait(until condition: @escaping @Sendable (Value) -> Bool) async throws {
        let ticket = state.withLock { $0.takeTicket() }
        let held = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                let outcome = state.withLock { state -> Bool? in
                    // Read inside the lock, so a cancel that races this call
                    // is answered here, or finds the continuation below.
                    if Task.isCancelled { return false }
                    if condition(state.value) { return true }
                    state.waiters.append(Waiter(ticket: ticket, condition: condition, continuation: continuation))
                    return nil
                }
                if let outcome { continuation.resume(returning: outcome) }
            }
        } onCancel: {
            state.withLock { $0.removeWaiter(ticket) }?.resume(returning: false)
        }
        guard held else { throw CancellationError() }
    }
}
