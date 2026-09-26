import Foundation
import FoundationModels
import FoundationModelsRouterTestSupport
import Synchronization
import Testing

@testable import FoundationModelsRouter

/// Exercises task ^1zt7vyg: a tool body that generates on the same resident
/// container as the submission that invoked it must finish, not suspend for
/// the life of that submission.
///
/// This mirrors `mlx-swift-lm`'s `ToolBodyContainerReentryTests` at the
/// router's own layer. Everything runs against stubs — a stub loader, a stub
/// container, and a stub backend that calls the session's own composed tool —
/// so the suite needs no network and no GPU.
///
/// Every handle comes from ``Router/resolve(profile:reporting:)``, never from a
/// hand-built ``RoutedLLM``, so each session is the shape a consumer holds.
///
/// A session has no lock: one pump for each session submits its messages
/// (task ^3qx0mpt). The stub container of these tests has no
/// ``GenerationQueue``, so a tool body that generates on another session over
/// it runs that model call directly and holds nothing that session needs. An
/// in-band tool body that asks its own session for an answer is refused at
/// once, because that answer could come only after the submission that waits
/// for the tool body. A declared background body asks its own session and
/// gets an answer from a later submission. A fork or a transcript read that a
/// tool body asks of its own session is served at once, from the settled
/// transcript of that session (task ^dpn2ytt). Over a container with a
/// queue, an in-band tool body that waits for a session on the same model is
/// refused at once (task ^1psqdm9, `GenerationQueueSubmissionTests`).
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
    /// answer starts. A ``HandedBackRecord`` holds what a backgrounded tool
    /// call handed back to the submission that made it: the backend writes it
    /// from inside its model call, and the test polls it while that submission
    /// is still open.
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

    /// The text a backgrounded tool call handed back to the submission that
    /// made it, recorded the moment the call returned — while that submission
    /// is still open.
    private typealias HandedBackRecord = ThreadSafeBox<String>

    /// A tool whose body drives a whole answer on a routed session — the shape
    /// a host has whenever a tool ranks or summarizes with a model.
    ///
    /// With no ``mount`` it declares nothing, so the session mounts it
    /// run-to-completion: a body that suspends stays running in band instead
    /// of being handed back as a pending envelope. With ``backgroundMount``
    /// it is the agent-tool shape: the call hands back a handle at once and
    /// the body generates behind the submission that started it.
    private struct NestedGeneratingTool: Tool, BackgroundTool {
        let name = "nested-generation-probe"
        let description = "test-only tool that generates on a routed session"

        /// The session this body generates on.
        let target: NestedTarget

        /// This tool's mark on the answer it hands back, so a chain of nested
        /// generations reads as the order its links actually ran in.
        let label: String

        /// The mount this tool declares for itself, or `nil` to declare none.
        var mount: ToolMount?

        /// The output a call produces when no target session was named, so a
        /// misbuilt fixture reads as a wrong answer rather than as a pass.
        static let noTargetOutput = "no target session"

        func call(arguments: ReentryToolArguments) async throws -> String {
            guard let session = target.value else { return Self.noTargetOutput }
            return label + Self.labelSeparator + (try await session.respond(to: arguments.value))
        }

        /// What a tool's ``label`` is joined to the answer it wraps with.
        static let labelSeparator = "->"
    }

    /// A tool whose body sends a message to a routed session and returns at
    /// once — the shape a host has whenever a tool queues work for the
    /// conversation it runs inside.
    ///
    /// It declares no mount, so the session mounts it run-to-completion: the
    /// body runs in band, inside the submission that called it.
    private struct SendingTool: Tool {
        let name = "send-probe"
        let description = "test-only tool that sends a message to a routed session"

        /// The session this body sends to.
        let target: NestedTarget

        /// The output a call produces when no target session was named, so a
        /// misbuilt fixture reads as a wrong answer rather than as a pass.
        static let noTargetOutput = "no target session"

        func call(arguments: ReentryToolArguments) async throws -> String {
            guard let session = target.value else { return Self.noTargetOutput }
            return await session.send(arguments.value).description
        }
    }

    /// A tool whose body forks a routed session — the shape a host has
    /// whenever a tool spawns a sub-agent from the conversation it runs
    /// inside.
    ///
    /// It reports the child's ``RoutedSession/parentId``, so a passing answer
    /// names the session the fork really came off. ``mount`` chooses between
    /// an in-band body and a declared background one, as on
    /// ``NestedGeneratingTool``.
    private struct ForkingTool: Tool, BackgroundTool {
        let name = "fork-probe"
        let description = "test-only tool that forks a routed session"

        /// The session this body forks.
        let target: NestedTarget

        /// The mount this tool declares for itself, or `nil` to declare none.
        var mount: ToolMount?

        /// The output a call produces when no target session was named, so a
        /// misbuilt fixture reads as a wrong answer rather than as a pass.
        static let noTargetOutput = "no target session"

        /// The output a call produces when the child it made names no parent.
        static let noParentOutput = "no parent"

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
    private struct TranscriptReadingTool: Tool, BackgroundTool {
        let name = "transcript-probe"
        let description = "test-only tool that reads a routed session's transcript"

        /// The session this body reads.
        let target: NestedTarget

        /// The mount this tool declares for itself, or `nil` to declare none.
        var mount: ToolMount?

        /// The output a call produces when no target session was named, so a
        /// misbuilt fixture reads as a wrong answer rather than as a pass.
        static let noTargetOutput = "no target session"

        func call(arguments: ReentryToolArguments) async throws -> String {
            guard let session = target.value else { return Self.noTargetOutput }
            return String(Array(await session.transcript).count)
        }
    }

    // MARK: - Backend

    /// The backend this suite drives: the first submission of a session that
    /// carries the fixture tool calls that tool and answers with its output;
    /// every other submission — a session with no tool, or a submission that
    /// delivers the mail of a settled background run — answers from the prompt
    /// it was given.
    ///
    /// `@unchecked Sendable` on the same terms as ``StubSessionBackend``: the
    /// owning session drives one backend method at a time (its pump submits
    /// one item at a time), and the test reads the captures only after the
    /// driving call returned. The one thing a test reads while a submission
    /// runs is the ``HandedBackRecord``, which carries its own lock.
    private final class ToolCallingBackend: LanguageModelSessionBackend, @unchecked Sendable {
        /// The prefix a plain answer opens with, so a test can tell a nested
        /// session's own answer from the tool output that carries it.
        static let answerPrefix = "answered: "

        private let inner = StubSessionBackend()

        /// The session's own composed tool list.
        private let tools: [any Tool]

        /// A latch the tool-calling submission waits on after its tool call
        /// returned and before it answers, or `nil` to answer at once. It is
        /// how a test keeps the submission that started a background run open
        /// while the run is looked at.
        private let answerHold: RunLatch?

        /// Where the tool-calling submission records what its tool call handed
        /// back, or `nil` to record nothing.
        private let handedBack: HandedBackRecord?

        /// Whether this backend has made its one tool call.
        private var hasCalledTool = false

        init(
            tools: [any Tool], answerHold: RunLatch? = nil, handedBack: HandedBackRecord? = nil
        ) {
            self.tools = tools
            self.answerHold = answerHold
            self.handedBack = handedBack
        }

        func respond(to prompt: String, maxTokens: Int?) async throws -> String {
            _ = try await inner.respond(to: prompt, maxTokens: maxTokens)
            guard !hasCalledTool, let mounted = composedFixtureTool else {
                return Self.answerPrefix + prompt
            }
            hasCalledTool = true
            let output = try await mounted.call(
                arguments: ReentryToolArguments(value: NestedGenerationReentryTests.nestedPrompt))
            handedBack?.set(output)
            await answerHold?.waitUntilOpen()
            return output
        }

        /// The session's composed fixture tool — a ``BackgroundToolRunner`` when the
        /// fixture declared background, a ``RunToCompletionRunner`` otherwise —
        /// or `nil` for a session that carries none.
        private var composedFixtureTool: (any Tool<ReentryToolArguments, String>)? {
            for tool in tools.map(ToolFailureDelivery.throwingTool(of:)) {
                if let background = tool as? BackgroundToolRunner<ReentryToolArguments> { return background }
                if let inBand = tool as? RunToCompletionRunner<ReentryToolArguments> { return inBand }
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
        /// The scripted counter of this container: one token per `Character`.
        let tokenCounter: any TokenCounter = CharacterTokenCounter()

        /// The latch every backend this container vends holds its tool-calling
        /// submission open on, or `nil` for backends that answer at once.
        var answerHold: RunLatch?

        /// Where the backends this container vends record what a tool call
        /// handed back, or `nil` to record nothing.
        var handedBack: HandedBackRecord?

        func makeSession(instructions: String?) -> any LanguageModelSessionBackend {
            makeSession(instructions: instructions, tools: [])
        }

        func makeSession(instructions: String?, tools: [any Tool]) -> any LanguageModelSessionBackend {
            ToolCallingBackend(tools: tools, answerHold: answerHold, handedBack: handedBack)
        }

        func makeSession(transcript: Transcript) -> any LanguageModelSessionBackend {
            StubSessionBackend(entries: Array(transcript))
        }
    }

    // MARK: - Constants

    /// The prompt the outer answer is given.
    private static let outerPrompt = "use the probe"

    /// The prompt the tool body submits to the session it generates on.
    private static let nestedPrompt = "rank the candidates"

    /// How many transcript entries the settled transcript of a fresh session
    /// holds while its first submission runs: none. The stub calls the fixture
    /// tool directly, with no tool-result boundary, so the last settled point
    /// is the start of the session.
    ///
    /// This is what a transcript read of that session reports while the
    /// submission runs. The live backend holds more by then: the `.prompt` of
    /// the submission, and the `.response` ``StubSessionBackend`` pairs with
    /// it. So the count says that the read saw the settled copy, not the live
    /// transcript.
    private static let entriesAtTheLastSettledPoint = 0

    /// The upper bound one stubbed answer is allowed.
    ///
    /// The answer loads no weights, downloads nothing, and comes from a stub,
    /// so it finishes far inside one second on any host. Thirty seconds is well
    /// past any scheduling delay, so only a real suspension reaches it. The bound
    /// exists so this suite FAILS instead of hanging: ``AsyncSemaphore/wait()``
    /// ignores cancellation, so a suspended answer can never be unwound.
    private static let answerTimeout = Duration.seconds(30)

    /// The upper bound one background run is allowed before it settles — the
    /// same bound as ``answerTimeout``, in the unit the mailbox's wait takes.
    private static let runSettlementTimeoutSeconds = TimeInterval(answerTimeout.components.seconds)

    /// The mount a fixture declares to be a background tool: every call hands
    /// back a handle at once, and the body runs behind the submission that
    /// made it.
    private static let backgroundMount = ToolMount(mode: .background, timeout: nil)

    // MARK: - Answer outcome

    /// What one answer produced, carried out of the task that waited for it.
    ///
    /// A failure is carried as its description, plus the typed refusal when it
    /// is one, so a test can compare it.
    private enum AnswerOutcome: Sendable {
        case finished(String)
        case failed(refusal: GenerationQueueError?, description: String)
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
        try await RouterTestFixtures.resolveStandardProfile(over: container, cacheDir: dir).profile
    }

    /// Runs `answer` in a task of its own and reports its outcome, or `nil`
    /// when `timeout` wins.
    ///
    /// The answer runs unstructured and reports through a stream rather than
    /// being awaited: an answer suspended on a semaphore cannot be cancelled,
    /// and a task group implicitly awaits every child, so awaiting the answer
    /// directly would hang the whole suite instead of failing this one test.
    ///
    /// - Parameters:
    ///   - answer: The work that waits for the answer.
    ///   - timeout: How long the answer is allowed.
    /// - Returns: The outcome of the answer, or `nil` when the timeout won.
    private static func outcome(
        of answer: @escaping @Sendable () async throws -> String,
        within timeout: Duration
    ) async -> AnswerOutcome? {
        let (outcomes, report) = AsyncStream<AnswerOutcome>.makeStream()
        let answerTask = Task {
            do {
                report.yield(.finished(try await answer()))
            } catch {
                report.yield(
                    .failed(
                        refusal: error as? GenerationQueueError,
                        description: String(describing: error)))
            }
            report.finish()
        }
        defer { answerTask.cancel() }
        return await withTaskGroup(of: AnswerOutcome?.self) { group in
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
    /// this suite covers when the answer suspended or failed instead.
    ///
    /// - Parameters:
    ///   - outcome: The outcome of the answer, or `nil` when the bound won.
    ///   - name: What the answer is called in the report.
    /// - Returns: The text of the answer, or `nil` when it produced none.
    private static func finishedAnswer(_ outcome: AnswerOutcome?, describing name: String) -> String? {
        switch outcome {
        case nil:
            Issue.record(
                """
                \(name) did not finish within \(answerTimeout). Work a tool body asks of a \
                routed session has to settle or be refused at once: a wait that could \
                never end must not suspend the submission it is part of.
                """)
            return nil
        case .failed(_, let description):
            Issue.record("\(name) failed instead of finishing: \(description)")
            return nil
        case .finished(let answer):
            return answer
        }
    }

    /// Asserts that `outcome` finished with `expected`, naming the defect this
    /// suite covers when the answer suspended instead.
    ///
    /// - Parameters:
    ///   - outcome: The outcome of the answer, or `nil` when the bound won.
    ///   - expected: The text the answer has to produce.
    ///   - name: What the answer is called in the report.
    private static func expectFinished(
        _ outcome: AnswerOutcome?, is expected: String, describing name: String
    ) {
        guard let answer = finishedAnswer(outcome, describing: name) else { return }
        #expect(answer == expected)
    }

    /// The completion token a backgrounded tool call handed back through
    /// `record`, once the call has returned — or `nil`, with an issue
    /// recorded, when no call returned a pending envelope inside the bound.
    ///
    /// The submission that made the call is still open when this returns: the
    /// backend records the handle before it waits on its answer hold.
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
        case .deadlineElapsed, .cancelled, .unknownToken:
            Issue.record(
                """
                \(run) did not settle within \(runSettlementTimeoutSeconds) seconds (\(outcome)). A \
                background body has to make progress while the submission that started it is still open.
                """)
            return nil
        }
    }

    /// Asserts that `outcome` failed with `expected`, naming the defect this
    /// suite covers when the call suspended or was served instead.
    ///
    /// - Parameters:
    ///   - outcome: The outcome of the answer, or `nil` when the bound won.
    ///   - expected: The refusal the call has to raise.
    ///   - call: What the refused call is called in the report.
    private static func expectRefused(
        _ outcome: AnswerOutcome?, with expected: GenerationQueueError, describing call: String
    ) {
        switch outcome {
        case nil:
            Issue.record(
                """
                The answer did not finish within \(answerTimeout). \(call) has to be refused, \
                never suspended behind the submission that waits for it.
                """)
        case .finished(let answer):
            Issue.record("The answer was \"\(answer)\" instead of a refusal of \(call).")
        case .failed(let refusal, let description):
            #expect(
                refusal == expected, "The refusal did not name the model of this session: \(description)")
        }
    }

    // MARK: - A different session over the same container

    @Test(
        "a tool body generates on a second session over the same resident container while its own submission runs"
    )
    @MainActor
    func aToolBodyGeneratesOnASecondSessionOverTheSameContainer() async throws {
        let dir = RouterTestFixtures.makeTempDir(prefix: "NestedGenerationReentryTests")
        defer { try? FileManager.default.removeItem(at: dir) }

        let target = NestedTarget()
        let profile = try await Self.makeProfile(container: ToolCallingLLMContainer(), dir: dir)

        let caller = profile.standard.makeSession(
            tools: [NestedGeneratingTool(target: target, label: "caller")])
        let nested = profile.standard.makeSession()
        target.set(nested)

        let outcome = await Self.outcome(
            of: { try await caller.respond(to: Self.outerPrompt) }, within: Self.answerTimeout)

        Self.expectFinished(
            outcome, is: Self.chainedAnswer(through: ["caller"]), describing: "The outer answer")
        withExtendedLifetime(profile) {}
    }

    @Test("a second level of nesting holds nothing the next level needs, so a chain of tool bodies all generate")
    @MainActor
    func aChainOfNestedGenerationsAllFinish() async throws {
        let dir = RouterTestFixtures.makeTempDir(prefix: "NestedGenerationReentryTests")
        defer { try? FileManager.default.removeItem(at: dir) }

        let outerTarget = NestedTarget()
        let middleTarget = NestedTarget()
        let profile = try await Self.makeProfile(container: ToolCallingLLMContainer(), dir: dir)

        let outer = profile.standard.makeSession(
            tools: [NestedGeneratingTool(target: outerTarget, label: "outer")])
        let middle = profile.standard.makeSession(
            tools: [NestedGeneratingTool(target: middleTarget, label: "middle")])
        let innermost = profile.standard.makeSession()
        outerTarget.set(middle)
        middleTarget.set(innermost)

        let outcome = await Self.outcome(
            of: { try await outer.respond(to: Self.outerPrompt) }, within: Self.answerTimeout)

        // Reading the labels outermost-first proves all three answers ran: the
        // middle answer, itself started from a tool body, holds nothing the
        // innermost answer needs while its own tool body runs.
        Self.expectFinished(
            outcome, is: Self.chainedAnswer(through: ["outer", "middle"]),
            describing: "The outermost answer")
        withExtendedLifetime(profile) {}
    }

    // MARK: - The same session

    @Test("an in-band tool body that waits for an answer of its own session gets the wait-cycle error at once")
    @MainActor
    func aToolBodyThatGeneratesOnItsOwnSessionIsRefused() async throws {
        let dir = RouterTestFixtures.makeTempDir(prefix: "NestedGenerationReentryTests")
        defer { try? FileManager.default.removeItem(at: dir) }

        let target = NestedTarget()
        let profile = try await Self.makeProfile(container: ToolCallingLLMContainer(), dir: dir)

        let caller = profile.standard.makeSession(
            tools: [NestedGeneratingTool(target: target, label: "caller")])
        // The tool waits for an answer of the very session whose submission
        // invoked it. That answer could come only after the submission, which
        // waits for the tool, so the wait could never end. It has to fail at
        // once, with the wait-cycle error that names the model.
        target.set(caller)
        let model = try #require(caller as? RoutedSessionActor).model

        let outcome = await Self.outcome(
            of: { try await caller.respond(to: Self.outerPrompt) }, within: Self.answerTimeout)

        Self.expectRefused(
            outcome, with: .waitInsideOpenSubmission(model: model),
            describing: "a tool body that generates on its own session")

        withExtendedLifetime(profile) {}
    }

    @Test(
        "an in-band tool body that sends a message to its own session gets its MessageID at once, and the message is the prompt of the next submission"
    )
    @MainActor
    func aToolBodyThatSendsToItsOwnSessionGetsAMessageIDAtOnce() async throws {
        let dir = RouterTestFixtures.makeTempDir(prefix: "NestedGenerationReentryTests")
        defer { try? FileManager.default.removeItem(at: dir) }

        let target = NestedTarget()
        let profile = try await Self.makeProfile(container: ToolCallingLLMContainer(), dir: dir)

        let caller = profile.standard.makeSession(tools: [SendingTool(target: target)])
        // The tool sends to the very session whose submission invoked it. A
        // send waits for nothing, so it returns at once, with no refusal.
        target.set(caller)
        let events = await caller.streamSessionEvents()

        let outcome = await Self.outcome(
            of: { try await caller.respond(to: Self.outerPrompt) }, within: Self.answerTimeout)
        let sentID = try #require(Self.finishedAnswer(outcome, describing: "The outer answer"))

        // No caller asks again: the pump delivers the sent message in the
        // next submission, and that submission names it.
        #expect(await caller.becomesIdle())
        await caller.close()
        // The first submission delivers the message of `respond`. The second
        // submission delivers only the sent message.
        let starts = await collect(events).submissionStarts
        #expect(starts.map(\.cause) == [.message, .message])
        let first = try #require(starts.first)
        let second = try #require(starts.last)
        #expect(first.messageIds.count == 1)
        #expect(!first.messageIds.map(\.description).contains(sentID))
        #expect(second.messageIds.map(\.description) == [sentID])
        let prompts = Array(await caller.transcript).compactMap { entry -> String? in
            guard case .prompt(let prompt) = entry else { return nil }
            return TranscriptEntryMapper.flattenedText(prompt)
        }
        #expect(prompts.last == Self.nestedPrompt)
        withExtendedLifetime(profile) {}
    }

    // MARK: - Forking from inside a tool body

    @Test("a tool body that forks its own session gets a child at once, rather than a refusal or a wait")
    func aToolBodyThatForksItsOwnSessionGetsAChildAtOnce() async throws {
        let dir = RouterTestFixtures.makeTempDir(prefix: "NestedGenerationReentryTests")
        defer { try? FileManager.default.removeItem(at: dir) }

        let target = NestedTarget()
        let profile = try await Self.makeProfile(container: ToolCallingLLMContainer(), dir: dir)

        let caller = profile.standard.makeSession(tools: [ForkingTool(target: target)])
        // The tool forks the very session whose submission invoked it. The
        // fork reads the settled transcript of that session, so it waits for
        // nothing the submission holds (task ^dpn2ytt).
        target.set(caller)

        let outcome = await Self.outcome(
            of: { try await caller.respond(to: Self.outerPrompt) }, within: Self.answerTimeout)

        // The child names the session it came off.
        Self.expectFinished(
            outcome, is: caller.id.description, describing: "The answer that forks its own session")

        withExtendedLifetime(profile) {}
    }

    @Test("a tool body forks a second session over the same resident container while its own submission runs")
    func aToolBodyForksASecondSessionOverTheSameContainer() async throws {
        let dir = RouterTestFixtures.makeTempDir(prefix: "NestedGenerationReentryTests")
        defer { try? FileManager.default.removeItem(at: dir) }

        let target = NestedTarget()
        let profile = try await Self.makeProfile(container: ToolCallingLLMContainer(), dir: dir)

        let caller = profile.standard.makeSession(tools: [ForkingTool(target: target)])
        let forked = profile.standard.makeSession()
        target.set(forked)

        let outcome = await Self.outcome(
            of: { try await caller.respond(to: Self.outerPrompt) }, within: Self.answerTimeout)

        // The child names the session it came off, so the refusal above reaches
        // the caller's own session and no other.
        Self.expectFinished(
            outcome, is: forked.id.description, describing: "The forking answer")
        withExtendedLifetime(profile) {}
    }

    // MARK: - Reading the transcript from inside a tool body

    @Test("a tool body reads its own session's transcript while its submission runs, and gets the settled transcript at once")
    func aToolBodyReadsItsOwnSessionsTranscript() async throws {
        let dir = RouterTestFixtures.makeTempDir(prefix: "NestedGenerationReentryTests")
        defer { try? FileManager.default.removeItem(at: dir) }

        let target = NestedTarget()
        let profile = try await Self.makeProfile(container: ToolCallingLLMContainer(), dir: dir)

        let caller = profile.standard.makeSession(tools: [TranscriptReadingTool(target: target)])
        // The tool reads the very session whose submission invoked it. The
        // read takes the settled transcript of that session, so it waits for
        // nothing the submission holds (task ^dpn2ytt).
        target.set(caller)

        let outcome = await Self.outcome(
            of: { try await caller.respond(to: Self.outerPrompt) }, within: Self.answerTimeout)

        // The count is the settled transcript, not the live one: the live
        // backend already holds the prompt of the submission and its answer.
        Self.expectFinished(
            outcome, is: String(Self.entriesAtTheLastSettledPoint),
            describing: "The transcript-reading answer")
        withExtendedLifetime(profile) {}
    }

    // MARK: - A declared background body

    /// The scaffolding one background-body test stands on: a profile whose
    /// tool-calling submission stays open on ``answerHold`` after its tool
    /// call returned, and records what that call handed back in
    /// ``handedBack``.
    private struct BackgroundHarness {
        /// The resolved profile sessions are vended from.
        let profile: LanguageModelProfile

        /// The latch the tool-calling submission stays open on after its tool
        /// call.
        let answerHold: RunLatch

        /// Where the tool-calling submission records what its tool call handed
        /// back.
        let handedBack: HandedBackRecord

        /// The session the fixture tool's body acts on.
        let target: NestedTarget

        /// Builds the harness over a fresh router that caches under `dir`.
        ///
        /// - Parameter dir: The temporary directory the router caches under.
        /// - Returns: The harness.
        static func make(dir: URL) async throws -> BackgroundHarness {
            let answerHold = RunLatch()
            let handedBack = HandedBackRecord()
            let profile = try await NestedGenerationReentryTests.makeProfile(
                container: ToolCallingLLMContainer(answerHold: answerHold, handedBack: handedBack), dir: dir)
            return BackgroundHarness(
                profile: profile, answerHold: answerHold, handedBack: handedBack, target: NestedTarget())
        }

        /// Starts the tool-calling answer of `session` in a task of its own,
        /// bounded by ``answerTimeout``, so the test can look at the run it
        /// starts while the submission is still open.
        ///
        /// - Parameter session: The session whose answer runs.
        /// - Returns: The task that carries the outcome of the answer.
        func startAnswer(on session: any RoutedSession) -> Task<AnswerOutcome?, Never> {
            Task {
                await NestedGenerationReentryTests.outcome(
                    of: { try await session.respond(to: NestedGenerationReentryTests.outerPrompt) },
                    within: NestedGenerationReentryTests.answerTimeout)
            }
        }

        /// Lets the held submission end, and reports what its answer produced.
        ///
        /// - Parameter answer: The task ``startAnswer(on:)`` returned.
        /// - Returns: The outcome of the answer, or `nil` when the bound won.
        func endAnswer(_ answer: Task<AnswerOutcome?, Never>) async -> AnswerOutcome? {
            await answerHold.open()
            return await answer.value
        }
    }

    @Test("a declared background body generates on a second session while the submission that started it is still open")
    @MainActor
    func aBackgroundBodyGeneratesOnASecondSessionWhileItsSubmissionIsOpen() async throws {
        let dir = RouterTestFixtures.makeTempDir(prefix: "NestedGenerationReentryTests")
        defer { try? FileManager.default.removeItem(at: dir) }

        let harness = try await BackgroundHarness.make(dir: dir)
        let caller = harness.profile.standard.makeSession(
            tools: [NestedGeneratingTool(target: harness.target, label: "caller", mount: Self.backgroundMount)])
        let nested = harness.profile.standard.makeSession()
        harness.target.set(nested)

        let answer = harness.startAnswer(on: caller)
        let token = await Self.handedBackToken(from: harness.handedBack)

        // The submission is still open, and the run it started settles all the
        // same: the submission holds nothing that the answer of the run on the
        // other session needs.
        if let token {
            let terminal = await Self.settledTerminal(of: token, on: caller, describing: "The background run")
            #expect(terminal?.outcome == .succeeded)
            #expect(terminal?.detail == Self.chainedAnswer(through: ["caller"]))
        }

        // The run settled before its submission ended, so the answer is the
        // handle the submission was handed.
        Self.expectFinished(
            await harness.endAnswer(answer), is: harness.handedBack.value ?? "", describing: "The outer answer")
        withExtendedLifetime(harness) {}
    }

    @Test("a declared background body asks the session that started it for an answer, and gets it from a later submission, with no error and no hang")
    @MainActor
    func aBackgroundBodyThatGeneratesOnItsOwnSessionGetsAnAnswer() async throws {
        let dir = RouterTestFixtures.makeTempDir(prefix: "NestedGenerationReentryTests")
        defer { try? FileManager.default.removeItem(at: dir) }

        let harness = try await BackgroundHarness.make(dir: dir)
        let caller = harness.profile.standard.makeSession(
            tools: [NestedGeneratingTool(target: harness.target, label: "caller", mount: Self.backgroundMount)])
        // The body asks the very session whose submission started it. Its
        // mark is closed, so the message is not refused: it waits in the
        // outbox for a later submission of the session.
        harness.target.set(caller)

        let answer = harness.startAnswer(on: caller)
        let token = try #require(await Self.handedBackToken(from: harness.handedBack))

        // The submission that started the run ends with the handle it was
        // handed. The pump then submits the message of the run, and the run
        // settles with the answer of that submission.
        Self.expectFinished(
            await harness.endAnswer(answer), is: harness.handedBack.value ?? "", describing: "The outer answer")
        // The progress report of the run is mail, so it rides the prompt of
        // that submission in front of the run's own message.
        let terminal = await Self.settledTerminal(of: token, on: caller, describing: "The run that asks its own session")
        #expect(terminal?.outcome == .succeeded)
        let detail = try #require(terminal?.detail)
        #expect(detail.hasPrefix("caller" + NestedGeneratingTool.labelSeparator + ToolCallingBackend.answerPrefix))
        #expect(detail.hasSuffix(Self.nestedPrompt))
        withExtendedLifetime(harness) {}
    }

    @Test("a declared background body that forks the session that started it does not wait for the submission")
    @MainActor
    func aBackgroundBodyThatForksItsOwnSessionDoesNotWaitForTheSubmission() async throws {
        let dir = RouterTestFixtures.makeTempDir(prefix: "NestedGenerationReentryTests")
        defer { try? FileManager.default.removeItem(at: dir) }

        let harness = try await BackgroundHarness.make(dir: dir)
        let caller = harness.profile.standard.makeSession(
            tools: [ForkingTool(target: harness.target, mount: Self.backgroundMount)])
        harness.target.set(caller)

        let answer = harness.startAnswer(on: caller)
        let token = try #require(await Self.handedBackToken(from: harness.handedBack))
        // The submission that started the run is still open. The fork reads
        // the settled transcript, so the run settles all the same, and its
        // child names the session it forked (task ^dpn2ytt).
        let terminal = await Self.settledTerminal(of: token, on: caller, describing: "The forking run")
        #expect(terminal?.outcome == .succeeded)
        #expect(terminal?.detail == caller.id.description)

        #expect(Self.finishedAnswer(await harness.endAnswer(answer), describing: "The forking answer") != nil)
        withExtendedLifetime(harness) {}
    }

    @Test("a declared background body that reads the transcript of the session that started it does not wait for the submission")
    @MainActor
    func aBackgroundBodyThatReadsItsOwnSessionsTranscriptDoesNotWaitForTheSubmission() async throws {
        let dir = RouterTestFixtures.makeTempDir(prefix: "NestedGenerationReentryTests")
        defer { try? FileManager.default.removeItem(at: dir) }

        let harness = try await BackgroundHarness.make(dir: dir)
        let caller = harness.profile.standard.makeSession(
            tools: [TranscriptReadingTool(target: harness.target, mount: Self.backgroundMount)])
        harness.target.set(caller)

        let answer = harness.startAnswer(on: caller)
        let token = try #require(await Self.handedBackToken(from: harness.handedBack))
        // The submission that started the run is still open. The read takes
        // the settled transcript, so the run settles all the same, with the
        // entries of the last settled point (task ^dpn2ytt).
        let terminal = await Self.settledTerminal(of: token, on: caller, describing: "The reading run")
        #expect(terminal?.outcome == .succeeded)
        #expect(terminal?.detail == String(Self.entriesAtTheLastSettledPoint))

        #expect(Self.finishedAnswer(await harness.endAnswer(answer), describing: "The reading answer") != nil)
        withExtendedLifetime(harness) {}
    }

    // MARK: - The model-call mark itself

    @Test("a model-call mark names its own session, and no other, until the call closes it")
    func aModelCallMarkNamesItsOwnSessionUntilItCloses() {
        let sessionID = ULID.generate()
        let mark = ModelCallMark(sessionID: sessionID)

        #expect(mark.isOpenModelCall(of: sessionID))
        #expect(!mark.isOpenModelCall(of: ULID.generate()))

        // The model call returns and closes its mark. A task that outlives the
        // call, and still carries the mark, is then in no model call.
        mark.close()
        #expect(!mark.isOpenModelCall(of: sessionID))
    }

    @Test("a background run keeps the session of the model call that started it, but is in no model call")
    func aBackgroundRunKeepsTheSessionButIsInNoModelCall() async throws {
        let sessionID = ULID.generate()
        let mark = ModelCallMark(sessionID: sessionID)

        let seen = await ModelCallMark.$current.withValue(mark) {
            await ModelCallMark.withBackgroundRunMark {
                ModelCallMark.current.map { ($0.sessionID, $0.isOpenModelCall(of: sessionID)) }
            }
        }

        // The session stays, but the run is no tool call the model is
        // suspended in. So its wait for an answer of that session is not
        // refused: the message waits for a later submission.
        let (runSessionID, runIsInTheCall) = try #require(seen)
        #expect(runSessionID == sessionID)
        #expect(!runIsInTheCall)
        // The background run leaves the model call that started it open.
        #expect(mark.isOpenModelCall(of: sessionID))
    }

    @Test("a background run started outside any model call carries no mark")
    func aBackgroundRunOutsideAModelCallCarriesNoMark() async {
        let seen = await ModelCallMark.withBackgroundRunMark { ModelCallMark.current }

        #expect(seen == nil)
    }

    // MARK: - An answer whose submission waits for the worker

    /// The prompt of the session whose submission waits behind the cancelled
    /// one.
    private static let nextPrompt = "summarize the ranking"

    @Test(
        "cancel() on a session whose submission waits removes it at once, and the worker then runs the next item"
    )
    func cancelOnASessionWhoseSubmissionWaitsRemovesItAtOnce() async throws {
        let dir = RouterTestFixtures.makeTempDir(prefix: "NestedGenerationReentryTests")
        defer { try? FileManager.default.removeItem(at: dir) }

        let fixture = PassObservingFixture()
        let queue = fixture.queue
        let profile = try await Self.makeProfile(container: fixture.container, dir: dir)

        let holder = profile.standard.makeSession()
        let waiter = profile.standard.makeSession()
        let next = profile.standard.makeSession()

        // The holder's submission runs on the worker, and its pass stays
        // inside the model until the latch opens.
        let holderAnswer = Task { try await holder.respond(to: Self.outerPrompt) }
        #expect(
            await BoundedWait.conditionReached("the holder's pass in the model") {
                await fixture.observer.enteredCount == 1
            })

        // The pump of the waiter runs its answer, which has an identity; only
        // its submission waits, in the queue of the model.
        let waiterFinished = AsyncSemaphore(value: 0)
        let waiterAnswer = Task {
            defer { waiterFinished.signal() }
            return try await waiter.respond(to: Self.nestedPrompt)
        }
        #expect(
            await BoundedWait.conditionReached("the waiter's submission waiting in the queue") {
                await queue.waitingCount == 1
            })
        // A third submission joins the queue behind the waiter's.
        let nextAnswer = Task { try await next.respond(to: Self.nextPrompt) }
        #expect(
            await BoundedWait.conditionReached("the next submission waiting behind the waiter's") {
                await queue.waitingCount == 2
            })

        // So the request reaches the waiting item, and the answer ends at once,
        // while the holder still runs on the worker.
        #expect(await waiter.cancel() == .requested)
        #expect(
            await BoundedWait.signalArrived(
                waiterFinished, named: "the end of the cancelled answer, while the holder still runs"))
        #expect(await queue.waitingCount == 1)

        await fixture.latch.open()
        #expect(try await holderAnswer.value == PassObservingModel.answer(to: Self.outerPrompt))
        await #expect(throws: CancellationError.self) { try await waiterAnswer.value }
        // The worker ran the next item after the holder, and never the
        // cancelled one.
        #expect(try await nextAnswer.value == PassObservingModel.answer(to: Self.nextPrompt))
        #expect(fixture.passes.recorded.map(\.prompt) == [Self.outerPrompt, Self.nextPrompt])
        #expect(await queue.isRunning == false)
        #expect(await queue.waitingCount == 0)

        // The cancelled session still generates: its pump and the queue are
        // both free.
        let followUp = await Self.outcome(
            of: { try await waiter.respond(to: Self.outerPrompt) }, within: Self.answerTimeout)
        Self.expectFinished(
            followUp, is: PassObservingModel.answer(to: Self.outerPrompt), describing: "The follow-up answer")
        withExtendedLifetime(profile) {}
    }
}
