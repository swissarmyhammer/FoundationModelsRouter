import Foundation
import FoundationModels
import FoundationModelsRouterTestSupport
import Synchronization
import Testing

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
@Suite("respond(to:): the answer of its own submission, and the pump that delivers each settled run as mail")
struct RespondRunPlaneDrainTests {
    // MARK: - Backends

    /// A backend scripted to start background work for a set number of
    /// submissions. Each of its first `backgroundingSubmissions` submissions
    /// tracks one fresh run on the session's own mailbox. Every later
    /// submission tracks none. This is the shape the delivery chain ends on:
    /// a delivery that starts yet more background work, until one delivery
    /// does not.
    ///
    /// It reaches the mailbox through the submission-scope ambient
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
            _ = try await inner.respond(to: prompt, maxTokens: maxTokens)
            if submission <= backgroundingSubmissions, let mailbox = ToolContext.current?.mailbox {
                let token = await releaser.track(on: mailbox)
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
    }

    /// Tracks fake runs on a mailbox and holds each one running until
    /// ``release(token:)`` — the controllable stand-in for background work a
    /// delivery submission starts.
    ///
    /// A released run settles on the mailbox, and its terminal then goes to
    /// the outbox of the session as mail, as the funnel of a background tool
    /// posts it. That mail starts the next delivery submission.
    private actor BackgroundRunReleaser {
        /// One latch per background run, keyed by the run's completion token.
        private var gates: [String: RunLatch] = [:]

        /// The mailbox each run is tracked on, keyed by the run's completion
        /// token.
        private var mailboxes: [String: SessionMailbox] = [:]

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
        /// - Parameter mailbox: The mailbox the run is tracked on.
        /// - Returns: The run's completion token.
        func track(on mailbox: SessionMailbox) async -> String {
            let gate = RunLatch()
            let token = await trackFakeRun(on: mailbox, latch: gate)
            gates[token] = gate
            mailboxes[token] = mailbox
            return token
        }

        /// Lets one background run settle, and posts its terminal as mail.
        /// An unknown token is a no-op.
        ///
        /// - Parameter token: The run's completion token.
        func release(token: String) async {
            guard let gate = gates.removeValue(forKey: token), let mailbox = mailboxes.removeValue(forKey: token)
            else { return }
            await gate.open()
            if case .settled(let terminal) = await mailbox.wait(completionToken: token, seconds: nil) {
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

    /// How long a test waits for a run it has already released to settle —
    /// generous, because the latch is opened first and the wait only has to
    /// observe an already-finishing run.
    private static let mailboxWaitTimeoutSeconds: Double = 30

    /// The no-progress timeout the timed-out run's tool declares: short, so
    /// the run settles as ``OperationOutcome/timedOut`` well inside the
    /// mailbox wait, and its latch never opens before then.
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
    /// - Returns: The resolved profile sessions are vended from.
    private static func makeProfile(
        container: any LoadedLLMContainer, dir: URL
    ) async throws -> LanguageModelProfile {
        let router = RouterTestFixtures.makeRouter(
            cacheDir: dir,
            loader: StubModelLoader(container: container, dimension: RouterTestFixtures.stubDimension)
        )
        return try await router.resolve(
            profile: RouterTestFixtures.profile(), reporting: ResolutionProgress())
    }

    /// Opens `gates` and waits for every run tracked on `session` to settle, so
    /// no background work outlives a test.
    ///
    /// - Parameters:
    ///   - session: The session whose runs settle.
    ///   - gates: The latches the background runs' bodies are waiting on.
    private static func releaseBackgroundRuns(on session: RoutedSession, opening gates: [RunLatch]) async {
        let tokens: [String] = await session.mailbox.backgroundRuns().map(\.completionToken)
        for gate in gates {
            await gate.open()
        }
        for token in tokens {
            _ = await session.mailbox.wait(
                completionToken: token, seconds: mailboxWaitTimeoutSeconds)
        }
    }

    /// Waits, bounded, for `session`'s run plane to report at least `count`
    /// background runs, then reports their tokens.
    ///
    /// - Parameters:
    ///   - count: How many background runs to wait for.
    ///   - session: The session whose mailbox is observed.
    /// - Returns: The background runs' completion tokens, in tracking order.
    private static func backgroundTokens(
        atLeast count: Int, on session: RoutedSession
    ) async -> [String] {
        #expect(
            await BoundedWait.conditionReached("\(count) runs tracked on the session") {
                await session.mailbox.backgroundRuns().count >= count
            })
        return await session.mailbox.backgroundRuns().map(\.completionToken)
    }

    /// Waits, bounded by ``mailboxWaitTimeoutSeconds``, for the run `token`
    /// names to settle, and reports its terminal event.
    ///
    /// - Parameters:
    ///   - token: The run's completion token.
    ///   - session: The session whose mailbox tracks the run.
    /// - Returns: The run's terminal event.
    /// - Throws: ``SignalNeverArrived`` when the run did not settle inside the
    ///   bound.
    private static func settledTerminal(of token: String, on session: RoutedSession) async throws -> OperationEvent {
        let outcome = await session.mailbox.wait(completionToken: token, seconds: mailboxWaitTimeoutSeconds)
        guard case .settled(let terminal) = outcome else {
            Issue.record("expected the run to settle inside the bound, got \(outcome)")
            throw SignalNeverArrived()
        }
        return terminal
    }

    /// Waits, bounded, until `backend` received `count` prompts: the first
    /// submission and each delivery submission after it.
    ///
    /// - Parameters:
    ///   - count: How many prompts to wait for.
    ///   - backend: The backend to watch.
    /// - Returns: The prompts, in call order.
    /// - Throws: ``SignalNeverArrived`` when the prompts did not arrive
    ///   inside the bound.
    private static func prompts(
        atLeast count: Int, reaching backend: BackgroundingBackend
    ) async throws -> [String] {
        guard
            await BoundedWait.conditionReached("\(count) prompts reaching the backend", when: {
                backend.receivedPrompts.count >= count
            })
        else { throw SignalNeverArrived() }
        return backend.receivedPrompts
    }

    /// Drives one `respond(to:)` call over `tool`, lets its run settle, and
    /// reports the prompt of the delivery submission that the pump started
    /// for it, with the run's own terminal event.
    ///
    /// - Parameters:
    ///   - tool: The one tool the session mounts.
    ///   - gate: The tool's latch, opened once the run is tracked when
    ///     `opening` is set, and always opened before returning.
    ///   - opening: Whether the run settles because the latch opens, or on
    ///     its own — by its timeout.
    ///   - dir: The temporary directory the router caches and records under.
    /// - Returns: The prompt of the delivery submission and the run's
    ///   terminal event.
    private static func deliveryPrompt(
        over tool: LatchedBackgroundToolRunner, gate: RunLatch, opening: Bool, dir: URL
    ) async throws -> (prompt: String, terminal: OperationEvent) {
        let container = BackgroundingLLMContainer()
        let profile = try await makeProfile(container: container, dir: dir)
        let session = profile.standard.makeSession(tools: [tool])
        let backend = try #require(container.lastBackend)

        _ = try await session.respond(to: "run the job")
        let token = try #require(await backgroundTokens(atLeast: 1, on: session).first)
        if opening {
            await gate.open()
        }
        let terminal = try await settledTerminal(of: token, on: session)
        let delivery = try #require(try await prompts(atLeast: 2, reaching: backend).last)
        await gate.open()
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
        let backend = try #require(container.lastBackend)

        // The answer is the answer of the first submission: the pending
        // envelope the tools returned. No run holds the caller.
        let answer = try await session.respond(to: "run both jobs")
        #expect(!answer.hasPrefix(BackgroundingBackend.answerPrefix))
        #expect(backend.receivedPrompts.count == 1)

        // Both runs were backgrounded inside the first submission. Releasing
        // them one at a time makes the pump deliver each one on its own.
        let tokens = await Self.backgroundTokens(atLeast: 2, on: session)
        #expect(tokens.count == 2)
        await firstGate.open()
        _ = await session.mailbox.wait(
            completionToken: tokens[0], seconds: Self.mailboxWaitTimeoutSeconds)
        await secondGate.open()
        _ = await session.mailbox.wait(
            completionToken: tokens[1], seconds: Self.mailboxWaitTimeoutSeconds)

        // Each run's own output reached the model, in a delivery submission
        // the pump started with no caller call — never only the pending
        // envelope the tools returned.
        #expect(
            await BoundedWait.conditionReached("both outputs reaching the model") {
                let deliveries = backend.receivedPrompts.dropFirst().joined(separator: "\n")
                return deliveries.contains(Self.firstToolOutput) && deliveries.contains(Self.secondToolOutput)
            })
        #expect(backend.receivedPrompts.dropFirst().allSatisfy { $0.hasSuffix(RoutedSessionActor.settledRunDeliveryPrompt) })

        // Nothing is left tracked, and the model was never asked to poll: two
        // tool calls, all in the first submission.
        #expect(await session.mailbox.backgroundRuns().isEmpty)
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
        let backend = try #require(container.lastBackend)
        await backend.releaser.deliverTerminals(to: session.outbox)

        // The caller gets the answer of its own submission at once.
        let answer = try await session.respond(to: "start")
        #expect(answer == ScriptedBackgroundingBackend.answerText(ofSubmission: 1))

        // Each run settles on its own. Its terminal is mail, and its delivery
        // submission starts the next run, until the seventh submission starts
        // none.
        let submissionCount = Self.backgroundingSubmissionCount + 1
        #expect(
            await BoundedWait.conditionReached("\(submissionCount) submissions reaching the backend") {
                backend.receivedPrompts.count == submissionCount
            })
        #expect(
            await BoundedWait.conditionReached("the pump ending with no run left") {
                let runs = await session.mailbox.backgroundRuns()
                let pumpRunning = await session.isPumpRunning
                return runs.isEmpty && !pumpRunning
            })
        #expect(backend.receivedPrompts.count == submissionCount)
        #expect(backend.receivedPrompts.dropFirst().allSatisfy { $0.hasSuffix(RoutedSessionActor.settledRunDeliveryPrompt) })

