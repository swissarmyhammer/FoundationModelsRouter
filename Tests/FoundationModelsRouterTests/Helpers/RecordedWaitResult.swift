import Synchronization

@testable import FoundationModelsRouter

/// What one wait that runs in a task of its own gave, or `nil` while it
/// waits.
///
/// The record is an event: ``record(_:)`` signals ``changes``. A test waits
/// for the result with `changes.wait(until: { result.value != nil })`, or
/// reads it once to see whether the wait has ended yet. A `nil` value tells
/// the test that the wait has not returned.
final class RecordedWaitResult: Sendable {
    /// The result of the wait, or `nil` while it waits.
    private let stored = Mutex<Bool?>(nil)

    /// The signal that ``record(_:)`` sends after it records the result.
    let changes: ChangeSignal

    /// The result of the wait, or `nil` while it waits.
    var value: Bool? { stored.withLock { $0 } }

    /// Makes an empty result.
    ///
    /// - Parameter changes: The signal to send when the result is recorded.
    ///   A test gives a signal that also reports an other state, when it
    ///   waits for that state or this result in one wait. The default is a
    ///   new signal of this result alone.
    init(reportingTo changes: ChangeSignal = ChangeSignal()) {
        self.changes = changes
    }

    /// Records the result of the wait, and signals ``changes``.
    ///
    /// - Parameter result: What the wait gave.
    func record(_ result: Bool) {
        stored.withLock { $0 = result }
        changes.signal()
    }
}
