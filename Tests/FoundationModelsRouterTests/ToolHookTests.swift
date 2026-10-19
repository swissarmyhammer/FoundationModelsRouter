import Foundation
import FoundationModels
import FoundationModelsHooks
import Synchronization
import Testing

@testable import FoundationModelsRouter

/// Holds the tool hooks of a session (task ^8d73hct): each tool call that the
/// model makes gives `PreToolUse` before the tool body, `PreToolResult`
/// before the output goes to the model, and `PostToolUse` at the end.
///
/// Each test runs a scripted answer (``ScriptedSessionFixture``) through a
/// router with a dispatcher that holds a ``ToolRecordingVisitor``. The
/// scripted model calls a test tool, and then answers with the tool outputs
/// that its transcript holds (``ScriptedAnswerLog/deliveredToolOutputs``).
/// Each test closes the session and calls `dispatcher.drain()` before it
/// reads the post events, because a post event arrives on a task of the
/// dispatcher.
@Suite("Tool hooks: PreToolUse, PreToolResult and PostToolUse for each tool call")
struct ToolHookTests {
    /// The suite's temp-directory prefix, handed to
    /// ``RouterTestFixtures/makeTempDir(prefix:)``.
    private static let tempDirPrefix = "ToolHookTests"

    /// The id of the one tool call of each script.
    private static let callID = "hook-call-1"

    /// The reason that a blocking visitor gives.
    private static let blockReason = "the tool call is not allowed"

    /// The step that a replaced `argumentsJSON` names.
    private static let replacedStep = "REPLACED"

    /// The output that a replacing visitor puts in place of the tool output.
    private static let replacedOutput = "replaced tool output"

    /// Arguments that do not decode to ``AmbientToolArguments``: they have no
    /// `value`.
    private static let undecodableArguments = #"{"other":"x"}"#

    // MARK: - Fixtures

    /// A visitor that records each tool event, in the order of delivery, and
    /// gives each pre event the decision of the test.
    final class ToolRecordingVisitor: HookVisitor {
        /// One recorded tool event.
        enum Event: Equatable {
            /// A `PreToolUse`.
            case use(PreToolUse)
            /// A `PreToolResult`.
            case result(PreToolResult)
            /// A `PostToolUse`.
            case post(PostToolUse)
        }

        /// The recorded events, each with the hook session of its context.
        let recorder = HookEventRecorder<Event>()

        /// The decision that the visitor gives a `PreToolUse`.
        private let decideUse: @Sendable (PreToolUse) -> PreDecision<PreToolUse>

        /// The decision that the visitor gives a `PreToolResult`.
        private let decideResult: @Sendable (PreToolResult) -> PreDecision<PreToolResult>

        /// Makes a visitor.
        ///
        /// - Parameters:
        ///   - decideUse: The decision for each `PreToolUse`. The default lets
        ///     each call go on as it is.
        ///   - decideResult: The decision for each `PreToolResult`. The
        ///     default lets each output go on as it is.
        init(
            decideUse: @escaping @Sendable (PreToolUse) -> PreDecision<PreToolUse> = { _ in .proceed },
            decideResult: @escaping @Sendable (PreToolResult) -> PreDecision<PreToolResult> = { _ in .proceed }
        ) {
            self.decideUse = decideUse
            self.decideResult = decideResult
        }

        /// The recorded `PostToolUse` events, in the order of delivery.
        var posts: [PostToolUse] {
            recorder.events.compactMap { event in
                guard case .post(let post) = event else { return nil }
                return post
            }
        }

        /// Records a `PreToolUse`, and gives the decision of the test.
        ///
        /// - Parameter context: The session and the event.
        /// - Returns: The decision of the test.
        func pre(_ context: HookContext<PreToolUse>) async -> PreDecision<PreToolUse> {
            recorder.record(.use(context.event), of: context.session)
            return decideUse(context.event)
        }

        /// Records a `PreToolResult`, and gives the decision of the test.
        ///
        /// - Parameter context: The session and the event.
        /// - Returns: The decision of the test.
        func pre(_ context: HookContext<PreToolResult>) async -> PreDecision<PreToolResult> {
            recorder.record(.result(context.event), of: context.session)
            return decideResult(context.event)
        }

