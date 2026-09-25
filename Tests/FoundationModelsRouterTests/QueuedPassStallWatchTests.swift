import Foundation
import FoundationModelsRouterTestSupport
import Testing

@testable import FoundationModelsRouter

/// Tasks ^ake8sax and ^1psqdm9: the stall watch measures generation, so it
/// runs only while a pass of the running submission generates
/// (`generation-queue.md`, section 5.6). A wait for the worker of the queue
/// and a tool body between two passes are not a stall. A session tells its
/// consumer that its submission waits for the worker with
/// ``SessionEvent/submissionQueued``, and that the worker started the
/// submission with ``SessionEvent/submissionStarted``.
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

    @Test(
        "a streaming request that waits for the worker longer than the stall interval reports the wait and no stall",
        .timeLimit(.minutes(1)))
    func aWaitForTheWorkerIsNotAStall() async throws {
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
            await waitingLog.contains(.submissionQueued)
        }
        try await Task.sleep(for: Self.heldLongerThanTheInterval)
        let stallsDuringTheWait = await waitingLog.stalls
        let stillWaiting = await fixture.queue.waitingCount == 1

        await fixture.latch.open()
        _ = try await holdingTurn.value
        try await waitingTurn.value
        let holdingTurnEnded = await BoundedWait.conditionReached("the end of the holding turn on its feed") {
            await holdingLog.events.contains { event in
                guard case .turnEnded = event else { return false }
                return true
            }
        }
        holdingDrain.cancel()

        #expect(holdingInside)
        #expect(waitReported)
        #expect(stillWaiting)
        #expect(stallsDuringTheWait.isEmpty)
        let waitingEvents = await waitingLog.events
        #expect(waitingEvents.filter { $0 == .submissionQueued }.count == 1)
        #expect(waitingEvents.filter { $0 == .submissionStarted }.count == 1)
        let queuedAt = try #require(waitingEvents.firstIndex(of: .submissionQueued))
        let startedAt = try #require(waitingEvents.firstIndex(of: .submissionStarted))
        #expect(queuedAt < startedAt)
        #expect(holdingTurnEnded)
        // The worker was free for the holding submission: it sends only the
        // start of its submission.
        let holdingEvents = await holdingLog.events
        #expect(!holdingEvents.contains(.submissionQueued))
        #expect(holdingEvents.filter { $0 == .submissionStarted }.count == 1)
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
            await log.contains(.submissionQueued)
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

    @Test("only the wait and the start of a submission reach the consumer; a pass sends no event")
    func onlyTheSubmissionPhasesReachTheConsumer() {
        let now = ContinuousClock.now

        #expect(GenerationCallPhase.submissionQueued.sessionEvent == .submissionQueued)
        #expect(GenerationCallPhase.submissionStarted(at: now).sessionEvent == .submissionStarted)
        #expect(GenerationCallPhase.passStarted(at: now).sessionEvent == nil)
        #expect(GenerationCallPhase.passEnded.sessionEvent == nil)
    }
}
