import FoundationModelsExtras
import Testing

@testable import FoundationModelsRouter

/// Exercises the wait for the sleepers of a ``ManualRunClock`` (rule T1): the
/// wait also ends on the end of a task, and the test then fails by an
/// assertion. The suite needs no session, no network and no GPU.
@Suite("The wait for the sleepers of a manual clock also ends on the end of a task")
struct ManualRunClockWaitTests {
    /// How far ahead of the clock the sleeper of a test sleeps. The test
    /// moves the clock this far to end the sleep.
    private static let sleepDuration: Duration = .seconds(1)

    /// The production change that makes this test fail: a wait that reads
    /// only the count of the sleepers. That wait does not end when the task
    /// ends, so it records no issue.
    @Test("a wait for sleepers fails the test and returns when the task ended and no sleeper came")
    func aWaitEndsOnTheEndOfTheTask() async {
        let clock = ManualRunClock()
        let ended = Task {}
        defer { ended.cancel() }

        await withKnownIssue("the task ended before a sleeper came on the clock") {
            try await clock.waitForSleepers(atLeast: 1, endingOnEndOf: ended)
        }
        #expect(clock.sleeperCount == 0)
    }

    /// The production change that makes this test fail: a wait that ends
    /// before the sleeper is on the clock. The count of the sleepers is then
    /// zero after the wait.
    @Test("a wait for sleepers returns with no issue when the sleeper came while the task runs")
    func aWaitReturnsWhenTheSleeperCame() async throws {
        let clock = ManualRunClock()
        let deadline = clock.now.advanced(by: Self.sleepDuration)
        let sleeping = Task { try await clock.sleep(until: deadline) }
        // The defer ends the sleep also when the wait throws.
        defer { sleeping.cancel() }

        try await clock.waitForSleepers(atLeast: 1, endingOnEndOf: sleeping)
        #expect(clock.sleeperCount == 1)

        clock.advance(by: Self.sleepDuration)
        try await sleeping.value
        #expect(clock.sleeperCount == 0)
    }
}
