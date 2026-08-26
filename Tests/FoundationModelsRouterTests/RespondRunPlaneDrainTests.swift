import Foundation
import FoundationModels
import Testing

@testable import FoundationModelsRouter

/// Exercises task ^nmpejc5: ``RoutedSession/respond(to:maxTokens:)`` drains the
/// run plane before it returns, so a turn that backgrounds its tool work still
/// answers from that work's own results rather than from the completion token
/// the tool handed back — while ``RoutedSession/streamEvents(to:maxTokens:)``
/// keeps backgrounding as its feature. Task ^ftdmr58 adds the run signals a
/// settled run owes the model on each surface: its honest outcome in the
/// drained answer, and ``SessionEvent/runSettled(_:)`` on the event stream.
///
/// Everything runs against stubs — tools gated on a ``RunLatch``, a backend
/// that calls them, and an ``InMemoryRecorder`` — so the suite needs no
/// network and no GPU.
@Suite("respond(to:): the run-plane drain, and the surfaces that keep backgrounding")
struct RespondRunPlaneDrainTests {
    // MARK: - Backends

    /// A backend whose every turn tracks one fresh run on the session's own
    /// mailbox — the shape the termination rule exists for: a drained turn
    /// that starts yet more background work.
    ///
    /// It reaches the mailbox through the turn-scope ambient ``ToolContext``
    /// the session binds around every model call, which is the same route a
    /// tool of that turn would take.
    ///
    /// `@unchecked Sendable` on the same terms as ``BackgroundingBackend``.
    private final class AlwaysSuspendingBackend: LanguageModelSessionBackend, @unchecked Sendable {
        /// The answer every turn produces, so a test can assert respond
        /// returned an answer rather than a pending envelope.
        static let answerText = "started another run"

        private let inner = StubSessionBackend()

        /// Holds every run this backend tracked, so the test can release them
        /// one at a time.
        let releaser = BackgroundRunReleaser()

        /// Every prompt this backend was asked to respond to, in turn order.
        private(set) var receivedPrompts: [String] = []

