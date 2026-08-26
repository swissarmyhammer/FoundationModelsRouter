import Foundation
import FoundationModels
import Synchronization
import Testing

@testable import FoundationModelsRouter

/// Exercises task ^1zt7vyg: a tool body that generates on the same resident
/// container as the turn that invoked it must finish, not suspend for the life of
/// that turn.
///
/// This mirrors `mlx-swift-lm`'s `ToolBodyContainerReentryTests` at the
/// router's own layer. Everything runs against stubs — a stub loader, a stub
/// container, and a stub backend that calls the session's own composed tool —
/// so the suite needs no network and no GPU.
///
/// Every handle comes from ``Router/resolve(profile:reporting:)``, never from a
/// hand-built ``RoutedLLM``. Only the handles a resolve vends share the pool
/// entry's one ``RoutedModel/generationGate``, and only handles that share a
/// gate can contend for it; a hand-built handle mints a gate of its own and
/// would hide the defect this suite exists to catch.
@Suite("Nested generation from inside a tool body")
struct NestedGenerationReentryTests {
    // MARK: - Test tool

    /// The argument schema the fixture tool takes: one string, the same
    /// smallest surface the other tool-wiring suites use.
    @Generable
    struct ReentryToolArguments {
        let value: String
    }

    /// One value a fixture writes one time and reads from another task.
    ///
    /// The `Mutex` is the synchronization the `Sendable` conformance rests on.
    /// A ``NestedTarget`` holds the session a tool body acts on: a tool is
    /// threaded into `makeSession` before that call returns a session, so the
    /// target cannot be an `init` argument, and the test writes it before any
    /// turn starts. A ``HandedBackRecord`` holds what a backgrounded tool call
    /// handed back to the turn that made it: the backend writes it from inside
    /// its model call, and the test polls it while that turn is still open.
    private final class ThreadSafeBox<Value: Sendable>: Sendable {
        private let storage: Mutex<Value?> = Mutex(nil)

        /// Stores the one value a later reader sees.
        ///
        /// - Parameter value: The value to store.
        func set(_ value: Value) {
            storage.withLock { $0 = value }
        }

        /// The stored value, or `nil` while nothing was stored.
        var value: Value? {
            storage.withLock { $0 }
        }
    }

    /// The session a tool body generates on, forks, or reads, set after the
    /// session exists.
    private typealias NestedTarget = ThreadSafeBox<any RoutedSession>

    /// The text a backgrounded tool call handed back to the turn that made it,
    /// recorded the moment the call returned — while that turn is still open.
    private typealias HandedBackRecord = ThreadSafeBox<String>

    /// A tool whose body drives a whole turn on a routed session — the shape a
    /// host has whenever a tool ranks or summarizes with a model.
    ///
    /// With no ``mount`` it declares nothing, so the session mounts it
    /// run-to-completion: a body that suspends stays running in band instead
    /// of being handed back as a pending envelope. With ``backgroundMount``
    /// it is the agent-tool shape: the call hands back a handle at once and
    /// the body generates behind the turn that started it.
    private struct NestedGeneratingTool: Tool, DetachmentParameterProviding {
        let name = "nested-generation-probe"
        let description = "test-only tool that generates on a routed session"

        /// The session this body generates on.
        let target: NestedTarget

        /// This tool's mark on the answer it hands back, so a chain of nested
        /// generations reads as the order its links actually ran in.
        let label: String

        /// The mount this tool declares for itself, or `nil` to declare none.
        var mount: DetachConfiguration?

        /// The output a call produces when no target session was named, so a
        /// misbuilt fixture reads as a wrong answer rather than as a pass.
        static let noTargetOutput = "no target session"

        var detachmentMount: DetachConfiguration? { mount }

        func call(arguments: ReentryToolArguments) async throws -> String {
            guard let session = target.value else { return Self.noTargetOutput }
            return label + Self.labelSeparator + (try await session.respond(to: arguments.value))
        }

        /// What a tool's ``label`` is joined to the answer it wraps with.
        static let labelSeparator = "->"
    }

    /// A tool whose body forks a routed session — the shape a host has
    /// whenever a tool spawns a sub-agent from the conversation it runs
    /// inside.
    ///
    /// It reports the child's ``RoutedSession/parentId``, so a passing answer
    /// names the session the fork really came off. ``mount`` chooses between
    /// an in-band body and a declared background one, as on
    /// ``NestedGeneratingTool``.
    private struct ForkingTool: Tool, DetachmentParameterProviding {
        let name = "fork-probe"
        let description = "test-only tool that forks a routed session"

        /// The session this body forks.
        let target: NestedTarget

        /// The mount this tool declares for itself, or `nil` to declare none.
        var mount: DetachConfiguration?

