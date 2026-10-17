import Synchronization
import Testing

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

    /// The task that records the end of an other task, or `nil` for a result
    /// that ``recordingEnd(of:reportingTo:)`` did not make.
    private let observer = Mutex<Task<Void, Never>?>(nil)

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

/// Rule T1: a wait of a test also ends on the failure event. The end of a
/// task is such an event: a task that runs the work under test ends also
/// when the state that the test waits for never comes.
extension RecordedWaitResult {
    /// Starts a task that waits for the end of `task`, and then records
    /// `true`.
    ///
    /// The end is an end with a value or with an error. A test reads the
    /// result in the failure event of
    /// ``ChangeSignal/wait(isolation:until:endingOn:sourceLocation:)``.
    ///
    /// The result keeps the handle of the observer task. The caller calls
    /// ``stopRecording()`` when its wait returned, in a `defer` right after
    /// this call, so the observer task records nothing after the wait.
    ///
    /// - Parameters:
    ///   - task: The task whose end the result records.
    ///   - changes: The signal to send when the end is recorded. Give the
    ///     signal of the state that the test waits for, so that one wait
    ///     sees the state and the end.
    /// - Returns: The result: `nil` while `task` runs, `true` after it ended.
    static func recordingEnd<Success: Sendable, Failure: Error>(
        of task: Task<Success, Failure>, reportingTo changes: ChangeSignal
    ) -> RecordedWaitResult {
        let ended = RecordedWaitResult(reportingTo: changes)
        let observing = Task {
            _ = await task.result
            guard !Task.isCancelled else { return }
            ended.record(true)
        }
        ended.observer.withLock { $0 = observing }
        return ended
    }

    /// Cancels the observer task of ``recordingEnd(of:reportingTo:)``.
    ///
    /// After the cancel, the observer task records no end and sends no
    /// signal. The observer task itself ends when the observed task ends:
    /// a wait for the result of a task does not end on a cancel. The end of
    /// the fixture of the test ends the observed task (rule T1). A result
    /// with no observer task ignores this call.
    func stopRecording() {
        observer.withLock { $0?.cancel() }
    }

    /// Waits until `wait` returns, or until `task` ended. When `task` ended
    /// first, or when `wait` threw, the test fails by an assertion.
    ///
    /// `wait` runs in a task of its own. Thus a wait that has no failure
    /// event of its own (a permit of a semaphore, a count of an observer, a
    /// log of a feed) also ends on the end of `task`. In a test that passes,
    /// `task` must not end before `wait` returns.
    ///
    /// - Parameters:
    ///   - wait: The wait for the state that the test wants.
    ///   - task: The task whose end is the failure event.
    ///   - sourceLocation: The place of the call, for the failure.
    /// - Throws: The error of `#require` when `task` ended first or `wait`
    ///   threw, or ``ConditionNeverHeld`` when the test was cancelled first.
    static func wait<Success: Sendable, Failure: Error>(
        for wait: @escaping @Sendable () async throws -> Void,
        endingOnEndOf task: Task<Success, Failure>,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        let changes = ChangeSignal()
        let waited = RecordedWaitResult(reportingTo: changes)
        let ended = recordingEnd(of: task, reportingTo: changes)
        defer { ended.stopRecording() }
        let waiting = Task {
            do {
                try await wait()
                waited.record(true)
            } catch {
                waited.record(false)
            }
        }
        defer { waiting.cancel() }
        try await changes.wait(
            until: { waited.value != nil }, endingOn: { ended.value != nil }, sourceLocation: sourceLocation)
        try #require(waited.value == true, "the wait threw before the state came", sourceLocation: sourceLocation)
    }
}
