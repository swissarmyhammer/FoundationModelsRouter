import Foundation
import FoundationModels
import FoundationModelsHooks
import FoundationModelsRouter
import FoundationModelsRouterTestSupport
import Testing

/// Holds ``HookLayeredLLMContainer`` of `FoundationModelsRouterTestSupport`
/// (task ^fk069kg): a scripted container whose backend calls its tools
/// directly gives no tool events, and the same container in a
/// ``HookLayeredLLMContainer`` gives `PreToolUse`, `PreToolResult` and
/// `PostToolUse`, as the live loader does.
///
/// This file imports each module with a plain `import`, as a host test does.
/// Thus each test uses only the public API of Router and of the test support
/// library. The scripted container is ``MountCallingLLMContainer``: its
/// backend calls the tools of the session directly, as the scripted model of
/// a host does.
///
/// Each test closes the session and calls `dispatcher.drain()` before it
/// reads the post events, because a post event arrives on a task of the
/// dispatcher.
@Suite("HookLayeredLLMContainer: a scripted container whose tools have the tool hook layer")
struct ScriptedToolHookLayerTests {
    /// The suite's temp-directory prefix, handed to
    /// ``RouterTestFixtures/makeTempDir(prefix:)``.
    private static let tempDirPrefix = "ScriptedToolHookLayerTests"

    /// The name of the folder of the hook data, in the temp directory.
    private static let hookDataFolderName = "hooks"

    /// The reason that a blocking visitor gives.
    private static let blockReason = "the tool call is not allowed"

    /// The prompt of each answer.
    private static let prompt = "call the tool"

    /// The output of a call of ``MarkerEmittingTool`` with the step of the
    /// scripted call.
    private static let markerOutput = ScriptedToolFixture.marker(for: ScriptedToolFixture.firstStepName)

    // MARK: - Fixtures

    /// A scripted session of a router with a dispatcher, and what the test
    /// reads.
    private struct Harness: HookedSessionFixture {
        /// The session under test.
        let session: any RoutedSession

        /// The dispatcher of the router.
        let dispatcher: HookDispatcher

        /// The visitor registered on ``dispatcher``.
        let visitor: ToolHookTests.ToolRecordingVisitor
    }

    /// The container of the router of a test.
    private enum ContainerShape {
        /// The scripted container in a ``HookLayeredLLMContainer``.
        case hookLayered
        /// The scripted container alone.
        case plain
    }

