import Foundation
import FoundationModelsExtras
import FoundationModelsRouterTestSupport
import Synchronization
import Testing

@testable import FoundationModelsRouter

/// Tasks ^ake8sax and ^1psqdm9: the stall watch measures generation, so it
/// runs only while a pass of the running submission generates
/// (`generation-queue.md`, section 5.6). A wait for the worker of the queue
/// and a tool body between two passes are not a stall. A session tells its
/// consumer that its submission waits for the worker with
/// ``SessionEvent/submissionQueued(_:)``, which carries the id of the
/// submission. It tells its consumer that the worker started the submission
/// with ``SessionEvent/submissionStarted(_:)``, which carries the same id.
///
/// Each session is a routed session over one ``LiveBackendContainer``, so each
/// submission goes through the production backend and its per-session
/// ``SessionLanguageModel``, which reports each pass to the session.
///
/// Each wait here waits for an event of the session, of the model, of the
/// tool or of the clock. A test does not wait for a time. The router of each
/// test gives a `ManualRunClock` to the run plane of each session, and the
/// stall watch runs on that clock, so the clock moves only when the test
/// advances it. A test that checks that no report comes does not advance the
/// clock, and reads the state of the watch at a point of a fixed order. A test
/// that checks a report advances the clock past the interval, and waits for
/// the report itself.
@Suite("A wait for the worker is not a stalled generation (tasks ^ake8sax, ^1psqdm9)")
struct QueuedPassStallWatchTests {
    /// The suite's temp-directory prefix, handed to
    /// ``RouterTestFixtures/makeTempDir(prefix:)``.
    private static let tempDirPrefix = "QueuedPassStallWatchTests"

    /// The stall report interval each watched session installs.
    private static let reportInterval: Duration = .milliseconds(50)

    /// How far the test advances the clock while the submission waits for
    /// the worker. With ``toolBodyTime`` it is shorter than
    /// ``reportInterval``, so no tick comes before the second pass.
    private static let workerWaitTime: Duration = .milliseconds(20)

    /// How far the test advances the clock while the tool body runs.
    private static let toolBodyTime: Duration = .milliseconds(10)

    /// How many passes the test of a wait and a tool body waits for before
    /// the second pass of the waiting session holds: the pass of the holding
    /// session, and the two passes of the waiting session.
    private static let passesBeforeTheHeldPass = 3

    /// The prompt of the session whose submission holds the worker.
    private static let holdingPrompt = "a"

    /// The prompt of the session whose submission waits for the worker.
    private static let waitingPrompt = "b"

    /// Resolves the standard profile over the container of `fixture`, with
    /// `clock` as the clock of the run plane of each session.
    ///
    /// - Parameters:
    ///   - fixture: The fixture whose container the router loads.
    ///   - dir: The cache directory of the router.
    ///   - clock: The clock of the runs and of the stall watch of each
    ///     session.
    /// - Returns: The router and the resolved profile.
    private static func resolve(
        _ fixture: PassObservingFixture, in dir: URL, clock: ManualRunClock
    ) async throws -> (router: Router, profile: LanguageModelProfile) {
        try await RouterTestFixtures.resolveStandardProfile(over: fixture.container, cacheDir: dir, runClock: clock)
    }

    /// The ids that the `submissionQueued` events among `events` carry, in
    /// order.
    ///
    /// - Parameter events: The events to read.
    /// - Returns: The ids of the queued submissions.
    private static func queuedIds(in events: [SessionEvent]) -> [SubmissionID] {
        events.compactMap { event in
            if case .submissionQueued(let id) = event { return id }
            return nil
        }
    }

    /// The stall reports among `events`, in order.
    ///
    /// - Parameter events: The events to read.
    /// - Returns: The stall reports.
    private static func stalls(in events: [SessionEvent]) -> [GenerationStall] {
        events.compactMap { event in
            if case .generationStalled(let stall) = event { return stall }
            return nil
        }
    }

    /// Waits until the stall watch of the model call in flight of `actor`
    /// counts no time, while a tool body of that call holds.
    ///
    /// The pass that called the tool can end a short time after the body
    /// started. Each recorded phase signals `phaseChanges`, so the wait reads
    /// the watch again after each phase. With correct code the wait ends
    /// while the body holds. With a defect, the body counts as time without
    /// progress, and the wait never ends: a stack of the test process shows
    /// it.
    ///
    /// - Parameter actor: The session whose tool body holds.
    /// - Throws: ``ConditionNeverHeld`` when the test task was cancelled first.
    private static func waitUntilNoTimeCounts(on actor: RoutedSessionActor) async throws {
        try await actor.generationPassObserver.phaseChanges.wait(until: {
            let watch = await actor.appliedStallWatch()
            return watch != nil && watch?.measuredFrom == nil
        })
    }

