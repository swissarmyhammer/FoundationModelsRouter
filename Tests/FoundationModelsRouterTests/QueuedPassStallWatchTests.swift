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
/// No wait here is a bare `await` on a turn that can stay suspended: the test
/// opens every latch and releases every step before it awaits a turn, so a
/// regression fails the test and does not hang the run.
@Suite("A wait for the worker is not a stalled generation (tasks ^ake8sax, ^1psqdm9)")
struct QueuedPassStallWatchTests {
    /// The suite's temp-directory prefix, handed to
    /// ``RouterTestFixtures/makeTempDir(prefix:)``.
    private static let tempDirPrefix = "QueuedPassStallWatchTests"

    /// The stall report interval each watched session installs.
    private static let reportInterval: Duration = .milliseconds(50)

    /// How long a test holds a session in a wait for the worker or in a tool
    /// body:
    /// twenty report intervals, so a watch that counted that time reports it.
    private static let heldLongerThanTheInterval: Duration = .seconds(1)

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

    /// A tool whose body holds for ``heldLongerThanTheInterval``.
    ///
    /// - Returns: The tool.
    private static func makeHoldingTool() -> PassBoundaryProbeTool {
        PassBoundaryProbeTool(log: PassBoundaryLog(), holdDuration: heldLongerThanTheInterval)
    }

