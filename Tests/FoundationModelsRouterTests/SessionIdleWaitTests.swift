import Foundation
import FoundationModels
import FoundationModelsRouterTestSupport
import Testing

@testable import FoundationModelsExtras
@testable import FoundationModelsRouter

/// Exercises task ^bm6tpe3: ``RoutedSession/awaitIdle()`` tells a host when a
/// session has no more work. No background run is open, no pump work runs or
/// waits, and no waiting mail can start an answer by itself.
///
/// Everything runs against the scripted ``BackgroundingBackend`` and real
/// background tools of the session, so the suite needs no network and no
/// GPU. The tests read the order of the steps, not a clock. The `.timeLimit`
/// ends a wait that never returns.
@Suite("A host waits until a session is idle", .timeLimit(.minutes(1)))
struct SessionIdleWaitTests {
    // MARK: - Fixtures

    /// A background tool whose run settles inside its own tool call. Its gate
    /// is open before the call, and its grace is far longer than the run, so
    /// the runner gives the result in the envelope of the call, and takes
    /// back the staged mail of the run.
    struct InlineSettlingTool: Tool, BackgroundTool {
        let name = "inline_settling_job"
        let description = "test-only background tool whose run settles inside its own call"

        /// The latch the body of the run waits on.
        let gate: RunLatch

        var mount: ToolMount? {
            ToolMount(mode: .background, timeout: nil)
        }

        var inlineSettleGrace: TimeInterval? {
            SessionIdleWaitTests.inlineSettleGrace
        }

        func call(arguments: BackgroundFixtureArguments) async throws -> String {
            await gate.waitUntilOpen()
            return SessionIdleWaitTests.runOutput
        }
    }

    /// One session over a ``BackgroundingBackend``, with what a test reads.
    struct Fixture: Sendable {
        /// The session under test.
        let session: any RoutedSession

        /// The backend the session runs on.
        let backend: BackgroundingBackend

        /// The router that keeps the models of the session resident.
        let router: Router

        /// The temporary directory the router caches under.
        let directory: URL
    }

    // MARK: - Constants

    /// The grace of ``InlineSettlingTool``: far longer than its run, whose
    /// gate is already open, so the wait of the runner ends when the run
    /// settles, and never at the grace.
    static let inlineSettleGrace: TimeInterval = 60

    /// The output of each background run.
    static let runOutput = "the job is done"

    /// The prompt of the caller message that starts the run.
    private static let jobPrompt = "run the job"

    /// The prompts that reach the backend when one run starts in the caller
    /// answer and its mail starts one more answer.
    private static let promptsWithAMailAnswer = 2

    // MARK: - Helpers

    /// Makes a session with `tools` over the backend that `container` vends.
    ///
    /// - Parameters:
    ///   - tools: The tools of the session.
    ///   - container: The container that vends the backend.
    ///   - mailOnlyAnswerLimit: The ``SessionConfiguration/mailOnlyAnswerLimit``
    ///     of the session.
    /// - Returns: The fixture.
    /// - Throws: What the resolve of the profile throws.
    private static func makeFixture(
        tools: [any Tool],
        container: BackgroundingLLMContainer = BackgroundingLLMContainer(),
        mailOnlyAnswerLimit: Int = SessionConfiguration.defaultMailOnlyAnswerLimit
    ) async throws -> Fixture {
        let directory = RouterTestFixtures.makeTempDir(prefix: "SessionIdleWaitTests")
        let (router, profile) = try await RouterTestFixtures.resolveStandardProfile(
            over: container, cacheDir: directory)
        let session = profile.standard.makeSession(
            configuration: SessionConfiguration(tools: tools, mailOnlyAnswerLimit: mailOnlyAnswerLimit))
        let backend = try #require(container.lastBackend)
        return Fixture(session: session, backend: backend, router: router, directory: directory)
    }

    /// Starts one ``RoutedSession/awaitIdle()`` call in a task of its own,
    /// and returns when the call waits for the next change of the session,
    /// or when it returned first.
    ///
    /// - Parameters:
    ///   - session: The session to wait on.
    ///   - outcome: Gets the result of the call.
    /// - Returns: The task of the call, which a test can cancel. A test reads
    ///   the result from `outcome`, not from the task.
    /// - Throws: ``ConditionNeverHeld`` when the `.timeLimit` of the suite
    ///   ends the wait first.
    @discardableResult
    private static func startIdleWait(
        on session: any RoutedSession, recording outcome: RecordedWaitResult
    ) async throws -> Task<Bool, Never> {
        let waiting = Task {
            let idle = await session.awaitIdle()
            outcome.record(idle)
            return idle
        }
        try await AwaitedCondition.wait(until: { session.idleWaitCount == 1 || outcome.value != nil })
        return waiting
    }

