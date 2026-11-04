import Foundation
import FoundationModels
import FoundationModelsExtras
import FoundationModelsHooks
import Operations
import Testing

@testable import FoundationModelsRouter

/// Holds ``HookLayeredLLMContainer`` in the main `FoundationModelsRouter`
/// product (task ^wn61ts5): a binary that links only the main product, such
/// as the ACP agent stub, gets the wrapper with the tool hook layer, with no
/// test support library and no `Testing` framework.
///
/// This file does not import `FoundationModelsRouterTestSupport`. Thus the
/// type must come from `FoundationModelsRouter` itself. The scripted
/// container is ``MountCallingLLMContainer``: its backend calls the tools of
/// the session directly, as the scripted model of a host does.
@Suite("HookLayeredLLMContainer: the wrapper is in the main Router product")
struct HookLayeredContainerInMainProductTests {
    /// The suite's temp-directory prefix, handed to
    /// ``RouterTestFixtures/makeTempDir(prefix:)``.
    private static let tempDirPrefix = "HookLayeredContainerInMainProductTests"

    /// The name of the folder of the hook data, in the temp directory.
    private static let hookDataFolderName = "hooks"

    /// The prompt of each answer.
    private static let prompt = "call the tool"

    /// The operation of a run that ends only at its cancel. The root waits
    /// inline for it as a child tool call.
    private static let inlineOperation = "swallow cancel"

    /// A scripted session of a router, and what the test reads.
    private struct Harness: HookedSessionFixture {
        /// The session under test.
        let session: any RoutedSession

        /// The dispatcher of the router.
        let dispatcher: HookDispatcher

        /// The visitor registered on ``dispatcher``.
        let visitor: ToolHookTests.ToolRecordingVisitor

        /// The clock of the run plane of the router.
        let clock: ManualRunClock
    }

    /// Makes a session over a ``HookLayeredLLMContainer`` that wraps a
    /// scripted container which makes one call of `tool`, runs `body`, and
    /// removes the temp directory.
    ///
    /// - Parameters:
    ///   - tool: The one tool of the session.
    ///   - argumentsJSON: The arguments of the one scripted call.
    ///   - body: The test.
    /// - Throws: What the resolve or `body` throws.
    private static func withSession(
        calling tool: some Tool, argumentsJSON: String, _ body: (Harness) async throws -> Void
    ) async throws {
        let directory = RouterTestFixtures.makeTempDir(prefix: tempDirPrefix)
        defer { try? FileManager.default.removeItem(at: directory) }
        let visitor = ToolHookTests.ToolRecordingVisitor()
        let dispatcher = HookDispatcher(dataDirectory: directory.appendingPathComponent(hookDataFolderName))
        dispatcher.register(visitor)
        let scripted = MountCallingLLMContainer(calls: [
            ScriptedMountCall(toolName: tool.name, argumentsJSON: argumentsJSON)
        ])
        let router = RouterTestFixtures.makeRouter(
            cacheDir: directory,
            loader: StubModelLoader(
                container: HookLayeredLLMContainer(wrapping: scripted), dimension: RouterTestFixtures.stubDimension),
            hooks: dispatcher)
        let clock = ManualRunClock()
        await router.useRunClock(clock)
        let profile = try await router.resolve(profile: RouterTestFixtures.profile(), reporting: ResolutionProgress())
        let session = profile.standard.makeSession(
            configuration: SessionConfiguration(tools: [tool], inlineSettleGrace: MountFixtures.manualClockGrace))
        let harness = Harness(session: session, dispatcher: dispatcher, visitor: visitor, clock: clock)
        // A test that throws before its own close still closes the session.
        defer { await harness.closeAndDrain() }
        try await body(harness)
    }

    /// The production change that makes this test fail: a main product
    /// without the wrapper, or a wrapper that gives the tools of a session no
    /// hook layer.
    @Test("a tool call through the wrapper gives PreToolUse and PostToolUse")
    func aToolCallGivesPreAndPostToolUse() async throws {
        let argumentsJSON = #"{"value":"\#(ScriptedToolFixture.firstStepName)"}"#
        try await Self.withSession(calling: MarkerEmittingTool(), argumentsJSON: argumentsJSON) { harness in
            _ = try await harness.session.respond(to: Self.prompt)
            await harness.closeAndDrain()

            let events = harness.visitor.recorder.events
            let hasUse = events.contains { if case .use = $0 { true } else { false } }
            let hasPost = events.contains { if case .post = $0 { true } else { false } }
            #expect(hasUse && hasPost)
        }
    }

    /// The production change that makes this test fail: a wrapper whose tools
    /// do not get the session layers, so a foreground cancel does not reach
    /// the root that waits inline for its child tool call.
    @Test("a foreground cancel of a root that waits inline for a child tool call ends the root")
    func foregroundCancelEndsTheRootThatWaitsInline() async throws {
        let gate = RunLatch()
        let tool = try ShutdownRunFixtures.makeTool(gate: gate)
        let argumentsJSON = ShutdownRunFixtures.arguments(op: Self.inlineOperation, name: ShutdownRecording.agentName)
        try await Self.withSession(calling: tool, argumentsJSON: argumentsJSON) { harness in
            var feed = await harness.session.streamSessionEvents().makeAsyncIterator()
            let session = harness.session
            let answering = Task { try await session.respond(to: Self.prompt) }
            try await harness.clock.waitForSleepers(atLeast: 1, endingOnEndOf: answering)

            let signal = harness.session.cancelForeground()
            let outputs = await SessionWorkEventTests.outputs(from: &feed, through: { $0 == .signalDone(signal) })

            let cancelled = outputs.contains { output in
                guard case .answerFailed(let failure) = output.event else { return false }
                return failure.reason == .cancelled
            }
            #expect(cancelled)
            await gate.open()
        }
    }
}
