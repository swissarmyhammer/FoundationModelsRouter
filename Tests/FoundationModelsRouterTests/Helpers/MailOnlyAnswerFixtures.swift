import Foundation
import FoundationModels
import FoundationModelsRouterTestSupport
import Synchronization
import Testing

@testable import FoundationModelsExtras
@testable import FoundationModelsRouter

/// The fixtures that the suites of the bound on mail-only answers share
/// (``SessionConfiguration/mailOnlyAnswerLimit``): `MailOnlyAnswerLimitTests`
/// and `MailOnlyAnswerCountTests`.
///
/// A scripted backend calls the one fixture tool of the session in the calls
/// that a test names. Each background run of a ``GatedJob`` waits at its own
/// gate, so the test decides when each run settles. A run that the test does
/// not settle is still open when the answer that started it ends, so that
/// answer started a new background run. Everything runs on a manual run
/// clock, so no settle period ends while a test runs.
enum MailOnlyAnswerFixtures {
    /// The failure of a fixture tool body that runs with no bound
    /// ``ToolContext``. A mounted tool body always has one.
    struct MissingToolContext: Error {}

    // MARK: - Constants

    /// The limit each test session has: small, so a test runs few submissions.
    static let limit = 3

    /// The prompts of one chain: the caller answer, then ``limit`` answers
    /// that mail alone started, each of which started a new background run.
    static let promptsOfOneChain = limit + 1

    /// The name of the ``GatedJob`` of each session.
    static let jobName = "gated_job"

    // MARK: - Gates

    /// The gates of the background runs of the ``GatedJob`` tools of one
    /// session: one gate for each run, by its completion token.
    actor RunGates {
        /// The gate of each run, by its completion token.
        private var gates: [String: RunLatch] = [:]

        /// Whether each gate opens when it is made.
        private var opensEachGate: Bool

        /// Makes the gates of one session.
        ///
        /// - Parameter opensEachGate: `true` when each gate opens when it is
        ///   made, so each run settles as soon as its body runs.
        init(opensEachGate: Bool = false) {
            self.opensEachGate = opensEachGate
        }

        /// The gate of the run `token`. The first read makes it.
        ///
        /// - Parameter token: The completion token of the run.
        /// - Returns: The gate.
        func gate(of token: String) async -> RunLatch {
            if let gate = gates[token] { return gate }
            let gate = RunLatch()
            gates[token] = gate
            if opensEachGate { await gate.open() }
            return gate
        }

        /// Opens each gate, also each gate that a later read makes, so no run
        /// body stays held.
        func openEachGate() async {
            opensEachGate = true
            for gate in gates.values {
                await gate.open()
            }
        }
    }

    // MARK: - Tools

    /// A background tool whose run waits at its gate in ``gates``, and then
    /// settles with ``output``.
    struct GatedJob: Tool, BackgroundTool {
        /// The output of each run.
        static let output = "the job is done"

        let name: String
        let description = "test-only background job that waits at the gate of its run"

        /// The gates of the runs of this tool.
        let gates: RunGates

        /// The settle period of each call, in seconds. With `0`, each call
        /// answers with its pending envelope at once.
        var settlePeriod: TimeInterval = 0

        var mount: ToolMount? {
            ToolMount(mode: .background, timeout: nil)
        }

        var inlineSettleGrace: TimeInterval { settlePeriod }

        func call(arguments: BackgroundFixtureArguments) async throws -> String {
            guard let context = ToolContext.current else { throw MissingToolContext() }
            await gates.gate(of: context.completionToken).waitUntilOpen()
            return Self.output
        }
    }

    /// A synchronous tool, as a script runner is: its body starts one inner
    /// background run of ``job`` on its own ``ToolContext``, and answers at
    /// once with ``output``, not with a pending envelope. The inner run stays
    /// open after the call.
    struct InnerJobStarter: Tool {
        /// The output of each call.
        static let output = "the script ran, and its job goes on"

        let name = "run_script"
        let description = "test-only script runner that starts one background job and answers at once"

        /// The tool of the inner run.
        let job: GatedJob

        func call(arguments: BackgroundFixtureArguments) async throws -> String {
            guard let context = ToolContext.current else { throw MissingToolContext() }
            _ = try await context.mount(job).call(arguments: arguments)
            return Self.output
        }
    }

    // MARK: - Backend