    /// Runs `work` in a task of its own, and records what it gives in the
    /// result that this function returns.
    ///
    /// A test reads the result with ``AwaitedCondition/wait(until:)``, not
    /// with `await task.value`. The `.timeLimit` cancels the test task, not
    /// the task of `work`, so a `work` that never returns then fails the
    /// test, and does not hang the test run.
    ///
    /// - Parameter work: The work to run.
    /// - Returns: The result that gets what `work` gives.
    private static func startRecorded(_ work: @escaping @Sendable () async -> Bool) -> RecordedWaitResult {
        let outcome = RecordedWaitResult()
        Task { outcome.record(await work()) }
        return outcome
    }

    /// Waits until `outcome` has a result, and gives it.
    ///
    /// - Parameter outcome: The result of a wait that runs in a task of its own.
    /// - Returns: The result.
    /// - Throws: ``ConditionNeverHeld`` when the `.timeLimit` of the suite
    ///   ends the wait first.
    private static func result(of outcome: RecordedWaitResult) async throws -> Bool? {
        try await AwaitedCondition.wait(until: { outcome.value != nil })
        return outcome.value
    }

    /// Starts the respond to ``jobPrompt`` in a task of its own.
    ///
    /// - Parameter session: The session to send the prompt to.
    /// - Returns: The result: `true` when the respond returned, `false` when
    ///   it threw.
    private static func startResponding(on session: any RoutedSession) -> RecordedWaitResult {
        startRecorded { (try? await session.respond(to: Self.jobPrompt)) != nil }
    }

    /// Reads `events` until `count` answers ended, and gives how many did.
    ///
    /// - Parameters:
    ///   - count: How many ``SessionEvent/answered(_:)`` events to read.
    ///   - events: The session-wide feed of the session.
    /// - Returns: How many answers ended, which is `count` unless the feed
    ///   finished first.
    private static func answers(_ count: Int, in events: AsyncStream<SessionEvent>) async -> Int {
        var answered = 0
        for await event in events {
            if case .answered = event {
                answered += 1
            }
            if answered == count {
                break
            }
        }
        return answered
    }

    /// Ends the fixture: opens `gates`, so no run body stays held, closes the
    /// session, and removes the directory.
    ///
    /// - Parameters:
    ///   - fixture: The fixture to end.
    ///   - gates: The gates of the runs of the session.
    private static func end(_ fixture: Fixture, opening gates: [RunLatch] = []) async {
        for gate in gates {
            await gate.open()
        }
        await fixture.session.close()
        try? FileManager.default.removeItem(at: fixture.directory)
        withExtendedLifetime(fixture.router) {}
    }

    // MARK: - Tests

    @Test("a session with no work is idle at once")
    func aSessionWithNoWorkIsIdleAtOnce() async throws {
        let fixture = try await Self.makeFixture(tools: [])

        #expect(await fixture.session.awaitIdle())

        await Self.end(fixture)
    }

    @Test("a pending run keeps the session busy until the answer of its mail ends")
    func aPendingRunKeepsTheSessionBusyUntilTheAnswerOfItsMail() async throws {
        let gate = RunLatch()
        let holdMailAnswer = RunLatch()
        let fixture = try await Self.makeFixture(
            tools: [LatchedBackgroundToolRunner(name: "pending_job", gate: gate, output: Self.runOutput)],
            container: BackgroundingLLMContainer(holdLaterAnswers: holdMailAnswer))
        let events = await fixture.session.streamSessionEvents()
        _ = try await fixture.session.respond(to: Self.jobPrompt)
        let outcome = RecordedWaitResult()
        try await Self.startIdleWait(on: fixture.session, recording: outcome)
        #expect(outcome.value == nil)

        // The run settles, and its mail starts an answer, which the backend
        // holds open: the session is busy.
        await gate.open()
        try await AwaitedCondition.wait(until: {
            fixture.backend.receivedPrompts.count == Self.promptsWithAMailAnswer
        })
        #expect(outcome.value == nil)

        await holdMailAnswer.open()

        #expect(try await Self.result(of: outcome) == true)
        #expect(await !fixture.session.isPumpRunning)
        #expect(fixture.backend.receivedPrompts.last?.hasSuffix(RoutedSessionActor.settledRunDeliveryPrompt) == true)
        #expect(await Self.answers(Self.promptsWithAMailAnswer, in: events) == Self.promptsWithAMailAnswer)
        await Self.end(fixture)
    }

