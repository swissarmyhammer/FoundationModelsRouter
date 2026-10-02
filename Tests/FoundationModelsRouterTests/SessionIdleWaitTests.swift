import Foundation
import FoundationModels
import FoundationModelsRouterTestSupport
import Synchronization
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

    /// What one ``RoutedSession/awaitIdle()`` call gave, or `nil` while the
    /// call waits.
    final class IdleWaitOutcome: Sendable {
        /// The result of the call, or `nil` while it waits.
        private let stored = Mutex<Bool?>(nil)

        /// The result of the call, or `nil` while it waits.
        var value: Bool? { stored.withLock { $0 } }

        /// Records the result of the call.
        ///
        /// - Parameter idle: What the call gave.
        func record(_ idle: Bool) {
            stored.withLock { $0 = idle }
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
    /// - Returns: The task of the call.
    /// - Throws: ``ConditionNeverHeld`` when the `.timeLimit` of the suite
    ///   ends the wait first.
    private static func startIdleWait(
        on session: any RoutedSession, recording outcome: IdleWaitOutcome
    ) async throws -> Task<Bool, Never> {
        let waiting = Task {
            let idle = await session.awaitIdle()
            outcome.record(idle)
            return idle
        }
        try await AwaitedCondition.wait(until: { session.idleWaitCount == 1 || outcome.value != nil })
        return waiting
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
        let outcome = IdleWaitOutcome()
        let waiting = try await Self.startIdleWait(on: fixture.session, recording: outcome)
        #expect(outcome.value == nil)

        // The run settles, and its mail starts an answer, which the backend
        // holds open: the session is busy.
        await gate.open()
        try await AwaitedCondition.wait(until: {
            fixture.backend.receivedPrompts.count == Self.promptsWithAMailAnswer
        })
        #expect(outcome.value == nil)

        await holdMailAnswer.open()

        #expect(await waiting.value)
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
        let responding = Task { try await fixture.session.respond(to: Self.jobPrompt) }

        // The run settled inside its own tool call, and the answer is held.
        try await AwaitedCondition.wait(until: { fixture.backend.toolOutputs.count == 1 })
        #expect(await fixture.session.mailbox.backgroundRuns().isEmpty)
        let outcome = IdleWaitOutcome()
        let waiting = try await Self.startIdleWait(on: fixture.session, recording: outcome)
        #expect(outcome.value == nil)

        await holdFirstAnswer.open()
        _ = try await responding.value

        #expect(await waiting.value)
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
        let outcome = IdleWaitOutcome()
        let waiting = try await Self.startIdleWait(on: fixture.session, recording: outcome)
        #expect(outcome.value == nil)

        waiting.cancel()

        #expect(await waiting.value == false)
        #expect(await fixture.session.mailbox.backgroundRuns().count == 1)
        await Self.end(fixture, opening: [gate])
    }

    @Test("close() ends a wait with false, before the drain of the close ends")
    func closeEndsAWait() async throws {
        let gate = RunLatch()
        let fixture = try await Self.makeFixture(
            tools: [LatchedBackgroundToolRunner(name: "pending_job", gate: gate, output: Self.runOutput)])
        _ = try await fixture.session.respond(to: Self.jobPrompt)
        let outcome = IdleWaitOutcome()
        let waiting = try await Self.startIdleWait(on: fixture.session, recording: outcome)
        #expect(outcome.value == nil)

        // The body of the run does not see its cancel until the gate opens,
        // so the drain of the close waits for it.
        let closing = Task { await fixture.session.close() }

        #expect(await waiting.value == false)
        await gate.open()
        await closing.value
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
}