    @Test(
        "a submission that waits sends submissionQueued with its id before submissionStarted with the same id, and the wait is no stall")
    func aWaitingSubmissionSendsItsQueuedIdBeforeItsStartAndNoStall() async throws {
        let dir = RouterTestFixtures.makeTempDir(prefix: Self.tempDirPrefix)
        defer { try? FileManager.default.removeItem(at: dir) }
        let fixture = PassObservingFixture()
        // The test never advances the clock, so the watch never ticks. The
        // test reads the state of the watch, which each tick reads.
        let resolved = try await Self.resolve(fixture, in: dir, clock: ManualRunClock())
        let queue = try #require(resolved.profile.standard.backendQueue)
        let holding = resolved.profile.standard.makeSession()
        let waiting = resolved.profile.standard.makeSession()
        let waitingActor = try #require(waiting as? RoutedSessionActor)
        await waiting.setGenerationStallReportInterval(Self.reportInterval)
        let (holdingLog, holdingDrain) = await SessionEventLog.watch(holding)

        let holdingAnswer = Task { try await holding.respond(to: Self.holdingPrompt) }
        // The latch holds each pass, so neither answer can end before the
        // event that the test waits for.
        try await RecordedWaitResult.wait(
            for: { try await fixture.passes.waitForPasses(1) }, endingOnEndOf: holdingAnswer)
        let (waitingLog, waitingAnswer) = SessionEventLog.collect(await waiting.streamEvents(to: Self.waitingPrompt))
        try await RecordedWaitResult.wait(
            for: { try await waitingLog.wait(until: { !Self.queuedIds(in: $0).isEmpty }) },
            endingOnEndOf: waitingAnswer)
        // The holding pass keeps the worker until the test opens the latch, so
        // the submission still waits. The watch of its call counts no time
        // now, so no tick of the watch can report a stall.
        let watchDuringTheWait = try #require(await waitingActor.appliedStallWatch())
        #expect(watchDuringTheWait.measuredFrom == nil)
        #expect(await queue.waitingCount == 1)

        await fixture.latch.open()
        _ = try await holdingAnswer.value
        try await waitingAnswer.value
        try await holdingLog.wait(until: { $0.contains(where: \.isAnswerEnd) })
        holdingDrain.cancel()

        // The waiting submission sends its id in submissionQueued, and then
        // sends submissionStarted with the same id. It is the first
        // submission of its session, and it carries the caller message.
        let waitingEvents = await waitingLog.events
        _ = eventsInsideAnswerFrame(waitingEvents)
        let queuedIds = Self.queuedIds(in: waitingEvents)
        #expect(queuedIds == [SubmissionID(1)])
        let queuedId = try #require(queuedIds.first)
        let starts = waitingEvents.submissionStarts
        #expect(starts.count == 1)
        let start = try #require(starts.first)
        #expect(start.submissionId == queuedId)
        #expect(start.cause == .message)
        let queuedAt = try #require(waitingEvents.firstIndex(of: .submissionQueued(queuedId)))
        let startedAt = try #require(waitingEvents.firstIndex(of: .submissionStarted(start)))
        #expect(queuedAt < startedAt)
        // The worker was free for the holding submission: it sends only the
        // start of its submission, and no submissionQueued.
        let holdingEvents = await holdingLog.events
        _ = eventsInsideAnswerFrame(holdingEvents)
        #expect(Self.queuedIds(in: holdingEvents).isEmpty)
        #expect(holdingEvents.submissionStarts.count == 1)
        #expect(await queue.isRunning == false)
        withExtendedLifetime(resolved) {}
    }

    @Test(
        "a tool body that runs longer than the stall interval reports no stall while it runs")
    func aToolBodyIsNotAStall() async throws {
        let dir = RouterTestFixtures.makeTempDir(prefix: Self.tempDirPrefix)
        defer { try? FileManager.default.removeItem(at: dir) }
        let fixture = PassObservingFixture(toolRounds: 1)
        await fixture.latch.open()
        // The test never advances the clock, so the watch never ticks. The
        // test reads the state of the watch, which each tick reads.
        let resolved = try await Self.resolve(fixture, in: dir, clock: ManualRunClock())
        let toolLog = PassBoundaryLog()
        let toolGate = AsyncSemaphore(value: 0)
        let tool = PassBoundaryProbeTool(log: toolLog, hold: { await toolGate.wait() })
        let session = resolved.profile.standard.makeSession(tools: [tool])
        let actor = try #require(session as? RoutedSessionActor)
        await session.setGenerationStallReportInterval(Self.reportInterval)

        let (_, answer) = SessionEventLog.collect(await session.streamEvents(to: Self.holdingPrompt))
        // The tool gate holds the body, so the answer cannot end before the
        // body starts. An answer that ends first did not call the tool.
        try await RecordedWaitResult.wait(
            for: { await toolLog.waitUntil { $0.contains(.toolBodyStarted) } }, endingOnEndOf: answer)
        try await Self.waitUntilNoTimeCounts(on: actor)
        toolGate.signal()
        try await answer.value
        withExtendedLifetime(resolved) {}
    }

