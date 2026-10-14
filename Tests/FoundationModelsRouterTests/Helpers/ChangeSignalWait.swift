@testable import FoundationModelsRouter

/// Thrown by ``ChangeSignal/wait(until:)`` when the waiting task was cancelled
/// before the state held. The test that caught it stops there, and does not
/// assert on a state that never came.
struct ConditionNeverHeld: Error {}

/// The one wait of the tests for a state: read the state, and when it is not
/// the state that the test wants, wait for the next change.
///
/// The owner of the state calls ``ChangeSignal/signal()`` after each change.
/// A test recorder (a backend that records its prompts, a log of the events
/// of a session) owns a signal of its own for this purpose. The session gives
/// its internal signals (``RoutedSessionActor/idleChanges``,
/// ``RoutedSessionActor/stateChanges``) through `SessionPlumbingAccess`.
///
/// No clock, no poll and no limit ends the wait. The wait ends when the state
/// holds, or when the waiting task is cancelled. A state that never comes
/// keeps the test waiting: a stack of the test process then shows the open
/// wait, and the missing event is the defect to find.
extension ChangeSignal {
    /// Waits until `condition` holds.
    ///
    /// Each cycle reads ``changeCount``, then reads the state through
    /// `condition`, and waits for the next change when the state does not
    /// hold. A change that comes between the read of the count and the wait is
    /// not lost: the wait then returns at once, and the next cycle reads the
    /// state again.
    ///
    /// - Parameters:
    ///   - isolation: The isolation of the caller. The wait runs there, so
    ///     `condition` can read the state of the caller.
    ///   - condition: Reads the state, and tells whether it is the state that
    ///     the test wants.
    /// - Throws: ``ConditionNeverHeld`` when the waiting task was cancelled
    ///   before the state held; otherwise what `condition` throws.
    func wait(
        isolation: isolated (any Actor)? = #isolation,
        until condition: () async throws -> Bool
    ) async throws {
        while true {
            let seen = changeCount
            if try await condition() {
                return
            }
            guard await waitForChange(after: seen) else {
                throw ConditionNeverHeld()
            }
        }
    }
}