        /// Records a `PostToolUse`.
        ///
        /// - Parameter context: The session and the event.
        func post(_ context: HookContext<PostToolUse>) async {
            recorder.record(.post(context.event), of: context.session)
        }
    }

    /// A tool that records the `HookSession.current` of each call, and
    /// returns the marker of the step that the call names.
    final class HookSessionProbeTool: Tool, Sendable {
        /// The model-facing name of the tool.
        static let toolName = "hook-session-probe"

        /// The `Tool` name requirement, bound to ``toolName``.
        let name = HookSessionProbeTool.toolName

        /// The `Tool` description requirement.
        let description = "test-only tool that records the hook session of each call"

        /// The hook session of each call, in call order.
        private let seen = Mutex<[HookSession?]>([])

        /// The `HookSession.current` of each call, in call order.
        var seenSessions: [HookSession?] {
            seen.withLock { $0 }
        }

        /// Records `HookSession.current`, and returns the marker of the step.
        ///
        /// - Parameter arguments: The arguments of the call; `value` is the
        ///   step.
        /// - Returns: ``ScriptedToolFixture/marker(for:)`` for the step.
        func call(arguments: AmbientToolArguments) async throws -> String {
            let current = HookSession.current
            seen.withLock { $0.append(current) }
            return ScriptedToolFixture.marker(for: arguments.value)
        }
    }

    /// The structured output of ``StructuredMarkerTool``.
    @Generable
    struct StructuredMarker: Equatable {
        /// The step that the call named.
        let value: String
    }

    /// A tool whose output is not `String`: it returns the step that the
    /// call names as a ``StructuredMarker``.
    final class StructuredMarkerTool: Tool, Sendable {
        /// The model-facing name of the tool.
        static let toolName = "structured-marker"

        /// The `Tool` name requirement, bound to ``toolName``.
        let name = StructuredMarkerTool.toolName

        /// The `Tool` description requirement.
        let description = "test-only tool that returns a structured marker"

        /// Returns the step as a structure.
        ///
        /// - Parameter arguments: The arguments of the call; `value` is the
        ///   step.
        /// - Returns: The structured marker of the step.
        func call(arguments: AmbientToolArguments) async throws -> StructuredMarker {
            StructuredMarker(value: arguments.value)
        }
    }

    /// A scripted session of a router with a dispatcher, and what the test
    /// reads.
    private struct HookedToolSession: HookedSessionFixture {
        /// The scripted fixture behind the session.
        let fixture: ScriptedSessionFixture

        /// The dispatcher of the router.
        let dispatcher: HookDispatcher

        /// The visitor registered on ``dispatcher``.
        let visitor: ToolRecordingVisitor

        /// The session under test.
        var session: any RoutedSession {
            fixture.session
        }
    }

    /// Makes a scripted session through a router with a dispatcher that
    /// holds `visitor`, runs `body`, and ends the fixture.
    ///
    /// - Parameters:
    ///   - toolName: The tool that the one scripted call names.
    ///   - tools: The tools of the session.
    ///   - visitor: The visitor of the dispatcher.
    ///   - body: The test.
    /// - Throws: What the resolve or `body` throws.
    private static func withHookedSession(
        calling toolName: String,
        mounting tools: [any Tool],
        visitor: ToolRecordingVisitor = ToolRecordingVisitor(),
        _ body: (HookedToolSession) async throws -> Void
    ) async throws {
        let hookData = RouterTestFixtures.makeTempDir(prefix: tempDirPrefix)
        defer { try? FileManager.default.removeItem(at: hookData) }
        let dispatcher = HookDispatcher(dataDirectory: hookData)
        dispatcher.register(visitor)
        let fixture = try await ScriptedSessionFixture.make(
            playing: oneCall(to: toolName), mounting: tools, tempDirPrefix: tempDirPrefix, hooks: dispatcher)
        defer { await fixture.end() }
        try await body(HookedToolSession(fixture: fixture, dispatcher: dispatcher, visitor: visitor))
    }

