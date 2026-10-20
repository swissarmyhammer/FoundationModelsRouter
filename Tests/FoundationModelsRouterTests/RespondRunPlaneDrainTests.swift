import Foundation
import FoundationModels
import FoundationModelsRouterTestSupport
import Synchronization
import Testing

@testable import FoundationModelsExtras
@testable import FoundationModelsRouter

/// Exercises the run plane of a session with no drain (task ^3qx0mpt,
/// restated from task ^nmpejc5): ``RoutedSession/respond(to:maxTokens:)``
/// answers from its own submission, and a background run that the submission
/// started does not hold the caller. The terminal of a settled run is mail:
/// the pump of the session delivers it to the model in a later submission,
/// with no caller call. Task ^ftdmr58 adds the run signals a settled run owes
/// the model: its honest outcome reaches the model, and
/// ``SessionEvent/runSettled(_:)`` reaches the event stream. Task ^chw3rc6
/// removed the round count, and the pump keeps that: a model that starts new
/// background work in each delivery gets one more delivery for each settled
/// run.
///
/// Everything runs against stubs — tools gated on a ``RunLatch``, a backend
/// that calls them, and an ``InMemoryRecorder`` — so the suite needs no
/// network and no GPU.
///
/// Each wait here ends on an event, with no wall clock (task ^v4zh807): a
/// tool output that the backend records after the run is tracked, a
/// settlement of the run plane, a ``SessionEvent/runSettled(_:)`` on the
/// feed of the session, or a change of the work of the session.
@Suite("respond(to:): the answer of its own submission, and the pump that delivers each settled run as mail")
struct RespondRunPlaneDrainTests {
    // MARK: - Backends

    /// A backend scripted to start background work for a set number of
    /// submissions. Each of its first `backgroundingSubmissions` submissions
    /// tracks one fresh run on the session's own run plane. Every later
    /// submission tracks none. This is the shape the delivery chain ends on:
    /// a delivery that starts yet more background work, until one delivery
    /// does not.
    ///
    /// It reaches the run plane through the submission-scope ambient
    /// ``ToolContext`` the session binds around every model call, which is
    /// the same route a tool of that submission would take.
    ///
    /// The prompts are behind a `Mutex`: the pump delivers each settled run in
    /// a submission of its own, so a test reads them while a delivery runs.
    private final class ScriptedBackgroundingBackend: LanguageModelSessionBackend {
        /// The answer one submission produces, so a test can assert which
        /// submission's answer `respond` returned.
        ///
        /// - Parameter submission: The submission's ordinal, counted from 1.
        /// - Returns: That submission's answer text.
        static func answerText(ofSubmission submission: Int) -> String {
            "answer of submission \(submission)"
        }

        /// The stub that records each submission's transcript entries and
        /// answers the surfaces this backend does not script.
        private let inner = StubSessionBackend()

        /// How many submissions, counted from the first, track a background
        /// run.
        private let backgroundingSubmissions: Int

        /// Holds every run this backend tracked, so the test can release them
        /// one at a time.
        let releaser = BackgroundRunReleaser()

        /// The prompt of each submission, behind the lock a test reads it
        /// through.
        private let prompts = Mutex<[String]>([])

        /// Every prompt this backend was asked to respond to, in submission
        /// order.
        var receivedPrompts: [String] { prompts.withLock { $0 } }

        /// Signals after each prompt that this backend records. A test waits
        /// on it for a submission that reaches the backend.
        let changes = ChangeSignal()

        /// Makes a backend that tracks a background run in each of its first
        /// `backgroundingSubmissions` submissions.
        ///
        /// - Parameter backgroundingSubmissions: How many submissions, counted
        ///   from the first, track a background run.
        init(backgroundingSubmissions: Int) {
            self.backgroundingSubmissions = backgroundingSubmissions
        }

