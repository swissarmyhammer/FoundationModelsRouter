import Foundation
import FoundationModelsRouterTestSupport
import Testing

@testable import FoundationModelsRouter

/// Tasks ^1psqdm9 and ^6wqketz: each summarizer call of a compaction is one
/// item on the queue of the container that runs it (`generation-queue.md`,
/// section 5.3), and a cancel of the session reaches that item while it waits.
///
/// The flash slot resolves to a ``LiveBackendContainer`` over a
/// ``PassObservingModel``, so the flash summarizer call and each call of a
/// session on the flash slot go through the production backend, and the test
/// sees whether two of them are inside the model at one time. The standard
/// slot is the stub warm-up of ``AutoCompactionFixtures``, whose last warm-up
/// answer leaves the session over the trigger of its budget.
///
/// No wait here is a bare `await` on an answer that can stay suspended: a test
/// opens the latch, or sees the end of the answer inside a bound, before it
/// awaits that answer. So a regression fails the test and does not hang the run.
@Suite("A summarizer call is one submission on the queue of its container (task ^1psqdm9)")
struct SummarizerSubmissionTests {
    /// The suite's temp-directory prefix, handed to
    /// ``RouterTestFixtures/makeTempDir(prefix:)``.
    private static let tempDirPrefix = "SummarizerSubmissionTests"

    /// The prompt of the session on the flash slot.
    private static let flashPrompt = "flash"

    /// The prompt of the answer whose proactive compaction calls the flash
    /// summarizer.
    private static let triggeringPrompt = "the answer over the trigger"

    /// The count of the passes on the flash model: the one of the flash
    /// session, then the one of the summarizer call.
    private static let flashPassCount = 2

    /// A compacting answer whose flash summarizer call waits for the flash
    /// worker, behind a submission of another session on the flash slot.
    private struct WaitingSummarizer {
        /// The flash slot: its container, its latch, and its observer.
        let flash: PassObservingFixture

        /// The session over the trigger, on the standard slot.
        let session: RoutedSession

        /// The standard container. Its log holds each call of the own-model
        /// tier.
        let standard: ConfiguredLLMContainer

        /// The answer of the session on the flash slot. Its pass holds the
        /// flash worker until the latch opens.
        let flashAnswer: Task<String, any Error>

        /// The events of the compacting answer.
        let log: SessionEventLog

        /// The task that drains the compacting answer. It throws what the
        /// answer throws.
        let compactingAnswer: Task<Void, any Error>

        /// Whether the pass of the flash session was inside the model inside
        /// the bound.
        let flashInside: Bool

        /// Whether the flash summarizer call waited for the flash worker
        /// inside the bound.
        let summarizerWaits: Bool
    }

    /// Starts a submission of another session on the flash slot, and then an
    /// answer of the session over the trigger. The proactive compaction of
    /// that answer calls the flash summarizer, and the call waits for the
    /// flash worker, which the other submission holds until the latch opens.
    ///
    /// - Returns: The parts that the test reads and releases.
    /// - Throws: Whatever the warm-up of the triggered session throws.
    private static func startSummarizerBehindAFlashSubmission() async throws -> WaitingSummarizer {
        let flash = PassObservingFixture()
        let (session, standard) = try await AutoCompactionFixtures.makeTriggeredSession(
            budget: AutoCompactionFixtures.fixedBudget, flash: flash.container, tempDirPrefix: tempDirPrefix)
        let flashSession = session.profile.flash.makeSession()

        // The flash session's submission runs on the flash worker, and its
        // pass stays inside the model until the latch opens.
        let flashAnswer = Task { try await flashSession.respond(to: flashPrompt) }
        let flashInside = await BoundedWait.conditionReached("the pass of the flash session") {
            await flash.observer.enteredCount == 1
        }

        // The next answer of the session over the trigger compacts first, and
        // its flash summarizer call waits behind the flash submission.
        let (log, compactingAnswer) = SessionEventLog.collect(await session.streamEvents(to: triggeringPrompt))
        let summarizerWaits = await BoundedWait.conditionReached("the flash summarizer call waiting for the worker") {
            await flash.queue.waitingCount == 1
        }
        return WaitingSummarizer(
            flash: flash, session: session, standard: standard, flashAnswer: flashAnswer, log: log,
            compactingAnswer: compactingAnswer, flashInside: flashInside, summarizerWaits: summarizerWaits)
    }

