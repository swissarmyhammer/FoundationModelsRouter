import Foundation
import FoundationModelsExtras
import FoundationModelsRouterTestSupport
import Synchronization
import Testing

@testable import FoundationModelsRouter

/// Tasks ^ake8sax, ^1psqdm9 and ^qhgfajc: the stall watch measures
/// generation, so it counts a pass only from its first output to its end. A
/// pass reports its start before it waits for the lock of the model, and the
/// model tells nothing when it takes the lock. A pass sends output only while
/// it holds the lock. Thus a wait for the lock, behind the long generation of
/// another session, is not a stall, and a tool body between two passes is not
/// a stall either.
///
/// Each session is a routed session over one ``LiveBackendContainer``, so each
/// submission goes through the production backend and its per-session
/// ``SessionLanguageModel``, which reports each pass to the session. The
/// ``PassObservingModel`` holds its ``FIFOGenerationLock`` for each pass, as
/// an MLX model does.
///
/// Each wait here waits for an event of the session, of the model, of the
/// tool or of the clock, inside the limit of a ``BoundedWait``. A test does
/// not wait for a time. The router of each test gives a `ManualRunClock` to
/// the run plane of each session, and the stall watch runs on that clock, so
/// the clock moves only when the test advances it. A test that checks that no
/// report comes reads the state of the watch at a point of a fixed order. A
/// test that checks a report advances the clock past the interval, and waits
/// for the report itself.
@Suite("A wait for the lock of the model is not a stalled generation (tasks ^ake8sax, ^1psqdm9, ^qhgfajc)")
struct LockWaitStallWatchTests {
    /// The suite's temp-directory prefix, handed to
    /// ``RouterTestFixtures/makeTempDir(prefix:)``.
    private static let tempDirPrefix = "LockWaitStallWatchTests"

    /// The stall report interval each watched session installs.
    private static let reportInterval: Duration = .milliseconds(50)

    /// How far the test advances the clock while the pass waits for the
    /// lock. With ``toolBodyTime`` it is shorter than ``reportInterval``, so
    /// no tick comes before the second pass.
    private static let lockWaitTime: Duration = .milliseconds(20)

    /// How far the test advances the clock while the tool body runs.
    private static let toolBodyTime: Duration = .milliseconds(10)

    /// How many passes the test of a wait and a tool body waits for before
    /// the second pass of the waiting session holds: the pass of the holding
    /// session, and the two passes of the waiting session.
    private static let passesBeforeTheHeldPass = 3

    /// The prompt of the session whose pass holds the lock.
    private static let holdingPrompt = "a"

    /// The prompt of the session whose pass waits for the lock.
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