    /// Runs the one scripted answer, whose one call names `tool`, on a
    /// session through a router with a dispatcher that holds `visitor`, and
    /// then runs `check`.
    ///
    /// - Parameters:
    ///   - tool: The one tool of the session, which the scripted call names.
    ///   - visitor: The visitor of the dispatcher.
    ///   - check: The assertions of the test. It gets the hooked session and
    ///     the events of the answer.
    /// - Throws: What the resolve, the answer or `check` throws.
    private static func withAnswer(
        calling tool: some Tool,
        visitor: ToolRecordingVisitor = ToolRecordingVisitor(),
        _ check: (HookedToolSession, [SessionEvent]) async throws -> Void
    ) async throws {
        try await withHookedSession(calling: tool.name, mounting: [tool], visitor: visitor) { hooked in
            let events = try await collectEvents(hooked.session, prompt: ScriptedToolFixture.prompt)
            try await check(hooked, events)
        }
    }

    /// Runs the one scripted answer that calls `tool` with a visitor that
    /// replaces each output (``outputReplacingVisitor()``), and expects that
    /// the model and the transcript get ``replacedOutput``.
    ///
    /// - Parameter tool: The one tool of the session.
    /// - Throws: What the answer throws.
    private static func checkReplacedOutput(of tool: some Tool) async throws {
        try await withAnswer(calling: tool, visitor: outputReplacingVisitor()) { hooked, _ in
            #expect(hooked.fixture.log.deliveredToolOutputs == [replacedOutput])
            #expect(recordedToolOutputs(of: hooked.fixture) == [replacedOutput])
        }
    }

    /// A script with one round that calls `toolName` one time with
    /// ``ScriptedToolFixture/firstStepName``.
    ///
    /// - Parameter toolName: The tool that the call names.
    /// - Returns: The script.
    private static func oneCall(to toolName: String) -> ScriptedAnswerScript {
        ScriptedAnswerScript(rounds: [
            [ScriptedToolCall(id: callID, toolName: toolName, argument: .literal(ScriptedToolFixture.firstStepName))]
        ])
    }

    /// The id and the arguments of each ``SessionEvent/toolCall(id:name:argumentsJSON:)``
    /// of `events`, in order.
    ///
    /// - Parameter events: The events of an answer.
    /// - Returns: The calls.
    private static func toolCalls(in events: [SessionEvent]) -> [(id: String, argumentsJSON: String)] {
        events.compactMap { event in
            guard case .toolCall(let id, _, let argumentsJSON) = event else { return nil }
            return (id, argumentsJSON)
        }
    }

    /// The hook session of `session`.
    ///
    /// - Parameter session: A session of a router with a dispatcher.
    /// - Returns: The hook session.
    /// - Throws: When the session has no hooks.
    private static func hookSession(of session: any RoutedSession) throws -> HookSession {
        let actor = try #require(session as? RoutedSessionActor)
        return try #require(actor.hooks).session
    }

    /// The text of each `.toolOutput` entry of the SDK transcript of
    /// `fixture`, in order.
    ///
    /// - Parameter fixture: The fixture whose answer ran.
    /// - Returns: The texts.
    private static func recordedToolOutputs(of fixture: ScriptedSessionFixture) -> [String] {
        ScriptedToolCallingModel.Executor.toolOutputTexts(in: Transcript(entries: fixture.transcriptEntries()))
    }

    /// The generated content of each structured segment of the `.toolOutput`
    /// entries of the SDK transcript of `fixture`, in order.
    ///
    /// - Parameter fixture: The fixture whose answer ran.
    /// - Returns: The JSON text of each structured segment.
    private static func recordedStructures(of fixture: ScriptedSessionFixture) -> [String] {
        fixture.transcriptEntries().flatMap { entry -> [String] in
            guard case .toolOutput(let output) = entry else { return [] }
            return output.segments.compactMap { segment in
                guard case .structure(let structure) = segment else { return nil }
                return structure.content.jsonString
            }
        }
    }