        func respond(to prompt: String, maxTokens: Int?) async throws -> String {
            let submission = prompts.withLock { prompts in
                prompts.append(prompt)
                return prompts.count
            }
            changes.signal()
            _ = try await inner.respond(to: prompt, maxTokens: maxTokens)
            if submission <= backgroundingSubmissions, let runPlane = ToolContext.current?.runPlane {
                let token = await releaser.track(on: runPlane)
                // The run settles on its own, beside the submission that
                // started it, as a quick background job does.
                let releaser = releaser
                Task { await releaser.release(token: token) }
            }
            return Self.answerText(ofSubmission: submission)
        }

        func streamResponse(to prompt: String, maxTokens: Int?) -> AsyncThrowingStream<String, Error> {
            inner.streamResponse(to: prompt, maxTokens: maxTokens)
        }

        func respond(to prompt: String, following grammar: Grammar, maxTokens: Int?) async throws -> String {
            try await inner.respond(to: prompt, following: grammar, maxTokens: maxTokens)
        }

        func makeFork() -> any LanguageModelSessionBackend {
            inner.makeFork()
        }

        func transcriptEntries() -> [Transcript.Entry] {
            inner.transcriptEntries()
        }

        func usageTokenCounts() -> (input: Int, output: Int)? {
            inner.usageTokenCounts()
        }

        func cachedInputTokenCount() -> Int? {
            inner.cachedInputTokenCount()
        }
    }

    /// Tracks fake runs on a run plane and holds each one running until
    /// ``release(token:)`` — the controllable stand-in for background work a
    /// delivery submission starts.
    ///
    /// A released run settles on the run plane, and its terminal then goes to
    /// the outbox of the session as mail, as the funnel of a background tool
    /// posts it. That mail starts the next delivery submission.
    private actor BackgroundRunReleaser {
        /// One latch per background run, keyed by the run's completion token.
        private var gates: [String: RunLatch] = [:]

        /// The run plane each run is tracked on, keyed by the run's completion
        /// token.
        private var runPlanes: [String: RunPlane] = [:]

        /// The outbox each settled terminal goes to, or `nil` before
        /// ``deliverTerminals(to:)``.
        private var outbox: SessionOutbox?

        /// Names the outbox each settled terminal goes to.
        ///
        /// - Parameter outbox: The outbox of the session.
        func deliverTerminals(to outbox: SessionOutbox) {
            self.outbox = outbox
        }

        /// Tracks one fresh run whose body waits for ``release(token:)``.
        ///
        /// - Parameter runPlane: The run plane the run is tracked on.
        /// - Returns: The run's completion token.
        func track(on runPlane: RunPlane) async -> String {
            let gate = RunLatch()
            let token = await trackFakeRun(on: runPlane, latch: gate)
            gates[token] = gate
            runPlanes[token] = runPlane
            return token
        }

        /// Lets one background run settle, and posts its terminal as mail.
        /// An unknown token is a no-op.
        ///
        /// - Parameter token: The run's completion token.
        func release(token: String) async {
            guard let gate = gates.removeValue(forKey: token), let runPlane = runPlanes.removeValue(forKey: token)
            else { return }
            await gate.open()
            if case .settled(let terminal) = await runPlane.wait(completionToken: token, seconds: nil) {
                await outbox?.post(event: terminal)
            }
        }

        /// Lets every run tracked so far settle, so no fake run outlives a
        /// test.
        func releaseAll() async {
            for gate in gates.values {
                await gate.open()
            }
        }
    }

    // MARK: - Containers

    /// Vends one retained ``ScriptedBackgroundingBackend`` per session.
    ///
    /// `@unchecked Sendable` invariant, the same one ``BackgroundingLLMContainer``
    /// documents: `lastBackend` is written once, synchronously, inside
    /// `makeSession(instructions:)` — itself called synchronously from
    /// `RoutedModel.makeSession` on the vending thread — and read only by the
    /// `@MainActor` test method after that vend returns.
    // swiftlint:disable:next no_unchecked_sendable  lastBackend is written once, synchronously, inside the vend, and read only by the @MainActor test after the vend returned
    private final class ScriptedBackgroundingLLMContainer: LoadedLLMContainer, @unchecked Sendable {
        /// The scripted counter of this container: one token per `Character`.
        let tokenCounter: any TokenCounter = CharacterTokenCounter()