    @Test(
        "a pass of the running submission that makes no fragment still reports a stall")
    func aHeldPassWithNoFragmentStillReportsAStall() async throws {
        let dir = RouterTestFixtures.makeTempDir(prefix: Self.tempDirPrefix)
        defer { try? FileManager.default.removeItem(at: dir) }
        let fixture = PassObservingFixture()
        let clock = ManualRunClock()
        let resolved = try await Self.resolve(fixture, in: dir, clock: clock)
        let session = resolved.profile.standard.makeSession()
        await session.setGenerationStallReportInterval(Self.reportInterval)

        let (log, answer) = SessionEventLog.collect(await session.streamEvents(to: Self.holdingPrompt))
        // The pass started, and holds until the test opens the latch. The
        // watch sleeps for its first interval. An answer that ends first did
        // not start the pass.
        try await RecordedWaitResult.wait(for: { try await fixture.passes.waitForPasses(1) }, endingOnEndOf: answer)
        await clock.waitForSleepers(atLeast: 1)
        clock.advance(by: Self.reportInterval)
        try await log.wait(until: { !Self.stalls(in: $0).isEmpty })
        await fixture.latch.open()
        try await answer.value

        let stall = try #require(await log.stalls.first)
        #expect(stall.visibility == .fragments(observed: 0))
        // The pass started at the start of the call, and the clock moved one
        // interval after it.
        #expect(stall.timeWithoutProgress == Self.reportInterval)
        #expect(stall.timeInFlight == Self.reportInterval)
        withExtendedLifetime(resolved) {}
    }

    @Test(
        "after a wait for the worker and a tool body, a stall measures only the pass, and its time in flight is the whole call")
    func aStallAfterAWaitAndAToolBodyMeasuresOnlyTheHeldPass() async throws {
        let dir = RouterTestFixtures.makeTempDir(prefix: Self.tempDirPrefix)
        defer { try? FileManager.default.removeItem(at: dir) }
        let step = AsyncSemaphore(value: 0)
        let fixture = PassObservingFixture(toolRounds: 1, step: step)
        await fixture.latch.open()
        let clock = ManualRunClock()
        let resolved = try await Self.resolve(fixture, in: dir, clock: clock)
        let holding = resolved.profile.standard.makeSession()
        let toolLog = PassBoundaryLog()
        let toolGate = AsyncSemaphore(value: 0)
        let tool = PassBoundaryProbeTool(log: toolLog, hold: { await toolGate.wait() })
        let waiting = resolved.profile.standard.makeSession(tools: [tool])
        let waitingActor = try #require(waiting as? RoutedSessionActor)
        await waiting.setGenerationStallReportInterval(Self.reportInterval)

        let holdingAnswer = Task { try await holding.respond(to: Self.holdingPrompt) }
        // The step holds each pass, so neither answer can end before the
        // event that the test waits for.
        try await RecordedWaitResult.wait(
            for: { try await fixture.passes.waitForPasses(1) }, endingOnEndOf: holdingAnswer)
        let (log, waitingAnswer) = SessionEventLog.collect(await waiting.streamEvents(to: Self.waitingPrompt))
        try await RecordedWaitResult.wait(
            for: { try await log.wait(until: { !Self.queuedIds(in: $0).isEmpty }) }, endingOnEndOf: waitingAnswer)
        // The call of the waiting session started before it reported its
        // wait, and its watch sleeps for its first interval. The holding pass
        // waits for its step, so the submission still waits while the clock
        // moves, and the watch counts no time.
        await clock.waitForSleepers(atLeast: 1)
        clock.advance(by: Self.workerWaitTime)
        let watchDuringTheWait = try #require(await waitingActor.appliedStallWatch())
        #expect(watchDuringTheWait.measuredFrom == nil)

        // One step for the holding pass, and one for the first pass of the
        // waiting session, which calls the tool. The second pass of the
        // waiting session then generates until the last step.
        step.signal()
        step.signal()
        // The tool gate holds the body, so the waiting answer cannot end
        // before the body starts.
        try await RecordedWaitResult.wait(
            for: { await toolLog.waitUntil { $0.contains(.toolBodyStarted) } }, endingOnEndOf: waitingAnswer)
        // The tool body counts no time while the clock moves.
        try await Self.waitUntilNoTimeCounts(on: waitingActor)
        clock.advance(by: Self.toolBodyTime)
        toolGate.signal()
        // The second pass started and holds for its step, and the watch noted
        // the tool result. Only then does the clock move past the interval.
        // Because the second pass holds, the waiting answer cannot end first.
        try await RecordedWaitResult.wait(
            for: { try await fixture.passes.waitForPasses(Self.passesBeforeTheHeldPass) },
            endingOnEndOf: waitingAnswer)
        try await waitingActor.generationProgressChanges.wait(until: {
            await waitingActor.appliedStallWatch()?.lastProgressKind == .toolResult
        })
        clock.advance(by: Self.reportInterval)
        try await log.wait(until: { !Self.stalls(in: $0).isEmpty })
        let stalls = await log.stalls
        step.signal()
        _ = try await holdingAnswer.value
        try await waitingAnswer.value

        let stall = try #require(stalls.first)
        #expect(stall.lastProgress == .toolResult)
        #expect(stall.visibility == .fragments(observed: 0))
        // The time without progress starts at the tool result and the start
        // of the second pass. The time in flight starts at the start of the
        // call, so it is longer by the wait and the tool body.
        #expect(stall.timeWithoutProgress == Self.reportInterval)
        #expect(stall.timeInFlight == Self.workerWaitTime + Self.toolBodyTime + Self.reportInterval)
        withExtendedLifetime(resolved) {}
    }