    /// A scripted model that calls the first composed fixture tool of its
    /// session in each call that ``callsTool`` names, and then answers.
    ///
    /// The pump drives this backend with no caller call, so every mutable
    /// field is behind one `Mutex`.
    final class Backend: LanguageModelSessionBackend {
        /// The backend that answers each call and records its prompt.
        private let inner = StubSessionBackend()

        /// The session's own composed tool list.
        private let tools: [any Tool]

        /// Whether the call with a one-based ordinal calls the tool.
        private let callsTool: @Sendable (Int) -> Bool

        /// The number of calls so far.
        private let callCount = Mutex(0)

        /// Makes a backend over `tools`.
        ///
        /// - Parameters:
        ///   - tools: The session's composed tool list.
        ///   - callsTool: Whether the call with a one-based ordinal calls the
        ///     tool.
        init(tools: [any Tool], callsTool: @escaping @Sendable (Int) -> Bool) {
            self.tools = tools
            self.callsTool = callsTool
        }

        /// The prompt of each call so far, in call order.
        var prompts: [String] { inner.receivedPrompts }

        func respond(to prompt: String, maxTokens: Int?) async throws -> String {
            let ordinal = callCount.withLock { count in
                count += 1
                return count
            }
            if callsTool(ordinal) {
                try await callTool(prompt: prompt)
            }
            return try await inner.respond(to: prompt, maxTokens: maxTokens)
        }