        /// The backend the newest `makeSession(instructions:)` call vended, or
        /// `nil` before the first call.
        private(set) var lastBackend: ScriptedBackgroundingBackend?

        /// How many submissions of each vended backend track a background run.
        private let backgroundingSubmissions: Int

        /// Makes a container whose every vended backend tracks a background
        /// run in each of its first `backgroundingSubmissions` submissions.
        ///
        /// - Parameter backgroundingSubmissions: How many submissions of each
        ///   vended backend track a background run.
        init(backgroundingSubmissions: Int) {
            self.backgroundingSubmissions = backgroundingSubmissions
        }

        func makeSession(instructions: String?) -> any LanguageModelSessionBackend {
            let backend = ScriptedBackgroundingBackend(backgroundingSubmissions: backgroundingSubmissions)
            lastBackend = backend
            return backend
        }

        func makeSession(transcript: Transcript) -> any LanguageModelSessionBackend {
            StubSessionBackend(entries: Array(transcript))
        }
    }

    // MARK: - Constants

    /// The two background results the pump has to deliver to the model — one
    /// per mounted tool, so a delivery of only the first run is a wrong
    /// answer rather than a lucky one.
    private static let firstToolOutput = "background result: the first job finished"

    /// The second mounted tool's result. See ``firstToolOutput``.
    private static let secondToolOutput = "background result: the second job finished"

    /// The no-progress timeout the timed-out run's tool declares. It is
    /// product input: the run settles as ``OperationOutcome/timedOut`` when
    /// it fires, and its latch never opens before then. The run plane runs on
    /// a `ManualRunClock`, so the timeout fires only when the test advances
    /// that clock by this value. The test does not sleep: it then waits for
    /// the ``SessionEvent/runSettled(_:)`` that the session sends.
    private static let fixtureTimeoutSeconds: TimeInterval = 0.05

    /// How many submissions start a background run in the no-round-count
    /// test. The card ^chw3rc6 sets it: the scripted model starts a run in
    /// each of 6 submissions and then none, so the pump runs one delivery
    /// submission more than this.
    private static let backgroundingSubmissionCount = 6

    // MARK: - Fixtures

    /// Builds a fresh router + resolved profile over `container`.
    ///
    /// - Parameters:
    ///   - container: The stub container every vended session's backend comes
    ///     from.
    ///   - dir: The temporary directory the router caches and records under.
    ///   - runClock: The clock of the run plane of each session, or `nil`
    ///     (the default) for the real time.
    /// - Returns: The resolved profile sessions are vended from.
    private static func makeProfile(
        container: any LoadedLLMContainer, dir: URL, runClock: (any RunClock)? = nil
    ) async throws -> LanguageModelProfile {
        try await RouterTestFixtures.resolveStandardProfile(over: container, cacheDir: dir, runClock: runClock).profile
    }

    /// Opens `gates`, waits for every run tracked on `session` to settle, and
    /// then closes `session`, so no background work and no session outlives
    /// a test (rule T1).
    ///
    /// A test calls it from one `defer` right after it makes the session, so
    /// the session closes also when the test throws.
    ///
    /// - Parameters:
    ///   - session: The session whose runs settle, and that closes.
    ///   - gates: The latches the background runs' bodies are waiting on.
    private static func releaseBackgroundRuns(on session: any RoutedSession, opening gates: [RunLatch]) async {
        let tokens: [String] = await session.runPlane.backgroundRuns().map(\.completionToken)
        for gate in gates {
            await gate.open()
        }
        for token in tokens {
            _ = await session.runPlane.wait(completionToken: token, seconds: nil)
        }
        await session.close()
    }

    /// Thrown by ``settledTerminal(of:on:)`` when the wait of the run plane
    /// ended and the run did not settle.
    private struct RunDidNotSettle: Error {}