        // No background run outlives the test, even when an expectation above
        // failed.
        await backend.releaser.releaseAll()
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
        let backend = try #require(container.lastBackend)

        for try await _ in await session.streamEvents(to: "run both jobs") {}

        // The stream finished while both runs were still in flight — that is
        // the feature on this surface — and no delivery submission ran.
        #expect(await session.mailbox.backgroundRuns().count == 2)
        #expect(backend.receivedPrompts.count == 1)

        // Settle the background runs so no background work outlives the test.
        let tokens: [String] = await session.mailbox.backgroundRuns().map(\.completionToken)
        await firstGate.open()
        await secondGate.open()
        for token in tokens {
            _ = await session.mailbox.wait(
                completionToken: token, seconds: Self.mailboxWaitTimeoutSeconds)
        }
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

        let collecting = Task { () -> [SessionEvent] in
            var events: [SessionEvent] = []
            for try await event in await session.streamEvents(to: "run the job") {
                events.append(event)
            }
            return events
        }

        let token = try #require(await Self.backgroundTokens(atLeast: 1, on: session).first)
        await gate.open()
        let terminal = try await Self.settledTerminal(of: token, on: session)
        await holdFirstSubmission.open()

        let events = try await collecting.value
        #expect(events.contains(.runSettled(terminal)))
    }

    // MARK: - No caller waits on a run

    @Test(
        "a respond whose submission backgrounded work returns at once: the run keeps running, and a cancel then finds no work to stop"
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
        let backend = try #require(container.lastBackend)

        // The run holds nothing: the call returns with its own submission's
        // answer, the pending envelope the backgrounding tool returned.
        let answer = try await session.respond(to: "run the job")
        #expect(!answer.hasPrefix(BackgroundingBackend.answerPrefix))
        #expect(backend.receivedPrompts.count == 1)

        // A run is not work of the pump, so a cancel finds nothing to stop,
        // and the run stays running, exactly as it was.
        #expect(
            await BoundedWait.conditionReached("the pump ending") { await !session.isPumpRunning })
        #expect(await session.cancel() == .nothingToCancel)
        #expect(await session.mailbox.backgroundRuns().count == 1)

        await Self.releaseBackgroundRuns(on: session, opening: [gate])
    }

    @Test(
        "cancelling the caller's own task reaches its running submission, and the run that submission already started keeps running"
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
        let backend = try #require(container.lastBackend)

        let responding = Task { try await session.respond(to: "run the job") }
        _ = try #require(await Self.backgroundTokens(atLeast: 1, on: session).first)

        // The caller's own task is cancelled. The model work of this stub
        // ignores the cancel, so the submission still answers when its hold
        // opens, with the pending envelope.
        responding.cancel()
        await holdFirstSubmission.open()
        let answer = try await responding.value
        #expect(!answer.hasPrefix(BackgroundingBackend.answerPrefix))
        #expect(backend.receivedPrompts.count == 1)

        // A cancelled submission stops; it does not sweep. The run it started
        // is still running, exactly as it was.
        #expect(await session.mailbox.backgroundRuns().count == 1)

        await Self.releaseBackgroundRuns(on: session, opening: [gate])
    }
}
