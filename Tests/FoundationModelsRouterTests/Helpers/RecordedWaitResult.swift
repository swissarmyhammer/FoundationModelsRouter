import Synchronization

/// What one wait that runs in a task of its own gave, or `nil` while it
/// waits.
///
/// A test reads it with ``AwaitedCondition/wait(until:)`` instead of
/// `await task.value`. A wait that never returns then fails the test at its
/// `.timeLimit`, and does not hang the test run.
final class RecordedWaitResult: Sendable {
    /// The result of the wait, or `nil` while it waits.
    private let stored = Mutex<Bool?>(nil)

    /// The result of the wait, or `nil` while it waits.
    var value: Bool? { stored.withLock { $0 } }

    /// Records the result of the wait.
    ///
    /// - Parameter result: What the wait gave.
    func record(_ result: Bool) {
        stored.withLock { $0 = result }
    }
}