        /// The output a call produces when no target session was named, so a
        /// misbuilt fixture reads as a wrong answer rather than as a pass.
        static let noTargetOutput = "no target session"

        /// The output a call produces when the child it made names no parent.
        static let noParentOutput = "no parent"

        var detachmentMount: DetachConfiguration? { mount }

        func call(arguments: ReentryToolArguments) async throws -> String {
            guard let session = target.value else { return Self.noTargetOutput }
            let child = try await session.fork(workingDirectory: nil)
            return child.parentId?.description ?? Self.noParentOutput
        }
    }

    /// A tool whose body reads a routed session's transcript — the shape a
    /// host has whenever a tool asks what has been said so far.
    ///
    /// It reports the entry count, so a passing answer says how much history
    /// the read actually saw. ``mount`` chooses between an in-band body and a
    /// declared background one, as on ``NestedGeneratingTool``.
    private struct TranscriptReadingTool: Tool, DetachmentParameterProviding {
        let name = "transcript-probe"
        let description = "test-only tool that reads a routed session's transcript"

        /// The session this body reads.
        let target: NestedTarget

        /// The mount this tool declares for itself, or `nil` to declare none.
        var mount: DetachConfiguration?

        /// The output a call produces when no target session was named, so a
        /// misbuilt fixture reads as a wrong answer rather than as a pass.
        static let noTargetOutput = "no target session"

        var detachmentMount: DetachConfiguration? { mount }

        func call(arguments: ReentryToolArguments) async throws -> String {
            guard let session = target.value else { return Self.noTargetOutput }
            return String(Array(await session.transcript).count)
        }
    }

    // MARK: - Backend

    /// The backend this suite drives: the first turn of a session that carries
    /// the fixture tool calls that tool and answers with its output; every
    /// other turn — a session with no tool, or a drained continuation turn
    /// after a background run settled — answers from the prompt it was given.
    ///
    /// `@unchecked Sendable` on the same terms as ``StubSessionBackend``: the
    /// owning session drives one backend method at a time (its turn lock
    /// serializes turns), and the test reads the captures only after the
    /// driving call returned. The one thing a test reads mid-turn is the
    /// ``HandedBackRecord``, which carries its own lock.
    private final class ToolCallingBackend: LanguageModelSessionBackend, @unchecked Sendable {
        /// The prefix a plain answer opens with, so a test can tell a nested
        /// session's own answer from the tool output that carries it.
        static let answerPrefix = "answered: "

        private let inner = StubSessionBackend()

        /// The session's own composed tool list.
        private let tools: [any Tool]

        /// A latch every turn waits on before it answers, or `nil` for a
        /// backend that answers at once. It is how a test holds one session's
        /// turn — and with it the container's one generation permit — open
        /// while it looks at another session.
        private let latch: RunLatch?

        /// A latch the tool-calling turn waits on after its tool call
        /// returned and before it answers, or `nil` to answer at once. It is
        /// how a test keeps the turn that started a background run open —
        /// still generating, still holding its permit — while the run is
        /// looked at.
        private let turnHold: RunLatch?

        /// Where the tool-calling turn records what its tool call handed back,
        /// or `nil` to record nothing.
        private let handedBack: HandedBackRecord?

        /// Whether this backend has made its one tool call.
        private var hasCalledTool = false

        init(
            tools: [any Tool], latch: RunLatch? = nil, turnHold: RunLatch? = nil,
            handedBack: HandedBackRecord? = nil
        ) {
            self.tools = tools
            self.latch = latch
            self.turnHold = turnHold
            self.handedBack = handedBack
        }

        func respond(to prompt: String, maxTokens: Int?) async throws -> String {
            _ = try await inner.respond(to: prompt, maxTokens: maxTokens)
            await latch?.waitUntilOpen()
            guard !hasCalledTool, let detached = composedFixtureTool else {
                return Self.answerPrefix + prompt
            }
            hasCalledTool = true
            let output = try await detached.call(
                arguments: ReentryToolArguments(value: NestedGenerationReentryTests.nestedPrompt))
            handedBack?.set(output)
            await turnHold?.waitUntilOpen()
            return output
        }

