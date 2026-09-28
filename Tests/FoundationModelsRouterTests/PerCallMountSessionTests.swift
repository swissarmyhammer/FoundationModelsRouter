import Foundation
import FoundationModels
import Testing

@testable import FoundationModelsExtras
@testable import FoundationModelsRouter

/// Tests, through a ``RoutedSession``, that each call of a tool chooses its
/// own mount (task ^3rr9rn4), and that the terminal of each settled
/// background run is staged one time and starts the next submission as mail.
///
/// A synchronous call returns its real output in band. A background call
/// returns a pending envelope, and its terminal comes back as mail. The
/// `OperationTool` case is the `agents` tool of FoundationModelsAgents: one
/// background operation and three synchronous ones. A background run that a
/// synchronous call starts through `ToolContext.mount(_:op:as:)` has a token
/// of its own, and its terminal comes back as mail too.
///
/// The Extras mount layer posts the terminal of EACH background run, nested
/// or not, to the sink of the session through the funnel of that run. The
/// sink is the outbox, which stages the terminal one time and wakes the pump.
/// The settlement of the run plane only journals the terminal, and the
/// journal refuses the second write. So a terminal is staged one time, and
/// these tests count each terminal line over every prompt the model got.
///
/// A scripted backend makes the tool calls, and ``RunLatch`` gates hold each
/// run. No wait has a wall clock: each wait reads a state until it holds, and
/// the `.timeLimit` of the suite ends a wait for a state that never comes.
@Suite(
    "Per-call mount: each call chooses synchronous or background, and each settled background run's terminal is staged one time",
    .timeLimit(.minutes(1)))
struct PerCallMountSessionTests {
    // MARK: - Vocabulary

    /// The prefix of the temporary directory of each test.
    private static let tempDirPrefix = "PerCallMountSessionTests"

    /// The inline settle grace of the per-call tool in the synchronous test.
    /// A background call would wait this long for its run and then answer.
    private static let inlineSettleGrace: TimeInterval = 0.01

    /// The value of a call that the per-call tool runs synchronously.
    private static let synchronousValue = "synchronous call"

    /// The value of a call that the per-call tool runs in the background.
    private static let backgroundValue = "background call"

    /// The value of the inner call of the nesting tool.
    private static let nestedValue = "nested call"

    // MARK: - Tools

    /// A tool that chooses the mount of each call from its argument: the
    /// ``PerCallMountSessionTests/synchronousValue`` runs synchronously, and
    /// each other value runs in the background. It declares no tool-wide
    /// mount, so the host mount is synchronous, and only the per-call answer
    /// makes a call run in the background.
    ///
    /// Its body opens `entered`, waits for `gate`, and returns
    /// ``output(for:)``.
    private struct PerCallMountTool: Tool, BackgroundTool {
        /// The name of the tool, which a scripted call names.
        static let toolName = "per_call_mount_tool"

        let name = toolName
        let description = "runs each call with the mount that its argument names"

        /// Opened when a body starts, so a test knows the call is in flight.
        let entered: RunLatch

        /// The latch the body waits on before it returns.
        let gate: RunLatch

        /// The inline settle grace of a background call, or `nil` for none.
        let grace: TimeInterval?

        /// The output of a call with `value`.
        ///
        /// - Parameter value: The argument of the call.
        /// - Returns: The output text.
        static func output(for value: String) -> String {
            "done: \(value)"
        }

        var inlineSettleGrace: TimeInterval? { grace }

        func mount(for arguments: GeneratedContent) -> ToolMount? {
            let value = try? arguments.value(String.self, forProperty: "value")
            return value == PerCallMountSessionTests.synchronousValue
                ? .synchronous : ToolMount(mode: .background, timeout: nil)
        }

        func call(arguments: MountArguments) async throws -> String {
            await entered.open()
            await gate.waitUntilOpen()
            return Self.output(for: arguments.value)
        }
    }

