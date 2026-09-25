import Foundation
import FoundationModelsRouterTestSupport
import Testing

@testable import FoundationModelsRouter

/// Task ^1psqdm9: each summarizer call of a compaction is one submission on
/// the queue of the container that runs it (`generation-queue.md`, section
/// 5.3).
///
/// The flash slot resolves to a ``LiveBackendContainer`` over a
/// ``PassObservingModel``, so the flash summarizer call and each call of a
/// session on the flash slot go through the production backend, and the test
/// sees whether two of them are inside the model at one time. The standard
/// slot is the stub warm-up of ``AutoCompactionFixtures``, whose last warm-up
/// turn leaves the session over the trigger of its budget.
///
/// No wait here is a bare `await` on a turn that can stay suspended: the test
/// opens the latch before it awaits a turn, so a regression fails the test and
/// does not hang the run.
@Suite("A summarizer call is one submission on the queue of its container (task ^1psqdm9)")
struct SummarizerSubmissionTests {
    /// The suite's temp-directory prefix, handed to
    /// ``RouterTestFixtures/makeTempDir(prefix:)``.
    private static let tempDirPrefix = "SummarizerSubmissionTests"

    /// The prompt of the session on the flash slot.
    private static let flashPrompt = "flash"

    /// The prompt of the turn whose proactive compaction calls the flash
    /// summarizer.
    private static let triggeringPrompt = "the turn over the trigger"

    /// The count of the passes on the flash model: the one of the flash
    /// session, then the one of the summarizer call.
    private static let flashPassCount = 2

    @Test("a flash summarizer call and a flash submission of another session never overlap")
    func aFlashSummarizerCallAndAFlashSubmissionNeverOverlap() async throws {
        let flash = PassObservingFixture()
        let (session, _) = try await AutoCompactionFixtures.makeTriggeredSession(
            budget: AutoCompactionFixtures.fixedBudget, flash: flash.container, tempDirPrefix: Self.tempDirPrefix)
        let flashSession = session.profile.flash.makeSession()

        // The flash session's submission runs on the flash worker, and its
        // pass stays inside the model until the latch opens.
        let flashTurn = Task { try await flashSession.respond(to: Self.flashPrompt) }
        let flashInside = await BoundedWait.conditionReached("the pass of the flash session") {
            await flash.observer.enteredCount == 1
        }

        // The next turn of the session over the trigger compacts first, and
        // its flash summarizer call waits behind the flash submission.
        let (log, compactingTurn) = SessionEventLog.collect(await session.streamEvents(to: Self.triggeringPrompt))
        let summarizerWaits = await BoundedWait.conditionReached("the flash summarizer call waiting for the worker") {
            await flash.queue.waitingCount == 1
        }
        let peakWhileTheSummarizerWaits = await flash.observer.maximumActive

        await flash.latch.open()
        _ = try await flashTurn.value
        try await compactingTurn.value

        #expect(flashInside)
        #expect(summarizerWaits)
        #expect(peakWhileTheSummarizerWaits == 1)
        #expect(await flash.observer.maximumActive == 1)
        #expect(await flash.observer.enteredCount == Self.flashPassCount)
        #expect(flash.passes.recorded.first?.prompt == Self.flashPrompt)
        #expect(await log.contains(.submissionQueued))
        #expect(await flash.queue.isRunning == false)
    }
}