        /// The session's composed fixture tool — a ``BackgroundTool`` when the
        /// fixture declared background, a ``RunToCompletionTool`` otherwise —
        /// or `nil` for a session that carries none.
        private var composedFixtureTool: (any Tool<ReentryToolArguments, String>)? {
            for tool in tools {
                if let background = tool as? BackgroundTool<ReentryToolArguments> { return background }
                if let inBand = tool as? RunToCompletionTool<ReentryToolArguments> { return inBand }
            }
            return nil
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

    /// Vends one ``ToolCallingBackend`` per session, handing it the composed
    /// tool list `makeSession` threaded through — so the tool the backend calls
    /// is the session's own wrapped instance, not a bare fixture tool.
    private struct ToolCallingLLMContainer: LoadedLLMContainer {
        /// The latch every backend this container vends waits on, or `nil` for
        /// backends that answer at once.
        var latch: RunLatch?

        /// The latch every backend this container vends holds its tool-calling
        /// turn open on, or `nil` for backends that answer at once.
        var turnHold: RunLatch?

        /// Where the backends this container vends record what a tool call
        /// handed back, or `nil` to record nothing.
        var handedBack: HandedBackRecord?

        func makeSession(instructions: String?) -> any LanguageModelSessionBackend {
            makeSession(instructions: instructions, tools: [])
        }

        func makeSession(instructions: String?, tools: [any Tool]) -> any LanguageModelSessionBackend {
            ToolCallingBackend(tools: tools, latch: latch, turnHold: turnHold, handedBack: handedBack)
        }

        func makeSession(transcript: Transcript) -> any LanguageModelSessionBackend {
            StubSessionBackend(entries: Array(transcript))
        }
    }

    // MARK: - Constants

    /// The prompt the outer turn is given.
    private static let outerPrompt = "use the probe"

    /// The prompt the tool body submits to the session it generates on.
    private static let nestedPrompt = "rank the candidates"

    /// How many transcript entries one stubbed model call has appended by the
    /// time it invokes the fixture tool: the turn's own `.prompt`, and the
    /// `.response` ``StubSessionBackend`` pairs with it.
    ///
    /// This is what a transcript read from inside that tool call reports, and
    /// it is what says the read saw the turn in progress rather than an empty
    /// or stale history.
    private static let entriesBeforeTheToolCall = 2

    /// The upper bound one stubbed turn is allowed.
    ///
    /// The turn loads no weights, downloads nothing, and answers from a stub,
    /// so it finishes far inside one second on any host. Thirty seconds is well
    /// past any scheduling delay, so only a real suspension reaches it. The bound
    /// exists so this suite FAILS instead of hanging: ``AsyncSemaphore/wait()``
    /// ignores cancellation, so a suspended turn can never be unwound.
    private static let turnTimeout = Duration.seconds(30)

    /// The upper bound one background run is allowed before it settles — the
    /// same bound as ``turnTimeout``, in the unit the mailbox's wait takes.
    private static let runSettlementTimeoutSeconds = TimeInterval(turnTimeout.components.seconds)

    /// The mount a fixture declares to be a background tool: every call hands
    /// back a handle at once, and the body runs behind the turn that made it.
    private static let backgroundMount = DetachConfiguration(mode: .background, timeout: nil)

    // MARK: - Turn outcome

    /// What one turn produced, carried out of the turn's own task.
    ///
    /// A failure is carried as its description, plus the typed refusal when it
    /// is one: `Error` is not `Sendable`, and ``SessionReentryError`` is.
    private enum TurnOutcome: Sendable {
        case finished(String)
        case failed(reentry: SessionReentryError?, description: String)
    }

    // MARK: - Fixtures

    /// Builds a fresh router and resolves the standard test profile over
    /// `container`.
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

    /// Runs `turn` in a task of its own and reports its outcome, or `nil` when
    /// `timeout` wins.
    ///
    /// The turn runs unstructured and reports through a stream rather than
    /// being awaited: a turn suspended on a semaphore cannot be cancelled, and a
    /// task group implicitly awaits every child, so awaiting the turn directly
    /// would hang the whole suite instead of failing this one test.
    ///
    /// - Parameters:
    ///   - turn: The turn to run.
    ///   - timeout: How long the turn is allowed.
    /// - Returns: The turn's outcome, or `nil` when the timeout won.
    private static func outcome(
        of turn: @escaping @Sendable () async throws -> String,
        within timeout: Duration
    ) async -> TurnOutcome? {
        let (outcomes, report) = AsyncStream<TurnOutcome>.makeStream()
        let turnTask = Task {
            do {
                report.yield(.finished(try await turn()))
            } catch {
                report.yield(
                    .failed(
                        reentry: error as? SessionReentryError,
                        description: String(describing: error)))
            }
            report.finish()
        }
        defer { turnTask.cancel() }
        return await withTaskGroup(of: TurnOutcome?.self) { group in
            group.addTask {
                for await outcome in outcomes { return outcome }
                return nil
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    /// The answer a chain of `labels` produces, outermost tool first, ending in
    /// the innermost session's own plain answer to ``nestedPrompt``.
    ///
    /// - Parameter labels: The tool labels the chain passes through, outermost
    ///   first.
    /// - Returns: The expected answer text.
    private static func chainedAnswer(through labels: [String]) -> String {
        // Built from the inside out, so the labels are consumed innermost
        // first and the finished text reads outermost first.
        let innermost = ToolCallingBackend.answerPrefix + nestedPrompt
        return labels.reversed().reduce(innermost) { answer, label in
            label + NestedGeneratingTool.labelSeparator + answer
        }
    }

    /// The answer `outcome` finished with, or `nil` after recording the defect
    /// this suite covers when the turn suspended or failed instead.
    ///
    /// - Parameters:
    ///   - outcome: The turn's outcome, or `nil` when the bound won.
    ///   - turn: What the turn is called in the report.
    /// - Returns: The turn's answer, or `nil` when it produced none.
    private static func finishedAnswer(_ outcome: TurnOutcome?, describing turn: String) -> String? {
        switch outcome {
        case nil:
            Issue.record(
                """
                \(turn) did not finish within \(turnTimeout). Work a tool body asks of a \
                routed session has to settle in band: a turn holds its own session's turn \
                lock and the container's one generation permit for its whole length, tool \
                call included, so a call that waits on either suspends for as long as the turn \
                it is part of.
                """)
            return nil
        case .failed(_, let description):
            Issue.record("\(turn) failed instead of finishing: \(description)")
            return nil
        case .finished(let answer):
            return answer
        }
    }

    /// Asserts that `outcome` finished with `expected`, naming the defect this
    /// suite covers when the turn suspended instead.
    ///
    /// - Parameters:
    ///   - outcome: The turn's outcome, or `nil` when the bound won.
    ///   - expected: The answer the turn has to produce.
    ///   - turn: What the turn is called in the report.
    private static func expectFinished(
        _ outcome: TurnOutcome?, is expected: String, describing turn: String
    ) {
        guard let answer = finishedAnswer(outcome, describing: turn) else { return }
        #expect(answer == expected)
    }

    /// The completion token a backgrounded tool call handed back through
    /// `record`, once the call has returned — or `nil`, with an issue
    /// recorded, when no call returned a pending envelope inside the bound.
    ///
    /// The turn that made the call is still open when this returns: the
    /// backend records the handle before it waits on its turn hold.
    ///
    /// - Parameter record: Where the backend records what the call handed back.
    /// - Returns: The token the pending envelope names, or `nil`.
    private static func handedBackToken(from record: HandedBackRecord) async -> String? {
        let returned = await BoundedWait.conditionReached(
            "the backgrounded call handing back its handle"
        ) {
            record.value != nil
        }
        guard returned, let text = record.value else { return nil }
        guard
            let envelope = try? JSONDecoder().decode(PendingRunEnvelope.self, from: Data(text.utf8))
        else {
            Issue.record("The tool call handed back \"\(text)\" rather than a pending envelope.")
            return nil
        }
        return envelope.completionToken
    }

    /// The terminal event `session`'s run `completionToken` settled with, or
    /// `nil`, with an issue recorded, when it did not settle inside the bound.
    ///
    /// - Parameters:
    ///   - completionToken: The background run's completion token.
    ///   - session: The session whose mailbox tracks the run.
    ///   - run: What the run is called in the report.
    /// - Returns: The run's terminal event, or `nil`.
    private static func settledTerminal(
        of completionToken: String, on session: any RoutedSession, describing run: String
    ) async -> OperationEvent? {
        let outcome = await session.mailbox.wait(
            completionToken: completionToken, seconds: runSettlementTimeoutSeconds)
        switch outcome {
        case .settled(let terminal):
            return terminal
        case .deadlineElapsed, .unknownToken:
            Issue.record(
                """
                \(run) did not settle within \(runSettlementTimeoutSeconds) seconds (\(outcome)). A \
                background body has to make progress while the turn that started it is still open.
                """)
            return nil
        }
    }

    /// Asserts that `outcome` failed with `expected`, naming the defect this
    /// suite covers when the call suspended or was served instead.
    ///
    /// - Parameters:
    ///   - outcome: The turn's outcome, or `nil` when the bound won.
    ///   - expected: The refusal the call has to raise.
    ///   - call: What the refused call is called in the report.
    private static func expectRefused(
        _ outcome: TurnOutcome?, with expected: SessionReentryError, describing call: String
    ) {
        switch outcome {
        case nil:
            Issue.record(
                """
                The turn did not finish within \(turnTimeout). \(call) has to be refused, \
                never suspended on the turn lock its own caller holds.
                """)
        case .finished(let answer):
            Issue.record("The turn answered \"\(answer)\" instead of refusing \(call).")
        case .failed(let reentry, let description):
            #expect(
                reentry == expected, "The refusal did not name this session: \(description)")
        }
    }

    /// Asserts that `gate` is back to the one permit it was minted with, with
    /// nobody queued on it.
    ///
    /// A borrowing turn that signalled a permit it never took would show here
    /// as an inflated count, which is the failure mode `AsyncSemaphore` has no
    /// ceiling to absorb.
    ///
    /// - Parameter gate: The pool entry's generation gate.
    private static func expectUntouched(_ gate: AsyncSemaphore) {
        #expect(gate.availablePermits == 1)
        #expect(gate.waiterCount == 0)
    }

    // MARK: - A different session over the same container

    @Test(
        "a tool body generates on a second session over the same resident container while its own turn is in flight"
    )
    @MainActor
    func aToolBodyGeneratesOnASecondSessionOverTheSameContainer() async throws {
        let dir = RouterTestFixtures.makeTempDir(prefix: "NestedGenerationReentryTests")
        defer { try? FileManager.default.removeItem(at: dir) }

        let target = NestedTarget()
        let profile = try await Self.makeProfile(container: ToolCallingLLMContainer(), dir: dir)
        let gate = profile.standard.generationGate

        let caller = profile.standard.makeSession(
            tools: [NestedGeneratingTool(target: target, label: "caller")])
        let nested = profile.standard.makeSession()
        target.set(nested)

        let outcome = await Self.outcome(
            of: { try await caller.respond(to: Self.outerPrompt) }, within: Self.turnTimeout)

        Self.expectFinished(
            outcome, is: Self.chainedAnswer(through: ["caller"]), describing: "The outer turn")
        Self.expectUntouched(gate)
        withExtendedLifetime(profile) {}
    }

    @Test("a borrowed permit carries a second level of nesting, so a chain of tool bodies all generate")
    @MainActor
    func aBorrowedPermitCarriesASecondLevelOfNesting() async throws {
        let dir = RouterTestFixtures.makeTempDir(prefix: "NestedGenerationReentryTests")
        defer { try? FileManager.default.removeItem(at: dir) }

        let outerTarget = NestedTarget()
        let middleTarget = NestedTarget()
        let profile = try await Self.makeProfile(container: ToolCallingLLMContainer(), dir: dir)
        let gate = profile.standard.generationGate

        let outer = profile.standard.makeSession(
            tools: [NestedGeneratingTool(target: outerTarget, label: "outer")])
        let middle = profile.standard.makeSession(
            tools: [NestedGeneratingTool(target: middleTarget, label: "middle")])
        let innermost = profile.standard.makeSession()
        outerTarget.set(middle)
        middleTarget.set(innermost)

        let outcome = await Self.outcome(
            of: { try await outer.respond(to: Self.outerPrompt) }, within: Self.turnTimeout)

        // Reading the labels outermost-first proves all three turns ran, and that
        // the middle turn — itself running on a borrowed permit — could lend that
        // same permit on again.
        Self.expectFinished(
            outcome, is: Self.chainedAnswer(through: ["outer", "middle"]),
            describing: "The outermost turn")
        Self.expectUntouched(gate)
        withExtendedLifetime(profile) {}
    }

    // MARK: - The same session

    @Test("a tool body that generates on its own session is refused, rather than suspending without a sound")
    @MainActor
    func aToolBodyThatGeneratesOnItsOwnSessionIsRefused() async throws {
        let dir = RouterTestFixtures.makeTempDir(prefix: "NestedGenerationReentryTests")
        defer { try? FileManager.default.removeItem(at: dir) }

        let target = NestedTarget()
        let profile = try await Self.makeProfile(container: ToolCallingLLMContainer(), dir: dir)
        let gate = profile.standard.generationGate

        let caller = profile.standard.makeSession(
            tools: [NestedGeneratingTool(target: target, label: "caller")])
        // The tool generates on the very session whose turn invoked it. The turn
        // lock is the correctness gate and is lent to nobody, so this has to
        // fail — and it has to fail with something a caller can read.
        target.set(caller)

        let outcome = await Self.outcome(
            of: { try await caller.respond(to: Self.outerPrompt) }, within: Self.turnTimeout)

        Self.expectRefused(
            outcome, with: .sameSessionTurnInFlight(sessionID: caller.id),
            describing: "a tool body that generates on its own session")

        Self.expectUntouched(gate)
        withExtendedLifetime(profile) {}
    }

    // MARK: - Forking from inside a tool body

    @Test("a tool body that forks its own session is refused, rather than suspending without a sound")
    func aToolBodyThatForksItsOwnSessionIsRefused() async throws {
        let dir = RouterTestFixtures.makeTempDir(prefix: "NestedGenerationReentryTests")
        defer { try? FileManager.default.removeItem(at: dir) }

        let target = NestedTarget()
        let profile = try await Self.makeProfile(container: ToolCallingLLMContainer(), dir: dir)
        let gate = profile.standard.generationGate

        let caller = profile.standard.makeSession(tools: [ForkingTool(target: target)])
        // The tool forks the very session whose turn invoked it. That turn holds
        // the turn lock a fork reads under, and cannot release it until the tool
        // returns, so this has to fail with something a caller can read.
        target.set(caller)

        let outcome = await Self.outcome(
            of: { try await caller.respond(to: Self.outerPrompt) }, within: Self.turnTimeout)

        Self.expectRefused(
            outcome, with: .forkDuringSameSessionTurn(sessionID: caller.id),
            describing: "a tool body that forks its own session")

        Self.expectUntouched(gate)
        withExtendedLifetime(profile) {}
    }

    @Test("a tool body forks a second session over the same resident container while its own turn is in flight")
    func aToolBodyForksASecondSessionOverTheSameContainer() async throws {
        let dir = RouterTestFixtures.makeTempDir(prefix: "NestedGenerationReentryTests")
        defer { try? FileManager.default.removeItem(at: dir) }

        let target = NestedTarget()
        let profile = try await Self.makeProfile(container: ToolCallingLLMContainer(), dir: dir)
        let gate = profile.standard.generationGate

        let caller = profile.standard.makeSession(tools: [ForkingTool(target: target)])
        let forked = profile.standard.makeSession()
        target.set(forked)

        let outcome = await Self.outcome(
            of: { try await caller.respond(to: Self.outerPrompt) }, within: Self.turnTimeout)

        // The child names the session it came off, so the refusal above reaches
        // the caller's own session and no other.
        Self.expectFinished(
            outcome, is: forked.id.description, describing: "The forking turn")
        Self.expectUntouched(gate)
        withExtendedLifetime(profile) {}
    }

    // MARK: - Reading the transcript from inside a tool body

    @Test("a tool body reads its own session's transcript mid-turn, rather than suspending without a sound")
    func aToolBodyReadsItsOwnSessionsTranscript() async throws {
        let dir = RouterTestFixtures.makeTempDir(prefix: "NestedGenerationReentryTests")
        defer { try? FileManager.default.removeItem(at: dir) }

        let target = NestedTarget()
        let profile = try await Self.makeProfile(container: ToolCallingLLMContainer(), dir: dir)
        let gate = profile.standard.generationGate

        let caller = profile.standard.makeSession(tools: [TranscriptReadingTool(target: target)])
        // The tool reads the very session whose turn invoked it. That turn holds
        // the turn lock, so a read that waited for it would never come back —
        // and it has nothing to wait for, since the only writer is suspended in
        // this tool.
        target.set(caller)

        let outcome = await Self.outcome(
            of: { try await caller.respond(to: Self.outerPrompt) }, within: Self.turnTimeout)

        // The count is the history as it stands mid-turn, which is what says the
        // read saw this session's own backend rather than nothing at all.
        Self.expectFinished(
            outcome, is: String(Self.entriesBeforeTheToolCall),
            describing: "The transcript-reading turn")
        Self.expectUntouched(gate)
        withExtendedLifetime(profile) {}
    }

    // MARK: - A declared background body

    /// The scaffolding one background-body test stands on: a profile whose
    /// tool-calling turn stays open on ``turnHold`` after its tool call
    /// returned, and records what that call handed back in ``handedBack``.
    private struct BackgroundHarness {
        /// The resolved profile sessions are vended from.
        let profile: LanguageModelProfile

        /// The latch the tool-calling turn stays open on after its tool call.
        let turnHold: RunLatch

        /// Where the tool-calling turn records what its tool call handed back.
        let handedBack: HandedBackRecord

        /// The session the fixture tool's body acts on.
        let target: NestedTarget

        /// The pool entry's one generation gate.
        var gate: AsyncSemaphore { profile.standard.generationGate }

        /// Builds the harness over a fresh router that caches under `dir`.
        ///
        /// - Parameter dir: The temporary directory the router caches under.
        /// - Returns: The harness.
        static func make(dir: URL) async throws -> BackgroundHarness {
            let turnHold = RunLatch()
            let handedBack = HandedBackRecord()
            let profile = try await NestedGenerationReentryTests.makeProfile(
                container: ToolCallingLLMContainer(turnHold: turnHold, handedBack: handedBack), dir: dir)
            return BackgroundHarness(
                profile: profile, turnHold: turnHold, handedBack: handedBack, target: NestedTarget())
        }

        /// Starts `session`'s tool-calling turn in a task of its own, bounded
        /// by ``turnTimeout``, so the test can look at the run it starts while
        /// the turn is still open.
        ///
        /// - Parameter session: The session whose turn runs.
        /// - Returns: The task carrying the turn's outcome.
        func startTurn(on session: any RoutedSession) -> Task<TurnOutcome?, Never> {
            Task {
                await NestedGenerationReentryTests.outcome(
                    of: { try await session.respond(to: NestedGenerationReentryTests.outerPrompt) },
                    within: NestedGenerationReentryTests.turnTimeout)
            }
        }

        /// Lets the held turn end, and reports what it produced.
        ///
        /// - Parameter turn: The task ``startTurn(on:)`` returned.
        /// - Returns: The turn's outcome, or `nil` when the bound won.
        func endTurn(_ turn: Task<TurnOutcome?, Never>) async -> TurnOutcome? {
            await turnHold.open()
            return await turn.value
        }
    }

    @Test("a declared background body generates on a second session while the turn that started it is still open")
    @MainActor
    func aBackgroundBodyGeneratesOnASecondSessionWhileItsTurnIsOpen() async throws {
        let dir = RouterTestFixtures.makeTempDir(prefix: "NestedGenerationReentryTests")
        defer { try? FileManager.default.removeItem(at: dir) }

        let harness = try await BackgroundHarness.make(dir: dir)
        let caller = harness.profile.standard.makeSession(
            tools: [NestedGeneratingTool(target: harness.target, label: "caller", mount: Self.backgroundMount)])
        let nested = harness.profile.standard.makeSession()
        harness.target.set(nested)

        let turn = harness.startTurn(on: caller)
        let token = await Self.handedBackToken(from: harness.handedBack)

        // The turn is still generating, on the container's one permit — and the
        // run it started settles all the same, on that same permit: it borrows,
        // it never takes, so the count does not move.
        #expect(harness.gate.availablePermits == 0)
        if let token {
            let terminal = await Self.settledTerminal(of: token, on: caller, describing: "The background run")
            #expect(terminal?.outcome == .succeeded)
            #expect(terminal?.detail == Self.chainedAnswer(through: ["caller"]))
        }
        #expect(harness.gate.availablePermits == 0)

        // The run settled before its turn ended, so the drain found nothing to
        // wait for and the turn answers with the handle it was handed.
        Self.expectFinished(
            await harness.endTurn(turn), is: harness.handedBack.value ?? "", describing: "The outer turn")
        Self.expectUntouched(harness.gate)
        withExtendedLifetime(harness) {}
    }

    @Test("a declared background body that generates on the session that started it is refused, not stalled")
    @MainActor
    func aBackgroundBodyThatGeneratesOnItsOwnSessionIsRefused() async throws {
        let dir = RouterTestFixtures.makeTempDir(prefix: "NestedGenerationReentryTests")
        defer { try? FileManager.default.removeItem(at: dir) }

        let harness = try await BackgroundHarness.make(dir: dir)
        let caller = harness.profile.standard.makeSession(
            tools: [NestedGeneratingTool(target: harness.target, label: "caller", mount: Self.backgroundMount)])
        // The body generates on the very session whose turn started it. That
        // turn holds the turn lock, which is lent to nobody, so the run has to
        // fail with something a reader can name — while the turn is still open.
        harness.target.set(caller)

        let turn = harness.startTurn(on: caller)
        if let token = await Self.handedBackToken(from: harness.handedBack) {
            let terminal = await Self.settledTerminal(of: token, on: caller, describing: "The refused run")
            #expect(terminal?.outcome == .failed)
            #expect(terminal?.detail.contains(caller.id.description) == true)
        }

        Self.expectFinished(
            await harness.endTurn(turn), is: harness.handedBack.value ?? "", describing: "The outer turn")
        Self.expectUntouched(harness.gate)
        withExtendedLifetime(harness) {}
    }

    @Test("a declared background body that forks the session that started it waits for that turn to end, then forks it")
    @MainActor
    func aBackgroundBodyThatForksItsOwnSessionWaitsForTheTurnToEnd() async throws {
        let dir = RouterTestFixtures.makeTempDir(prefix: "NestedGenerationReentryTests")
        defer { try? FileManager.default.removeItem(at: dir) }

        let harness = try await BackgroundHarness.make(dir: dir)
        let caller = harness.profile.standard.makeSession(
            tools: [ForkingTool(target: harness.target, mount: Self.backgroundMount)])
        harness.target.set(caller)

        let turn = harness.startTurn(on: caller)
        let token = await Self.handedBackToken(from: harness.handedBack)
        // A background body is no tool call the model is suspended in: the turn
        // that started it is still writing, so the fork waits for the turn lock
        // like any outside caller rather than being refused or served mid-turn.
        if let token {
            #expect(await caller.mailbox.wait(completionToken: token, seconds: 0) == .deadlineElapsed)
        }

        #expect(Self.finishedAnswer(await harness.endTurn(turn), describing: "The forking turn") != nil)
        // The child came off the finished turn, and names the session it forked.
        if let token {
            let terminal = await Self.settledTerminal(of: token, on: caller, describing: "The forking run")
            #expect(terminal?.outcome == .succeeded)
            #expect(terminal?.detail == caller.id.description)
        }
        Self.expectUntouched(harness.gate)
        withExtendedLifetime(harness) {}
    }

    @Test("a declared background body that reads the transcript of the session that started it waits for that turn to end")
    @MainActor
    func aBackgroundBodyThatReadsItsOwnSessionsTranscriptWaitsForTheTurnToEnd() async throws {
        let dir = RouterTestFixtures.makeTempDir(prefix: "NestedGenerationReentryTests")
        defer { try? FileManager.default.removeItem(at: dir) }

        let harness = try await BackgroundHarness.make(dir: dir)
        let caller = harness.profile.standard.makeSession(
            tools: [TranscriptReadingTool(target: harness.target, mount: Self.backgroundMount)])
        harness.target.set(caller)

        let turn = harness.startTurn(on: caller)
        let token = await Self.handedBackToken(from: harness.handedBack)
        // The only writer is not suspended in this body, so the lock-free read
        // an in-band tool call gets is not on offer: the read waits for the
        // turn lock.
        if let token {
            #expect(await caller.mailbox.wait(completionToken: token, seconds: 0) == .deadlineElapsed)
        }

        #expect(Self.finishedAnswer(await harness.endTurn(turn), describing: "The reading turn") != nil)
        // The read saw the finished turn's own history.
        if let token {
            let terminal = await Self.settledTerminal(of: token, on: caller, describing: "The reading run")
            #expect(terminal?.outcome == .succeeded)
            #expect(terminal?.detail == String(Self.entriesBeforeTheToolCall))
        }
        Self.expectUntouched(harness.gate)
        withExtendedLifetime(harness) {}
    }

    // MARK: - The loan itself

    @Test("a background-run window lends the permit, and says nothing about the model being suspended")
    func aBackgroundRunWindowLendsThePermitWithoutClaimingSuspension() async {
        let gate = AsyncSemaphore(value: 1)
        let sessionID = ULID.generate()
        let loan = GenerationPermitLoan(gate: gate, sessionID: sessionID, holdsPermit: true)
        #expect(!loan.lends(over: gate))

        await GenerationPermitLoan.$current.withValue(loan) {
            await withGenerationLent(across: .backgroundRun) {
                #expect(loan.lends(over: gate))
                #expect(!loan.isSuspendedInToolCall(ofSession: sessionID))
            }
        }
        #expect(!loan.lends(over: gate))
    }

    @Test("a closed loan lends nothing, whatever window is still open on it")
    func aClosedLoanLendsNothing() async {
        let gate = AsyncSemaphore(value: 1)
        let loan = GenerationPermitLoan(gate: gate, sessionID: ULID.generate(), holdsPermit: true)

        // The turn's model call returns — and closes its loan — while the
        // background run it started is still going.
        await GenerationPermitLoan.$current.withValue(loan) {
            await withGenerationLent(across: .backgroundRun) {
                loan.close()
                #expect(!loan.lends(over: gate))
            }
        }
        #expect(!loan.lends(over: gate))
    }

    // MARK: - A turn still waiting for a permit

    @Test("cancelCurrentTurn() on a session still waiting for a generation permit reports that it cannot cancel")
    @MainActor
    func cancelOnASessionWaitingForAPermitReportsItCannot() async throws {
        let dir = RouterTestFixtures.makeTempDir(prefix: "NestedGenerationReentryTests")
        defer { try? FileManager.default.removeItem(at: dir) }

        let latch = RunLatch()
        let profile = try await Self.makeProfile(
            container: ToolCallingLLMContainer(latch: latch), dir: dir)
        let gate = profile.standard.generationGate

        let holder = profile.standard.makeSession()
        let waiter = profile.standard.makeSession()

        // The holder's turn takes the container's one permit and stays inside
        // its own model call until the latch opens.
        let holderTurn = Task { try await holder.respond(to: Self.outerPrompt) }
        #expect(
            await BoundedWait.conditionReached("the holder's turn taking the one permit") {
                gate.availablePermits == 0
            })

        // The waiter's turn now suspends in `beginTurn()`, on the gate.
        let waiterTurn = Task { try await waiter.respond(to: Self.outerPrompt) }
        #expect(
            await BoundedWait.conditionReached("the waiter's turn suspending on the gate") {
                gate.waiterCount == 1
            })

        // Nothing has started on the waiter, so there is nothing to cancel and
        // this says so — rather than reporting a request that would reach no
        // model call at all.
        #expect(await waiter.cancelCurrentTurn() == .noTurnInFlight)

        await latch.open()
        #expect(try await holderTurn.value == ToolCallingBackend.answerPrefix + Self.outerPrompt)
        #expect(try await waiterTurn.value == ToolCallingBackend.answerPrefix + Self.outerPrompt)
        Self.expectUntouched(gate)
        withExtendedLifetime(profile) {}
    }
}