    /// A synchronous tool whose body mounts a ``MountFixtures/GatedTool`` as
    /// background on its own ``ToolContext``, calls it, and returns the
    /// envelope of that nested run in band.
    private struct NestingSynchronousTool: Tool, BackgroundTool {
        let name = "nesting_synchronous_tool"
        let description = "starts a background run from inside a synchronous call"

        /// The prefix of the output before the nested envelope.
        static let outputPrefix = "nested: "

        /// The latch the nested run waits on.
        let gate: RunLatch

        var mount: ToolMount? { .synchronous }

        func call(arguments: MountArguments) async throws -> String {
            let context = try #require(ToolContext.current)
            let nested = context.mount(MountFixtures.GatedTool(gate: gate), as: ToolMount(mode: .background, timeout: nil))
            return Self.outputPrefix + (try await nested.call(arguments: MountArguments(value: PerCallMountSessionTests.nestedValue)))
        }
    }

    // MARK: - Harness

    /// One session over a ``MountCallingBackend``, with its recorder and its
    /// temporary directory.
    private struct Harness {
        /// The session under test.
        let session: RoutedSession

        /// The backend that makes the scripted calls.
        let backend: MountCallingBackend

        /// The recorder that the session journals through.
        let recorder: InMemoryRecorder

        /// The temporary directory to remove.
        let directory: URL

        /// Waits until the backend got `count` prompts and the pump of the
        /// session stopped, and returns the prompts.
        ///
        /// - Parameter count: The count of prompts to wait for.
        /// - Returns: Every prompt the backend got, in order.
        /// - Throws: ``ConditionNeverHeld`` when the `.timeLimit` of the
        ///   suite ended the wait.
        func promptsAfterThePumpStops(atLeast count: Int) async throws -> [String] {
            try await AwaitedCondition.wait(until: { backend.receivedPrompts.count >= count })
            try await AwaitedCondition.wait(until: { await !session.isPumpRunning })
            return backend.receivedPrompts
        }
    }

    /// Makes a session that mounts `tools`, whose first submission makes
    /// `calls`.
    ///
    /// - Parameters:
    ///   - tools: The tools of the session.
    ///   - calls: The calls of the first submission.
    /// - Returns: The harness.
    /// - Throws: What profile resolution throws.
    private static func makeHarness(tools: [any Tool], calls: [ScriptedMountCall]) async throws -> Harness {
        let directory = RouterTestFixtures.makeTempDir(prefix: tempDirPrefix)
        let recorder = InMemoryRecorder()
        let container = MountCallingLLMContainer(calls: calls)
        let router = RouterTestFixtures.makeRouter(
            cacheDir: directory,
            recorder: recorder,
            loader: StubModelLoader(container: container, dimension: RouterTestFixtures.stubDimension)
        )
        let profile = try await router.resolve(profile: RouterTestFixtures.profile(), reporting: ResolutionProgress())
        let session = profile.standard.makeSession(tools: tools)
        let backend = try #require(container.lastBackend)
        return Harness(session: session, backend: backend, recorder: recorder, directory: directory)
    }

