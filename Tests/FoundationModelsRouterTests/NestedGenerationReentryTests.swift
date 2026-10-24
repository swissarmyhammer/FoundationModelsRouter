import Foundation
import FoundationModels
import FoundationModelsRouterTestSupport
import Synchronization
import Testing

@testable import FoundationModelsExtras
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
/// (task ^3qx0mpt). The router puts no lock around a model call, so a tool
/// body that generates on another session over the same container runs that
/// model call directly and holds nothing that session needs. An
/// in-band tool body that asks its own session for an answer is refused at
/// once, because that answer could come only after the submission that waits
/// for the tool body. A declared background body asks its own session and
/// gets an answer from a later submission. A transcript read that a tool
/// body asks of its own session is served at once, from the settled
/// transcript of that session (task ^dpn2ytt). Over a model whose passes
/// hold a FIFO lock, an in-band tool body that waits for a session on the
/// same model gets its answer (task ^qhgfajc, `ToolBodyHoldsNoLockTests`).
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
    /// from inside its model call, and the test waits for it on ``changes``
    /// while that submission is still open.
    private final class ThreadSafeBox<Value: Sendable>: Sendable {
        private let storage: Mutex<Value?> = Mutex(nil)

        /// The signal that ``set(_:)`` sends after it stores a value.
        let changes = ChangeSignal()

        /// Stores the one value a later reader sees, and signals ``changes``.
        ///
        /// - Parameter value: The value to store.
        func set(_ value: Value) {
            storage.withLock { $0 = value }
            changes.signal()
        }

        /// The stored value, or `nil` while nothing was stored.
        var value: Value? {
            storage.withLock { $0 }
        }
    }

    /// The session a tool body generates on, sends to, or reads, set after the
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
            return try session.send(arguments.value).description
        }
    }

    /// A tool whose body sends a message to a routed session, and then waits
    /// for that message: for its terminal event, or for its answer — the
    /// shape a host has whenever a tool asks the conversation it runs inside
    /// for a result.
    ///
    /// It declares no mount, so the session mounts it run-to-completion: the
    /// body runs in band, inside the submission that called it.
    private struct MailWaitingTool: Tool {
        /// The wait the body makes for the message it sent.
        enum Wait: Sendable, CustomStringConvertible {
            /// ``RoutedSession/awaitTerminal(of:)-(MailID)``.
            case terminal

            /// ``RoutedSession/awaitAnswer(of:)``.
            case answer

            /// The name of the wait in a report.
            var description: String {
                switch self {
                case .terminal: "awaitTerminal(of:)"
                case .answer: "awaitAnswer(of:)"
                }
            }
        }

        let name = "mail-wait-probe"
        let description = "test-only tool that sends a message to a routed session and waits for it"

        /// The session this body sends to and waits on.
        let target: NestedTarget

        /// The wait the body makes.
        let wait: Wait

        /// The output a call produces when no target session was named, so a
        /// misbuilt fixture reads as a wrong answer rather than as a pass.
        static let noTargetOutput = "no target session"

        func call(arguments: ReentryToolArguments) async throws -> String {
            guard let session = target.value else { return Self.noTargetOutput }
            let id = try session.send(arguments.value)
            switch wait {
            case .terminal:
                return String(describing: try await session.awaitTerminal(of: id))
            case .answer:
                return try await session.awaitAnswer(of: id).reply
            }
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

        func cachedInputTokenCount() -> Int? {
            inner.cachedInputTokenCount()
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

    /// Waits for `answer`, and reports its outcome.
    ///
    /// The end of the answer is the event: its text, or its error (a refusal
    /// comes at once). No clock ends the wait. An answer that suspends for
    /// ever keeps the test waiting, and a stack of the test process then shows
    /// the open wait.
    ///
    /// - Parameters:
    ///   - isolation: The isolation of the caller. `answer` runs there.
    ///   - answer: The work that waits for the answer.
    /// - Returns: The outcome of the answer.
    private static func outcome(
        isolation: isolated (any Actor)? = #isolation,
        of answer: () async throws -> String
    ) async -> AnswerOutcome {
        do {
            return .finished(try await answer())
        } catch {
            return .failed(refusal: error as? GenerationQueueError, description: String(describing: error))
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
    /// this suite covers when the answer failed instead.
    ///
    /// - Parameters:
    ///   - outcome: The outcome of the answer.
    ///   - name: What the answer is called in the report.
    /// - Returns: The text of the answer, or `nil` when it produced none.
    private static func finishedAnswer(_ outcome: AnswerOutcome, describing name: String) -> String? {
        switch outcome {
        case .failed(_, let description):
            Issue.record("\(name) failed instead of finishing: \(description)")
            return nil
        case .finished(let answer):
            return answer
        }
    }

    /// Asserts that `outcome` finished with `expected`, naming the defect this
    /// suite covers when the answer failed instead.
    ///
    /// - Parameters:
    ///   - outcome: The outcome of the answer.
    ///   - expected: The text the answer has to produce.
    ///   - name: What the answer is called in the report.
    private static func expectFinished(
        _ outcome: AnswerOutcome, is expected: String, describing name: String
    ) {
        #expect(finishedAnswer(outcome, describing: name) == expected)
    }

    /// The completion token a backgrounded tool call handed back through
    /// `record`, once the call has returned — or `nil`, with an issue
    /// recorded, when the call returned no pending envelope.
    ///
    /// The wait ends when the backend records what the call handed back. The
    /// submission that made the call is still open when this returns: the
    /// backend records the handle before it waits on its answer hold.
    ///
    /// The wait also ends when `answer` ended (rule T1): a tool call that
    /// throws ends the answer with no record. In a test that passes, the
    /// answer hold keeps the answer open after the record, so the answer
    /// cannot end first.
    ///
    /// - Parameters:
    ///   - record: Where the backend records what the call handed back.
    ///   - answer: The task of the answer whose tool call hands back the
    ///     record.
    /// - Returns: The token the pending envelope names, or `nil`.
    /// - Throws: The error of `#require` when the answer ended first, or
    ///   ``ConditionNeverHeld`` when the test task was cancelled first.
    private static func handedBackToken(
        from record: HandedBackRecord, endingOnEndOf answer: Task<AnswerOutcome, Never>
    ) async throws -> String? {
        let answerEnded = RecordedWaitResult.recordingEnd(of: answer, reportingTo: record.changes)
        defer { answerEnded.stopRecording() }
        try await record.changes.wait(until: { record.value != nil }, endingOn: { answerEnded.value != nil })
        let text = try #require(record.value)
        guard
            let envelope = try? JSONDecoder().decode(PendingRunEnvelope.self, from: Data(text.utf8))
        else {
            Issue.record("The tool call handed back \"\(text)\" rather than a pending envelope.")
            return nil
        }
        return envelope.completionToken
    }

    /// The terminal event `session`'s run `completionToken` settled with, or
    /// `nil`, with an issue recorded, when the run plane reports no
    /// settlement.
    ///
    /// The wait has no deadline: the settlement of the run is the event.
    ///
    /// - Parameters:
    ///   - completionToken: The background run's completion token.
    ///   - session: The session whose run plane tracks the run.
    ///   - run: What the run is called in the report.
    /// - Returns: The run's terminal event, or `nil`.
    private static func settledTerminal(
        of completionToken: String, on session: any RoutedSession, describing run: String
    ) async -> OperationEvent? {
        let outcome = await session.runPlane.wait(completionToken: completionToken, seconds: nil)
        switch outcome {
        case .settled(let terminal):
            return terminal
        case .deadlineElapsed:
            Issue.record("\(run) reported an elapsed deadline, but the wait had no deadline.")
            return nil
        case .cancelled, .unknownToken:
            Issue.record(
                """
                \(run) did not settle (\(outcome)). A background body has to make progress while \
                the submission that started it is still open.
                """)
            return nil
        }
    }

    /// Asserts that `outcome` failed with `expected`, naming the defect this
    /// suite covers when the call was served instead.
    ///
    /// - Parameters:
    ///   - outcome: The outcome of the answer.
    ///   - expected: The refusal the call has to raise.
    ///   - call: What the refused call is called in the report.
    private static func expectRefused(
        _ outcome: AnswerOutcome, with expected: GenerationQueueError, describing call: String
    ) {
        switch outcome {
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
        defer { await SessionFixtureLifecycle.close([caller, nested]) }
        target.set(nested)

        let outcome = await Self.outcome(
            of: { try await caller.respond(to: Self.outerPrompt) })

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
        defer { await SessionFixtureLifecycle.close([outer, middle, innermost]) }
        outerTarget.set(middle)
        middleTarget.set(innermost)

        let outcome = await Self.outcome(
            of: { try await outer.respond(to: Self.outerPrompt) })

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
        defer { await caller.close() }
        // The tool waits for an answer of the very session whose submission
        // invoked it. That answer could come only after the submission, which
        // waits for the tool, so the wait could never end. It has to fail at
        // once, with the wait-cycle error that names the model.
        target.set(caller)
        let model = try #require(caller as? RoutedSessionActor).model

        // The refusal is the event: the answer ends with it, with no clock.
        let outcome = await Self.outcome(of: { try await caller.respond(to: Self.outerPrompt) })

        Self.expectRefused(
            outcome, with: .waitInsideOpenSubmission(model: model),
            describing: "a tool body that generates on its own session")

        withExtendedLifetime(profile) {}
    }

    @Test("an in-band tool body that waits for the terminal event of a mail of its own session gets the wait-cycle error at once")
    @MainActor
    func aToolBodyThatAwaitsATerminalOfItsOwnSessionIsRefused() async throws {
        try await Self.expectOwnMailWaitRefused(.terminal)
    }

    @Test("an in-band tool body that waits for the answer of a mail of its own session gets the wait-cycle error at once")
    @MainActor
    func aToolBodyThatAwaitsAnAnswerOfItsOwnSessionIsRefused() async throws {
        try await Self.expectOwnMailWaitRefused(.answer)
    }

    /// Runs one answer whose in-band tool body sends a mail to its own
    /// session, and then waits for that mail with `wait`. Asserts that the
    /// wait fails at once with the wait-cycle error that names the model.
    ///
    /// The mail could be delivered only by a submission after the one that
    /// waits for the tool body, so the wait could never end.
    ///
    /// - Parameter wait: The wait the tool body makes for its mail.
    /// - Throws: What the setup of the profile throws.
    private static func expectOwnMailWaitRefused(_ wait: MailWaitingTool.Wait) async throws {
        let dir = RouterTestFixtures.makeTempDir(prefix: "NestedGenerationReentryTests")
        defer { try? FileManager.default.removeItem(at: dir) }

        let target = NestedTarget()
        let profile = try await makeProfile(container: ToolCallingLLMContainer(), dir: dir)

        let caller = profile.standard.makeSession(tools: [MailWaitingTool(target: target, wait: wait)])
        defer { await caller.close() }
        target.set(caller)
        let model = try #require(caller as? RoutedSessionActor).model

        // The refusal is the event: the answer ends with it, with no clock.
        let answer = await Self.outcome(of: { try await caller.respond(to: Self.outerPrompt) })

        Self.expectRefused(
            answer, with: .waitInsideOpenSubmission(model: model),
            describing: "a tool body that waits for a mail of its own session (\(wait))")
        withExtendedLifetime(profile) {}
    }

    @Test(
        "an in-band tool body that sends a message to its own session gets its MailID at once, and the message is the prompt of the next submission"
    )
    @MainActor
    func aToolBodyThatSendsToItsOwnSessionGetsAMailIDAtOnce() async throws {
        let dir = RouterTestFixtures.makeTempDir(prefix: "NestedGenerationReentryTests")
        defer { try? FileManager.default.removeItem(at: dir) }

        let target = NestedTarget()
        let profile = try await Self.makeProfile(container: ToolCallingLLMContainer(), dir: dir)

        let caller = profile.standard.makeSession(tools: [SendingTool(target: target)])
        defer { await caller.close() }
        // The tool sends to the very session whose submission invoked it. A
        // send waits for nothing, so it returns at once, with no refusal.
        target.set(caller)
        let events = await caller.streamSessionEvents().events

        let outcome = await Self.outcome(of: { try await caller.respond(to: Self.outerPrompt) })
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
        #expect(first.mailIds.count == 1)
        #expect(!first.mailIds.map(\.description).contains(sentID))
        #expect(second.mailIds.map(\.description) == [sentID])
        let prompts = Array(await caller.transcript).compactMap { entry -> String? in
            guard case .prompt(let prompt) = entry else { return nil }
            return TranscriptEntryMapper.flattenedText(prompt)
        }
        #expect(prompts.last == Self.nestedPrompt)
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
        defer { await caller.close() }
        // The tool reads the very session whose submission invoked it. The
        // read takes the settled transcript of that session, so it waits for
        // nothing the submission holds (task ^dpn2ytt).
        target.set(caller)

        let outcome = await Self.outcome(of: { try await caller.respond(to: Self.outerPrompt) })

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
        /// so the test can look at the run it starts while the submission is
        /// still open.
        ///
        /// - Parameter session: The session whose answer runs.
        /// - Returns: The task that carries the outcome of the answer.
        func startAnswer(on session: any RoutedSession) -> Task<AnswerOutcome, Never> {
            Task {
                await NestedGenerationReentryTests.outcome(
                    of: { try await session.respond(to: NestedGenerationReentryTests.outerPrompt) })
            }
        }

        /// Makes the session whose tool-calling answer a test starts, with
        /// `tools`.
        ///
        /// The settle period of the session is `0`, so a background call
        /// answers with its pending envelope at once, also when its run ends
        /// at once. The test then sees the run settle while the submission
        /// that started it is still open.
        ///
        /// - Parameter tools: The tools of the session.
        /// - Returns: The session.
        func makeCallerSession(tools: [any Tool]) -> any RoutedSession {
            profile.standard.makeSession(configuration: SessionConfiguration(tools: tools, inlineSettleGrace: 0))
        }

        /// Lets the held submission end, and reports what its answer produced.
        ///
        /// - Parameter answer: The task ``startAnswer(on:)`` returned.
        /// - Returns: The outcome of the answer.
        func endAnswer(_ answer: Task<AnswerOutcome, Never>) async -> AnswerOutcome {
            await answerHold.open()
            return await answer.value
        }

        /// Opens ``answerHold``, and then closes each of `sessions`.
        ///
        /// A test calls it from one `defer` right after it makes its
        /// sessions, so each session closes also when the test throws (rule
        /// T1). A close waits for the held submission, so the hold opens
        /// first.
        ///
        /// - Parameter sessions: The sessions that the test made.
        func close(_ sessions: [any RoutedSession]) async {
            await SessionFixtureLifecycle.close(sessions, opening: [answerHold])
        }
    }

    @Test("a declared background body generates on a second session while the submission that started it is still open")
    @MainActor
    func aBackgroundBodyGeneratesOnASecondSessionWhileItsSubmissionIsOpen() async throws {
        let dir = RouterTestFixtures.makeTempDir(prefix: "NestedGenerationReentryTests")
        defer { try? FileManager.default.removeItem(at: dir) }

        let harness = try await BackgroundHarness.make(dir: dir)
        let caller = harness.makeCallerSession(
            tools: [NestedGeneratingTool(target: harness.target, label: "caller", mount: Self.backgroundMount)])
        let nested = harness.profile.standard.makeSession()
        defer { await harness.close([caller, nested]) }
        harness.target.set(nested)

        let answer = harness.startAnswer(on: caller)
        let token = try #require(
            try await Self.handedBackToken(from: harness.handedBack, endingOnEndOf: answer))

        // The submission is still open, and the run it started settles all the
        // same: the submission holds nothing that the answer of the run on the
        // other session needs.
        let terminal = await Self.settledTerminal(of: token, on: caller, describing: "The background run")
        #expect(terminal?.outcome == .succeeded)
        #expect(terminal?.detail == Self.chainedAnswer(through: ["caller"]))

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
        let caller = harness.makeCallerSession(
            tools: [NestedGeneratingTool(target: harness.target, label: "caller", mount: Self.backgroundMount)])
        defer { await harness.close([caller]) }
        // The body asks the very session whose submission started it. Its
        // mark is closed, so the message is not refused: it waits in the
        // outbox for a later submission of the session.
        harness.target.set(caller)

        let answer = harness.startAnswer(on: caller)
        let token = try #require(
            try await Self.handedBackToken(from: harness.handedBack, endingOnEndOf: answer))

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

    @Test("a declared background body that reads the transcript of the session that started it does not wait for the submission")
    @MainActor
    func aBackgroundBodyThatReadsItsOwnSessionsTranscriptDoesNotWaitForTheSubmission() async throws {
        let dir = RouterTestFixtures.makeTempDir(prefix: "NestedGenerationReentryTests")
        defer { try? FileManager.default.removeItem(at: dir) }

        let harness = try await BackgroundHarness.make(dir: dir)
        let caller = harness.makeCallerSession(
            tools: [TranscriptReadingTool(target: harness.target, mount: Self.backgroundMount)])
        defer { await harness.close([caller]) }
        harness.target.set(caller)

        let answer = harness.startAnswer(on: caller)
        let token = try #require(
            try await Self.handedBackToken(from: harness.handedBack, endingOnEndOf: answer))
        // The submission that started the run is still open. The read takes
        // the settled transcript, so the run settles all the same, with the
        // entries of the last settled point (task ^dpn2ytt).
        let terminal = await Self.settledTerminal(of: token, on: caller, describing: "The reading run")
        #expect(terminal?.outcome == .succeeded)
        #expect(terminal?.detail == String(Self.entriesAtTheLastSettledPoint))

        #expect(Self.finishedAnswer(await harness.endAnswer(answer), describing: "The reading answer") != nil)
        withExtendedLifetime(harness) {}
    }

    // MARK: - An answer whose pass waits for the lock of the model

    /// The prompt of the session whose pass waits behind the cancelled one.
    private static let nextPrompt = "summarize the ranking"

    @Test(
        "cancelAll() on a session whose pass waits for the lock of the model ends its answer at once, and the next pass then runs"
    )
    func cancelOnASessionWhoseSubmissionWaitsRemovesItAtOnce() async throws {
        let dir = RouterTestFixtures.makeTempDir(prefix: "NestedGenerationReentryTests")
        defer { try? FileManager.default.removeItem(at: dir) }

        let fixture = PassObservingFixture()
        let profile = try await Self.makeProfile(container: fixture.container, dir: dir)
        let lock = fixture.lock

        let holder = profile.standard.makeSession()
        let waiter = profile.standard.makeSession()
        let next = profile.standard.makeSession()
        // The latch opens first, so no pass stays held, and then each of the
        // three sessions closes, also when the test throws (rule T1).
        defer { await SessionFixtureLifecycle.close([holder, waiter, next], opening: [fixture.latch]) }
        let waiterFeed = await waiter.streamSessionEvents()

        // The holder's pass holds the lock of the model, and stays inside
        // the model until the latch opens. Each wait also ends when its
        // answer ended (rule T1): the latch holds the holder in the model and
        // the other passes in the lock, so in a test that passes no answer
        // ends first.
        let holderAnswer = Task { try await holder.respond(to: Self.outerPrompt) }
        try await BoundedWait.run {
            try await RecordedWaitResult.wait(
                for: { try await fixture.observer.waitUntil { $0.entered == 1 } }, endingOnEndOf: holderAnswer)
        }

        // The pump of the waiter runs its answer, which has an identity; its
        // pass waits for the lock of the model.
        let waiterAnswer = Task { try await waiter.respond(to: Self.nestedPrompt) }
        try await BoundedWait.run { try await lock.waitForWaiters(1) }
        // A third pass waits for the lock behind the waiter's.
        let nextAnswer = Task { try await next.respond(to: Self.nextPrompt) }
        try await BoundedWait.run { try await lock.waitForWaiters(2) }

        // The cancelAll() signal stops the running answer of the waiter. The
        // cancel does not wait for the lock, so the answer ends at once,
        // while the holder still holds the lock: the latch is still closed,
        // so the end of the cancelled answer comes before the holder can
        // end. The signal does not wait for the pump, so the test waits for
        // the end of the pump of the waiter. The abandoned pass keeps its
        // place in the lock, as a pass of MLX does, and leaves at its turn.
        let stop = waiter.cancelAll()
        #expect(try await BoundedWait.run { try await waiter.awaitTerminal(of: stop) } == .signalDone(stop))
        await #expect(throws: CancellationError.self) { try await BoundedWait.value(of: waiterAnswer) }
        #expect(await waiter.isIdleOnceThePumpEnds())
        #expect(await lock.waitingCount == 2)

        await fixture.latch.open()
        #expect(try await BoundedWait.value(of: holderAnswer) == PassObservingModel.answer(to: Self.outerPrompt))
        // The next pass ran after the holder, and the cancelled one never
        // ran.
        #expect(try await BoundedWait.value(of: nextAnswer) == PassObservingModel.answer(to: Self.nextPrompt))
        #expect(fixture.passes.recorded.map(\.prompt) == [Self.outerPrompt, Self.nextPrompt])
        #expect(await lock.waitingCount == 0)

        // The cancelled session still generates: its pump and the lock are
        // both free.
        let followUp = await Self.outcome(of: { try await waiter.respond(to: Self.outerPrompt) })
        Self.expectFinished(
            followUp, is: PassObservingModel.answer(to: Self.outerPrompt), describing: "The follow-up answer")

        // The cancelled answer and the follow-up answer of the waiter each end
        // with exactly one terminal event, and the signal ends with its own.
        await waiter.close()
        var outputs: [SessionOutput] = []
        for await output in waiterFeed {
            outputs.append(output)
        }
        let ledger = TerminalEventLedger(outputs: outputs)
        ledger.expectExactlyOneTerminal(for: ledger.endedMailIds.flatMap { $0 })
        #expect(ledger.endedMailIds.count == 2)
        ledger.expectExactlyOneTerminal(forSignals: [stop])
        withExtendedLifetime(profile) {}
    }
}
