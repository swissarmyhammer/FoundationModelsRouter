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

/// Rule T1 for the two events of the tests that have no failure event of
/// their own: an ``AwaitedEvent`` and a permit of an ``AsyncSemaphore``. The
/// failure event is the end of the task that must send the event.
///
/// ``wait(for:endingOnEndOf:sourceLocation:)`` with a closure reads only the
/// result of its own wait task after the end. When `task` sends the event
/// and then ends at once, that wait task can record its result after the end
/// was recorded, and the test fails in a run that the program passes. These
/// waits read the event itself again after the end, so the order of the two
/// records does not change the result.
extension RecordedWaitResult {
    /// Waits until `event` was sent, or until `task` ended. When `task`
    /// ended and `event` was not sent, the test fails by an assertion.
    ///
    /// The wait reads ``AwaitedEvent/hasArrived`` on each signal of
    /// ``AwaitedEvent/changes``, and the end of `task` signals the same
    /// signal. This wait is not a waiter of ``AwaitedEvent/wait()``, so a
    /// test can also call that wait. In a test that passes, `task` must not
    /// end before it sent `event`.
    ///
    /// - Parameters:
    ///   - event: The event that the test waits for.
    ///   - task: The task that must send `event`. Its end is the failure
    ///     event.
    ///   - sourceLocation: The place of the call, for the failure.
    /// - Throws: The error of `#require` when `task` ended before `event`
    ///   was sent, or ``ConditionNeverHeld`` when the test was cancelled
    ///   first.
    static func wait<Success: Sendable, Failure: Error>(
        for event: AwaitedEvent,
        endingOnEndOf task: Task<Success, Failure>,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        let ended = recordingEnd(of: task, reportingTo: event.changes)
        defer { ended.stopRecording() }
        try await event.changes.wait(
            until: { event.hasArrived }, endingOn: { ended.value != nil }, sourceLocation: sourceLocation)
    }

    /// Takes one permit of `semaphore`, or ends when `task` ended. When
    /// `task` ended and no permit came, the test fails by an assertion, and
    /// the wait takes no permit after it returned.
    ///
    /// The semaphore is an event: `task` signals it, and only the test takes
    /// its permits. The wait takes the permit through
    /// ``AsyncSemaphore/waitUnlessCancelled()`` in a task of its own. When
    /// `task` ended first, the wait cancels that task: a cancelled waiter
    /// leaves the queue and takes no later permit. A permit that `task` gave
    /// before the waiter joined the queue stays free in the semaphore after
    /// the cancel, and the wait then takes that permit. Thus a permit that
    /// came before the end is always taken, and no waiter stays after the
    /// wait. In a test that passes, `task` must not end before it signalled
    /// `semaphore`.
    ///
    /// - Parameters:
    ///   - semaphore: The semaphore that `task` signals.
    ///   - task: The task that must signal `semaphore`. Its end is the
    ///     failure event.
    ///   - sourceLocation: The place of the call, for the failure.
    /// - Throws: The error of `#require` when `task` ended before a permit
    ///   came, or ``ConditionNeverHeld`` when the test was cancelled first.
    static func wait<Success: Sendable, Failure: Error>(
        forPermitOf semaphore: AsyncSemaphore,
        endingOnEndOf task: Task<Success, Failure>,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        let changes = ChangeSignal()
        let acquired = RecordedWaitResult(reportingTo: changes)
        let ended = recordingEnd(of: task, reportingTo: changes)
        defer { ended.stopRecording() }
        let acquiring = Task {
            do {
                try await semaphore.waitUnlessCancelled()
                acquired.record(true)
            } catch {
                acquired.record(false)
            }
        }
        defer { acquiring.cancel() }
        try await changes.wait(until: { acquired.value != nil || ended.value != nil })
        acquiring.cancel()
        await acquiring.value
        let tookPermit = if acquired.value == true { true } else { try await takeFreePermit(of: semaphore) }
        try #require(tookPermit, "the task ended before the semaphore got a permit", sourceLocation: sourceLocation)
    }

    /// Takes one permit of `semaphore`, or ends when the mail `id` of
    /// `session` has its terminal event. When the mail ended and no permit
    /// came, the test fails by an assertion.
    ///
    /// Use it when the test sent the mail with ``RoutedSession/send(_:)``
    /// and has no task of the answer: the terminal event of the mail is then
    /// the failure event. See
    /// ``wait(forPermitOf:endingOnEndOf:sourceLocation:)``.
    ///
    /// - Parameters:
    ///   - semaphore: The semaphore that the work of the mail signals.
    ///   - id: The mail whose terminal event is the failure event.
    ///   - session: The session of the mail.
    ///   - sourceLocation: The place of the call, for the failure.
    /// - Throws: The error of `#require` when the mail ended before a permit
    ///   came, or ``ConditionNeverHeld`` when the test was cancelled first.
    static func wait(
        forPermitOf semaphore: AsyncSemaphore, endingOnTerminalOf id: MailID, on session: any RoutedSession,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        let mailEnding = Task { _ = try? await session.awaitTerminal(of: id) }
        defer { mailEnding.cancel() }
        try await wait(forPermitOf: semaphore, endingOnEndOf: mailEnding, sourceLocation: sourceLocation)
    }

    /// Takes a permit of `semaphore` when one is free, and does not wait.
    ///
    /// Only the test takes the permits of `semaphore`, so a free permit
    /// stays free until this call takes it.
    ///
    /// - Parameter semaphore: The semaphore that has the permit.
    /// - Returns: `true` when a permit was free and the call took it.
    /// - Throws: `CancellationError` when the test was cancelled.
    private static func takeFreePermit(of semaphore: AsyncSemaphore) async throws -> Bool {
        let isFree = semaphore.availablePermits > 0
        if isFree {
            try await semaphore.waitUnlessCancelled()
        }
        return isFree
    }
}