    /// A visitor that replaces the output of each `PreToolResult` with
    /// ``replacedOutput``.
    ///
    /// - Returns: The new visitor.
    private static func outputReplacingVisitor() -> ToolRecordingVisitor {
        ToolRecordingVisitor(decideResult: { event in
            .replace(
                PreToolResult(
                    toolCallID: event.toolCallID, toolName: event.toolName, argumentsJSON: event.argumentsJSON,
                    output: replacedOutput))
        })
    }

    // MARK: - No hook

    /// The production change that makes this test fail: a tool body that
    /// sees a hook session in a session of a router with no dispatcher.
    @Test("a session of a router with no dispatcher binds no hook session")
    func aRouterWithNoDispatcherBindsNoHookSession() async throws {
        let probe = HookSessionProbeTool()
        let fixture = try await ScriptedSessionFixture.make(
            playing: Self.oneCall(to: HookSessionProbeTool.toolName), mounting: [probe],
            tempDirPrefix: Self.tempDirPrefix)
        defer { await fixture.end() }

        _ = try await collectEvents(fixture.session, prompt: ScriptedToolFixture.prompt)

        #expect(probe.seenSessions == [nil])
        #expect(fixture.log.deliveredToolOutputs == [ScriptedToolFixture.marker(for: ScriptedToolFixture.firstStepName)])
    }

    /// The production change that makes this test fail: a checked tool that
    /// runs a hook or binds a hook session when it runs outside a model call.
    @Test("a tool call outside a model call runs no hook")
    func aCallOutsideAModelCallRunsNoHook() async throws {
        let probe = HookSessionProbeTool()
        try await Self.withHookedSession(calling: HookSessionProbeTool.toolName, mounting: [probe]) { hooked in
            let checked = try #require(probe.sessionChecked as? any Tool<AmbientToolArguments, String>)

            let output = try await checked.call(arguments: AmbientToolArguments(value: ScriptedToolFixture.firstStepName))
            await hooked.closeAndDrain()

            #expect(output == ScriptedToolFixture.marker(for: ScriptedToolFixture.firstStepName))
            #expect(probe.seenSessions == [nil])
            #expect(hooked.visitor.recorder.events.isEmpty)
        }
    }

    // MARK: - The three events

