import Foundation
import FoundationModels
import Synchronization
import Testing

@testable import FoundationModelsRouter

/// Exercises task ^1zt7vyg: a tool body that generates on the same resident
/// container as the turn that invoked it must finish, not park for the life of
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

    /// The session a tool body generates on, set after the session exists.
    ///
    /// A tool is threaded into `makeSession` before that call returns a
    /// session, so the target cannot be an `init` argument. The `Mutex` is the
    /// synchronization the `Sendable` conformance rests on: the test writes the
    /// target one time, before any turn starts, and the tool body reads it.
    private final class NestedTarget: Sendable {
        private let storage: Mutex<(any RoutedSession)?> = Mutex(nil)

        /// Names the session a later tool body generates on.
        ///
        /// - Parameter session: The session the tool body drives.
        func set(_ session: any RoutedSession) {
            storage.withLock { $0 = session }
        }

        /// The session a tool body generates on, or `nil` when none was named.
        var session: (any RoutedSession)? {
            storage.withLock { $0 }
        }
    }

    /// A tool whose body drives a whole turn on a routed session — the shape a
    /// host has whenever a tool ranks or summarizes with a model.
    ///
    /// It raises its own `waitSeconds` far above the stock five so a body that
    /// parks stays parked instead of detaching into a pending envelope. The
    /// body has to settle in-band, which is exactly what this suite asserts.
    private struct NestedGeneratingTool: Tool, DetachmentParameterProviding {
        let name = "nested-generation-probe"
        let description = "test-only tool that generates on a routed session"

        /// The session this body generates on.
        let target: NestedTarget

        /// This tool's mark on the answer it hands back, so a chain of nested
        /// generations reads as the order its links actually ran in.
        let label: String

        /// The output a call produces when no target session was named, so a
        /// misbuilt fixture reads as a wrong answer rather than as a pass.
        static let noTargetOutput = "no target session"

        /// How long one call may block before the engine detaches it.
        ///
        /// Under the suite's own turn bound, so a park is reported as a
        /// detached run rather than as a hung test, and well above the stock
        /// five seconds, so a body that settles normally never reaches it.
        static let waitSecondsBeforeDetaching: TimeInterval = 20

        func call(arguments: ReentryToolArguments) async throws -> String {
            guard let session = target.session else { return Self.noTargetOutput }
            return label + Self.labelSeparator + (try await session.respond(to: arguments.value))
        }

        /// What a tool's ``label`` is joined to the answer it wraps with.
        static let labelSeparator = "->"

        func detachmentClocks(
            from arguments: GeneratedContent
        ) -> (waitSeconds: TimeInterval?, timeout: TimeInterval?) {
            (Self.waitSecondsBeforeDetaching, nil)
        }
    }

    // MARK: - Backend

    /// The backend this suite drives: a turn whose session carries the fixture
    /// tool calls that tool and answers with its output; every other turn
    /// answers from the prompt it was given.
    ///
    /// `@unchecked Sendable` on the same terms as ``StubSessionBackend``: the
    /// owning session drives one backend method at a time (its turn lock
    /// serializes turns), and the test reads the captures only after the
    /// driving call returned.
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

        init(tools: [any Tool], latch: RunLatch? = nil) {
            self.tools = tools
            self.latch = latch
        }

        func respond(to prompt: String, maxTokens: Int?) async throws -> String {
            _ = try await inner.respond(to: prompt, maxTokens: maxTokens)
            await latch?.waitUntilOpen()
            for tool in tools {
                guard let detached = tool as? DetachingTool<ReentryToolArguments> else { continue }
                return try await detached.call(
                    arguments: ReentryToolArguments(value: NestedGenerationReentryTests.nestedPrompt))
            }
            return Self.answerPrefix + prompt
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

        func makeSession(instructions: String?) -> any LanguageModelSessionBackend {
            makeSession(instructions: instructions, tools: [])
        }

        func makeSession(instructions: String?, tools: [any Tool]) -> any LanguageModelSessionBackend {
            ToolCallingBackend(tools: tools, latch: latch)
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

    /// The upper bound one stubbed turn is allowed.
    ///
    /// The turn loads no weights, downloads nothing, and answers from a stub,
    /// so it finishes far inside one second on any host. Thirty seconds is well
    /// past any scheduling delay, so only a real park reaches it. The bound
    /// exists so this suite FAILS instead of hanging: ``AsyncSemaphore/wait()``
    /// ignores cancellation, so a parked turn can never be unwound.
    private static let turnTimeout = Duration.seconds(30)

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
    /// being awaited: a turn parked on a semaphore cannot be cancelled, and a
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

    /// Asserts that `outcome` finished with `expected`, naming the defect this
    /// suite covers when the turn parked instead.
    ///
    /// - Parameters:
    ///   - outcome: The turn's outcome, or `nil` when the bound won.
    ///   - expected: The answer the turn has to produce.
    ///   - turn: What the turn is called in the report.
    private static func expectFinished(
        _ outcome: TurnOutcome?, is expected: String, describing turn: String
    ) {
        switch outcome {
        case nil:
            Issue.record(
                """
                \(turn) did not finish within \(turnTimeout). A tool body that generates on \
                the same resident container as its own turn parks: the turn holds the \
                container's one generation permit for its whole length, tool call included, \
                and the tool body cannot take one.
                """)
        case .failed(_, let description):
            Issue.record("\(turn) failed instead of finishing: \(description)")
        case .finished(let answer):
            #expect(answer == expected)
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
    private static func expectGateUntouched(_ gate: AsyncSemaphore) {
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
        Self.expectGateUntouched(gate)
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
        Self.expectGateUntouched(gate)
        withExtendedLifetime(profile) {}
    }

    // MARK: - The same session

    @Test("a tool body that generates on its own session is refused, rather than parking without a sound")
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

        switch outcome {
        case nil:
            Issue.record(
                """
                The turn did not finish within \(Self.turnTimeout). A tool body that \
                generates on its own session must be refused, not parked on that \
                session's own turn lock.
                """)
        case .finished(let answer):
            Issue.record("The turn answered \"\(answer)\" instead of being refused.")
        case .failed(let reentry, let description):
            #expect(
                reentry == .sameSessionTurnInFlight(sessionID: caller.id),
                "The refusal did not name this session: \(description)")
        }

        Self.expectGateUntouched(gate)
        withExtendedLifetime(profile) {}
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

        // The waiter's turn now parks in `beginTurn()`, on the gate.
        let waiterTurn = Task { try await waiter.respond(to: Self.outerPrompt) }
        #expect(
            await BoundedWait.conditionReached("the waiter's turn parking on the gate") {
                gate.waiterCount == 1
            })

        // Nothing has started on the waiter, so there is nothing to cancel and
        // this says so — rather than reporting a request that would reach no
        // model call at all.
        #expect(await waiter.cancelCurrentTurn() == .noTurnInFlight)

        await latch.open()
        #expect(try await holderTurn.value == ToolCallingBackend.answerPrefix + Self.outerPrompt)
        #expect(try await waiterTurn.value == ToolCallingBackend.answerPrefix + Self.outerPrompt)
        Self.expectGateUntouched(gate)
        withExtendedLifetime(profile) {}
    }
}