    /// Makes a scripted session of a router with a dispatcher that holds
    /// `visitor`, runs `body`, and removes the temp directory.
    ///
    /// The one tool of the session is `tool`. The first submission of each
    /// backend calls `tool` one time with
    /// ``ScriptedToolFixture/firstStepName``.
    ///
    /// - Parameters:
    ///   - tool: The one tool of the session.
    ///   - shape: The container of the router. The default is
    ///     ``ContainerShape/hookLayered``.
    ///   - visitor: The visitor of the dispatcher.
    ///   - body: The test.
    /// - Throws: What the resolve or `body` throws.
    private static func withSession(
        calling tool: some Tool,
        in shape: ContainerShape = .hookLayered,
        visitor: ToolHookTests.ToolRecordingVisitor = ToolHookTests.ToolRecordingVisitor(),
        _ body: (Harness) async throws -> Void
    ) async throws {
        let directory = RouterTestFixtures.makeTempDir(prefix: tempDirPrefix)
        defer { try? FileManager.default.removeItem(at: directory) }
        let dispatcher = HookDispatcher(dataDirectory: directory.appendingPathComponent(hookDataFolderName))
        dispatcher.register(visitor)
        let scripted = MountCallingLLMContainer(calls: [
            ScriptedMountCall(
                toolName: tool.name, argumentsJSON: #"{"value":"\#(ScriptedToolFixture.firstStepName)"}"#)
        ])
        let container: any LoadedLLMContainer =
            switch shape {
            case .hookLayered: HookLayeredLLMContainer(wrapping: scripted)
            case .plain: scripted
            }
        let router = RouterTestFixtures.makeRouter(
            cacheDir: directory,
            loader: StubModelLoader(container: container, dimension: RouterTestFixtures.stubDimension),
            hooks: dispatcher)
        let profile = try await router.resolve(profile: RouterTestFixtures.profile(), reporting: ResolutionProgress())
        let session = profile.standard.makeSession(configuration: SessionConfiguration(tools: [tool]))
        let harness = Harness(session: session, dispatcher: dispatcher, visitor: visitor)
        // A test that throws before its own close still closes the session.
        defer { await harness.closeAndDrain() }
        try await body(harness)
    }

    /// The first `PreToolUse` of `events`.
    ///
    /// - Parameter events: The recorded tool events.
    /// - Returns: The first `PreToolUse`, or `nil` when `events` has none.
    private static func firstUse(in events: [ToolHookTests.ToolRecordingVisitor.Event]) -> PreToolUse? {
        events.lazy.compactMap { event -> PreToolUse? in
            guard case .use(let use) = event else { return nil }
            return use
        }.first
    }

    // MARK: - The three events

    /// The production change that makes this test fail: a container that
    /// gives the tools of a session no hook layer, or a layer that sends the
    /// tool events out of order.
    @Test("one tool call through the container gives PreToolUse, PreToolResult and PostToolUse in order")
    func oneToolCallGivesTheThreeEventsInOrder() async throws {
        try await Self.withSession(calling: MarkerEmittingTool()) { harness in
            let answer = try await harness.session.respond(to: Self.prompt)
            await harness.closeAndDrain()

            let events = harness.visitor.recorder.events
            let use = try #require(Self.firstUse(in: events))
            let name = MarkerEmittingTool.toolName
            #expect(answer == Self.markerOutput)
            #expect(
                try AmbientToolArguments(GeneratedContent(json: use.argumentsJSON)).value
                    == ScriptedToolFixture.firstStepName)
            #expect(
                events == [
                    .use(PreToolUse(toolCallID: use.toolCallID, toolName: name, argumentsJSON: use.argumentsJSON)),
                    .result(
                        PreToolResult(
                            toolCallID: use.toolCallID, toolName: name, argumentsJSON: use.argumentsJSON,
                            output: Self.markerOutput)),
                    .post(
                        PostToolUse(
                            toolCallID: use.toolCallID, toolName: name, argumentsJSON: use.argumentsJSON,
                            output: Self.markerOutput, succeeded: true)),
                ])
        }
    }

    // MARK: - A block

    /// The production change that makes this test fail: a block through the
    /// container that still runs the tool body, or that gives the model
    /// another output.
    @Test("a block on PreToolUse through the container does not run the tool body")
    func aBlockDoesNotRunTheBody() async throws {
        let tool = MarkerEmittingTool()
        let visitor = ToolHookTests.ToolRecordingVisitor(decideUse: { _ in .block(reason: Self.blockReason) })
        try await Self.withSession(calling: tool, visitor: visitor) { harness in
            let answer = try await harness.session.respond(to: Self.prompt)
            await harness.closeAndDrain()

            #expect(tool.calledSteps.isEmpty)
            #expect(answer == Self.blockReason)
            let post = try #require(harness.visitor.posts.first)
            #expect(post.output == Self.blockReason)
            #expect(!post.succeeded)
        }
    }

    // MARK: - A tool that throws

    /// The production change that makes this test fail: a layer above the
    /// failure delivery, which does not see the throw of the tool body, or a
    /// layer that says that the call succeeded.
    @Test("a tool that throws through the container gives PostToolUse with succeeded false")
    func aThrowingToolGivesAFailedPostToolUse() async throws {
        try await Self.withSession(calling: ThrowingMarkerTool()) { harness in
            let answer = try await harness.session.respond(to: Self.prompt)
            await harness.closeAndDrain()

            let events = harness.visitor.recorder.events
            let use = try #require(Self.firstUse(in: events))
            let failure = ThrowingMarkerTool.CallFailure(step: ScriptedToolFixture.firstStepName).description
            #expect(answer == failure)
            #expect(
                events == [
                    .use(use),
                    .post(
                        PostToolUse(
                            toolCallID: use.toolCallID, toolName: ThrowingMarkerTool.toolName,
                            argumentsJSON: use.argumentsJSON, output: failure, succeeded: false)),
                ])
        }
    }

    // MARK: - A fork

    /// The production change that makes this test fail: a container that
    /// puts the hook layer on the tools of a session but not on the tools of
    /// its fork. The live backend puts the layer on the tools of each fork.
    @Test("a tool call of a fork through the container gives the three events with the hook session of the fork")
    func aToolCallOfAForkGivesTheThreeEvents() async throws {
        try await Self.withSession(calling: MarkerEmittingTool()) { harness in
            let fork = try await harness.session.fork(workingDirectory: nil)
            // A throw of the answer still closes the fork.
            defer { await fork.close() }
            let answer = try await fork.respond(to: Self.prompt)
            await fork.close()
            await harness.closeAndDrain()

            #expect(answer == Self.markerOutput)
            #expect(harness.visitor.recorder.events.count == 3)
            #expect(
                harness.visitor.recorder.sessions.map(\.sessionID)
                    == Array(repeating: fork.id.description, count: 3))
        }
    }

    // MARK: - The scripted container alone

    /// The production change that makes this test fail: a scripted container
    /// that puts the hook layer on its tools by itself. The layer is an
    /// option that a test selects with ``HookLayeredLLMContainer``.
    @Test("the scripted container alone gives no tool event")
    func theScriptedContainerAloneGivesNoToolEvent() async throws {
        let tool = MarkerEmittingTool()
        try await Self.withSession(calling: tool, in: .plain) { harness in
            let answer = try await harness.session.respond(to: Self.prompt)
            await harness.closeAndDrain()

            #expect(answer == Self.markerOutput)
            #expect(tool.calledSteps == [ScriptedToolFixture.firstStepName])
            #expect(harness.visitor.recorder.events.isEmpty)
        }
    }
}
