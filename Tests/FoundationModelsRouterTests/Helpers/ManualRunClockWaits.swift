import FoundationModelsExtras
import Testing

@testable import FoundationModelsRouter

/// Rule T1: a wait for the sleepers of a `ManualRunClock` also ends on the
/// failure event.
///
/// `ManualRunClock.waitForSleepers(atLeast:)` is production code of the
/// package FoundationModelsExtras. Its wait has no cancel handler: a cancel of
/// its task does not end it, and only the next change of the set of waits of
/// the clock resumes it. This target does not change that package. The wait
/// below runs that wait in a task of its own, and waits for the first of two
/// events: the count of sleepers came, or the observed task ended.
///
/// The inner task stays suspended until the next change of the clock, because
/// the wait of the package has no cancel handler. It holds no gate and no
/// test resource, and it does not block the test: it is one parked task. A
/// cancel handler in FoundationModelsExtras is a later item of that package.
extension ManualRunClock {
    /// Waits until at least `count` waits are open on this clock, or until
    /// `task` ended. When `task` ended first, and the clock still does not
    /// hold `count` waits, the test fails by an assertion.
    ///
    /// After the end of `task`, the wait reads ``sleeperCount`` again. Thus a
    /// sleeper that came before the end passes, also when the inner task did
    /// not record it yet. In a test that passes, the work that must put the
    /// waits on the clock must not end before the waits came.
    ///
    /// - Parameters:
    ///   - count: The number of waits.
    ///   - task: The task whose end is the failure event: for example the
    ///     answer, or the settle of the run, that must put the waits on the
    ///     clock.
    ///   - sourceLocation: The place of the call, for the failure.
    /// - Throws: The error of `#require` when `task` ended first, or
    ///   ``ConditionNeverHeld`` when the test was cancelled first.
    func waitForSleepers<Success: Sendable, Failure: Error>(
        atLeast count: Int,
        endingOnEndOf task: Task<Success, Failure>,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        let changes = ChangeSignal()
        let ended = RecordedWaitResult.recordingEnd(of: task, reportingTo: changes)
        defer { ended.stopRecording() }
        let counted = RecordedWaitResult(reportingTo: changes)
        let counting = Task {
            await self.waitForSleepers(atLeast: count)
            guard !Task.isCancelled else { return }
            counted.record(true)
        }
        // The cancel does not end the inner wait. It only keeps the inner
        // task from a record after this wait returned.
        defer { counting.cancel() }
        try await changes.wait(
            until: { counted.value == true || self.sleeperCount >= count },
            endingOn: { ended.value != nil },
            sourceLocation: sourceLocation)
    }
}