    /// The call of the per-call tool with `value`.
    ///
    /// - Parameter value: The argument of the call.
    /// - Returns: The scripted call.
    private static func perCallMountCall(value: String) -> ScriptedMountCall {
        ScriptedMountCall(toolName: PerCallMountTool.toolName, argumentsJSON: #"{"value":"\#(value)"}"#)
    }

    /// Waits for the run of `token` to settle, with no deadline, and returns
    /// its terminal.
    ///
    /// - Parameters:
    ///   - token: The completion token of the run.
    ///   - session: The session whose run plane tracks the run.
    /// - Returns: The terminal event of the run.
    /// - Throws: ``SignalNeverArrived`` when the wait ended and the run did
    ///   not settle.
    private static func settledTerminal(of token: String, on session: RoutedSession) async throws -> OperationEvent {
        let outcome = await session.mailbox.wait(completionToken: token, seconds: nil)
        guard case .settled(let terminal) = outcome else {
            Issue.record("expected run \(token) to settle, got \(outcome)")
            throw SignalNeverArrived()
        }
        return terminal
    }

    /// Checks that `terminal` reached the model one time, in the one
    /// submission after the first, and that this submission was a delivery
    /// that the terminal started as mail.
    ///
    /// - Parameters:
    ///   - terminal: The terminal of the settled background run.
    ///   - harness: The harness of the test.
    /// - Throws: ``ConditionNeverHeld`` when the `.timeLimit` of the suite
    ///   ended a wait.
    private static func expectDeliveredOneTime(_ terminal: OperationEvent, in harness: Harness) async throws {
        let prompts = try await harness.promptsAfterThePumpStops(atLeast: 2)
        let line = OperationEventSegment.renderedLine(for: terminal)
        #expect(prompts.count == 2)
        #expect(prompts.last?.hasSuffix(RoutedSessionActor.settledRunDeliveryPrompt) == true)
        #expect(prompts.joined(separator: "\n").components(separatedBy: line).count - 1 == 1)
        #expect(await harness.session.outbox.pending().events.isEmpty)
    }

    /// The journaled terminals under `token`, read from the `.toolOutput`
    /// entries of the recorder.
    ///
    /// - Parameters:
    ///   - recorder: The recorder of the session.
    ///   - token: The completion token of the run.
    /// - Returns: Every journaled `.completed` event under `token`.
    private static func journaledTerminals(in recorder: InMemoryRecorder, for token: String) async -> [OperationEvent] {
        await recorder.events.filter { $0.kind == .toolOutput }.flatMap(\.operationEvents).filter {
            $0.kind == .completed && $0.correlationID == token
        }
    }

    // MARK: - A synchronous call answers in band

    @Test("a call whose mount(for:) gives synchronous returns its real output in band, also when it takes longer than inlineSettleGrace")
    func aSynchronousCallReturnsItsOutputInBand() async throws {
        let entered = RunLatch()
        let gate = RunLatch()
        let tool = PerCallMountTool(entered: entered, gate: gate, grace: Self.inlineSettleGrace)
        let harness = try await Self.makeHarness(
            tools: [tool], calls: [Self.perCallMountCall(value: Self.synchronousValue)])
        defer { try? FileManager.default.removeItem(at: harness.directory) }

        let answering = Task { try await harness.session.respond(to: "run it in band") }
        await entered.waitUntilOpen()
        // The body is held, and the run plane has no run: a background call
        // starts its run before its body runs, so this call runs in band.
        #expect(await harness.session.mailbox.backgroundRuns().isEmpty)
        // This sleep only makes the call longer than the grace. No assertion
        // waits on a clock.
        try await Task.sleep(for: .seconds(Self.inlineSettleGrace))
        await gate.open()

        let answer = try await answering.value
        #expect(answer == PerCallMountTool.output(for: Self.synchronousValue))
        #expect(!PendingRunEnvelope.isRendered(text: answer))
        // A synchronous call that succeeds posts no terminal, so no mail
        // starts a submission.
        let prompts = try await harness.promptsAfterThePumpStops(atLeast: 1)
        #expect(prompts.count == 1)
    }

    // MARK: - A background call returns a pending envelope

    @Test("a call whose mount(for:) gives background returns a pending envelope, also when it ends at once, and its terminal starts the next submission as mail")
    func aBackgroundCallReturnsAPendingEnvelopeAndItsTerminalStartsASubmission() async throws {
        let entered = RunLatch()
        let gate = RunLatch()
        await gate.open()
        let tool = PerCallMountTool(entered: entered, gate: gate, grace: nil)
        let harness = try await Self.makeHarness(
            tools: [tool], calls: [Self.perCallMountCall(value: Self.backgroundValue)])
        defer { try? FileManager.default.removeItem(at: harness.directory) }

        let answer = try await harness.session.respond(to: "run it in the background")
        let envelope = try MountFixtures.decodeEnvelope(answer)
        #expect(envelope.pending)
        #expect(envelope.outcome == nil)

        let terminal = try await Self.settledTerminal(of: envelope.completionToken, on: harness.session)
        #expect(terminal.outcome == .succeeded)
        #expect(terminal.detail == PerCallMountTool.output(for: Self.backgroundValue))
        try await Self.expectDeliveredOneTime(terminal, in: harness)
    }

    // MARK: - An OperationTool with one background operation

    @Test("an OperationTool with one background operation and three synchronous operations: start returns a token, list, check and cancel answer in band, and the start terminal starts a submission")
    func anOperationToolRunsEachOperationWithItsOwnMount() async throws {
        let startGate = RunLatch()
        let agent = AgentOperationFixtures.agentName
        let operations: [(op: String, name: String?)] = [
            ("start agent", agent), ("list agents", nil), ("check agent", agent), ("cancel agent", agent),
        ]
        let calls = operations.map { op, name in
            ScriptedMountCall(
                toolName: AgentOperationFixtures.toolName,
                argumentsJSON: AgentOperationFixtures.arguments(op: op, name: name))
        }
        let harness = try await Self.makeHarness(
            tools: [try AgentOperationFixtures.makeTool(startGate: startGate)], calls: calls)
        defer { try? FileManager.default.removeItem(at: harness.directory) }

        let answer = try await harness.session.respond(to: "start, list, check and cancel")
        let outputs = harness.backend.toolOutputs
        try #require(outputs.count == calls.count)

        // `start agent` returned a token, and its run still waits.
        let envelope = try MountFixtures.decodeEnvelope(outputs[0])
        #expect(envelope.pending)
        #expect(await harness.session.mailbox.backgroundRuns().map(\.completionToken) == [envelope.completionToken])

        // The three synchronous operations answered in band.
        #expect(outputs[1] == (try AgentOperationFixtures.encodedOutput("listed \(agent)")))
        #expect(outputs[2] == (try AgentOperationFixtures.encodedOutput("checked \(agent)")))
        #expect(outputs[3] == (try AgentOperationFixtures.encodedOutput("cancelled \(agent)")))
        #expect(answer == outputs[3])

        await startGate.open()
        let terminal = try await Self.settledTerminal(of: envelope.completionToken, on: harness.session)
        #expect(terminal.detail == (try AgentOperationFixtures.encodedOutput("started \(agent)")))
        try await Self.expectDeliveredOneTime(terminal, in: harness)
    }

    // MARK: - A background run that a synchronous call starts

    @Test("a background mount from inside a synchronous call gives a token, and its terminal is staged one time and starts a submission")
    func aNestedBackgroundRunDeliversItsTerminalAsMail() async throws {
        let gate = RunLatch()
        let tool = NestingSynchronousTool(gate: gate)
        let harness = try await Self.makeHarness(
            tools: [tool],
            calls: [ScriptedMountCall(toolName: tool.name, argumentsJSON: #"{"value":"outer call"}"#)])
        defer { try? FileManager.default.removeItem(at: harness.directory) }

        // The synchronous call answers in band with the envelope of the
        // nested run.
        let answer = try await harness.session.respond(to: "start a nested run")
        #expect(answer.hasPrefix(NestingSynchronousTool.outputPrefix))
        let envelope = try MountFixtures.decodeEnvelope(String(answer.dropFirst(NestingSynchronousTool.outputPrefix.count)))
        #expect(envelope.pending)
        #expect(await harness.session.mailbox.backgroundRuns().map(\.completionToken) == [envelope.completionToken])

        await gate.open()
        let terminal = try await Self.settledTerminal(of: envelope.completionToken, on: harness.session)
        #expect(terminal.correlationID == envelope.completionToken)
        #expect(terminal.detail == "gated: \(Self.nestedValue)")
        try await Self.expectDeliveredOneTime(terminal, in: harness)
        #expect(await Self.journaledTerminals(in: harness.recorder, for: envelope.completionToken) == [terminal])
    }
}