    /// The time between two phases of the watch test.
    private static let phaseStep: Duration = .seconds(1)

    @Test("a watch counts nothing while its submission waits, then counts from the start of the submission, then of each pass")
    func aWatchCountsFromTheStartOfTheSubmissionAndOfEachPass() {
        let callStart = ContinuousClock.now
        var watch = GenerationStallWatch(
            id: 1, startedAt: callStart, lastProgressAt: callStart, submissionStartedAt: nil)
        let waitingFrom = watch.measuredFrom
        watch.apply(.submissionQueued)
        let queuedFrom = watch.measuredFrom

        // With no pass report yet, the time counts from the start of the
        // submission, as for a backend with no executor seam.
        let submissionStart = callStart.advanced(by: Self.phaseStep)
        watch.apply(.submissionStarted(at: submissionStart))
        let startedFrom = watch.measuredFrom

        let passStart = submissionStart.advanced(by: Self.phaseStep)
        watch.apply(.passStarted(at: passStart))
        let passFrom = watch.measuredFrom
        watch.apply(.passEnded)
        let toolBodyFrom = watch.measuredFrom

        #expect(waitingFrom == nil)
        #expect(queuedFrom == nil)
        #expect(startedFrom == submissionStart)
        #expect(passFrom == passStart)
        #expect(toolBodyFrom == nil)
    }

    @Test("a call with no queue counts from the start of the call, which is the start of its submission")
    func aCallWithNoQueueCountsFromItsStart() {
        let callStart = ContinuousClock.now
        let watch = GenerationStallWatch(
            id: 1, startedAt: callStart, lastProgressAt: callStart, submissionStartedAt: callStart)

        #expect(watch.measuredFrom == callStart)
    }

    @Test(
        "only the wait of an open submission reaches the consumer, as submissionQueued with its id; a start, a pass and a wait with no open submission send no event"
    )
    func onlyTheWaitOfAnOpenSubmissionReachesTheConsumer() {
        let now = ContinuousClock.now
        let open = SubmissionID(1)

        #expect(GenerationCallPhase.submissionQueued.sessionEvent(submission: open) == .submissionQueued(open))
        // A summarizer call of a compaction has no open submission.
        #expect(GenerationCallPhase.submissionQueued.sessionEvent(submission: nil) == nil)
        // The start of a submission reaches the consumer through the session,
        // not through a phase.
        #expect(GenerationCallPhase.submissionStarted(at: now).sessionEvent(submission: open) == nil)
        #expect(GenerationCallPhase.submissionStarted(at: now).sessionEvent(submission: nil) == nil)
        #expect(GenerationCallPhase.passStarted(at: now).sessionEvent(submission: open) == nil)
        #expect(GenerationCallPhase.passStarted(at: now).sessionEvent(submission: nil) == nil)
        #expect(GenerationCallPhase.passEnded.sessionEvent(submission: open) == nil)
        #expect(GenerationCallPhase.passEnded.sessionEvent(submission: nil) == nil)
    }
}

extension RoutedSessionActor {
    /// Applies each call phase that the session did not apply yet, and gives
    /// the stall watch of the model call in flight.
    ///
    /// Each tick of the watch applies the phases in the same way
    /// (``reportGenerationStall(id:)``). So the result is the state that a
    /// tick reads now, and a `nil` ``GenerationStallWatch/measuredFrom`` means
    /// that no tick can report a stall now.
    ///
    /// - Returns: The watch, or `nil` when no model call is in flight.
    func appliedStallWatch() -> GenerationStallWatch? {
        drainGenerationPassPhases()
        return generationStallWatch
    }
}
