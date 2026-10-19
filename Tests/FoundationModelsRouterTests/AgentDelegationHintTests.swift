import Foundation
import FoundationModels
import FoundationModelsRouterTestSupport
import Testing
import ULID

@testable import FoundationModelsExtras
@testable import FoundationModelsRouter

/// Exercises the ``AgentDelegationHint``: a root session that can start an
/// agent, and that does a code change by hand, gets one hint to give the
/// change to an agent.
///
/// The advisor tests count calls directly. The session tests drive a real
/// tool loop with the scripted ``ScriptedRoundsModel``: the hint is the
/// prompt of the next submission of the answer, never text in a tool result.
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

    /// An advisor over an agents tool that can start `agents`.
    ///
    /// - Parameters:
    ///   - agents: The agents that the tool can start.
    ///   - hint: The settings of the hint.
    /// - Returns: The advisor.
    static func makeAdvisor(
        agents: [CatalogEntry] = [coder], hint: AgentDelegationHint = AgentDelegationHint()
    ) -> AgentDelegationAdvisor {
        AgentDelegationAdvisor(hint: hint, launcher: HintAgentsTool(agents: agents))
    }

    /// One inner call of a run, as the witness of the mount site reports it.
    ///
    /// - Parameters:
    ///   - tool: The name of the inner tool.
    ///   - op: The mount op of the call.
    ///   - arguments: The arguments, or `nil`.
    /// - Returns: The witnessed call.
    static func innerCall(_ tool: String, op: String, arguments: GeneratedContent? = nil) -> WitnessedToolCall {
        WitnessedToolCall(tool: tool, op: op, arguments: arguments, sessionID: ULID.generate())
    }

    // MARK: - The advisor

    @Test("the third code read makes the hint due, one time")
    func theThirdReadMakesTheHintDue() async {
        let advisor = Self.makeAdvisor()
        advisor.record(tool: "files", op: "read file")
        advisor.record(tool: "files", op: "read file")
        #expect(await advisor.takeHint() == nil)
        advisor.record(tool: "files", op: "read file")
        #expect(await advisor.takeHint() == Self.hint(naming: "coder"))
        advisor.record(tool: "files", op: "edit file")
        #expect(await advisor.takeHint() == nil)
    }

    @Test("the first file edit makes the hint due")
    func theFirstEditMakesTheHintDue() async {
        let advisor = Self.makeAdvisor()
        advisor.record(tool: "files", op: "edit file")
        #expect(await advisor.takeHint() == Self.hint(naming: "coder"))
    }

    @Test("an inner edit and inner reads of a run count through the witness")
    func innerCallsCountThroughTheWitness() async {
        let edit = Self.makeAdvisor()
        edit.toolCallWillBegin(Self.innerCall("edit", op: "edit files"))
        #expect(await edit.takeHint() == Self.hint(naming: "coder"))

        let reads = Self.makeAdvisor()
        reads.toolCallWillBegin(Self.innerCall("read", op: "read files"))
        reads.toolCallWillBegin(Self.innerCall("grep", op: "grep files"))
        #expect(await reads.takeHint() == nil)
        reads.toolCallWillBegin(Self.innerCall("getSymbol", op: "getSymbol code_context"))
        #expect(await reads.takeHint() == Self.hint(naming: "coder"))
    }

    @Test("a code_context call that reads no code is not a read")
    func aCodeContextHousekeepingCallIsNotARead() async {
        let advisor = Self.makeAdvisor()
        for op in ["detectProjects code_context", "getStatus code_context", "getSymbol code_context"] {
            advisor.toolCallWillBegin(Self.innerCall(String(op.split(separator: " ")[0]), op: op))
        }
        advisor.toolCallWillBegin(Self.innerCall("searchSymbol", op: "searchSymbol code_context"))
        #expect(await advisor.takeHint() == nil)
        advisor.toolCallWillBegin(Self.innerCall("grepCode", op: "grepCode code_context"))
        #expect(await advisor.takeHint() == Self.hint(naming: "coder"))
    }

    @Test("a start of an agent, outer or inner, stops the hint")
    func aStartOfAnAgentStopsTheHint() async {
        let outer = Self.makeAdvisor()
        outer.record(tool: "agents", op: "start agent")
        outer.record(tool: "files", op: "edit file")
        #expect(await outer.takeHint() == nil)

        let inner = Self.makeAdvisor()
        inner.toolCallWillBegin(
            Self.innerCall("agents", op: "agents", arguments: GeneratedContent(properties: ["op": "start agent"])))
        inner.record(tool: "files", op: "edit file")
        #expect(await inner.takeHint() == nil)
    }

    @Test("a released hint is due again")
    func aReleasedHintIsDueAgain() async {
        let advisor = Self.makeAdvisor()
        advisor.record(tool: "files", op: "edit file")
        #expect(await advisor.takeHint() != nil)
        advisor.releaseHint()
        #expect(await advisor.takeHint() == Self.hint(naming: "coder"))
    }

    @Test("the hint names an agent only when exactly one launchable agent is a code agent")
    func theHintNamesOneCodeAgent() async {
        for agents in [[Self.researcher], [Self.coder, CatalogEntry(name: "fixer", description: "fixes bugs")]] {
            let advisor = Self.makeAdvisor(agents: agents)
            advisor.record(tool: "files", op: "edit file")
            #expect(await advisor.takeHint() == Self.hint(naming: AgentDelegationHint.unnamedAgent))
        }
        let advisor = Self.makeAdvisor(agents: [Self.researcher, Self.coder])
        advisor.record(tool: "files", op: "edit file")
        #expect(await advisor.takeHint() == Self.hint(naming: "coder"))
    }

    @Test("an agents tool that can start no agent gives no hint, and the hint stays due")
    func noLaunchableAgentGivesNoHint() async {
        let advisor = Self.makeAdvisor(agents: [])
        advisor.record(tool: "files", op: "edit file")
        #expect(await advisor.takeHint() == nil)
    }

    @Test("the trigger is configurable")
    func theTriggerIsConfigurable() async {
        let advisor = Self.makeAdvisor(hint: AgentDelegationHint(editsBeforeHint: nil, readsBeforeHint: 1))
        advisor.record(tool: "files", op: "edit file")
        #expect(await advisor.takeHint() == nil)
        advisor.record(tool: "files", op: "read file")
        #expect(await advisor.takeHint() == Self.hint(naming: "coder"))
    }

    @Test("only a root session with settings and an AgentLaunching tool gets an advisor")
    func onlyARootSessionGetsAnAdvisor() {
        let tools: [any Tool] = [HintFilesTool(), HintAgentsTool(agents: [Self.coder])]
        #expect(AgentDelegationAdvisor.make(hint: AgentDelegationHint(), tools: tools, isRoot: true) != nil)
        #expect(AgentDelegationAdvisor.make(hint: AgentDelegationHint(), tools: tools, isRoot: false) == nil)
        #expect(AgentDelegationAdvisor.make(hint: nil, tools: tools, isRoot: true) == nil)
        #expect(AgentDelegationAdvisor.make(hint: AgentDelegationHint(), tools: [HintFilesTool()], isRoot: true) == nil)
    }

    // MARK: - The session

    /// A session over a ``ScriptedRoundsModel`` and its log.
    struct Fixture {
        /// The started session.
        let started: SessionFixtureLifecycle.Started

        /// The log of the renders of the model.
        let log: RenderProbeLog

        /// The session.
        var session: any RoutedSession { started.session }

        /// Ends the session.
        func end() async {
            await SessionFixtureLifecycle.end(started, opening: [])
        }
    }

    /// Starts a session whose model plays `rounds`.
    ///
    /// - Parameters:
    ///   - rounds: The rounds of tool calls of the model.
    ///   - parentCall: The parent call, or `nil` for a root session.
    /// - Returns: The fixture.
    static func makeFixture(rounds: [[ScriptedRoundCall]], parentCall: ToolContext? = nil) async throws -> Fixture {
        let log = RenderProbeLog()
        let started = try await SessionFixtureLifecycle.start(
            over: LiveBackendContainer(model: ScriptedRoundsModel(log: log, rounds: rounds)),
            configuration: SessionConfiguration(
                tools: [HintFilesTool(), HintAgentsTool(agents: [coder]), HintScriptTool()], parentCall: parentCall),
            prefix: "AgentDelegationHintTests")
        return Fixture(started: started, log: log)
    }

    /// A call of the files tool with `op`.
    static func files(_ op: String) -> ScriptedRoundCall {
        ScriptedRoundCall(name: "files", arguments: #"{"op": "\#(op)", "path": "a.py"}"#)
    }

    /// A call of the script tool whose inner call has `code` as its op.
    static func script(_ code: String) -> ScriptedRoundCall {
        ScriptedRoundCall(name: "runCode", arguments: #"{"code": "\#(code)", "path": "a.py"}"#)
    }

    /// The text of each tool output of `transcript`.
    static func outputTexts(_ transcript: Transcript) -> [String] {
        transcript.compactMap { entry in
            guard case .toolOutput(let output) = entry else { return nil }
            return Summarization.text(of: output.segments)
        }
    }

    /// The hint prompt of the default settings.
    static let hintPrompt = RoutedSessionActor.delegationHintPrompt(hint(naming: "coder"))

    @Test("the hint is the prompt of the next submission after the round of the edit, and no tool output holds it")
    func theHintIsThePromptAfterTheRound() async throws {
        let fixture = try await Self.makeFixture(rounds: [[Self.files("edit file")], [Self.files("read file")]])
        defer { await fixture.end() }

        let answer = try await fixture.session.respond(to: "fix the bug")

        #expect(answer == ScriptedRoundsModel.Executor.answerText)
        let transcript = await fixture.session.transcript
        #expect(transcript.promptTexts.filter { $0 == Self.hintPrompt }.count == 1)
        #expect(Self.outputTexts(transcript) == ["edit file a.py", "read file a.py"])
        #expect(!Self.outputTexts(transcript).contains { $0.contains("Give it to an agent") })
        let hintRender = try #require(fixture.log.renders.first { $0.promptTexts.last == Self.hintPrompt })
        #expect(Self.outputTexts(hintRender) == ["edit file a.py"])
    }

    @Test("an inner edit of a script gives the hint after the round of the script")
    func anInnerEditGivesTheHint() async throws {
        let fixture = try await Self.makeFixture(rounds: [[Self.script("edit files")]])
        defer { await fixture.end() }

        _ = try await fixture.session.respond(to: "fix the bug")

        let transcript = await fixture.session.transcript
        #expect(transcript.promptTexts.last == Self.hintPrompt)
        #expect(Self.outputTexts(transcript) == ["ran edit files a.py"])
    }

    @Test("the hint waits for every result of its round")
    func theHintWaitsForTheRound() async throws {
        let fixture = try await Self.makeFixture(rounds: [[Self.files("edit file"), Self.files("read file")]])
        defer { await fixture.end() }

        _ = try await fixture.session.respond(to: "fix the bug")

        let transcript = await fixture.session.transcript
        #expect(transcript.promptTexts.last == Self.hintPrompt)
        #expect(Set(Self.outputTexts(transcript)) == ["edit file a.py", "read file a.py"])
    }

    @Test("a session that started an agent gets no hint")
    func aStartedAgentGivesNoHint() async throws {
        let fixture = try await Self.makeFixture(rounds: [
            [ScriptedRoundCall(name: "agents", arguments: #"{"op": "start agent", "name": "coder"}"#)],
            [Self.files("edit file")],
        ])
        defer { await fixture.end() }

        _ = try await fixture.session.respond(to: "fix the bug")

        #expect(await !fixture.session.transcript.promptTexts.contains(Self.hintPrompt))
    }

    @Test("a child session gets no hint")
    func aChildSessionGetsNoHint() async throws {
        let root = try await Self.makeFixture(rounds: [])
        defer { await root.end() }
        let parentCall = ToolContext(
            sessionID: root.session.id, runPlane: root.session.runPlane,
            sink: DroppingEventSink(), tool: "agents", op: "start agent",
            completionToken: ToolContext.makeCompletionToken(), isCancelled: { false })
        let child = try await Self.makeFixture(rounds: [[Self.files("edit file")]], parentCall: parentCall)
        defer { await child.end() }

        _ = try await child.session.respond(to: "fix the bug")

        #expect(await !child.session.transcript.promptTexts.contains(Self.hintPrompt))
    }

    @Test("the hint is no work: the session ends the answer at no work")
    func theHintIsNoWork() async throws {
        let fixture = try await Self.makeFixture(rounds: [[Self.files("edit file")]])
        defer { await fixture.end() }

        _ = try await fixture.session.respond(to: "fix the bug")

        #expect(await fixture.session.awaitIdle())
        #expect(fixture.session.runPlane.workRegistry.hasWork == false)
        #expect(await fixture.session.pendingMessages().isEmpty)
    }
}

/// The arguments of the files tool of the suite.
@Generable
struct HintToolArguments {
    /// The op of the call.
    let op: String

    /// The path of the call.
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
/// `ToolContext.mount`, the way `runCode` calls `tools.*`, mounted under the
/// op `code`. The arguments have no `op`, so the outer call is neither a
/// read nor an edit.
struct HintScriptTool: Tool {
    let name = "runCode"
    let description = "test-only script tool"

    @Generable
    struct Arguments {
        /// The op of the inner call.
        let code: String

        /// The path of the inner call.
        let path: String
    }

    func call(arguments: Arguments) async throws -> String {
        guard let context = ToolContext.current else { throw HintScriptWithoutContext() }
        let inner = context.mount(HintInnerFilesTool(), op: arguments.code)
        let content = GeneratedContent(properties: ["path": arguments.path])
        return "ran \(arguments.code) " + (try await inner.call(arguments: HintInnerArguments(content)))
    }
}
