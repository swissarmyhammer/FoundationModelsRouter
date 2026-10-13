import Synchronization

/// What one wait that runs in a task of its own gave, or `nil` while it
/// waits.
///
/// A test reads it with ``AwaitedCondition/wait(until:)``, or reads it once to
/// see whether the wait has ended yet. A `nil` value tells the test that the
/// wait has not returned.
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
