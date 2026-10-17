import Testing

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
/// holds, or when the waiting task is cancelled.
///
/// Rule T1: each wait of a test also ends on the failure event — the event
/// that comes also when the state never comes, for example the settle of the
/// run under test. ``wait(isolation:until:endingOn:sourceLocation:)`` waits
/// for both, and the test then fails by an assertion. Use the wait with one
/// condition only when no such event exists, or when the test failed before
/// it waits.
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

    /// Waits until a counter is at least `count`.
    ///
    /// This is the one wait of the tests for a count: a count of prompts,
    /// passes, posts or waiters. It is ``wait(isolation:until:)`` with the
    /// condition `value() >= count`.
    ///
    /// - Parameters:
    ///   - isolation: The isolation of the caller. The wait runs there, so
    ///     `value` can read the state of the caller.
    ///   - count: The smallest value of the counter that ends the wait.
    ///   - value: Reads the counter.
    /// - Throws: ``ConditionNeverHeld`` when the waiting task was cancelled
    ///   before the counter got to `count`; otherwise what `value` throws.
    func wait(
        isolation: isolated (any Actor)? = #isolation,
        untilAtLeast count: Int,
        of value: () async throws -> Int
    ) async throws {
        try await wait(until: { try await value() >= count })
    }

    /// Waits until `condition` holds, or until `failureEvent` holds (rule
    /// T1). When the failure event came and `condition` does not hold, the
    /// test fails by an assertion.
    ///
    /// The failure event is an event that comes also when the state of
    /// `condition` never comes: a run that settles, a session that closes, a
    /// feed that ends. In a test that passes, the failure event must not come
    /// before the state, or the state must hold at the time of the failure
    /// event. Else the test fails in a run that the program passes.
    ///
    /// - Parameters:
    ///   - isolation: The isolation of the caller. The wait runs there, so
    ///     `condition` and `failureEvent` can read the state of the caller.
    ///   - condition: Reads the state, and tells whether it is the state that
    ///     the test wants.
    ///   - failureEvent: Tells whether the failure event came.
    ///   - sourceLocation: The place of the call, for the failure.
    /// - Throws: The error of `#require` when the failure event came first;
    ///   ``ConditionNeverHeld`` when the waiting task was cancelled first;
    ///   otherwise what `condition` or `failureEvent` throws.
    func wait(
        isolation: isolated (any Actor)? = #isolation,
        until condition: () async throws -> Bool,
        endingOn failureEvent: () async throws -> Bool,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        try await wait(until: {
            if try await condition() { return true }
            return try await failureEvent()
        })
        let stateHeld = try await condition()
        try #require(
            stateHeld, "the failure event came before the state that the test waits for",
            sourceLocation: sourceLocation)
    }

    /// Waits until `condition` holds, or until `task` ended (rule T1). When
    /// `task` ended and `condition` does not hold, the test fails by an
    /// assertion.
    ///
    /// The end of `task` is the failure event: the end signals this signal
    /// (``RecordedWaitResult/recordingEnd(of:reportingTo:)``), so one wait
    /// sees the state and the end. After the end, the wait reads the state
    /// again. Thus a state that came before `task` ended passes, also when
    /// the end signal comes first. In a test that passes, `task` must not end
    /// before the state comes: for example `task` is the answer that makes
    /// the state, and a gate of the test holds that answer.
    ///
    /// - Parameters:
    ///   - isolation: The isolation of the caller. The wait runs there, so
    ///     `condition` can read the state of the caller.
    ///   - condition: Reads the state, and tells whether it is the state that
    ///     the test wants.
    ///   - task: The task whose end is the failure event.
    ///   - sourceLocation: The place of the call, for the failure.
    /// - Throws: The error of `#require` when `task` ended first;
    ///   ``ConditionNeverHeld`` when the waiting task was cancelled first;
    ///   otherwise what `condition` throws.
    func wait<Success: Sendable, Failure: Error>(
        isolation: isolated (any Actor)? = #isolation,
        until condition: () async throws -> Bool,
        endingOnEndOf task: Task<Success, Failure>,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        let ended = RecordedWaitResult.recordingEnd(of: task, reportingTo: self)
        defer { ended.stopRecording() }
        try await wait(until: condition, endingOn: { ended.value != nil }, sourceLocation: sourceLocation)
    }
}