    /// Whether `event` is the open or the close record of a tool call.
    ///
    /// - Parameters:
    ///   - event: The event to read.
    ///   - closed: `true` to match a close record, `false` to match an open one.
    /// - Returns: `true` when `event` is such a record.
    private static func isToolInvocation(_ event: SessionEvent, closed: Bool) -> Bool {
        guard case .toolInvocation(let record) = event else { return false }
        return (record.closedAt != nil) == closed
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

    @Test(
        "a submission that waits sends submissionQueued with its id before submissionStarted with the same id, and the wait is no stall",
        .timeLimit(.minutes(1)))
    func aWaitingSubmissionSendsItsQueuedIdBeforeItsStartAndNoStall() async throws {
        let dir = RouterTestFixtures.makeTempDir(prefix: Self.tempDirPrefix)
        defer { try? FileManager.default.removeItem(at: dir) }
        let fixture = PassObservingFixture()
        let resolved = try await Self.resolve(fixture, in: dir)
        let holding = resolved.profile.standard.makeSession()
        let waiting = resolved.profile.standard.makeSession()
        await waiting.setGenerationStallReportInterval(Self.reportInterval)
        let (holdingLog, holdingDrain) = await SessionEventLog.watch(holding)

        let holdingTurn = Task { try await holding.respond(to: Self.holdingPrompt) }
        let holdingInside = await BoundedWait.conditionReached("the pass of the holding session") {
            fixture.passes.recorded.count == 1
        }
        let (waitingLog, waitingTurn) = SessionEventLog.collect(await waiting.streamEvents(to: Self.waitingPrompt))
        let waitReported = await BoundedWait.conditionReached("the report of the wait") {
            await !Self.queuedIds(in: waitingLog.events).isEmpty
        }
        try await Task.sleep(for: Self.heldLongerThanTheInterval)
        let stallsDuringTheWait = await waitingLog.stalls
        let stillWaiting = await fixture.queue.waitingCount == 1

        await fixture.latch.open()
        _ = try await holdingTurn.value
        try await waitingTurn.value
        let holdingAnswered = await BoundedWait.conditionReached("the answer of the holding session on its feed") {
            await holdingLog.events.contains(where: \.isAnswerEnd)
        }
        holdingDrain.cancel()

        #expect(holdingInside)
        #expect(waitReported)
        #expect(stillWaiting)
        #expect(stallsDuringTheWait.isEmpty)
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
        #expect(holdingAnswered)
        // The worker was free for the holding submission: it sends only the
        // start of its submission, and no submissionQueued.
        let holdingEvents = await holdingLog.events
        _ = eventsInsideAnswerFrame(holdingEvents)
        #expect(Self.queuedIds(in: holdingEvents).isEmpty)
        #expect(holdingEvents.submissionStarts.count == 1)
        #expect(await fixture.queue.isRunning == false)
        withExtendedLifetime(resolved) {}
    }

    @Test(
        "a tool body that runs longer than the stall interval reports no stall while it runs",
        .timeLimit(.minutes(1)))
    func aToolBodyIsNotAStall() async throws {
        let dir = RouterTestFixtures.makeTempDir(prefix: Self.tempDirPrefix)
        defer { try? FileManager.default.removeItem(at: dir) }
        let fixture = PassObservingFixture(toolRounds: 1)
        await fixture.latch.open()
        let resolved = try await Self.resolve(fixture, in: dir)
        let session = resolved.profile.standard.makeSession(tools: [Self.makeHoldingTool()])
        await session.setGenerationStallReportInterval(Self.reportInterval)

        let (log, turn) = SessionEventLog.collect(await session.streamEvents(to: Self.holdingPrompt))
        try await turn.value

        let events = await log.events
        let bodyOpened = try #require(events.firstIndex { Self.isToolInvocation($0, closed: false) })
        let bodyClosed = try #require(events.firstIndex { Self.isToolInvocation($0, closed: true) })
        let stallsDuringTheBody = events[bodyOpened...bodyClosed].filter { event in
            guard case .generationStalled = event else { return false }
            return true
        }
        #expect(stallsDuringTheBody.isEmpty)
        withExtendedLifetime(resolved) {}
    }

    @Test(
        "a pass of the running submission that makes no fragment still reports a stall",
        .timeLimit(.minutes(1)))
    func aHeldPassWithNoFragmentStillReportsAStall() async throws {
        let dir = RouterTestFixtures.makeTempDir(prefix: Self.tempDirPrefix)
        defer { try? FileManager.default.removeItem(at: dir) }
        let fixture = PassObservingFixture()
        let resolved = try await Self.resolve(fixture, in: dir)
        let session = resolved.profile.standard.makeSession()
        await session.setGenerationStallReportInterval(Self.reportInterval)

        let (log, turn) = SessionEventLog.collect(await session.streamEvents(to: Self.holdingPrompt))
        let reported = await BoundedWait.conditionReached("a stall report of the held pass") {
            await !log.stalls.isEmpty
        }
        await fixture.latch.open()
        try await turn.value

        #expect(reported)
        let stall = try #require(await log.stalls.first)
        #expect(stall.visibility == .fragments(observed: 0))
        #expect(stall.timeWithoutProgress >= Self.reportInterval)
        withExtendedLifetime(resolved) {}
    }

    @Test(
        "after a wait for the worker and a tool body, a stall measures only the pass, and its time in flight is the whole call",
        .timeLimit(.minutes(1)))
    func aStallAfterAWaitAndAToolBodyMeasuresOnlyTheHeldPass() async throws {
        let dir = RouterTestFixtures.makeTempDir(prefix: Self.tempDirPrefix)
        defer { try? FileManager.default.removeItem(at: dir) }
        let step = AsyncSemaphore(value: 0)
        let fixture = PassObservingFixture(toolRounds: 1, step: step)
        await fixture.latch.open()
        let resolved = try await Self.resolve(fixture, in: dir)
        let holding = resolved.profile.standard.makeSession()
        let waiting = resolved.profile.standard.makeSession(tools: [Self.makeHoldingTool()])
        await waiting.setGenerationStallReportInterval(Self.reportInterval)

        let holdingTurn = Task { try await holding.respond(to: Self.holdingPrompt) }
        let holdingInside = await BoundedWait.conditionReached("the pass of the holding session") {
            fixture.passes.recorded.count == 1
        }
        let (log, waitingTurn) = SessionEventLog.collect(await waiting.streamEvents(to: Self.waitingPrompt))
        let waitReported = await BoundedWait.conditionReached("the report of the wait") {
            await !Self.queuedIds(in: log.events).isEmpty
        }
        try await Task.sleep(for: Self.heldLongerThanTheInterval)
        // One step for the holding pass, and one for the first pass of the
        // waiting session, which calls the tool. The second pass of the
        // waiting session then generates until the last step.
        step.signal()
        step.signal()
        let reported = await BoundedWait.conditionReached("a stall report of the held second pass") {
            await log.stalls.contains { $0.lastProgress == .toolResult }
        }
        let stalls = await log.stalls
        step.signal()
        _ = try await holdingTurn.value
        try await waitingTurn.value

        #expect(holdingInside)
        #expect(waitReported)
        #expect(reported)
        #expect(stalls.allSatisfy { $0.lastProgress == .toolResult })
        let stall = try #require(stalls.first { $0.lastProgress == .toolResult })
        #expect(stall.visibility == .fragments(observed: 0))
        #expect(stall.timeWithoutProgress >= Self.reportInterval)
        #expect(stall.timeWithoutProgress < Self.heldLongerThanTheInterval)
        #expect(stall.timeInFlight >= Self.heldLongerThanTheInterval * 2)
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
