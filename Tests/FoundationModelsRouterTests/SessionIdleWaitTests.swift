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
/// GPU. The tests read the order of the steps, not a clock.
@Suite("A host waits until a session is idle")
struct SessionIdleWaitTests {
    // MARK: - Fixtures

    /// A background tool whose run settles inside its own tool call. Its gate
    /// is open before the call, and its grace is far longer than the run, so
    /// the call answers with the own output of the run, and the runner takes
    /// back the staged mail of the run.
    struct InlineSettlingTool: Tool, BackgroundTool {
        let name = "inline_settling_job"
        let description = "test-only background tool whose run settles inside its own call"

        /// The latch the body of the run waits on.
        let gate: RunLatch

        var mount: ToolMount? {
            ToolMount(mode: .background, timeout: nil)
        }

        var inlineSettleGrace: TimeInterval {
            SessionIdleWaitTests.inlineSettleGrace
        }

        func call(arguments: BackgroundFixtureArguments) async throws -> String {
            await gate.waitUntilOpen()
            return SessionIdleWaitTests.runOutput
        }
    }

    /// One session over a ``BackgroundingBackend``, with what a test reads.
    typealias Fixture = BackgroundingSessionFixture

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
        try await Fixture.make(
            prefix: "SessionIdleWaitTests", tools: tools, container: container,
            mailOnlyAnswerLimit: mailOnlyAnswerLimit)
    }

    /// One ``RoutedSession/awaitIdle()`` call that runs in a task of its own.
    struct IdleWait {
        /// The task of the call, which a test can cancel.
        let waiting: Task<Bool, Never>

        /// Gets the result of the call. A test reads the result here, not
        /// from the task.
        let outcome: RecordedWaitResult
    }

    /// Starts one ``RoutedSession/awaitIdle()`` call in a task of its own,
    /// and returns when the call waits for the next change of the session,
    /// or when it returned first.
    ///
    /// The result of the call reports to
    /// ``RoutedSession/idleWaiterChanges``, the signal of each change of the
    /// waiters of the session. So one wait on that signal sees the call
    /// start to wait, and also sees the call return first.
    ///
    /// - Parameter session: The session to wait on.
    /// - Returns: The task of the call and its result.
    /// - Throws: ``ConditionNeverHeld`` when the waiting task was cancelled
    ///   before the call waited or returned.
    private static func startIdleWait(on session: any RoutedSession) async throws -> IdleWait {
        let outcome = RecordedWaitResult(reportingTo: session.idleWaiterChanges)
        let waiting = Task {
            let idle = await session.awaitIdle()
            outcome.record(idle)
            return idle
        }
        try await session.idleWaiterChanges.wait(until: { session.idleWaitCount == 1 || outcome.value != nil })
        return IdleWait(waiting: waiting, outcome: outcome)
    }

    /// Runs `work` in a task of its own, and records what it gives in the
    /// result that this function returns.
    ///
    /// A test reads the result with ``result(of:)``, or reads it one time to
    /// see that `work` did not return yet.
    ///
    /// - Parameter work: The work to run.
    /// - Returns: The result that gets what `work` gives.
    private static func startRecorded(_ work: @escaping @Sendable () async -> Bool) -> RecordedWaitResult {
        let outcome = RecordedWaitResult()
        Task { outcome.record(await work()) }
        return outcome
    }

    /// Waits until `outcome` has a result, and gives it. The record of the
    /// result signals the changes of `outcome`.
    ///
    /// - Parameter outcome: The result of a wait that runs in a task of its own.
    /// - Returns: The result.
    /// - Throws: ``ConditionNeverHeld`` when the waiting task was cancelled
    ///   before the result came.
    private static func result(of outcome: RecordedWaitResult) async throws -> Bool? {
        try await outcome.changes.wait(until: { outcome.value != nil })
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

    // MARK: - Tests

    @Test("a session with no work is idle at once")
    func aSessionWithNoWorkIsIdleAtOnce() async throws {
        let fixture = try await Self.makeFixture(tools: [])

        #expect(await fixture.session.awaitIdle())

        await fixture.end()
    }

    @Test("a pending run keeps the session busy until the answer of its mail ends")
    func aPendingRunKeepsTheSessionBusyUntilTheAnswerOfItsMail() async throws {
        let gate = RunLatch()
        let holdMailAnswer = RunLatch()
        let fixture = try await Self.makeFixture(
            tools: [LatchedBackgroundToolRunner(name: "pending_job", gate: gate, output: Self.runOutput)],
            container: BackgroundingLLMContainer(holdLaterAnswers: holdMailAnswer))
        let events = await fixture.session.streamSessionEvents().events
        _ = try await fixture.session.respond(to: Self.jobPrompt)
        let outcome = try await Self.startIdleWait(on: fixture.session).outcome
        #expect(outcome.value == nil)

        // The run settles, and its mail starts an answer, which the backend
        // holds open: the session is busy.
        await gate.open()
        try await fixture.backend.changes.wait(until: {
            fixture.backend.receivedPrompts.count == Self.promptsWithAMailAnswer
        })
        #expect(outcome.value == nil)

        await holdMailAnswer.open()

        #expect(try await Self.result(of: outcome) == true)
        #expect(await !fixture.session.isPumpRunning)
        #expect(fixture.backend.receivedPrompts.last?.hasSuffix(RoutedSessionActor.settledRunDeliveryPrompt) == true)
        #expect(await Self.answers(Self.promptsWithAMailAnswer, in: events) == Self.promptsWithAMailAnswer)
        await fixture.end()
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
        try await fixture.backend.changes.wait(until: { fixture.backend.toolOutputs.count == 1 })
        #expect(await fixture.session.runPlane.backgroundRuns().isEmpty)
        let outcome = try await Self.startIdleWait(on: fixture.session).outcome
        #expect(outcome.value == nil)

        await holdFirstAnswer.open()
        #expect(try await Self.result(of: responded) == true)

        #expect(try await Self.result(of: outcome) == true)
        #expect(fixture.backend.receivedPrompts == [Self.jobPrompt])
        #expect(fixture.backend.toolOutputs.first?.contains(Self.runOutput) == true)
        await fixture.end()
    }

    @Test("a cancel of the waiting task ends the wait with false, and the run goes on")
    func aCancelOfTheWaitingTaskEndsTheWait() async throws {
        let gate = RunLatch()
        let fixture = try await Self.makeFixture(
            tools: [LatchedBackgroundToolRunner(name: "pending_job", gate: gate, output: Self.runOutput)])
        _ = try await fixture.session.respond(to: Self.jobPrompt)
        let idleWait = try await Self.startIdleWait(on: fixture.session)
        #expect(idleWait.outcome.value == nil)

        idleWait.waiting.cancel()

        #expect(try await Self.result(of: idleWait.outcome) == false)
        #expect(await fixture.session.runPlane.backgroundRuns().count == 1)
        await fixture.end(opening: [gate])
    }

    @Test("close() ends a wait with false, before the drain of the close ends")
    func closeEndsAWait() async throws {
        let gate = RunLatch()
        let fixture = try await Self.makeFixture(
            tools: [LatchedBackgroundToolRunner(name: "pending_job", gate: gate, output: Self.runOutput)])
        _ = try await fixture.session.respond(to: Self.jobPrompt)
        let outcome = try await Self.startIdleWait(on: fixture.session).outcome
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
        await fixture.end()
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
        await fixture.end()
    }

    @Test("a call after close() returned gives false at once")
    func aCallAfterCloseGivesFalse() async throws {
        let fixture = try await Self.makeFixture(tools: [])
        await fixture.session.close()

        #expect(await fixture.session.awaitIdle() == false)

        #expect(fixture.session.idleWaitCount == 0)
        await fixture.end()
    }

    @Test("a call in a task that was cancelled before the call gives false at once while a run is open")
    func aCallInACancelledTaskGivesFalse() async throws {
        let gate = RunLatch()
        let fixture = try await Self.makeFixture(
            tools: [LatchedBackgroundToolRunner(name: "pending_job", gate: gate, output: Self.runOutput)])
        _ = try await fixture.session.respond(to: Self.jobPrompt)
        #expect(await fixture.session.runPlane.backgroundRuns().count == 1)

        let outcome = Self.startRecorded {
            withUnsafeCurrentTask { $0?.cancel() }
            return await fixture.session.awaitIdle()
        }
        #expect(try await Self.result(of: outcome) == false)
        #expect(fixture.session.idleWaitCount == 0)
        await fixture.end(opening: [gate])
    }

    // MARK: - The check, with no schedule

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
        let token = await trackFakeRun(on: session.runPlane, latch: gate)
        let terminal = try await MountFixtures.settledTerminal(of: token, in: session.runPlane)
        await session.outbox.post(event: terminal)
    }

    @Test("with no pump, an unheld terminal of a settled run is work: the check says not idle")
    func anUnheldSettledTerminalIsWork() async throws {
        let fixture = try await Self.makeFixture(tools: [])
        let session = try fixture.sessionActor()
        try await Self.stageASettledTerminal(on: fixture.session)

        #expect(await session.isPumpRunning == false)
        #expect(await session.runPlane.backgroundRuns().isEmpty)
        #expect(await session.isIdle() == false)

        await fixture.end()
    }

    @Test("with no pump, a held terminal of a settled run is no work: the check says idle")
    func aHeldSettledTerminalIsNoWork() async throws {
        let fixture = try await Self.makeFixture(tools: [])
        let session = try fixture.sessionActor()
        try await Self.stageASettledTerminal(on: fixture.session)
        // The pump holds run mail that it takes and puts back, for example
        // at the bound on answers that mail alone starts.
        let outbox = fixture.session.outbox
        let taken = outbox.queue.take { candidate, _ in candidate.isRunMail }
        #expect(outbox.putBack(holding: taken).isEmpty)

        #expect(await outbox.pending().events.map(\.isHeld) == [true])
        #expect(await session.isIdle())

        await fixture.end()
    }

    @Test("a new answer between the first and the second read of the session state makes the check say not idle")
    func aNewAnswerBetweenTheReadsIsWork() async throws {
        let fixture = try await Self.makeFixture(tools: [])
        let session = try fixture.sessionActor()
        let workId = await session.lastWorkId
        let reads = await session.readRunsAndMail()

        #expect(await session.isIdle(startedAt: workId, reading: reads))
        #expect(await session.isIdle(startedAt: workId &+ 1, reading: reads) == false)

        await fixture.end()
    }

    @Test("a pump that runs at the second read of the session state makes the check say not idle")
    func aPumpAtTheSecondReadIsWork() async throws {
        let holdFirstAnswer = RunLatch()
        let fixture = try await Self.makeFixture(
            tools: [], container: BackgroundingLLMContainer(holdFirstAnswer: holdFirstAnswer))
        let session = try fixture.sessionActor()
        let workId = await session.lastWorkId
        let reads = await session.readRunsAndMail()
        let responded = Self.startResponding(on: fixture.session)
        try await fixture.backend.changes.wait(until: { fixture.backend.receivedPrompts.count == 1 })

        let workIdOfTheAnswer = await session.lastWorkId
        #expect(workIdOfTheAnswer != workId)
        #expect(await session.isIdle(startedAt: workIdOfTheAnswer, reading: reads) == false)

        await holdFirstAnswer.open()
        #expect(try await Self.result(of: responded) == true)
        await fixture.end()
    }
}