    /// The production change that makes this test fail: a tool call that
    /// sends no tool event, sends them out of order, or names another id than
    /// the id of its ``SessionEvent/toolCall(id:name:argumentsJSON:)``.
    @Test("one tool call gives PreToolUse, PreToolResult and PostToolUse in order, with the id of its toolCall event")
    func oneToolCallGivesTheThreeEventsInOrder() async throws {
        try await Self.withAnswer(calling: MarkerEmittingTool()) { hooked, events in
            await hooked.closeAndDrain()

            let call = try #require(Self.toolCalls(in: events).first)
            let name = MarkerEmittingTool.toolName
            let output = ScriptedToolFixture.marker(for: ScriptedToolFixture.firstStepName)
            #expect(
                hooked.visitor.recorder.events == [
                    .use(PreToolUse(toolCallID: call.id, toolName: name, argumentsJSON: call.argumentsJSON)),
                    .result(
                        PreToolResult(
                            toolCallID: call.id, toolName: name, argumentsJSON: call.argumentsJSON, output: output)),
                    .post(
                        PostToolUse(
                            toolCallID: call.id, toolName: name, argumentsJSON: call.argumentsJSON, output: output,
                            succeeded: true)),
                ])
        }
    }

    /// The production change that makes this test fail: a tool body that
    /// does not see the hook session of the session that made the call.
    @Test("inside a tool body HookSession.current is the hook session of the calling session")
    func aToolBodySeesTheHookSessionOfItsSession() async throws {
        let probe = HookSessionProbeTool()
        try await Self.withAnswer(calling: probe) { hooked, _ in
            let session = try Self.hookSession(of: hooked.session)
            #expect(probe.seenSessions == [session])
        }
    }

    /// The production change that makes this test fail: a fork whose tool
    /// body sees the hook session of its parent, or none.
    @Test("inside a tool body of a fork HookSession.current is the hook session of the fork")
    func aToolBodyOfAForkSeesTheHookSessionOfTheFork() async throws {
        let probe = HookSessionProbeTool()
        try await Self.withHookedSession(calling: HookSessionProbeTool.toolName, mounting: [probe]) { hooked in
            let fork = try await hooked.session.fork(workingDirectory: nil)
            _ = try await collectEvents(fork, prompt: ScriptedToolFixture.prompt)
            let forkSession = try Self.hookSession(of: fork)
            await fork.close()

            #expect(forkSession != (try Self.hookSession(of: hooked.session)))
            #expect(probe.seenSessions == [forkSession])
        }
    }

    // MARK: - Sub-agent

    /// Runs one scripted answer on a sub-agent of the session of `hooked`,
    /// whose one tool is `probe`.
    ///
    /// - Parameters:
    ///   - hooked: The hooked session that starts the sub-agent.
    ///   - probe: The tool of the sub-agent.
    /// - Returns: The hook session of the sub-agent.
    /// - Throws: What the answer throws.
    private static func runSubagentAnswer(
        of hooked: HookedToolSession, mounting probe: HookSessionProbeTool
    ) async throws -> HookSession {
        let child = hooked.fixture.profile.standard.makeSession(
            configuration: SessionConfiguration(tools: [probe], parentCall: .startAgentCall(of: hooked.session)))
        _ = try await collectEvents(child, prompt: ScriptedToolFixture.prompt)
        let childSession = try hookSession(of: child)
        await child.close()
        return childSession
    }

    /// The production change that makes this test fail: a sub-agent whose
    /// tool body sees the hook session of its parent, or none.
    @Test("inside a tool body of a sub-agent HookSession.current is the hook session of the sub-agent")
    func aToolBodyOfASubagentSeesTheHookSessionOfTheSubagent() async throws {
        let probe = HookSessionProbeTool()
        try await Self.withHookedSession(calling: HookSessionProbeTool.toolName, mounting: []) { hooked in
            let childSession = try await Self.runSubagentAnswer(of: hooked, mounting: probe)

            #expect(childSession.parentSessionID == hooked.session.id.description)
            #expect(probe.seenSessions == [childSession])
        }
    }

    /// The production change that makes this test fail: tool events that
    /// only a root session sends.
    @Test("a sub-agent session also emits the tool events, with its own hook session")
    func aSubagentEmitsTheToolEvents() async throws {
        let probe = HookSessionProbeTool()
        try await Self.withHookedSession(calling: HookSessionProbeTool.toolName, mounting: []) { hooked in
            let childSession = try await Self.runSubagentAnswer(of: hooked, mounting: probe)
            await hooked.closeAndDrain()

            #expect(hooked.visitor.recorder.events.count == 3)
            #expect(hooked.visitor.recorder.sessions == Array(repeating: childSession, count: 3))
        }
    }

    // MARK: - PreToolUse decisions

    /// The production change that makes this test fail: a block that still
    /// runs the tool body, or that gives the model another output.
    @Test("a block on PreToolUse does not run the tool body, and the model gets the reason as the output")
    func aBlockDoesNotRunTheBody() async throws {
        let tool = MarkerEmittingTool()
        let visitor = ToolRecordingVisitor(decideUse: { _ in .block(reason: Self.blockReason) })
        try await Self.withAnswer(calling: tool, visitor: visitor) { hooked, _ in
            await hooked.closeAndDrain()

            #expect(tool.calledSteps.isEmpty)
            #expect(hooked.fixture.log.deliveredToolOutputs == [Self.blockReason])
            let post = try #require(hooked.visitor.posts.first)
            #expect(post.output == Self.blockReason)
            #expect(!post.succeeded)
        }
    }

    /// The production change that makes this test fail: a replaced
    /// `argumentsJSON` that the tool body does not get.
    @Test("a replaced argumentsJSON is what the tool body gets")
    func aReplacedArgumentsJSONReachesTheBody() async throws {
        let tool = MarkerEmittingTool()
        let visitor = ToolRecordingVisitor(decideUse: { event in
            .replace(
                PreToolUse(
                    toolCallID: event.toolCallID, toolName: event.toolName,
                    argumentsJSON: #"{"value":"\#(Self.replacedStep)"}"#))
        })
        try await Self.withAnswer(calling: tool, visitor: visitor) { hooked, _ in
            #expect(tool.calledSteps == [Self.replacedStep])
            #expect(hooked.fixture.log.deliveredToolOutputs == [ScriptedToolFixture.marker(for: Self.replacedStep)])
        }
    }

    /// The production change that makes this test fail: a replacement that
    /// does not decode and still runs the tool body, or that gives the model
    /// another output than the decode error.
    @Test("a replaced argumentsJSON that does not decode gives the decode error as the output")
    func anUndecodableReplacementGivesTheDecodeError() async throws {
        let tool = MarkerEmittingTool()
        let visitor = ToolRecordingVisitor(decideUse: { event in
            .replace(
                PreToolUse(
                    toolCallID: event.toolCallID, toolName: event.toolName, argumentsJSON: Self.undecodableArguments))
        })
        let decodeError = #expect(throws: (any Error).self) {
            try AmbientToolArguments(GeneratedContent(json: Self.undecodableArguments))
        }
        let expectedOutput = String(describing: try #require(decodeError))
        try await Self.withAnswer(calling: tool, visitor: visitor) { hooked, _ in
            #expect(tool.calledSteps.isEmpty)
            #expect(hooked.fixture.log.deliveredToolOutputs == [expectedOutput])
        }
    }

    // MARK: - PreToolResult and PostToolUse

    /// The production change that makes this test fail: a replaced output
    /// that the model or the transcript does not get.
    @Test("a replaced output on PreToolResult is what the model gets and what the transcript records")
    func aReplacedOutputReachesTheModelAndTheTranscript() async throws {
        try await Self.checkReplacedOutput(of: MarkerEmittingTool())
    }

    /// The production change that makes this test fail: a tool body that
    /// throws and gives no `PostToolUse`, or one that says it succeeded.
    @Test("a tool body that throws gives PostToolUse with succeeded false")
    func aThrowingBodyGivesAFailedPostToolUse() async throws {
        try await Self.withAnswer(calling: ThrowingMarkerTool()) { hooked, events in
            await hooked.closeAndDrain()

            let call = try #require(Self.toolCalls(in: events).first)
            let name = ThrowingMarkerTool.toolName
            let failure = ThrowingMarkerTool.CallFailure(step: ScriptedToolFixture.firstStepName).description
            #expect(
                hooked.visitor.recorder.events == [
                    .use(PreToolUse(toolCallID: call.id, toolName: name, argumentsJSON: call.argumentsJSON)),
                    .post(
                        PostToolUse(
                            toolCallID: call.id, toolName: name, argumentsJSON: call.argumentsJSON, output: failure,
                            succeeded: false)),
                ])
            #expect(hooked.fixture.log.deliveredToolOutputs == [failure])
        }
    }

    // MARK: - A tool whose output is not text

    /// The production change that makes this test fail: a hook layer that
    /// changes the recorded structure of a tool whose output no visitor
    /// replaced.
    @Test("a structured output that no visitor replaces is recorded as before")
    func aStructuredOutputIsRecordedAsBefore() async throws {
        try await Self.withAnswer(calling: StructuredMarkerTool()) { hooked, _ in
            let expected = StructuredMarker(value: ScriptedToolFixture.firstStepName).generatedContent.jsonString
            #expect(Self.recordedStructures(of: hooked.fixture) == [expected])
        }
    }

    /// The production change that makes this test fail: a replaced output of
    /// a structured tool that the model or the transcript does not get. The
    /// SDK records the replaced text as a text segment.
    @Test("a replaced output of a structured tool is what the model gets and what the transcript records")
    func aReplacedStructuredOutputIsRecorded() async throws {
        try await Self.checkReplacedOutput(of: StructuredMarkerTool())
    }
}