    /// Waits until the tools of the first submission handed back `count`
    /// pending envelopes, then reports the tokens of the background runs.
    ///
    /// The run plane tracks a run before its tool hands back the pending
    /// envelope, and `backend` records each envelope and then signals its
    /// changes. So when `backend` has `count` tool outputs, the run plane
    /// tracks the runs. Call it only while no run can settle: each gate of
    /// the runs is still shut.
    ///
    /// The wait also ends when `answer` ended (rule T1). Give the task of the
    /// answer whose first submission calls the tools, while the backend
    /// holds that submission open after its tool calls: in a test that
    /// passes, the answer then does not end before the tool outputs came.
    ///
    /// - Parameters:
    ///   - count: How many background runs to wait for.
    ///   - session: The session whose run plane is observed.
    ///   - backend: The backend that calls the tools of the session.
    ///   - answer: The task of the answer that calls the tools.
    /// - Returns: The background runs' completion tokens, in tracking order.
    /// - Throws: The error of `#require` when `answer` ended first, or
    ///   ``ConditionNeverHeld`` when the waiting task was cancelled first.
    private static func backgroundTokens<Success: Sendable, Failure: Error>(
        atLeast count: Int, on session: any RoutedSession, reportedBy backend: BackgroundingBackend,
        endingOnEndOf answer: Task<Success, Failure>
    ) async throws -> [String] {
        try await backend.changes.wait(until: { backend.toolOutputs.count >= count }, endingOnEndOf: answer)
        return await session.runPlane.backgroundRuns().map(\.completionToken)
    }

    /// Waits for the run `token` names to settle, and reports its terminal
    /// event.
    ///
    /// The wait is ``RunPlane/wait(completionToken:seconds:)`` with no
    /// expiry: the run plane resumes it when the run settles.
    ///
    /// - Parameters:
    ///   - token: The run's completion token.
    ///   - session: The session whose run plane tracks the run.
    /// - Returns: The run's terminal event.
    /// - Throws: ``RunDidNotSettle`` when the wait ended and the run did not
    ///   settle.
    private static func settledTerminal(of token: String, on session: any RoutedSession) async throws -> OperationEvent {
        let outcome = await session.runPlane.wait(completionToken: token, seconds: nil)
        guard case .settled(let terminal) = outcome else {
            Issue.record("expected the run to settle, got \(outcome)")
            throw RunDidNotSettle()
        }
        return terminal
    }

    /// Reads `events` up to the first ``SessionEvent/runSettled(_:)``, and
    /// gives its terminal.
    ///
    /// - Parameter events: The feed of the session.
    /// - Returns: The terminal of the first settled run, or `nil` when the
    ///   feed ended first.
    private static func firstSettledTerminal(in events: AsyncStream<SessionEvent>) async -> OperationEvent? {
        for await event in events {
            if case .runSettled(let terminal) = event {
                return terminal
            }
        }
        return nil
    }

    /// Waits until `backend` received `count` prompts: the first submission
    /// and each delivery submission after it.
    ///
    /// The wait also ends when the work of `session` ended (rule T1,
    /// ``MailQueueFixtures/waitForPrompts(_:on:endingWhenWorkEnds:sourceLocation:)``).
    ///
    /// - Parameters:
    ///   - count: How many prompts to wait for.
    ///   - backend: The backend to watch.
    ///   - session: The session of `backend`.
    /// - Returns: The prompts, in call order.
    /// - Throws: The error of `#require` when the work ended first, or
    ///   ``ConditionNeverHeld`` when the waiting task was cancelled first.
    private static func prompts(
        atLeast count: Int, reaching backend: BackgroundingBackend, of session: any RoutedSession
    ) async throws -> [String] {
        try await MailQueueFixtures.waitForPrompts(count, on: backend, endingWhenWorkEnds: session)
        return backend.receivedPrompts
    }

