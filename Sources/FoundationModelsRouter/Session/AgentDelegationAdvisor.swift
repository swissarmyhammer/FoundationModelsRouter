import FoundationModels
import FoundationModelsExtras
import Synchronization

/// The state of the ``AgentDelegationHint`` of one root session: it counts
/// the file edits and the code reads of the session, sees a start of an
/// agent, and gives the hint at most one time.
///
/// The advisor counts two kinds of calls. ``AgentDelegationHintTool`` counts
/// each outer call, the call that the model makes. The advisor is the
/// `ToolCallWitness` of the mount site of the session, so it also counts
/// each inner call of a run, for example a `tools.files.edit` call of a
/// script. A child site drops the witness, so a call of a child session
/// never counts here.
///
/// The advisor takes no lease and posts no event, so the hint is not work.
final class AgentDelegationAdvisor: ToolCallWitness, Sendable {
    /// The text between a tool result and the hint.
    static let separator = "\n\n"

    /// The counts of the session.
    private struct State {
        /// The file edits so far.
        var edits = 0

        /// The code reads so far.
        var reads = 0

        /// Whether the session called the agents tool to start an agent.
        var startedAgent = false

        /// Whether the session gave the hint, or a call takes it now.
        var gaveHint = false
    }

    /// The settings of the hint.
    let hint: AgentDelegationHint

    /// The tool that tells which agents the session can start.
    private let launcher: any AgentLaunching

    /// The counts of the session.
    private let state = Mutex(State())

    /// Makes an advisor over `launcher`.
    ///
    /// - Parameters:
    ///   - hint: The settings of the hint.
    ///   - launcher: The tool that tells which agents the session can start.
    init(hint: AgentDelegationHint, launcher: any AgentLaunching) {
        self.hint = hint
        self.launcher = launcher
    }

    /// The advisor of a session, or `nil` when the session gets no hint: it
    /// has no settings, it is not a root session, or no original tool is an
    /// `AgentLaunching` tool.
    ///
    /// - Parameters:
    ///   - hint: The settings of the hint, or `nil` for none.
    ///   - tools: The original tools of the session.
    ///   - isRoot: Whether the session is a root session.
    /// - Returns: The advisor, or `nil`.
    static func make(hint: AgentDelegationHint?, tools: [any Tool], isRoot: Bool) -> AgentDelegationAdvisor? {
        guard let hint, isRoot else { return nil }
        let launchers = tools.compactMap { $0 as? any AgentLaunching }
        guard let launcher = launchers.first(where: { $0.name == hint.agentsToolName }) ?? launchers.first else {
            return nil
        }
        return AgentDelegationAdvisor(hint: hint, launcher: launcher)
    }

    // MARK: - Counting

    /// Counts one inner call of a run of the session.
    ///
    /// - Parameter call: The inner call.
    func toolCallWillBegin(_ call: WitnessedToolCall) {
        record(tool: call.tool, op: Self.op(of: call.arguments) ?? call.op)
    }

    /// Counts one call of `tool` with `op`.
    ///
    /// - Parameters:
    ///   - tool: The name of the tool.
    ///   - op: The op of the call: the `op` of its arguments, its mount op,
    ///     or the tool name.
    func record(tool: String, op: String) {
        let lastWord = op.split(separator: " ").last.map(String.init)
        let isStart = tool == hint.agentsToolName && op == hint.startAgentOp
        let isEdit = hint.editOps.contains(op)
        let isRead =
            !hint.nonReadOps.contains(op)
            && (hint.readOps.contains(op) || hint.readTools.contains(tool)
                || lastWord.map(hint.readTools.contains) == true)
        state.withLock { state in
            if isStart { state.startedAgent = true }
            if isEdit { state.edits += 1 }
            if isRead { state.reads += 1 }
        }
    }

    /// The `op` property of `arguments`, or `nil` when it has none or it is
    /// empty.
    ///
    /// - Parameter arguments: The arguments of a call, or `nil`.
    /// - Returns: The op, or `nil`.
    static func op(of arguments: GeneratedContent?) -> String? {
        guard let op = try? arguments?.value(String.self, forProperty: "op"), !op.isEmpty else { return nil }
        return op
    }

