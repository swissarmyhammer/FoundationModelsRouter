import Foundation
import FoundationModelsRouterTestSupport
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
/// Each wait here waits for an event of the session, of the model or of the
/// tool. A test does not wait for a time: it reads the state of the watch at a
/// point of a fixed order, or it waits for the stall report itself.
@Suite("A wait for the worker is not a stalled generation (tasks ^ake8sax, ^1psqdm9)")
struct QueuedPassStallWatchTests {
    /// The suite's temp-directory prefix, handed to
    /// ``RouterTestFixtures/makeTempDir(prefix:)``.
    private static let tempDirPrefix = "QueuedPassStallWatchTests"

    /// The stall report interval each watched session installs.
    private static let reportInterval: Duration = .milliseconds(50)

    /// A stall report interval that no test reaches. A test that proves that
    /// no time counts installs it, so the ticker of the watch never reports,
    /// and the test reads the state of the watch, which a tick reads.
    private static let unreachableReportInterval: Duration = .seconds(600)

    /// The prompt of the session whose submission holds the worker.
    private static let holdingPrompt = "a"

    /// The prompt of the session whose submission waits for the worker.
    private static let waitingPrompt = "b"

    /// Resolves the standard profile over the container of `fixture`.
    ///
    /// - Parameters:
    ///   - fixture: The fixture whose container the router loads.
    ///   - dir: The cache directory of the router.
    /// - Returns: The router and the resolved profile.
    private static func resolve(
        _ fixture: PassObservingFixture, in dir: URL
    ) async throws -> (router: Router, profile: LanguageModelProfile) {
        try await RouterTestFixtures.resolveStandardProfile(over: fixture.container, cacheDir: dir)
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
        let resolved = try await Self.resolve(fixture, in: dir)
        let queue = try #require(resolved.profile.standard.backendQueue)
        let holding = resolved.profile.standard.makeSession()
        let waiting = resolved.profile.standard.makeSession()
        let waitingActor = try #require(waiting as? RoutedSessionActor)
        // The ticker never reports, so its timing cannot change the result.
        // The test reads the state of the watch, which each tick reads.
        await waiting.setGenerationStallReportInterval(Self.unreachableReportInterval)
        let (holdingLog, holdingDrain) = await SessionEventLog.watch(holding)

        let holdingAnswer = Task { try await holding.respond(to: Self.holdingPrompt) }
        try await fixture.passes.waitForPasses(1)
        let (waitingLog, waitingAnswer) = SessionEventLog.collect(await waiting.streamEvents(to: Self.waitingPrompt))
        try await waitingLog.wait(until: { !Self.queuedIds(in: $0).isEmpty })
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
        let resolved = try await Self.resolve(fixture, in: dir)
        let toolLog = PassBoundaryLog()
        let toolGate = AsyncSemaphore(value: 0)
        let tool = PassBoundaryProbeTool(log: toolLog, hold: { await toolGate.wait() })
        let session = resolved.profile.standard.makeSession(tools: [tool])
        let actor = try #require(session as? RoutedSessionActor)
        // The ticker never reports, so its timing cannot change the result.
        // The test reads the state of the watch, which each tick reads.
        await session.setGenerationStallReportInterval(Self.unreachableReportInterval)

        let (_, answer) = SessionEventLog.collect(await session.streamEvents(to: Self.holdingPrompt))
        await toolLog.waitUntil { $0.contains(.toolBodyStarted) }
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
        let resolved = try await Self.resolve(fixture, in: dir)
        let session = resolved.profile.standard.makeSession()
        await session.setGenerationStallReportInterval(Self.reportInterval)

        let (log, answer) = SessionEventLog.collect(await session.streamEvents(to: Self.holdingPrompt))
        // The pass holds until the test opens the latch, so the watch sends
        // its report when its interval ends.
        try await log.wait(until: { !Self.stalls(in: $0).isEmpty })
        await fixture.latch.open()
        try await answer.value

        let stall = try #require(await log.stalls.first)
        #expect(stall.visibility == .fragments(observed: 0))
        // The watch reports only when the time without progress reached
        // its interval.
        #expect(stall.timeWithoutProgress >= Self.reportInterval)
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
        let resolved = try await Self.resolve(fixture, in: dir)
        let holding = resolved.profile.standard.makeSession()
        let toolLog = PassBoundaryLog()
        let toolGate = AsyncSemaphore(value: 0)
        let tool = PassBoundaryProbeTool(log: toolLog, hold: { await toolGate.wait() })
        let waiting = resolved.profile.standard.makeSession(tools: [tool])
        let waitingActor = try #require(waiting as? RoutedSessionActor)
        await waiting.setGenerationStallReportInterval(Self.reportInterval)

        let holdingAnswer = Task { try await holding.respond(to: Self.holdingPrompt) }
        try await fixture.passes.waitForPasses(1)
        let (log, waitingAnswer) = SessionEventLog.collect(await waiting.streamEvents(to: Self.waitingPrompt))
        try await log.wait(until: { !Self.queuedIds(in: $0).isEmpty })
        // The call of the waiting session started before it reported its
        // wait, so it started before this instant.
        let callStartedBefore = ContinuousClock.now
        // The holding pass waits for its step, so the submission still waits,
        // and the watch counts no time.
        let watchDuringTheWait = try #require(await waitingActor.appliedStallWatch())
        #expect(watchDuringTheWait.measuredFrom == nil)

        // One step for the holding pass, and one for the first pass of the
        // waiting session, which calls the tool. The second pass of the
        // waiting session then generates until the last step.
        step.signal()
        step.signal()
        await toolLog.waitUntil { $0.contains(.toolBodyStarted) }
        // The tool body counts no time: the test reads the state of the
        // watch, and not the reports of the ticker, whose timing can put a
        // report of the first pass beside the start of the body.
        try await Self.waitUntilNoTimeCounts(on: waitingActor)
        // The tool result and the second pass come after the test opens the
        // gate, so both come after this instant.
        let secondPassStartedAfter = ContinuousClock.now
        toolGate.signal()
        try await log.wait(until: { events in
            Self.stalls(in: events).contains { $0.lastProgress == .toolResult }
        })
        let stalls = await log.stalls
        step.signal()
        _ = try await holdingAnswer.value
        try await waitingAnswer.value

        let stall = try #require(stalls.first { $0.lastProgress == .toolResult })
        #expect(stall.visibility == .fragments(observed: 0))
        #expect(stall.timeWithoutProgress >= Self.reportInterval)
        // Both times of the report end at the same instant. The time in
        // flight starts at the start of the call, and the time without
        // progress starts in the second pass. So the time in flight is
        // longer by the wait, the first pass and the tool body at least.
        #expect(
            stall.timeInFlight - stall.timeWithoutProgress >= callStartedBefore.duration(to: secondPassStartedAfter))
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
