import Foundation
import FoundationModelsRouterTestSupport
import Testing

@testable import FoundationModelsRouter

/// Tasks ^1psqdm9, ^6wqketz and ^qhgfajc: each pass of a summarizer call of a
/// compaction takes the lock of the model that runs it, as each other pass on
/// that model does, and the close of the session, the one cancel of a running
/// compaction, reaches that call at once while it waits for the lock.
///
/// The flash slot resolves to a ``LiveBackendContainer`` over a
/// ``PassObservingModel``, so the flash summarizer call and each call of a
/// session on the flash slot go through the production backend, and the test
/// sees whether two of them are inside the model at one time. The standard
/// slot is the stub warm-up of ``AutoCompactionFixtures``, whose last warm-up
/// answer leaves the session over the trigger of its budget.
///
/// Each wait here waits for an event: the entry of a pass into the flash
/// model, the pass of the summarizer call that waits for the lock of the
/// flash model, or an event of the answer. Each wait that a regression can
/// keep open is a ``BoundedWait``.
@Suite("A summarizer call takes the lock of its model one pass at a time (tasks ^1psqdm9, ^qhgfajc)")
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

    /// The triggered session of this suite: a stub standard slot and a flash
    /// slot over the ``PassObservingModel`` of a ``PassObservingFixture``.
    private typealias TriggeredFixture = AutoCompactionFixtures.CompactionSession<
        ConfiguredLLMContainer, LiveBackendContainer<PassObservingModel>
    >

    /// A compacting answer whose flash summarizer call waits for the lock of
    /// the flash model, behind a pass of another session on the flash slot.
    private struct WaitingSummarizer {
        /// The flash slot: its container, its latch, its lock and its observer.
        let flash: PassObservingFixture

        /// The session over the trigger, on the standard slot, with its
        /// containers and its temporary directory. The log of its standard
        /// container holds each call of the own-model tier.
        let triggered: TriggeredFixture

        /// The other session, on the flash slot. Its pass holds the lock of
        /// the flash model until the latch opens.
        let flashSession: any RoutedSession

        /// The answer of the session on the flash slot. Its pass holds the
        /// lock of the flash model until the latch opens.
        let flashAnswer: Task<String, any Error>

        /// The events of the compacting answer.
        let log: SessionEventLog

        /// The task that drains the compacting answer. It throws what the
        /// answer throws.
        let compactingAnswer: Task<Void, any Error>

        /// Opens the flash latch, closes the flash session, and then ends
        /// ``triggered``: it closes the session over the trigger and removes
        /// its temporary directory.
        ///
        /// A test calls it from one `defer` right after it gets the parts, so
        /// each session closes and the directory goes also when the test
        /// throws (rule T1). A session that the test closed already closes
        /// again with no effect.
        func end() async {
            await Self.end(flashSession: flashSession, triggered: triggered, opening: flash.latch)
        }

        /// Opens `latch`, closes `flashSession`, and then ends `triggered`.
        ///
        /// This is the one teardown sequence of the parts. ``end()`` uses it
        /// for a full set of parts, and
        /// ``SummarizerSubmissionTests/startSummarizerBehindAFlashSubmission()``
        /// uses it for the parts that it made before it threw.
        ///
        /// - Parameters:
        ///   - flashSession: The session on the flash slot, or `nil` when it
        ///     was not made. The latch opens also then.
        ///   - triggered: The fixture of the session over the trigger, or
        ///     `nil` when it was not made.
        ///   - latch: The flash latch that holds the pass of the flash
        ///     session.
        static func end(
            flashSession: (any RoutedSession)?, triggered: TriggeredFixture?, opening latch: RunLatch
        ) async {
            await SessionFixtureLifecycle.close(flashSession, opening: [latch])
            await triggered?.end()
        }
    }

    /// Starts a submission of another session on the flash slot, and then an
    /// answer of the session over the trigger. The proactive compaction of
    /// that answer calls the flash summarizer, and the pass of the call waits
    /// for the lock of the flash model, which the pass of the other
    /// submission holds until the latch opens.
    ///
    /// When this helper throws, it opens the flash latch first, then closes
    /// each session that it made, and then removes the temporary directory
    /// (rule T1).
    ///
    /// - Returns: The parts that the test reads and releases.
    /// - Throws: Whatever the warm-up of the triggered session throws.
    private static func startSummarizerBehindAFlashSubmission() async throws -> WaitingSummarizer {
        let flash = PassObservingFixture()
        // The fixture and the session that this helper made, for the end on
        // a throw.
        var triggeredFixture: TriggeredFixture?
        var flashSideSession: (any RoutedSession)?
        do {
            let triggered = try await AutoCompactionFixtures.makeTriggeredSession(
                budget: AutoCompactionFixtures.fixedBudget, flash: flash.container, tempDirPrefix: tempDirPrefix)
            triggeredFixture = triggered
            let session = triggered.session
            let flashSession = session.profile.flash.makeSession()
            flashSideSession = flashSession

            // The pass of the flash session holds the lock of the flash model,
            // and stays inside the model until the latch opens. The wait also
            // ends when that answer ends (rule T1): the latch holds its pass,
            // so in a test that passes it cannot end first.
            let flashAnswer = Task { try await flashSession.respond(to: flashPrompt) }
            try await BoundedWait.run {
                try await RecordedWaitResult.wait(
                    for: { try await flash.observer.waitUntil { $0.entered == 1 } }, endingOnEndOf: flashAnswer)
            }

            // The next answer of the session over the trigger compacts first,
            // and the pass of its flash summarizer call waits for the lock of
            // the flash model. The summarizer call sends no event of the
            // session.
            let (log, compactingAnswer) = SessionEventLog.collect(await session.streamEvents(to: triggeringPrompt))
            try await BoundedWait.run { try await flash.lock.waitForWaiters(1) }
            return WaitingSummarizer(
                flash: flash, triggered: triggered,
                flashSession: flashSession, flashAnswer: flashAnswer, log: log, compactingAnswer: compactingAnswer)
        } catch {
            await WaitingSummarizer.end(
                flashSession: flashSideSession, triggered: triggeredFixture, opening: flash.latch)
            throw error
        }
    }

    @Test("a flash summarizer call and a flash call of another session never overlap")
    func aFlashSummarizerCallAndAFlashSubmissionNeverOverlap() async throws {
        let waiting = try await Self.startSummarizerBehindAFlashSubmission()
        defer { await waiting.end() }
        let flash = waiting.flash
        let peakWhileTheSummarizerWaits = await flash.observer.maximumActive

        await flash.latch.open()
        _ = try await BoundedWait.value(of: waiting.flashAnswer)
        try await BoundedWait.value(of: waiting.compactingAnswer)

        #expect(peakWhileTheSummarizerWaits == 1)
        #expect(await flash.observer.maximumActive == 1)
        #expect(await flash.observer.enteredCount == Self.flashPassCount)
        #expect(flash.passes.recorded.first?.prompt == Self.flashPrompt)
    }

    /// Task ^6wqketz. Only ``RoutedSession/close()`` cancels a running
    /// compaction. The production change that makes this test fail: a call
    /// whose cancel waits for the lock of the model (the close then ends only
    /// after the latch opens), or a compaction that goes on to the own-model
    /// tier after the cancel (the standard log then grows, and the outcome is
    /// not `.cancelled`).
    @Test("close while the flash summarizer call waits for the lock of the model cancels the call at once and cancels the compaction")
    func closeWhileTheSummarizerWaitsCancelsItAtOnce() async throws {
        let waiting = try await Self.startSummarizerBehindAFlashSubmission()
        defer { await waiting.end() }
        let flash = waiting.flash
        let standardCallsBeforeTheClose = waiting.triggered.standard.generationLog.calls.count

        // No signal and no stop of the answer affects a running compaction:
        // only the close cancels it.
        let closing = Task { await waiting.triggered.session.close() }
        // The answer ends while the pass of the flash session still holds the
        // lock: the cancel of the waiting summarizer call does not wait for
        // the lock.
        let log = waiting.log
        try await BoundedWait.run { try await log.wait(until: { !$0.answerFailures.isEmpty }) }
        let passesAfterTheClose = await flash.observer.enteredCount

        await flash.latch.open()
        _ = try await BoundedWait.value(of: waiting.flashAnswer)
        try await BoundedWait.run { await closing.value }

        #expect(passesAfterTheClose == 1)
        let events = await waiting.log.events
        #expect(events.answerFailures.map(\.reason) == [.cancelled])
        #expect(events.compactionResults.isEmpty)
        #expect(events.compactionFailures.map(\.outcome) == [.cancelled])
        // The compaction did not go on to the own-model tier.
        #expect(waiting.triggered.standard.generationLog.calls.count == standardCallsBeforeTheClose)
        await #expect(throws: CancellationError.self) {
            try await BoundedWait.value(of: waiting.compactingAnswer)
        }
        // The abandoned pass left the lock at its turn, and never ran.
        let lock = flash.lock
        try await BoundedWait.run { try await lock.changes.wait(until: { await lock.waitingCount == 0 }) }
        #expect(await flash.observer.enteredCount == 1)
    }
}