    /// Opens each hold of the passes and of the tool bodies of a test, and
    /// then closes each of `sessions`.
    ///
    /// A test calls it from one `defer` right after it makes its sessions, so
    /// they close also when the test throws (rule T1). A close waits for the
    /// end of each held pass and each held tool body, so the holds open first.
    /// The close opens the latch of `fixture`. No wait on a gate ends on a
    /// cancel (``AsyncSemaphore/wait()``), so each gate gets one permit for
    /// each pass that a test of this suite can make: no test makes more than
    /// ``passesBeforeTheHeldPass``. A permit that no wait takes does nothing.
    ///
    /// - Parameters:
    ///   - sessions: The sessions to close.
    ///   - fixture: The fixture whose latch holds each pass.
    ///   - gates: The semaphores that hold a pass or a tool body. The default
    ///     is no gate.
    private static func close(
        _ sessions: [any RoutedSession], of fixture: PassObservingFixture, signalling gates: [AsyncSemaphore] = []
    ) async {
        await SessionFixtureLifecycle.close(
            sessions, opening: [fixture.latch], releasing: gates, permits: passesBeforeTheHeldPass)
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
    /// progress, and the wait ends only at the limit of its ``BoundedWait``.
    ///
    /// - Parameter actor: The session whose tool body holds.
    /// - Throws: ``ConditionNeverHeld`` when the test task was cancelled first.
    private static func waitUntilNoTimeCounts(on actor: RoutedSessionActor) async throws {
        try await actor.generationPassObserver.phaseChanges.wait(until: {
            let watch = await actor.appliedStallWatch()
            return watch != nil && watch?.measuredFrom == nil
        })
    }

    /// Waits until the watch of the model call in flight of `actor` counts
    /// from the first output of the running pass. The read is of the first
    /// output itself: before the first pass report, the watch counts from the
    /// start of the submission, as for a backend with no executor seam.
    ///
    /// The relay of the pass reports its first output event before it gives
    /// the event to the SDK, and each recorded phase signals `phaseChanges`.
    /// The SDK can keep the text of a pass until a later event, so the
    /// session need not see that output as a fragment yet: the watch counts
    /// from the first output event of the pass, not from a fragment.
    ///
    /// - Parameter actor: The session whose pass sent its first output.
    /// - Throws: ``ConditionNeverHeld`` when the test task was cancelled first.
    private static func waitUntilTheFirstOutputCounts(on actor: RoutedSessionActor) async throws {
        try await actor.generationPassObserver.phaseChanges.wait(until: {
            await actor.appliedStallWatch()?.passOutputSince != nil
        })
    }

    @Test("a call that waits for the lock behind the long generation of another session gives no stall")
    func aCallThatWaitsForTheLockGivesNoStall() async throws {
        let dir = RouterTestFixtures.makeTempDir(prefix: Self.tempDirPrefix)
        defer { try? FileManager.default.removeItem(at: dir) }
        let fixture = PassObservingFixture()
        // The test never advances the clock, so the watch never ticks. The
        // test reads the state of the watch, which each tick reads.
        let resolved = try await Self.resolve(fixture, in: dir, clock: ManualRunClock())
        let holding = resolved.profile.standard.makeSession()
        let waiting = resolved.profile.standard.makeSession()
        defer { await Self.close([holding, waiting], of: fixture) }
        let waitingActor = try #require(waiting as? RoutedSessionActor)
        await waiting.setGenerationStallReportInterval(Self.reportInterval)

        let holdingAnswer = Task { try await holding.respond(to: Self.holdingPrompt) }
        // The latch holds each pass, so neither answer can end before the
        // event that the test waits for.
        try await BoundedWait.run {
            try await RecordedWaitResult.wait(
                for: { try await fixture.passes.waitForPasses(1) }, endingOnEndOf: holdingAnswer)
        }
        let (waitingLog, waitingAnswer) = SessionEventLog.collect(await waiting.streamEvents(to: Self.waitingPrompt))
        try await BoundedWait.run { try await fixture.lock.waitForWaiters(1) }
        // The holding pass keeps the lock until the test opens the latch, so
        // the pass of the waiting session still waits. Its submission and
        // its pass started, and the watch of its call counts no time now, so
        // no tick of the watch can report a stall.
        let watchDuringTheWait = try #require(await waitingActor.appliedStallWatch())
        #expect(watchDuringTheWait.reportsPasses)
        #expect(watchDuringTheWait.measuredFrom == nil)

        await fixture.latch.open()
        _ = try await BoundedWait.value(of: holdingAnswer)
        try await BoundedWait.value(of: waitingAnswer)

        // One start and one end for the one SDK call, and no stall.
        let waitingEvents = await waitingLog.events
        _ = eventsInsideAnswerFrame(waitingEvents)
        #expect(waitingEvents.submissionStarts.count == 1)
        #expect(waitingEvents.submissionEnds.count == 1)
        #expect(waitingEvents.submissionStarts.first?.submissionId == waitingEvents.submissionEnds.first?.submissionId)
        #expect(Self.stalls(in: waitingEvents).isEmpty)
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
        defer { await Self.close([session], of: fixture, signalling: [toolGate]) }
        let actor = try #require(session as? RoutedSessionActor)
        await session.setGenerationStallReportInterval(Self.reportInterval)

        let (_, answer) = SessionEventLog.collect(await session.streamEvents(to: Self.holdingPrompt))
        // The tool gate holds the body, so the answer cannot end before the
        // body starts. An answer that ends first did not call the tool.
        try await BoundedWait.run {
            try await RecordedWaitResult.wait(
                for: { try await toolLog.waitUntil { $0.contains(.toolBodyStarted) } }, endingOnEndOf: answer)
        }
        try await BoundedWait.run { try await Self.waitUntilNoTimeCounts(on: actor) }
        toolGate.signal()
        try await BoundedWait.value(of: answer)
        withExtendedLifetime(resolved) {}
    }

    @Test("a pass that has the lock and gives no output for longer than the interval still reports a stall")
    func aHeldPassWithNoOutputStillReportsAStall() async throws {
        let dir = RouterTestFixtures.makeTempDir(prefix: Self.tempDirPrefix)
        defer { try? FileManager.default.removeItem(at: dir) }
        let fixture = PassObservingFixture(holdsAfterFirstOutput: true)
        let clock = ManualRunClock()
        let resolved = try await Self.resolve(fixture, in: dir, clock: clock)
        let session = resolved.profile.standard.makeSession()
        defer { await Self.close([session], of: fixture) }
        let actor = try #require(session as? RoutedSessionActor)
        await session.setGenerationStallReportInterval(Self.reportInterval)

        let (log, answer) = SessionEventLog.collect(await session.streamEvents(to: Self.holdingPrompt))
        // The pass holds the lock, sent its first output, and holds until the
        // test opens the latch. The watch sleeps for its first interval.
        try await BoundedWait.run { try await Self.waitUntilTheFirstOutputCounts(on: actor) }
        try await BoundedWait.run { try await clock.waitForSleepers(atLeast: 1, endingOnEndOf: answer) }
        clock.advance(by: Self.reportInterval)
        try await BoundedWait.run { try await log.wait(until: { !Self.stalls(in: $0).isEmpty }) }
        await fixture.latch.open()
        try await BoundedWait.value(of: answer)

        let stall = try #require(await log.stalls.first)
        // The session saw no fragment yet: the watch counts from the first
        // output event of the pass.
        #expect(stall.lastProgress == .callStart)
        #expect(stall.visibility == .fragments(observed: 0))
        // The first output came at the start of the call, and the clock moved
        // one interval after it.
        #expect(stall.timeWithoutProgress == Self.reportInterval)
        #expect(stall.timeInFlight == Self.reportInterval)
        withExtendedLifetime(resolved) {}
    }

    @Test(
        "after a wait for the lock and a tool body, a stall measures only the pass after its first output, and its time in flight is the whole call")
    func aStallAfterAWaitAndAToolBodyMeasuresOnlyTheHeldPass() async throws {
        let dir = RouterTestFixtures.makeTempDir(prefix: Self.tempDirPrefix)
        defer { try? FileManager.default.removeItem(at: dir) }
        let step = AsyncSemaphore(value: 0)
        let fixture = PassObservingFixture(toolRounds: 1, step: step, holdsAfterFirstOutput: true)
        await fixture.latch.open()
        let clock = ManualRunClock()
        let resolved = try await Self.resolve(fixture, in: dir, clock: clock)
        let holding = resolved.profile.standard.makeSession()
        let toolLog = PassBoundaryLog()
        let toolGate = AsyncSemaphore(value: 0)
        let tool = PassBoundaryProbeTool(log: toolLog, hold: { await toolGate.wait() })
        let waiting = resolved.profile.standard.makeSession(tools: [tool])
        defer { await Self.close([holding, waiting], of: fixture, signalling: [step, toolGate]) }
        let waitingActor = try #require(waiting as? RoutedSessionActor)
        await waiting.setGenerationStallReportInterval(Self.reportInterval)

        let holdingAnswer = Task { try await holding.respond(to: Self.holdingPrompt) }
        // The step holds each pass, so neither answer can end before the
        // event that the test waits for.
        try await BoundedWait.run {
            try await RecordedWaitResult.wait(
                for: { try await fixture.passes.waitForPasses(1) }, endingOnEndOf: holdingAnswer)
        }
        let (log, waitingAnswer) = SessionEventLog.collect(await waiting.streamEvents(to: Self.waitingPrompt))
        // The first pass of the waiting session waits for the lock, and its
        // watch sleeps for its first interval. The holding pass waits for its
        // step, so the pass still waits while the clock moves, and the watch
        // counts no time.
        try await BoundedWait.run { try await fixture.lock.waitForWaiters(1) }
        try await BoundedWait.run { try await clock.waitForSleepers(atLeast: 1, endingOnEndOf: waitingAnswer) }
        clock.advance(by: Self.lockWaitTime)
        let watchDuringTheWait = try #require(await waitingActor.appliedStallWatch())
        #expect(watchDuringTheWait.measuredFrom == nil)

        // One step for the holding pass, and one for the first pass of the
        // waiting session, which calls the tool. The second pass of the
        // waiting session then sends its first output and holds until the
        // last step.
        step.signal()
        step.signal()
        // The tool gate holds the body, so the waiting answer cannot end
        // before the body starts.
        try await BoundedWait.run {
            try await RecordedWaitResult.wait(
                for: { try await toolLog.waitUntil { $0.contains(.toolBodyStarted) } }, endingOnEndOf: waitingAnswer)
        }
        // The tool body counts no time while the clock moves.
        try await BoundedWait.run { try await Self.waitUntilNoTimeCounts(on: waitingActor) }
        clock.advance(by: Self.toolBodyTime)
        toolGate.signal()
        // The second pass sent its first output and holds for its step. Only
        // then does the clock move past the interval. Because the second pass
        // holds, the waiting answer cannot end first.
        try await BoundedWait.run {
            try await RecordedWaitResult.wait(
                for: { try await fixture.passes.waitForPasses(Self.passesBeforeTheHeldPass) },
                endingOnEndOf: waitingAnswer)
        }
        try await BoundedWait.run { try await Self.waitUntilTheFirstOutputCounts(on: waitingActor) }
        try await BoundedWait.run {
            try await waitingActor.generationProgressChanges.wait(until: {
                await waitingActor.appliedStallWatch()?.lastProgressKind == .toolResult
            })
        }
        clock.advance(by: Self.reportInterval)
        try await BoundedWait.run { try await log.wait(until: { !Self.stalls(in: $0).isEmpty }) }
        let stalls = await log.stalls
        step.signal()
        _ = try await BoundedWait.value(of: holdingAnswer)
        try await BoundedWait.value(of: waitingAnswer)

        let stall = try #require(stalls.first)
        #expect(stall.lastProgress == .toolResult)
        #expect(stall.visibility == .fragments(observed: 0))
        // The time without progress starts at the tool result and the first
        // output of the second pass. The time in flight starts at the start of the call, so it is
        // longer by the wait for the lock and the tool body.
        #expect(stall.timeWithoutProgress == Self.reportInterval)
        #expect(stall.timeInFlight == Self.lockWaitTime + Self.toolBodyTime + Self.reportInterval)
        withExtendedLifetime(resolved) {}
    }

    /// The time between two phases of the watch test.
    private static let phaseStep: Duration = .seconds(1)

    @Test("a watch counts from the start of the submission, then nothing from the start of a pass to its first output")
    func aWatchCountsFromTheFirstOutputOfEachPass() {
        let callStart = ContinuousClock.now
        var watch = GenerationStallWatch(
            id: 1, startedAt: callStart, lastProgressAt: callStart, submissionStartedAt: callStart)

        // With no pass report yet, the time counts from the start of the
        // submission, as for a backend with no executor seam.
        let submissionStart = callStart.advanced(by: Self.phaseStep)
        watch.apply(.submissionStarted(at: submissionStart))
        let startedFrom = watch.measuredFrom

        // The pass can wait for the lock of the model: nothing counts.
        let passStart = submissionStart.advanced(by: Self.phaseStep)
        watch.apply(.passStarted(at: passStart))
        let passFrom = watch.measuredFrom

        let firstOutput = passStart.advanced(by: Self.phaseStep)
        watch.apply(.firstOutputEvent(at: firstOutput))
        let outputFrom = watch.measuredFrom
        // A second report of the same pass does not move the start.
        watch.apply(.firstOutputEvent(at: firstOutput.advanced(by: Self.phaseStep)))
        let laterOutputFrom = watch.measuredFrom

        watch.apply(.passEnded)
        let toolBodyFrom = watch.measuredFrom

        #expect(startedFrom == submissionStart)
        #expect(passFrom == nil)
        #expect(outputFrom == firstOutput)
        #expect(laterOutputFrom == firstOutput)
        #expect(toolBodyFrom == nil)
    }

    @Test("a call whose backend reports no pass counts from the start of the call, which is the start of its submission")
    func aCallWithNoPassReportsCountsFromItsStart() {
        let callStart = ContinuousClock.now
        let watch = GenerationStallWatch(
            id: 1, startedAt: callStart, lastProgressAt: callStart, submissionStartedAt: callStart)

        #expect(watch.measuredFrom == callStart)
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