    @Test("a run that settles inside the running answer starts no mail answer, and the session is idle after that answer")
    func aRunThatSettlesInsideTheAnswerStartsNoMailAnswer() async throws {
        let gate = RunLatch()
        await gate.open()
        let holdFirstAnswer = RunLatch()
        let fixture = try await Self.makeFixture(
            tools: [InlineSettlingTool(gate: gate)],
            container: BackgroundingLLMContainer(holdFirstAnswer: holdFirstAnswer))
        let responded = Self.startResponding(on: fixture.session)

        // The run settled inside its own tool call, and the answer is held.
        try await AwaitedCondition.wait(until: { fixture.backend.toolOutputs.count == 1 })
        #expect(await fixture.session.mailbox.backgroundRuns().isEmpty)
        let outcome = RecordedWaitResult()
        try await Self.startIdleWait(on: fixture.session, recording: outcome)
        #expect(outcome.value == nil)

        await holdFirstAnswer.open()
        #expect(try await Self.result(of: responded) == true)

        #expect(try await Self.result(of: outcome) == true)
        #expect(fixture.backend.receivedPrompts == [Self.jobPrompt])
        #expect(fixture.backend.toolOutputs.first?.contains(Self.runOutput) == true)
        await Self.end(fixture)
    }

    @Test("a cancel of the waiting task ends the wait with false, and the run goes on")
    func aCancelOfTheWaitingTaskEndsTheWait() async throws {
        let gate = RunLatch()
        let fixture = try await Self.makeFixture(
            tools: [LatchedBackgroundToolRunner(name: "pending_job", gate: gate, output: Self.runOutput)])
        _ = try await fixture.session.respond(to: Self.jobPrompt)
        let outcome = RecordedWaitResult()
        let waiting = try await Self.startIdleWait(on: fixture.session, recording: outcome)
        #expect(outcome.value == nil)

        waiting.cancel()

        #expect(try await Self.result(of: outcome) == false)
        #expect(await fixture.session.mailbox.backgroundRuns().count == 1)
        await Self.end(fixture, opening: [gate])
    }

    @Test("close() ends a wait with false, before the drain of the close ends")
    func closeEndsAWait() async throws {
        let gate = RunLatch()
        let fixture = try await Self.makeFixture(
            tools: [LatchedBackgroundToolRunner(name: "pending_job", gate: gate, output: Self.runOutput)])
        _ = try await fixture.session.respond(to: Self.jobPrompt)
        let outcome = RecordedWaitResult()
        try await Self.startIdleWait(on: fixture.session, recording: outcome)
        #expect(outcome.value == nil)

        // The body of the run does not see its cancel until the gate opens,
        // so the drain of the close waits for it.
        let closed = Self.startRecorded {
            await fixture.session.close()
            return true
        }

        #expect(try await Self.result(of: outcome) == false)
        #expect(closed.value == nil)
        await gate.open()
        #expect(try await Self.result(of: closed) == true)
        await Self.end(fixture)
    }

    @Test("mail that the mail-only answer limit holds counts as idle")
    func heldMailCountsAsIdle() async throws {
        let gate = RunLatch()
        await gate.open()
        let fixture = try await Self.makeFixture(
            tools: [LatchedBackgroundToolRunner(name: "settling_job", gate: gate, output: Self.runOutput)],
            mailOnlyAnswerLimit: 0)
        _ = try await fixture.session.respond(to: Self.jobPrompt)

        #expect(await fixture.session.awaitIdle())

        let waitingMail = await fixture.session.outbox.pending().events
        #expect(waitingMail.contains { $0.event.kind == .completed })
        #expect(waitingMail.allSatisfy { $0.isHeld })
        #expect(fixture.backend.receivedPrompts == [Self.jobPrompt])
        await Self.end(fixture)
    }

    @Test("a call after close() returned gives false at once")
    func aCallAfterCloseGivesFalse() async throws {
        let fixture = try await Self.makeFixture(tools: [])
        await fixture.session.close()

        #expect(await fixture.session.awaitIdle() == false)

        #expect(fixture.session.idleWaitCount == 0)
        await Self.end(fixture)
    }