    /// Drives one `respond(to:)` call over `tool`, lets its run settle, and
    /// reports the prompt of the delivery submission that the pump started
    /// for it, with the run's own terminal event.
    ///
    /// The terminal comes from the ``SessionEvent/runSettled(_:)`` on the
    /// feed of the session. A run that its own timeout ends can settle
    /// before the test reads the run plane, and the feed keeps the event.
    ///
    /// - Parameters:
    ///   - tool: The one tool the session mounts.
    ///   - gate: The tool's latch, opened after the first answer when
    ///     `opening` is set, and always opened before returning. The session
    ///     then closes, also when this helper throws (rule T1).
    ///   - opening: Whether the run settles because the latch opens, or on
    ///     its own — by its timeout, when the test advances the clock of the
    ///     run plane.
    ///   - dir: The temporary directory the router caches and records under.
    /// - Returns: The prompt of the delivery submission and the run's
    ///   terminal event.
    private static func deliveryPrompt(
        over tool: LatchedBackgroundToolRunner, gate: RunLatch, opening: Bool, dir: URL
    ) async throws -> (prompt: String, terminal: OperationEvent) {
        let container = BackgroundingLLMContainer()
        let clock = ManualRunClock()
        let profile = try await makeProfile(container: container, dir: dir, runClock: clock)
        let session = profile.standard.makeSession(tools: [tool])
        defer { await SessionFixtureLifecycle.close(session, opening: [gate]) }
        let backend = try #require(container.lastBackend)
        let events = await session.streamSessionEvents().events
        // The settle of the run, or the end of the feed, is the failure event
        // of the wait for the timeout window: a run that settles puts no
        // window on the clock.
        let settled = Task { await firstSettledTerminal(in: events) }
        defer { settled.cancel() }

        _ = try await session.respond(to: "run the job")
        if opening {
            await gate.open()
        } else {
            // The timeout window of the run waits, and the run posts nothing
            // in it. One full window ends the run.
            try await clock.waitForSleepers(atLeast: 1, endingOnEndOf: settled)
            clock.advance(by: .seconds(fixtureTimeoutSeconds))
        }
        let terminal = try #require(await settled.value)
        let delivery = try #require(try await prompts(atLeast: 2, reaching: backend, of: session).last)
        return (delivery, terminal)
    }

    // MARK: - respond(to:) answers from its own submission

    @Test(
        "respond(to:) answers from its own submission, and the pump delivers the terminal of each run it backgrounded to the model with no caller call"
    )
    @MainActor
    func respondAnswersAndThePumpDeliversEachSettledRun() async throws {
        let dir = RouterTestFixtures.makeTempDir(prefix: "RespondRunPlaneDrainTests")
        defer { try? FileManager.default.removeItem(at: dir) }

        let container = BackgroundingLLMContainer()
        let profile = try await Self.makeProfile(container: container, dir: dir)
        let firstGate = RunLatch()
        let secondGate = RunLatch()
        let session = profile.standard.makeSession(tools: [
            LatchedBackgroundToolRunner(name: "first-job", gate: firstGate, output: Self.firstToolOutput),
            LatchedBackgroundToolRunner(name: "second-job", gate: secondGate, output: Self.secondToolOutput),
        ])
        defer { await Self.releaseBackgroundRuns(on: session, opening: [firstGate, secondGate]) }
        let backend = try #require(container.lastBackend)

        // The answer is the answer of the first submission: the pending
        // envelope the tools returned. No run holds the caller.
        let answer = try await session.respond(to: "run both jobs")
        #expect(!answer.hasPrefix(BackgroundingBackend.answerPrefix))
        #expect(backend.receivedPrompts.count == 1)

        // Both runs were backgrounded inside the first submission. Releasing
        // them one at a time makes the pump deliver each one on its own.
        // The respond returned, so the first submission recorded each tool
        // output that it will record: with fewer outputs the test fails
        // here, and the run plane tracks each run (rule T1).
        try #require(backend.toolOutputs.count >= 2)
        let tokens = await session.runPlane.backgroundRuns().map(\.completionToken)
        #expect(tokens.count == 2)
        let firstToken = try #require(tokens.first)
        let secondToken = try #require(tokens.last)
        await firstGate.open()
        _ = await session.runPlane.wait(completionToken: firstToken, seconds: nil)
        await secondGate.open()
        _ = await session.runPlane.wait(completionToken: secondToken, seconds: nil)

        // Each run's own output reached the model, in a delivery submission
        // the pump started with no caller call — never only the pending
        // envelope the tools returned. The wait also ends when the work of
        // the session ended with fewer deliveries (rule T1): a settled
        // terminal that waits in the outbox is work, so the work ends only
        // after the pump delivered it.
        let workEnds = Task { await session.awaitIdle() }
        defer { workEnds.cancel() }
        try await backend.changes.wait(
            until: {
                let deliveries = backend.receivedPrompts.dropFirst().joined(separator: "\n")
                return deliveries.contains(Self.firstToolOutput) && deliveries.contains(Self.secondToolOutput)
            }, endingOnEndOf: workEnds)
        #expect(backend.receivedPrompts.dropFirst().allSatisfy { $0.hasSuffix(RoutedSessionActor.settledRunDeliveryPrompt) })

        // Nothing is left tracked, and the model was never asked to poll: two
        // tool calls, all in the first submission.
        #expect(await session.runPlane.backgroundRuns().isEmpty)
        #expect(backend.toolCallCount == 2)
    }

