import Foundation
import FoundationModels
import FoundationModelsRouterTestSupport
import Testing
import ULID

@testable import FoundationModelsExtras
@testable import FoundationModelsRouter

/// Exercises the ``AgentDelegationHint``: a root session that can start an
/// agent, and that does a code change by hand, gets one hint in a tool
/// result to give the change to an agent.
///
/// Each test calls the mounted, model-facing tools of a real session
/// directly, so the suite needs no model output. The scripted
/// ``BackgroundingLLMContainer`` only vends the backend.
@Suite("A root session that does a code change by hand gets one hint to give it to an agent")
struct AgentDelegationHintTests {
    // MARK: - Helpers

    /// The one code agent of the default catalog.
    static let coder = CatalogEntry(name: "coder", description: "writes and fixes code")

    /// An agent that is not a code agent.
    static let researcher = CatalogEntry(name: "researcher", description: "answers questions from the web")

    /// The hint that names `agent`.
    ///
    /// - Parameter agent: The name in the hint.
    /// - Returns: The text of the hint.
    static func hint(naming agent: String) -> String {
        AgentDelegationHint.defaultTemplate.replacingOccurrences(
            of: AgentDelegationHint.agentPlaceholder, with: agent)
    }

    /// A started session and the tools it mounted, by name.
    struct Fixture {
        /// The started session.
        let started: SessionFixtureLifecycle.Started

        /// The session as its concrete type.
        var session: RoutedSessionActor {
            get throws { try #require(started.session as? RoutedSessionActor) }
        }

        /// Calls the mounted tool `name` with `json` as its arguments, the way
        /// the model calls it. A failure of the call is an issue of the test.
        ///
        /// - Parameters:
        ///   - name: The name of the tool.
        ///   - json: The arguments, as a JSON object.
        /// - Returns: The text of the result, or `nil` when the call failed.
        func call(_ name: String, _ json: String) async -> String? {
            do {
                let tool = try #require(try session.tools.first { $0.name == name })
                return try await Self.call(tool, json)
            } catch {
                Issue.record(error)
                return nil
            }
        }

        /// Calls `tool` with `json` as its arguments.
        private static func call<T: Tool>(_ tool: T, _ json: String) async throws -> String {
            let arguments = try T.Arguments(GeneratedContent(json: json))
            return try #require(try await tool.call(arguments: arguments) as? String)
        }

        /// Runs `body`, then ends the session.
        func endingAfter(_ body: () async throws -> Void) async throws {
            do {
                try await body()
            } catch {
                await SessionFixtureLifecycle.end(started, opening: [])
                throw error
            }
            await SessionFixtureLifecycle.end(started, opening: [])
        }
    }

    /// Starts a session with a files tool, an agents tool that launches
    /// `agents`, and a script tool.
    ///
    /// - Parameters:
    ///   - agents: The agents that the agents tool can start.
    ///   - hint: The hint settings, or `nil` for none.
    ///   - parentCall: The parent call, or `nil` for a root session.
    ///   - agentSpawn: The spawn lineage, or `nil`.
    /// - Returns: The fixture.
    static func makeFixture(
        agents: [CatalogEntry] = [coder],
        hint: AgentDelegationHint? = AgentDelegationHint(),
        parentCall: ToolContext? = nil,
        agentSpawn: SessionSidecar.AgentSpawn? = nil
    ) async throws -> Fixture {
        let configuration = SessionConfiguration(
            tools: [HintFilesTool(), HintAgentsTool(agents: agents), HintScriptTool()],
            agentSpawn: agentSpawn,
            parentCall: parentCall,
            agentDelegationHint: hint)
        return Fixture(
            started: try await SessionFixtureLifecycle.start(
                over: BackgroundingLLMContainer(), configuration: configuration, prefix: "AgentDelegationHintTests"))
    }

    // MARK: - Tests

    @Test("the third code read gets the hint, and no other read gets it")
    func theThirdReadGetsTheHint() async throws {
        let fixture = try await Self.makeFixture()
        try await fixture.endingAfter {
            let read = #"{"op": "read file", "path": "a.py"}"#
            #expect(await fixture.call("files", read) == "read file a.py")
            #expect(await fixture.call("files", read) == "read file a.py")
            #expect(
                await fixture.call("files", read)
                    == "read file a.py" + AgentDelegationAdvisor.separator + Self.hint(naming: "coder"))
            #expect(await fixture.call("files", read) == "read file a.py")
            #expect(await fixture.call("files", #"{"op": "edit file", "path": "a.py"}"#) == "edit file a.py")
        }
    }