    @Test("a call in a task that was cancelled before the call gives false at once while a run is open")
    func aCallInACancelledTaskGivesFalse() async throws {
        let gate = RunLatch()
        let fixture = try await Self.makeFixture(
            tools: [LatchedBackgroundToolRunner(name: "pending_job", gate: gate, output: Self.runOutput)])
        _ = try await fixture.session.respond(to: Self.jobPrompt)
        #expect(await fixture.session.mailbox.backgroundRuns().count == 1)

        let outcome = Self.startRecorded {
            withUnsafeCurrentTask { $0?.cancel() }
            return await fixture.session.awaitIdle()
        }
        try await AwaitedCondition.wait(until: { outcome.value != nil })

        #expect(outcome.value == false)
        #expect(fixture.session.idleWaitCount == 0)
        await Self.end(fixture, opening: [gate])
    }

    // MARK: - The check, with no schedule

    /// The session of `fixture` as its one concrete type, whose idle check
    /// the tests below call.
    ///
    /// - Parameter fixture: The fixture.
    /// - Returns: The session actor.
    /// - Throws: When the session is not a ``RoutedSessionActor``.
    private static func actor(of fixture: Fixture) throws -> RoutedSessionActor {
        try #require(fixture.session as? RoutedSessionActor)
    }

    /// Settles one fake run on the run plane of `session`, and stages its
    /// terminal in the outbox of `session`, not held. The session never
    /// attached its journal and its observers, so no pump starts, and the
    /// settlement reaches no observer.
    ///
    /// - Parameter session: The session.
    /// - Throws: When the run does not settle.
    private static func stageASettledTerminal(on session: any RoutedSession) async throws {
        let gate = RunLatch()
        await gate.open()
        let token = await trackFakeRun(on: session.mailbox, latch: gate)
        let terminal = try await MountFixtures.settledTerminal(of: token, in: session.mailbox)
        await session.outbox.post(event: terminal)
    }

    @Test("with no pump, an unheld terminal of a settled run is work: the check says not idle")
    func anUnheldSettledTerminalIsWork() async throws {
        let fixture = try await Self.makeFixture(tools: [])
        let session = try Self.actor(of: fixture)
        try await Self.stageASettledTerminal(on: fixture.session)

        #expect(await session.isPumpRunning == false)
        #expect(await session.mailbox.backgroundRuns().isEmpty)
        #expect(await session.isIdle() == false)

        await Self.end(fixture)
    }

    @Test("with no pump, a held terminal of a settled run is no work: the check says idle")
    func aHeldSettledTerminalIsNoWork() async throws {
        let fixture = try await Self.makeFixture(tools: [])
        let session = try Self.actor(of: fixture)
        try await Self.stageASettledTerminal(on: fixture.session)
        await fixture.session.outbox.holdPendingMail()

        #expect(await fixture.session.outbox.pending().events.count == 1)
        #expect(await session.isIdle())

        await Self.end(fixture)
    }

    @Test("a new answer between the first and the second read of the session state makes the check say not idle")
    func aNewAnswerBetweenTheReadsIsWork() async throws {
        let fixture = try await Self.makeFixture(tools: [])
        let session = try Self.actor(of: fixture)
        let workId = await session.lastWorkId
        let reads = await session.readRunsAndMail()

        #expect(await session.isIdle(startedAt: workId, reading: reads))
        #expect(await session.isIdle(startedAt: workId &+ 1, reading: reads) == false)

        await Self.end(fixture)
    }

    @Test("a pump that runs at the second read of the session state makes the check say not idle")
    func aPumpAtTheSecondReadIsWork() async throws {
        let holdFirstAnswer = RunLatch()
        let fixture = try await Self.makeFixture(
            tools: [], container: BackgroundingLLMContainer(holdFirstAnswer: holdFirstAnswer))
        let session = try Self.actor(of: fixture)
        let workId = await session.lastWorkId
        let reads = await session.readRunsAndMail()
        let responded = Self.startResponding(on: fixture.session)
        try await AwaitedCondition.wait(until: { fixture.backend.receivedPrompts.count == 1 })

        let workIdOfTheAnswer = await session.lastWorkId
        #expect(workIdOfTheAnswer != workId)
        #expect(await session.isIdle(startedAt: workIdOfTheAnswer, reading: reads) == false)

        await holdFirstAnswer.open()
        #expect(try await Self.result(of: responded) == true)
        await Self.end(fixture)
    }
}