    // MARK: - The run signals a settled run owes the model

    @Test("signal 5, I am done: a run that finishes reports succeeded, and its terminal line reaches the model in a delivery submission")
    @MainActor
    func doneSignalReachesTheModelAsASucceededTerminal() async throws {
        let dir = RouterTestFixtures.makeTempDir(prefix: "RespondRunPlaneDrainTests")
        defer { try? FileManager.default.removeItem(at: dir) }

        let gate = RunLatch()
        let tool = LatchedBackgroundToolRunner(name: "finishing-job", gate: gate, output: Self.firstToolOutput)
        let (prompt, terminal) = try await Self.deliveryPrompt(over: tool, gate: gate, opening: true, dir: dir)

        #expect(terminal.outcome == .succeeded)
        #expect(terminal.detail == Self.firstToolOutput)
        #expect(prompt.contains(OperationEventSegment.renderedLine(for: terminal)))
    }

    @Test("signal 4, I have an error: a run whose body throws reports failed, and its terminal line reaches the model in a delivery submission")
    @MainActor
    func errorSignalReachesTheModelAsAFailedTerminal() async throws {
        let dir = RouterTestFixtures.makeTempDir(prefix: "RespondRunPlaneDrainTests")
        defer { try? FileManager.default.removeItem(at: dir) }

        let gate = RunLatch()
        let tool = LatchedBackgroundToolRunner(name: "failing-job", gate: gate, output: Self.firstToolOutput, fails: true)
        let (prompt, terminal) = try await Self.deliveryPrompt(over: tool, gate: gate, opening: true, dir: dir)

        #expect(terminal.outcome == .failed)
        #expect(prompt.contains(OperationEventSegment.renderedLine(for: terminal)))
    }

    @Test("a run its own timeout ends reports timedOut, and its terminal line reaches the model the same way")
    @MainActor
    func timedOutRunReachesTheModelAsATimedOutTerminal() async throws {
        let dir = RouterTestFixtures.makeTempDir(prefix: "RespondRunPlaneDrainTests")
        defer { try? FileManager.default.removeItem(at: dir) }

        let gate = RunLatch()
        let tool = LatchedBackgroundToolRunner(
            name: "hanging-job", gate: gate, output: Self.firstToolOutput, timeout: Self.fixtureTimeoutSeconds)
        let (prompt, terminal) = try await Self.deliveryPrompt(over: tool, gate: gate, opening: false, dir: dir)

        #expect(terminal.outcome == .timedOut)
        #expect(prompt.contains(OperationEventSegment.renderedLine(for: terminal)))
    }

    // MARK: - The deliveries have no round count

