import Foundation
import FoundationModelsRouterTestSupport
import Testing

@testable import FoundationModelsRouter

/// Tasks ^1psqdm9 and ^6wqketz: each summarizer call of a compaction is one
/// item on the queue of the pool entry of the model that runs it
/// (`generation-queue.md`, section 5.3), and the close of the session, the
/// one cancel of a running compaction, reaches that item while it waits.
///
/// The flash slot resolves to a ``LiveBackendContainer`` over a
/// ``PassObservingModel``, so the flash summarizer call and each call of a
/// session on the flash slot go through the production backend, and the test
/// sees whether two of them are inside the model at one time. The standard
/// slot is the stub warm-up of ``AutoCompactionFixtures``, whose last warm-up
/// answer leaves the session over the trigger of its budget.
///
/// Each wait here waits for an event: the entry of a pass into the flash
/// model, the job that the flash queue makes for the summarizer call (its
/// queue depth metric, through a ``QueueDepthProbe`` that the session gets as
/// its metrics factory), or an event of the answer. No wait has a clock or a
/// limit.
@Suite("A summarizer call is one submission on the queue of its model (task ^1psqdm9)")
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

        /// The queue of the pool entry of the flash model.
        let flashQueue: GenerationQueue

        /// The session over the trigger, on the standard slot.
        let session: any RoutedSession

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
    }

    /// Starts a submission of another session on the flash slot, and then an
    /// answer of the session over the trigger. The proactive compaction of
    /// that answer calls the flash summarizer, and the call waits for the
    /// flash worker, which the other submission holds until the latch opens.
    ///
    /// When this helper throws, it opens the flash latch first (rule T1).
    ///
    /// - Returns: The parts that the test reads and releases.
    /// - Throws: Whatever the warm-up of the triggered session throws.
    private static func startSummarizerBehindAFlashSubmission() async throws -> WaitingSummarizer {
        let flash = PassObservingFixture()
        do {
            let (session, standard) = try await AutoCompactionFixtures.makeTriggeredSession(
                budget: AutoCompactionFixtures.fixedBudget, flash: flash.container, tempDirPrefix: tempDirPrefix)
            let flashQueue = try #require(session.profile.flash.backendQueue)
            let flashSession = session.profile.flash.makeSession()

            // The flash session's submission runs on the flash worker, and its
            // pass stays inside the model until the latch opens. The wait also
            // ends when that answer ends (rule T1): the latch holds its pass,
            // so in a test that passes it cannot end first.
            let flashAnswer = Task { try await flashSession.respond(to: flashPrompt) }
            try await RecordedWaitResult.wait(
                for: { try await flash.observer.waitUntil { $0.entered == 1 } }, endingOnEndOf: flashAnswer)

            // The next answer of the session over the trigger compacts first, and
            // its flash summarizer call waits behind the flash submission. The
            // summarizer call sends no event of the session. The task of the
            // compaction inherits the metrics factory of the session, so the
            // flash queue records the depth meter of the job of the call through
            // the probe.
            let probe = QueueDepthProbe(model: session.profile.flash.chosen)
            await session.useCaptureMetrics(for: probe)
            let (log, compactingAnswer) = SessionEventLog.collect(await session.streamEvents(to: triggeringPrompt))
            await probe.enqueued.wait()
            return WaitingSummarizer(
                flash: flash, flashQueue: flashQueue, session: session, standard: standard,
                flashAnswer: flashAnswer, log: log, compactingAnswer: compactingAnswer)
        } catch {
            await flash.latch.open()
            throw error
        }
    }

    @Test("a flash summarizer call and a flash submission of another session never overlap")
    func aFlashSummarizerCallAndAFlashSubmissionNeverOverlap() async throws {
        let waiting = try await Self.startSummarizerBehindAFlashSubmission()
        let flash = waiting.flash
        let peakWhileTheSummarizerWaits = await flash.observer.maximumActive

        await flash.latch.open()
        _ = try await waiting.flashAnswer.value
        try await waiting.compactingAnswer.value

        #expect(peakWhileTheSummarizerWaits == 1)
        #expect(await flash.observer.maximumActive == 1)
        #expect(await flash.observer.enteredCount == Self.flashPassCount)
        #expect(flash.passes.recorded.first?.prompt == Self.flashPrompt)
        // The summarizer call is not a submission of the session, so its wait
        // sends no submissionQueued. Only the queue of the flash model
        // shows the wait (the depth meter that the probe counted).
        #expect(await !waiting.log.events.contains(where: Self.isSubmissionQueued))
        #expect(await waiting.flashQueue.isRunning == false)
    }

    /// Task ^6wqketz. Only ``RoutedSession/close()`` cancels a running
    /// compaction. The production change that makes this test fail: a queue
    /// that does not take a waiting item out when the task of the compaction
    /// is cancelled (the close then ends only after the latch opens), or a
    /// compaction that goes on to the own-model tier after the cancel (the
    /// standard log then grows, and the outcome is not `.cancelled`).
    @Test("close while the flash summarizer call waits for the worker takes the call out of the queue and cancels the compaction")
    func closeWhileTheSummarizerWaitsTakesItOutOfTheQueue() async throws {
        let waiting = try await Self.startSummarizerBehindAFlashSubmission()
        let flash = waiting.flash
        defer { await flash.latch.open() }
        let standardCallsBeforeTheClose = waiting.standard.generationLog.calls.count

        // No signal and no stop of the answer affects a running compaction:
        // only the close cancels it.
        let closing = Task { await waiting.session.close() }
        // The answer ends while the flash submission still holds the worker:
        // the waiting summarizer item left the queue and never ran.
        try await waiting.log.wait(until: { !$0.answerFailures.isEmpty })
        let waitingAfterTheClose = await waiting.flashQueue.waitingCount
        let passesAfterTheClose = await flash.observer.enteredCount

        await flash.latch.open()
        _ = try await waiting.flashAnswer.value
        await closing.value

        #expect(waitingAfterTheClose == 0)
        #expect(passesAfterTheClose == 1)
        let events = await waiting.log.events
        #expect(events.answerFailures.map(\.reason) == [.cancelled])
        #expect(events.compactionResults.isEmpty)
        #expect(events.compactionFailures.map(\.outcome) == [.cancelled])
        // The compaction did not go on to the own-model tier.
        #expect(waiting.standard.generationLog.calls.count == standardCallsBeforeTheClose)
        await #expect(throws: CancellationError.self) {
            try await waiting.compactingAnswer.value
        }
        #expect(await flash.observer.enteredCount == 1)
        #expect(await waiting.flashQueue.isRunning == false)
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