        func respond(to prompt: String, maxTokens: Int?) async throws -> String {
            receivedPrompts.append(prompt)
            _ = try await inner.respond(to: prompt, maxTokens: maxTokens)
            if let mailbox = ToolContext.current?.mailbox {
                await releaser.track(on: mailbox)
            }
            return Self.answerText
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

    /// Tracks fake runs on a mailbox and holds each one running until the test
    /// releases it — the controllable stand-in for background work a drained
    /// turn starts.
    private actor BackgroundRunReleaser {
        /// One latch per background run, keyed by the run's completion token.
        private var gates: [String: RunLatch] = [:]

        /// Tracks one fresh run whose body waits for ``release(token:)``.
        ///
        /// - Parameter mailbox: The mailbox the run is tracked on.
        func track(on mailbox: SessionMailbox) async {
            let gate = RunLatch()
            let token = await trackFakeRun(on: mailbox, latch: gate)
            gates[token] = gate
        }

        /// Lets one background run settle. An unknown token is a no-op.
        ///
        /// - Parameter token: The run's completion token.
        func release(token: String) async {
            await gates[token]?.open()
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

    /// Vends one retained ``AlwaysSuspendingBackend`` per session, under the same
    /// `@unchecked Sendable` invariant ``BackgroundingLLMContainer`` documents.
    private final class AlwaysSuspendingLLMContainer: LoadedLLMContainer, @unchecked Sendable {
        private(set) var lastBackend: AlwaysSuspendingBackend?

        func makeSession(instructions: String?) -> any LanguageModelSessionBackend {
            let backend = AlwaysSuspendingBackend()
            lastBackend = backend
            return backend
        }

        func makeSession(transcript: Transcript) -> any LanguageModelSessionBackend {
            StubSessionBackend(entries: Array(transcript))
        }
    }

    // MARK: - Constants

    /// The two background results the drain has to fold into the answer — one
    /// per mounted tool, so a drain that settles only the first run is a wrong
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

    /// Waits, bounded, for `session` to hold a ``RoutedSession/respond(to:maxTokens:)``
    /// call suspended on a wait of its own run plane.
    ///
    /// That is the state the two cancellation routes under test have to reach:
    /// the call's own turn is over, so no turn is in flight, and the call is
    /// suspended on a run that will not settle. A cancellation landing a moment
    /// earlier would land on the turn instead and prove nothing about the
    /// drain.
    ///
    /// - Parameter session: The session whose drain is observed.
    /// - Throws: ``SignalNeverArrived`` when no drain suspended on a wait inside
    ///   the bound.
    private static func awaitDrainWait(on session: RoutedSession) async throws {
        guard
            await BoundedWait.conditionReached(
                "a respond call suspending on a wait of the run plane",
                when: { await session.isSuspendedOnRunPlaneDrainWait })
        else {
            throw SignalNeverArrived()
        }
    }

    /// Opens `gates` and waits for every run tracked on `session` to settle, so
    /// no detached work outlives a test.
    ///
    /// - Parameters:
    ///   - session: The session whose mailbox is drained.
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

    /// Drives one `respond(to:)` call over `tool`, lets its run settle, and
    /// reports the drained answer with the run's own terminal event.
    ///
    /// - Parameters:
    ///   - tool: The one tool the session mounts.
    ///   - gate: The tool's latch, opened once the run is tracked when
    ///     `opening` is set, and always opened before returning.
    ///   - opening: Whether the run settles because the latch opens, or on
    ///     its own — by its timeout.
    ///   - dir: The temporary directory the router caches and records under.
    /// - Returns: The answer `respond` returned and the run's terminal event.
    private static func drainedAnswer(
        over tool: LatchedBackgroundTool, gate: RunLatch, opening: Bool, dir: URL
    ) async throws -> (answer: String, terminal: OperationEvent) {
        let container = BackgroundingLLMContainer()
        let profile = try await makeProfile(container: container, dir: dir)
        let session = profile.standard.makeSession(tools: [tool])

        let responding = Task { try await session.respond(to: "run the job") }
        let token = try #require(await backgroundTokens(atLeast: 1, on: session).first)
        if opening {
            await gate.open()
        }
        let terminal = try await settledTerminal(of: token, on: session)
        let answer = try await responding.value
        await gate.open()
        return (answer, terminal)
    }

    // MARK: - respond(to:) drains before it returns

    @Test(
        "respond(to:) waits for every run its turn backgrounded, folds their results into the same call, and returns with nothing left tracked"
    )
    @MainActor
    func respondDrainsEveryBackgroundRunBeforeReturning() async throws {
        let dir = RouterTestFixtures.makeTempDir(prefix: "RespondRunPlaneDrainTests")
        defer { try? FileManager.default.removeItem(at: dir) }

        let container = BackgroundingLLMContainer()
        let profile = try await Self.makeProfile(container: container, dir: dir)
        let firstGate = RunLatch()
        let secondGate = RunLatch()
        let session = profile.standard.makeSession(tools: [
            LatchedBackgroundTool(name: "first-job", gate: firstGate, output: Self.firstToolOutput),
            LatchedBackgroundTool(name: "second-job", gate: secondGate, output: Self.secondToolOutput),
        ])
        let backend = try #require(container.lastBackend)

        let responding = Task { try await session.respond(to: "run both jobs") }

        // Both runs are backgrounded inside the first turn. Releasing them one at a time —
        // and waiting for the first to settle before releasing the second —
        // is what makes a drain that collects only the first run a wrong
        // answer rather than a lucky one.
        let tokens = await Self.backgroundTokens(atLeast: 2, on: session)
        #expect(tokens.count == 2)
        await firstGate.open()
        _ = await session.mailbox.wait(
            completionToken: tokens[0], seconds: Self.mailboxWaitTimeoutSeconds)
        await secondGate.open()

        let answer = try await responding.value

        // The answer is the drained continuation turn's, written from both
        // runs' own output — never from the pending envelope the tools
        // returned.
        #expect(answer.hasPrefix(BackgroundingBackend.answerPrefix))
        #expect(answer.contains(Self.firstToolOutput))
        #expect(answer.contains(Self.secondToolOutput))

        // Nothing is left tracked, and the model was never asked to poll: one
        // turn of its own, one drained continuation turn, two tool calls.
        #expect(await session.mailbox.backgroundRuns().isEmpty)
        #expect(backend.receivedPrompts.count == 2)
        #expect(backend.toolCallCount == 2)
    }

    // MARK: - The run signals a settled run owes the model

    @Test("signal 5, I am done: a run that finishes reports succeeded, and its terminal line reaches the model in the drained answer")
    @MainActor
    func doneSignalReachesTheModelAsASucceededTerminal() async throws {
        let dir = RouterTestFixtures.makeTempDir(prefix: "RespondRunPlaneDrainTests")
        defer { try? FileManager.default.removeItem(at: dir) }

        let gate = RunLatch()
        let tool = LatchedBackgroundTool(name: "finishing-job", gate: gate, output: Self.firstToolOutput)
        let (answer, terminal) = try await Self.drainedAnswer(over: tool, gate: gate, opening: true, dir: dir)

        #expect(terminal.outcome == .succeeded)
        #expect(terminal.detail == Self.firstToolOutput)
        #expect(answer.contains(OperationEventSegment.renderedLine(for: terminal)))
    }

    @Test("signal 4, I have an error: a run whose body throws reports failed, and its terminal line reaches the model in the drained answer")
    @MainActor
    func errorSignalReachesTheModelAsAFailedTerminal() async throws {
        let dir = RouterTestFixtures.makeTempDir(prefix: "RespondRunPlaneDrainTests")
        defer { try? FileManager.default.removeItem(at: dir) }

        let gate = RunLatch()
        let tool = LatchedBackgroundTool(name: "failing-job", gate: gate, output: Self.firstToolOutput, fails: true)
        let (answer, terminal) = try await Self.drainedAnswer(over: tool, gate: gate, opening: true, dir: dir)

        #expect(terminal.outcome == .failed)
        #expect(answer.contains(OperationEventSegment.renderedLine(for: terminal)))
    }

    @Test("a run its own timeout ends reports timedOut, and its terminal line reaches the model the same way")
    @MainActor
    func timedOutRunReachesTheModelAsATimedOutTerminal() async throws {
        let dir = RouterTestFixtures.makeTempDir(prefix: "RespondRunPlaneDrainTests")
        defer { try? FileManager.default.removeItem(at: dir) }

        let gate = RunLatch()
        let tool = LatchedBackgroundTool(
            name: "hanging-job", gate: gate, output: Self.firstToolOutput, timeout: Self.fixtureTimeoutSeconds)
        let (answer, terminal) = try await Self.drainedAnswer(over: tool, gate: gate, opening: false, dir: dir)

        #expect(terminal.outcome == .timedOut)
        #expect(answer.contains(OperationEventSegment.renderedLine(for: terminal)))
    }

    // MARK: - The termination rule

    @Test(
        "a drained turn that backgrounds another run still terminates: respond runs its own turn plus at most the drain-round limit"
    )
    @MainActor
    func drainedTurnThatBackgroundsAnotherRunTerminates() async throws {
        let dir = RouterTestFixtures.makeTempDir(prefix: "RespondRunPlaneDrainTests")
        defer { try? FileManager.default.removeItem(at: dir) }

        let container = AlwaysSuspendingLLMContainer()
        let profile = try await Self.makeProfile(container: container, dir: dir)
        let session = profile.standard.makeSession()
        let backend = try #require(container.lastBackend)

        let responding = Task { try await session.respond(to: "start") }

        // Release each background run only after it has been observed tracked
        // twice, so the drain's own snapshot — taken microseconds after the
        // run is tracked, while this driver sleeps between observations — can never
        // miss it and end the loop early.
        let driver = Task {
            var seen: Set<String> = []
            while !Task.isCancelled {
                for run in await session.mailbox.backgroundRuns() {
                    if seen.insert(run.completionToken).inserted { continue }
                    await backend.releaser.release(token: run.completionToken)
                }
                try? await Task.sleep(nanoseconds: BoundedWait.pollIntervalNanoseconds)
            }
        }

        let answer = try await responding.value
        driver.cancel()

        #expect(answer == AlwaysSuspendingBackend.answerText)
        #expect(backend.receivedPrompts.count == 1 + RoutedSessionActor.backgroundRunDrainRoundLimit)

        // Nothing detached outlives the test.
        await backend.releaser.releaseAll()
    }

    // MARK: - streamEvents(to:) still backgrounds

    @Test("streamEvents(to:) still backgrounds: it finishes with the turn's runs still running, and runs no drained turn")
    @MainActor
    func streamEventsKeepsBackgroundingItsBackgroundRuns() async throws {
        let dir = RouterTestFixtures.makeTempDir(prefix: "RespondRunPlaneDrainTests")
        defer { try? FileManager.default.removeItem(at: dir) }

        let container = BackgroundingLLMContainer()
        let profile = try await Self.makeProfile(container: container, dir: dir)
        let firstGate = RunLatch()
        let secondGate = RunLatch()
        let session = profile.standard.makeSession(tools: [
            LatchedBackgroundTool(name: "first-job", gate: firstGate, output: Self.firstToolOutput),
            LatchedBackgroundTool(name: "second-job", gate: secondGate, output: Self.secondToolOutput),
        ])
        let backend = try #require(container.lastBackend)

        for try await _ in await session.streamEvents(to: "run both jobs") {}

        // The stream finished while both runs were still in flight — that is
        // the feature on this surface — and no continuation turn ran.
        #expect(await session.mailbox.backgroundRuns().count == 2)
        #expect(backend.receivedPrompts.count == 1)

        // Settle the background runs so no detached work outlives the test.
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

        // The first turn is held open after its tool call, so the run settles
        // while the stream is still running.
        let holdTurn = RunLatch()
        let container = BackgroundingLLMContainer(holdFirstTurn: holdTurn)
        let profile = try await Self.makeProfile(container: container, dir: dir)
        let gate = RunLatch()
        let session = profile.standard.makeSession(tools: [
            LatchedBackgroundTool(name: "first-job", gate: gate, output: Self.firstToolOutput)
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
        await holdTurn.open()

        let events = try await collecting.value
        #expect(events.contains(.runSettled(terminal)))
    }

    // MARK: - Cancelling a call suspended in its drain

    @Test(
        "cancelCurrentTurn() reaches a respond suspended in its run-plane drain: it reports requested, and the call ends with its own turn's answer"
    )
    @MainActor
    func cancelCurrentTurnEndsARespondSuspendedInItsDrain() async throws {
        let dir = RouterTestFixtures.makeTempDir(prefix: "RespondRunPlaneDrainTests")
        defer { try? FileManager.default.removeItem(at: dir) }

        let container = BackgroundingLLMContainer()
        let profile = try await Self.makeProfile(container: container, dir: dir)
        let gate = RunLatch()
        let session = profile.standard.makeSession(tools: [
            LatchedBackgroundTool(name: "first-job", gate: gate, output: Self.firstToolOutput)
        ])
        let backend = try #require(container.lastBackend)

        let returned = AsyncSemaphore(value: 0)
        let responding = Task { () -> String in
            defer { returned.signal() }
            return try await session.respond(to: "run the job")
        }
        try await Self.awaitDrainWait(on: session)

        // The call's own turn is over, so nothing holds the turn lock — and the
        // caller is still inside `respond`. This is the call the cancellation
        // has to reach.
        #expect(await session.cancelCurrentTurn() == .requested)

        try await BoundedWait.awaitSignal(returned, named: "the cancelled respond call returning")
        let answer = try await responding.value

        // A cancelled drain answers with the last turn's answer rather than
        // throwing: here that is this call's own turn's answer, the pending
        // envelope the detaching tool returned. No drained continuation turn
        // ran.
        #expect(!answer.hasPrefix(BackgroundingBackend.answerPrefix))
        #expect(backend.receivedPrompts.count == 1)

        // A cancelled drain stops waiting; it does not sweep. The run it was
        // waiting on is still running, exactly as it was.
        #expect(await session.mailbox.backgroundRuns().count == 1)

        await Self.releaseBackgroundRuns(on: session, opening: [gate])
    }

    @Test("cancelling the caller's own task ends a respond suspended in its run-plane drain")
    @MainActor
    func cancellingTheCallersTaskEndsARespondSuspendedInItsDrain() async throws {
        let dir = RouterTestFixtures.makeTempDir(prefix: "RespondRunPlaneDrainTests")
        defer { try? FileManager.default.removeItem(at: dir) }

        let container = BackgroundingLLMContainer()
        let profile = try await Self.makeProfile(container: container, dir: dir)
        let gate = RunLatch()
        let session = profile.standard.makeSession(tools: [
            LatchedBackgroundTool(name: "first-job", gate: gate, output: Self.firstToolOutput)
        ])
        let backend = try #require(container.lastBackend)

        let returned = AsyncSemaphore(value: 0)
        let responding = Task { () -> String in
            defer { returned.signal() }
            return try await session.respond(to: "run the job")
        }
        try await Self.awaitDrainWait(on: session)

        // The other cancellation route: the caller's own task, which the
        // mailbox's wait ignores by design.
        responding.cancel()

        try await BoundedWait.awaitSignal(returned, named: "the cancelled respond call returning")
        let answer = try await responding.value
        #expect(!answer.hasPrefix(BackgroundingBackend.answerPrefix))
        #expect(backend.receivedPrompts.count == 1)
        #expect(await session.mailbox.backgroundRuns().count == 1)

        await Self.releaseBackgroundRuns(on: session, opening: [gate])
    }
}