    @Test(
        "the pump delivers each settled run with no round count: a model that backgrounds work in each of 6 submissions gets a seventh, and respond answers with the first"
    )
    @MainActor
    func deliveriesRunUntilASubmissionStartsNoBackgroundWork() async throws {
        let dir = RouterTestFixtures.makeTempDir(prefix: "RespondRunPlaneDrainTests")
        defer { try? FileManager.default.removeItem(at: dir) }

        let container = ScriptedBackgroundingLLMContainer(backgroundingSubmissions: Self.backgroundingSubmissionCount)
        let profile = try await Self.makeProfile(container: container, dir: dir)
        let session = profile.standard.makeSession()
        defer { await session.close() }
        let backend = try #require(container.lastBackend)
        // No background run outlives the test, also when the test throws.
        defer { await backend.releaser.releaseAll() }
        await backend.releaser.deliverTerminals(to: session.outbox)

        // The caller gets the answer of its own submission at once.
        let answer = try await session.respond(to: "start")
        #expect(answer == ScriptedBackgroundingBackend.answerText(ofSubmission: 1))

        // Each run settles on its own. Its terminal is mail, and its delivery
        // submission starts the next run, until the seventh submission starts
        // none.
        let submissionCount = Self.backgroundingSubmissionCount + 1
        // No failure event: a fake run posts its terminal after its settle, so an idle wait races here.
        try await backend.changes.wait(untilAtLeast: submissionCount, of: { backend.receivedPrompts.count })
        // The settlement of each run and the end of each pump are changes of
        // the work of the session (`idleChanges`), so the wait reads the runs
        // and the pump again after each one.
        try await session.idleChanges.wait(until: {
            let runs = await session.runPlane.backgroundRuns()
            let pumpRunning = await session.isPumpRunning
            return runs.isEmpty && !pumpRunning
        })
        #expect(backend.receivedPrompts.count == submissionCount)
        #expect(backend.receivedPrompts.dropFirst().allSatisfy { $0.hasSuffix(RoutedSessionActor.settledRunDeliveryPrompt) })
    }

    // MARK: - streamEvents(to:) still backgrounds

    @Test("streamEvents(to:) still backgrounds: it finishes with the answer's runs still running, and runs no delivery while they run")
    @MainActor
    func streamEventsKeepsBackgroundingItsBackgroundRuns() async throws {
        let dir = RouterTestFixtures.makeTempDir(prefix: "RespondRunPlaneDrainTests")
        defer { try? FileManager.default.removeItem(at: dir) }

        let container = BackgroundingLLMContainer()
        let profile = try await Self.makeProfile(container: container, dir: dir)
        let firstGate = RunLatch()
        let secondGate = RunLatch()
        let session = profile.standard.makeSession(tools: [
            LatchedBackgroundToolRunner(name: "first-job", gate: firstGate, output: Self.firstToolOutput),
            LatchedBackgroundToolRunner(name: "second-job", gate: secondGate, output: Self.secondToolOutput),
        ])
        // Settle the background runs so no background work outlives the test,
        // also when the test throws.
        defer { await Self.releaseBackgroundRuns(on: session, opening: [firstGate, secondGate]) }
        let backend = try #require(container.lastBackend)

        for try await _ in await session.streamEvents(to: "run both jobs") {}

        // The stream finished while both runs were still in flight — that is
        // the feature on this surface — and no delivery submission ran.
        #expect(await session.runPlane.backgroundRuns().count == 2)
        #expect(backend.receivedPrompts.count == 1)
    }

    @Test("streamEvents(to:) emits runSettled for a run that settles before the stream ends")
    @MainActor
    func streamEventsEmitsTheTerminalOfARunThatSettlesBeforeTheStreamEnds() async throws {
        let dir = RouterTestFixtures.makeTempDir(prefix: "RespondRunPlaneDrainTests")
        defer { try? FileManager.default.removeItem(at: dir) }

        // The first submission is held open after its tool call, so the run
        // settles while the stream is still running.
        let holdFirstSubmission = RunLatch()
        let container = BackgroundingLLMContainer(holdFirstAnswer: holdFirstSubmission)
        let profile = try await Self.makeProfile(container: container, dir: dir)
        let gate = RunLatch()
        let session = profile.standard.makeSession(tools: [
            LatchedBackgroundToolRunner(name: "first-job", gate: gate, output: Self.firstToolOutput)
        ])
        defer { await Self.releaseBackgroundRuns(on: session, opening: [gate, holdFirstSubmission]) }
        let backend = try #require(container.lastBackend)

        let collecting = Task { () -> [SessionEvent] in
            var events: [SessionEvent] = []
            for try await event in await session.streamEvents(to: "run the job") {
                events.append(event)
            }
            return events
        }

        let tokens = try await Self.backgroundTokens(atLeast: 1, on: session, reportedBy: backend, endingOnEndOf: collecting)
        let token = try #require(tokens.first)
        await gate.open()
        let terminal = try await Self.settledTerminal(of: token, on: session)
        await holdFirstSubmission.open()

        let events = try await collecting.value
        #expect(events.contains(.runSettled(terminal)))
    }