    @Test("the first file edit gets the hint")
    func theFirstEditGetsTheHint() async throws {
        let fixture = try await Self.makeFixture()
        try await fixture.endingAfter {
            #expect(
                await fixture.call("files", #"{"op": "edit file", "path": "a.py"}"#)
                    == "edit file a.py" + AgentDelegationAdvisor.separator + Self.hint(naming: "coder"))
        }
    }

    @Test("a code_context call that reads no code is not a read")
    func aCodeContextHousekeepingCallIsNotARead() async throws {
        let fixture = try await Self.makeFixture()
        try await fixture.endingAfter {
            for code in [
                "detectProjects code_context", "getStatus code_context", "getSymbol code_context",
                "searchSymbol code_context",
            ] {
                #expect(
                    await fixture.call("runCode", #"{"code": "\#(code)", "path": "a.py"}"#) == "ran \(code) a.py")
            }
            #expect(
                await fixture.call("runCode", #"{"code": "grepCode code_context", "path": "a.py"}"#)
                    == "ran grepCode code_context a.py" + AgentDelegationAdvisor.separator
                    + Self.hint(naming: "coder"))
        }
    }

    @Test("a session that started an agent gets no hint")
    func aStartedAgentGivesNoHint() async throws {
        let fixture = try await Self.makeFixture()
        try await fixture.endingAfter {
            _ = await fixture.call("agents", #"{"op": "start agent", "name": "coder"}"#)
            #expect(await fixture.call("files", #"{"op": "edit file", "path": "a.py"}"#) == "edit file a.py")
        }
    }

    @Test("an inner edit of a script gets the hint on the result of the script")
    func anInnerEditGetsTheHint() async throws {
        let fixture = try await Self.makeFixture()
        try await fixture.endingAfter {
            #expect(
                await fixture.call("runCode", #"{"code": "edit files", "path": "a.py"}"#)
                    == "ran edit files a.py" + AgentDelegationAdvisor.separator + Self.hint(naming: "coder"))
        }
    }

    @Test("an inner start of an agent of a script stops the hint")
    func anInnerStartGivesNoHint() async throws {
        let fixture = try await Self.makeFixture()
        try await fixture.endingAfter {
            _ = await fixture.call("runCode", #"{"code": "start agent", "path": "coder"}"#)
            #expect(await fixture.call("files", #"{"op": "edit file", "path": "a.py"}"#) == "edit file a.py")
        }
    }

    @Test("the hint names no agent when no one launchable agent is a code agent")
    func theHintNamesNoAgentWithoutOneCodeAgent() async throws {
        for agents in [
            [Self.researcher],
            [Self.coder, CatalogEntry(name: "fixer", description: "fixes bugs")],
        ] {
            let fixture = try await Self.makeFixture(agents: agents)
            try await fixture.endingAfter {
                #expect(
                    await fixture.call("files", #"{"op": "edit file", "path": "a.py"}"#)
                        == "edit file a.py" + AgentDelegationAdvisor.separator
                        + Self.hint(naming: AgentDelegationHint.unnamedAgent))
            }
        }
    }

    @Test("a session whose agents tool can start no agent gets no hint")
    func noLaunchableAgentGivesNoHint() async throws {
        let fixture = try await Self.makeFixture(agents: [])
        try await fixture.endingAfter {
            #expect(await fixture.call("files", #"{"op": "edit file", "path": "a.py"}"#) == "edit file a.py")
        }
    }

    @Test("a child session gets no hint")
    func aChildSessionGetsNoHint() async throws {
        let root = try await Self.makeFixture(hint: nil)
        try await root.endingAfter {
            let parentCall = ToolContext(
                sessionID: try root.session.id, runPlane: try root.session.runPlane,
                sink: DroppingEventSink(), tool: "agents", op: "start agent",
                completionToken: ToolContext.makeCompletionToken(), isCancelled: { false })
            let child = try await Self.makeFixture(parentCall: parentCall)
            try await child.endingAfter {
                #expect(await child.call("files", #"{"op": "edit file", "path": "a.py"}"#) == "edit file a.py")
            }
        }
    }

    @Test("a session with a spawn lineage gets no hint")
    func aSpawnedSessionGetsNoHint() async throws {
        let fixture = try await Self.makeFixture(
            agentSpawn: SessionSidecar.AgentSpawn(parentSessionId: ULID.generate(), parentToolCallId: "call-1"))
        try await fixture.endingAfter {
            #expect(await fixture.call("files", #"{"op": "edit file", "path": "a.py"}"#) == "edit file a.py")
        }
    }

    @Test("the trigger is configurable, and no settings give no hint")
    func theTriggerIsConfigurable() async throws {
        let readFirst = try await Self.makeFixture(
            hint: AgentDelegationHint(editsBeforeHint: nil, readsBeforeHint: 1))
        try await readFirst.endingAfter {
            #expect(await readFirst.call("files", #"{"op": "edit file", "path": "a.py"}"#) == "edit file a.py")
            #expect(
                await readFirst.call("files", #"{"op": "read file", "path": "a.py"}"#)
                    == "read file a.py" + AgentDelegationAdvisor.separator + Self.hint(naming: "coder"))
        }
        let off = try await Self.makeFixture(hint: nil)
        try await off.endingAfter {
            #expect(await off.call("files", #"{"op": "edit file", "path": "a.py"}"#) == "edit file a.py")
        }
    }

    @Test("the hint is no work: it takes no lease and queues no mail")
    func theHintIsNoWork() async throws {
        let fixture = try await Self.makeFixture()
        try await fixture.endingAfter {
            _ = await fixture.call("files", #"{"op": "edit file", "path": "a.py"}"#)
            let session = try fixture.session
            #expect(session.runPlane.workRegistry.hasWork == false)
            #expect(await session.pendingMessages().isEmpty)
            #expect(await session.awaitIdle())
        }
    }
}

/// The arguments of each tool of the suite.
@Generable
struct HintToolArguments {
    /// The op of the call.
    let op: String

    /// The path, or the agent name of a start.
    let path: String
}

/// A files tool: it answers with its op and path.
struct HintFilesTool: Tool {
    let name = "files"
    let description = "test-only files tool"

    func call(arguments: HintToolArguments) async throws -> String {
        "\(arguments.op) \(arguments.path)"
    }
}

/// An agents tool that can start ``agents``.
struct HintAgentsTool: Tool, AgentLaunching {
    let name = "agents"
    let description = "test-only agents tool"

    /// The agents that the tool can start.
    let agents: [CatalogEntry]

    @Generable
    struct Arguments {
        let op: String
        let name: String
    }

    func call(arguments: Arguments) async throws -> String {
        "started \(arguments.name)"
    }

    func launchableAgents() async -> [CatalogEntry] {
        agents
    }
}

/// The arguments of an inner files call of a script: the op is the mount op
/// of the call, not an argument, as for a `tools.files.edit` call.
@Generable
struct HintInnerArguments {
    /// The path of the call.
    let path: String
}

/// An inner files tool of a script: it answers with its path.
struct HintInnerFilesTool: Tool {
    let name = "edit"
    let description = "test-only inner files tool"

    func call(arguments: HintInnerArguments) async throws -> String {
        arguments.path
    }
}

/// The failure of a ``HintScriptTool`` call that has no ambient context.
struct HintScriptWithoutContext: Error {}

/// A script tool: each call makes one inner call through
/// `ToolContext.mount`, the way `runCode` calls `tools.*`. A `code` of
/// `start agent` calls an inner agents tool with that op in its arguments.
/// Each other `code` calls an inner files tool mounted under that op. The
/// arguments have no `op`, so the outer call is neither a read nor an edit.
struct HintScriptTool: Tool {
    let name = "runCode"
    let description = "test-only script tool"

    @Generable
    struct Arguments {
        /// The op of the inner call.
        let code: String

        /// The path, or the agent name of a start.
        let path: String
    }

    func call(arguments: Arguments) async throws -> String {
        guard let context = ToolContext.current else { throw HintScriptWithoutContext() }
        if arguments.code == "start agent" {
            let inner = context.mount(HintAgentsTool(agents: []))
            let content = GeneratedContent(properties: ["op": arguments.code, "name": arguments.path])
            return "ran " + (try await inner.call(arguments: HintAgentsTool.Arguments(content)))
        }
        let inner = context.mount(HintInnerFilesTool(), op: arguments.code)
        let content = GeneratedContent(properties: ["path": arguments.path])
        return "ran \(arguments.code) " + (try await inner.call(arguments: HintInnerArguments(content)))
    }
}