    @Test("a flash summarizer call and a flash submission of another session never overlap")
    func aFlashSummarizerCallAndAFlashSubmissionNeverOverlap() async throws {
        let waiting = try await Self.startSummarizerBehindAFlashSubmission()
        let flash = waiting.flash
        let peakWhileTheSummarizerWaits = await flash.observer.maximumActive

        await flash.latch.open()
        _ = try await waiting.flashAnswer.value
        try await waiting.compactingAnswer.value

        #expect(waiting.flashInside)
        #expect(waiting.summarizerWaits)
        #expect(peakWhileTheSummarizerWaits == 1)
        #expect(await flash.observer.maximumActive == 1)
        #expect(await flash.observer.enteredCount == Self.flashPassCount)
        #expect(flash.passes.recorded.first?.prompt == Self.flashPrompt)
        // The summarizer call is not a submission of the session, so its wait
        // sends no submissionQueued. Only the queue of the flash container
        // shows the wait (`summarizerWaits` above).
        #expect(await !waiting.log.events.contains(where: Self.isSubmissionQueued))
        #expect(await flash.queue.isRunning == false)
    }

    /// Task ^6wqketz. The production change that makes this test fail: a
    /// queue that does not take a waiting item out when its submitter is
    /// cancelled (the answer then ends only after the latch opens), or a
    /// compaction that goes on to the own-model tier after a cancel (the
    /// standard log then grows, and the reason is not `.cancelled`).
    @Test("a cancel while the flash summarizer call waits for the worker cancels the answer")
    func aCancelWhileTheSummarizerWaitsCancelsTheAnswer() async throws {
        let waiting = try await Self.startSummarizerBehindAFlashSubmission()
        let flash = waiting.flash
        let standardCallsBeforeTheCancel = waiting.standard.generationLog.calls.count

        let cancellation = await waiting.session.cancel()
        // The answer ends while the flash submission still holds the worker:
        // the waiting summarizer item left the queue and never ran.
        let answerEnded = await BoundedWait.conditionReached("the end of the cancelled answer") {
            await !waiting.log.events.answerFailures.isEmpty
        }
        let waitingAfterTheCancel = await flash.queue.waitingCount
        let passesAfterTheCancel = await flash.observer.enteredCount

        await flash.latch.open()
        _ = try await waiting.flashAnswer.value

        #expect(waiting.flashInside)
        #expect(waiting.summarizerWaits)
        #expect(cancellation == .requested)
        #expect(answerEnded)
        #expect(waitingAfterTheCancel == 0)
        #expect(passesAfterTheCancel == 1)
        let events = await waiting.log.events
        // `.cancelled` is the reason only when `isWorkCancelled` holds at the
        // end of the answer.
        #expect(events.answerFailures.map(\.reason) == [.cancelled])
        #expect(events.compactionResults.isEmpty)
        // The compaction did not go on to the own-model tier.
        #expect(waiting.standard.generationLog.calls.count == standardCallsBeforeTheCancel)
        await #expect(throws: CancellationError.self) {
            try await waiting.compactingAnswer.value
        }
        #expect(await flash.observer.enteredCount == 1)
        #expect(await flash.queue.isRunning == false)
    }

    /// Whether `event` is a `submissionQueued` event, with any id.
    ///
    /// - Parameter event: The event to read.
    /// - Returns: `true` when `event` is `submissionQueued`.
    private static func isSubmissionQueued(_ event: SessionEvent) -> Bool {
        if case .submissionQueued = event { return true }
        return false
    }
}