    // MARK: - No caller waits on a run

    @Test(
        "a respond whose submission backgrounded work returns at once: the run keeps running, and a stop then finds no work to stop"
    )
    @MainActor
    func aRespondDoesNotWaitForTheRunItStarted() async throws {
        let dir = RouterTestFixtures.makeTempDir(prefix: "RespondRunPlaneDrainTests")
        defer { try? FileManager.default.removeItem(at: dir) }

        let container = BackgroundingLLMContainer()
        let profile = try await Self.makeProfile(container: container, dir: dir)
        let gate = RunLatch()
        let session = profile.standard.makeSession(tools: [
            LatchedBackgroundToolRunner(name: "first-job", gate: gate, output: Self.firstToolOutput)
        ])
        defer { await Self.releaseBackgroundRuns(on: session, opening: [gate]) }
        let backend = try #require(container.lastBackend)

        // The run holds nothing: the call returns with its own submission's
        // answer, the pending envelope the backgrounding tool returned.
        let answer = try await session.respond(to: "run the job")
        #expect(!answer.hasPrefix(BackgroundingBackend.answerPrefix))
        #expect(backend.receivedPrompts.count == 1)

        // A run is not work of the pump, so a stop of the running work finds
        // nothing to stop, and the run stays running, exactly as it was.
        #expect(await session.pumpEnds())
        #expect(await session.stopRunningWork() == false)
        #expect(await session.runPlane.backgroundRuns().count == 1)
    }

    @Test(
        "cancelling the caller's own task ends its wait, the running submission goes on to its answer, and the run it started keeps running"
    )
    @MainActor
    func cancellingTheCallersTaskLeavesTheStartedRunRunning() async throws {
        let dir = RouterTestFixtures.makeTempDir(prefix: "RespondRunPlaneDrainTests")
        defer { try? FileManager.default.removeItem(at: dir) }

        // The first submission is held open after its tool call, so the
        // cancel lands while it runs.
        let holdFirstSubmission = RunLatch()
        let container = BackgroundingLLMContainer(holdFirstAnswer: holdFirstSubmission)
        let profile = try await Self.makeProfile(container: container, dir: dir)
        let gate = RunLatch()
        let session = profile.standard.makeSession(tools: [
            LatchedBackgroundToolRunner(name: "first-job", gate: gate, output: Self.firstToolOutput)
        ])
        defer { await Self.releaseBackgroundRuns(on: session, opening: [gate, holdFirstSubmission]) }
        let backend = try #require(container.lastBackend)

        let feed = await session.streamSessionEvents()
        let responding = Task { try await session.respond(to: "run the job") }
        let tokens = try await Self.backgroundTokens(atLeast: 1, on: session, reportedBy: backend, endingOnEndOf: responding)
        _ = try #require(tokens.first)

        // The caller's own task is cancelled. Its mail is in the open answer,
        // so the cancel ends only the wait of the caller: the caller gets
        // CancellationError, and the submission still answers when its hold
        // opens, with the pending envelope. The hold opens before the test
        // waits for the caller, so a fault that makes the caller wait for the
        // answer fails the test and does not hang it.
        responding.cancel()
        await holdFirstSubmission.open()
        await #expect(throws: CancellationError.self) {
            try await responding.value
        }
        let events = await feed.eventsToTheFirstAnswerEnd()
        let answer = try #require(events.answers.first)
        #expect(events.answerFailures.isEmpty)
        #expect(!answer.reply.hasPrefix(BackgroundingBackend.answerPrefix))
        #expect(backend.receivedPrompts.count == 1)

        // The cancel of a caller does not stop the answer, and it does not
        // sweep. The run that the submission started is still running,
        // exactly as it was.
        #expect(await session.runPlane.backgroundRuns().count == 1)
    }
}