        /// Calls the first composed fixture tool of the session.
        ///
        /// - Parameter prompt: The prompt of the call, which the tool receives
        ///   as its argument.
        /// - Throws: What the tool throws.
        private func callTool(prompt: String) async throws {
            let tool = try #require(tools.fixtureTools.first)
            _ = try await tool.call(arguments: BackgroundFixtureArguments(value: prompt))
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

    /// Vends one ``Backend`` for the session a test makes, with the composed
    /// tool list of that session.
    ///
    /// The last vended backend is behind a ``Mutex``, and every other stored
    /// property is an immutable `Sendable` value. Thus the type is `Sendable`
    /// with no unchecked claim.
    final class Container: LoadedLLMContainer, Sendable {
        /// The scripted counter of this container: one token per `Character`.
        let tokenCounter: any TokenCounter = CharacterTokenCounter()

        /// Whether the call with a one-based ordinal calls the tool.
        private let callsTool: @Sendable (Int) -> Bool

        /// The backend the last vend made.
        private let vended = Mutex<Backend?>(nil)

        /// Makes a container.
        ///
        /// - Parameter callsTool: Whether the call with a one-based ordinal of
        ///   each vended backend calls the tool.
        init(callsTool: @escaping @Sendable (Int) -> Bool) {
            self.callsTool = callsTool
        }

        /// The backend the last vend made, or `nil` before a vend.
        var lastBackend: Backend? { vended.withLock { $0 } }

        func makeSession(instructions: String?) -> any LanguageModelSessionBackend {
            makeSession(instructions: instructions, tools: [])
        }

        func makeSession(instructions: String?, tools: [any Tool]) -> any LanguageModelSessionBackend {
            let backend = Backend(tools: tools, callsTool: callsTool)
            vended.withLock { $0 = backend }
            return backend
        }

        func makeSession(transcript: Transcript) -> any LanguageModelSessionBackend {
            StubSessionBackend(entries: Array(transcript))
        }
    }

    // MARK: - Session

    /// One session over a ``Backend``, with what a test reads.
    struct Session: Sendable {
        /// The session under test.
        let session: any RoutedSession

        /// The backend the session runs on.
        let backend: Backend

        /// The gates of the runs of the fixture tool.
        let gates: RunGates

        /// The feed of the session's events.
        let events: SessionEventLog

        /// The task that drains ``events``.
        let drain: Task<Void, Never>

        /// The router that keeps the models of the session resident.
        let router: Router

        /// The temporary directory the router caches under.
        let directory: URL

        /// Makes a session with `limit` and the one fixture tool that `tool`
        /// makes, and watches its events. The run plane of the session has a
        /// manual clock, so no settle period ends.
        ///
        /// - Parameters:
        ///   - prefix: The prefix of the temporary directory of the router.
        ///   - limit: The ``SessionConfiguration/mailOnlyAnswerLimit`` of the
        ///     session. The default is ``MailOnlyAnswerFixtures/limit``.
        ///   - gates: The gates of the runs of the fixture tool. The default
        ///     holds each run until the test settles it.
        ///   - tool: Makes the fixture tool of the session over `gates`. The
        ///     default makes a ``GatedJob`` with the name
        ///     ``MailOnlyAnswerFixtures/jobName``.
        ///   - callsTool: Whether the backend call with a one-based ordinal
        ///     calls the fixture tool.
        /// - Returns: The fixture.
        /// - Throws: What the resolve of the profile throws, or when the
        ///   container vended no backend. Before it throws, it closes the
        ///   session that it made and removes the directory.
        static func make(
            prefix: String, limit: Int = MailOnlyAnswerFixtures.limit, gates: RunGates = RunGates(),
            tool: (RunGates) -> any Tool = { GatedJob(name: MailOnlyAnswerFixtures.jobName, gates: $0) },
            callsTool: @escaping @Sendable (Int) -> Bool
        ) async throws -> Self {
            let tool = tool(gates)
            let directory = RouterTestFixtures.makeTempDir(prefix: prefix)
            let container = Container(callsTool: callsTool)
            let resolved = try await RouterTestFixtures.removingDirectoryOnThrow(directory) {
                try await RouterTestFixtures.resolveStandardProfile(
                    over: container, cacheDir: directory, runClock: ManualRunClock())
            }
            let session = resolved.profile.standard.makeSession(
                configuration: SessionConfiguration(tools: [tool], mailOnlyAnswerLimit: limit))
            let backend = try await RouterTestFixtures.removingDirectoryOnThrow(
                directory, alsoOnThrow: { await session.close() }
            ) {
                try #require(container.lastBackend)
            }
            let (events, drain) = await SessionEventLog.watch(session)
            return Self(
                session: session, backend: backend, gates: gates, events: events, drain: drain,
                router: resolved.router, directory: directory)
        }

        /// Sends `prompt` as a caller message, and waits until the pump ended
        /// its answer. The answer of the first caller message attaches the
        /// outbox of the session, so later mail wakes the pump.
        ///
        /// - Parameter prompt: The prompt of the caller message.
        /// - Throws: What the answer throws.
        func answerCallerPrompt(_ prompt: String) async throws {
            _ = try await session.respond(to: prompt)
            #expect(await session.pumpEnds())
        }

        /// Settles the one open run of the tool `name`, and waits until the
        /// pump handled its terminal: an answer delivered it, or the bound
        /// held it.
        ///
        /// - Parameter name: The name of the tool of the run. The default is
        ///   ``MailOnlyAnswerFixtures/jobName``.
        /// - Throws: When the run plane does not hold exactly one open run of
        ///   `name`, or ``ConditionNeverHeld`` when the test task was
        ///   cancelled first.
        func settleTheOpenRun(of name: String = MailOnlyAnswerFixtures.jobName) async throws {
            let runs = await session.runPlane.backgroundRuns().filter { $0.tool == name }
            try #require(runs.count == 1, "exactly one run of \(name) must be open")
            let token = try #require(runs.first).completionToken
            await gates.gate(of: token).open()
            _ = await session.runPlane.wait(completionToken: token, seconds: nil)
            try await waitUntilThePumpHandledTheTerminal(of: token)
        }

        /// Waits until the pump handled the terminal of the settled run
        /// `token`: no pump runs, and no terminal of the run waits in the
        /// queue unheld.
        ///
        /// The funnel of a run posts its terminal before the run plane settles
        /// the run, and the pump delivers a terminal only after the run
        /// settled. So the wake of that post can find nothing to deliver, and
        /// the wake of the settlement (`deliver(settledTerminal:)`) starts the
        /// answer. The end of each pump and each settlement are changes of
        /// ``RoutedSession/idleChanges``, so the wait reads the state again
        /// after each one.
        ///
        /// - Parameter token: The completion token of the settled run.
        /// - Throws: ``ConditionNeverHeld`` when the test task was cancelled
        ///   first.
        private func waitUntilThePumpHandledTheTerminal(of token: String) async throws {
            try await session.idleChanges.wait(until: {
                let pumpRunning = await session.isPumpRunning
                let terminalWaits = await session.outbox.pending().events.contains {
                    $0.event.correlationID == token && $0.event.kind == .completed && !$0.isHeld
                }
                return !pumpRunning && !terminalWaits
            })
        }

        /// Settles the open run of the tool `name` `count` times, one after
        /// the other. See ``settleTheOpenRun(of:)``.
        ///
        /// - Parameters:
        ///   - count: How many runs to settle.
        ///   - name: The name of the tool of the runs. The default is
        ///     ``MailOnlyAnswerFixtures/jobName``.
        /// - Throws: What ``settleTheOpenRun(of:)`` throws.
        func settleTheOpenRuns(_ count: Int, of name: String = MailOnlyAnswerFixtures.jobName) async throws {
            for _ in 0..<count {
                try await settleTheOpenRun(of: name)
            }
        }

        /// Settles the runs of one whole chain, one after the other: the run
        /// of the caller answer, then the run of each of the
        /// ``MailOnlyAnswerFixtures/limit`` answers that mail alone started.
        /// The bound holds the terminal of the last run.
        ///
        /// - Throws: What ``settleTheOpenRun(of:)`` throws.
        func settleTheRunsOfOneChain() async throws {
            try await settleTheOpenRuns(MailOnlyAnswerFixtures.promptsOfOneChain)
        }

        /// Waits until the session sent `count` pause events or more. A test
        /// reads the exact count from the events that ``end()`` gives, so a
        /// session that sends more pauses fails the test and does not hold
        /// the wait.
        ///
        /// - Parameter count: How many pause events to wait for.
        /// - Throws: ``ConditionNeverHeld`` when the test task was cancelled
        ///   first.
        func waitForPauses(_ count: Int) async throws {
            try await events.wait(until: { $0.mailDeliveryPauses.count >= count })
        }

        /// The mail that waits in the outbox of the session.
        ///
        /// - Returns: The pending mail events, in outbox order.
        func waitingMail() async -> [SessionOutbox.PendingEvent] {
            await session.outbox.pending().events
        }

        /// Ends the fixture: opens each gate, so no run body stays held,
        /// closes the session, and removes the directory.
        ///
        /// The close finishes the feed after the last event of the session,
        /// so the drain task ends after it appended that event.
        ///
        /// The end is idempotent, so a test can call it in its body to read
        /// the events and again from a `defer` (rule T1). Each step allows a
        /// second call: an open gate stays open, ``RoutedSession/close()`` is
        /// idempotent, the value of the ended drain task comes back at once,
        /// and the removal of a directory that is not there is a `try?`. A
        /// second call gives the same events as the first.
        ///
        /// - Returns: Each event of the feed, in delivery order.
        @discardableResult
        func end() async -> [SessionEvent] {
            await gates.openEachGate()
            await session.close()
            await drain.value
            try? FileManager.default.removeItem(at: directory)
            withExtendedLifetime(router) {}
            return await events.events
        }
    }

    // MARK: - A run that sends messages

    /// One open background run that sends messages to its session
    /// (`ToolContext.message(_:)`) and settles when a test settles it.
    struct MessagingRun {
        /// The session of the run.
        let session: any RoutedSession

        /// The completion token of the run.
        let token: String

        /// The gate that holds the body of the run.
        let gate: RunLatch

        /// The context of the run, which posts to the outbox of the session.
        let context: ToolContext

        /// Starts a run on the run plane of `session`.
        ///
        /// - Parameter session: The session of the run.
        /// - Returns: The run.
        static func start(on session: any RoutedSession) async -> Self {
            let gate = RunLatch()
            let token = await trackFakeRun(on: session.runPlane, latch: gate)
            let context = PendingElicitationFixtures.makeContext(
                for: session, postingTo: session.outbox, completionToken: token)
            return Self(session: session, token: token, gate: gate, context: context)
        }

        /// Sends `text` as a message of the run, and waits until the pump
        /// handled it: an answer delivered it, or the bound held it. The post
        /// of the message wakes the pump before it returns.
        ///
        /// - Parameter text: The text of the message.
        func send(_ text: String) async {
            await context.message(text)
            #expect(await session.pumpEnds())
        }

        /// Settles the run, posts its terminal as the funnel of a real run
        /// does, and waits until the pump handled the terminal.
        ///
        /// - Throws: When the run does not settle.
        func settle() async throws {
            await gate.open()
            let terminal = try await MountFixtures.settledTerminal(of: token, in: session.runPlane)
            await session.outbox.post(event: terminal)
            #expect(await session.pumpEnds())
        }
    }
}