    /// Wraps `tool` in an ``AgentDelegationHintTool`` over this advisor when
    /// its output is `String`. Any other tool passes through unchanged, as in
    /// ``ToolOutputCapping/makeWrapped(tool:toTokenLimit:counter:)``.
    ///
    /// - Parameter tool: The tool to wrap.
    /// - Returns: The decorator, or `tool` unchanged.
    func makeWrapped(tool: any Tool) -> any Tool {
        func open<T: Tool>(_ tool: T) -> any Tool {
            guard let stringTool = tool as? any Tool<T.Arguments, String> else { return tool }
            return AgentDelegationHintTool<T.Arguments>(wrapped: stringTool, advisor: self)
        }
        return open(tool)
    }

    // MARK: - The hint

    /// Whether the counts of `state` reach a trigger of ``hint``.
    ///
    /// - Parameter state: The counts.
    /// - Returns: Whether the session does a code change by hand.
    private func reachesTrigger(_ state: State) -> Bool {
        let edited = hint.editsBeforeHint.map { state.edits >= $0 } ?? false
        let read = hint.readsBeforeHint.map { state.reads >= $0 } ?? false
        return edited || read
    }

    /// Takes the hint when it is due: the counts reach a trigger, the
    /// session started no agent, it gave no hint, and it can start an agent.
    /// After a hint, each later call gives `nil`.
    ///
    /// - Returns: The text of the hint, or `nil`.
    func takeHint() async -> String? {
        let isDue = state.withLock { state in
            guard !state.gaveHint, !state.startedAgent, reachesTrigger(state) else { return false }
            state.gaveHint = true
            return true
        }
        guard isDue else { return nil }
        let agents = await launcher.launchableAgents()
        guard !agents.isEmpty else {
            state.withLock { $0.gaveHint = false }
            return nil
        }
        return hint.template.replacingOccurrences(
            of: AgentDelegationHint.agentPlaceholder, with: agentName(among: agents))
    }

    /// The name of the one code agent of `agents`, or
    /// ``AgentDelegationHint/unnamedAgent`` when not exactly one agent has a
    /// word of ``AgentDelegationHint/codeAgentKeywords``.
    ///
    /// - Parameter agents: The agents that the session can start.
    /// - Returns: The name in the hint.
    private func agentName(among agents: [CatalogEntry]) -> String {
        let keywords = hint.codeAgentKeywords.map { $0.lowercased() }
        let codeAgents = agents.filter { agent in
            let text = (agent.name + " " + agent.description).lowercased()
            return keywords.contains { text.contains($0) }
        }
        guard codeAgents.count == 1, let agent = codeAgents.first else { return AgentDelegationHint.unnamedAgent }
        return agent.name
    }
}

/// A `Tool` decorator that counts each outer call of a root session in its
/// ``AgentDelegationAdvisor``, and appends the hint to the first result that
/// is due.
///
/// It sits over the capping layer, so the cap never cuts the hint, and
/// beneath the failure delivery, so a failed call gets no hint. A rendered
/// ``PendingRunEnvelope`` is control-plane data: it gets no hint, and the
/// hint stays due for the next result. The decorator never changes the
/// arguments, and adds only the hint to the output.
struct AgentDelegationHintTool<
    Arguments: ConvertibleFromGeneratedContent
>: Tool, SubmissionBoundaryTool, ToolDecorator {
    let wrapped: any Tool<Arguments, String>

    /// The advisor of the session.
    let advisor: AgentDelegationAdvisor

    var name: String { wrapped.name }
    var description: String { wrapped.description }
    var parameters: GenerationSchema { wrapped.parameters }
    var includesSchemaInInstructions: Bool { wrapped.includesSchemaInInstructions }

    /// Counts the call, calls `wrapped`, and appends the hint when it is due.
    ///
    /// - Throws: Whatever `wrapped` throws, unmodified.
    func call(arguments: Arguments) async throws -> String {
        let content = (arguments as? any ConvertibleToGeneratedContent)?.generatedContent
        advisor.record(tool: name, op: AgentDelegationAdvisor.op(of: content) ?? name)
        let output = try await wrapped.call(arguments: arguments)
        guard PendingRunEnvelope.makeDecoded(fromRendered: output) == nil, let hint = await advisor.takeHint() else {
            return output
        }
        return output + AgentDelegationAdvisor.separator + hint
    }
}
