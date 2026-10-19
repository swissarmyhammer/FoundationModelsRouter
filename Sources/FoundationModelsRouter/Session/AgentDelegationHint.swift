import Foundation

/// The settings of the one hint that tells a root session to give a code
/// change to an agent.
///
/// A root session that can start an agent, and that has not started one,
/// can still do a code change by hand: it reads the code, and then edits
/// it. The hint is one short text that the session appends to a
/// model-facing tool result at the moment the session does that work. It
/// tells the model to call the `agents` tool with `start agent`.
///
/// The session gives the hint at most one time. It gives the hint only when
/// all of these are true:
/// - The session is a root session: it has no
///   ``SessionConfiguration/parentCall`` and no
///   ``SessionConfiguration/agentSpawn``. A child session, for example an
///   agent run, does its own work.
/// - An original tool of the session is an `AgentLaunching` tool whose
///   `launchableAgents()` list is not empty.
/// - The session has not called the ``agentsToolName`` tool with the op
///   ``startAgentOp``.
/// - The session reached ``editsBeforeHint`` file edits or
///   ``readsBeforeHint`` code reads, whichever comes first. A call counts
///   both as an outer call of the model and as an inner call of a run, for
///   example a `tools.files.edit` call of a script.
///
/// The hint is advice in a tool result. It never blocks, delays or changes a
/// call. It takes no lease and queues no mail, so it is not work, and the
/// no-work idle of the session does not change.
public struct AgentDelegationHint: Sendable, Equatable {
    /// The text in ``template`` that the session replaces with the name of
    /// the agent.
    public static let agentPlaceholder = "{agent}"

    /// The default of ``template``.
    public static let defaultTemplate =
        "This is a code change. Give it to an agent: call the tool \"agents\" with "
        + "{\"op\": \"start agent\", \"name\": \"\(agentPlaceholder)\", \"prompt\": \"<the full task>\"}."

    /// The agent name that the hint gives when no one launchable agent
    /// matches ``codeAgentKeywords``.
    public static let unnamedAgent = "<the agent whose description matches>"

    /// The name of the tool that starts an agent.
    public var agentsToolName: String

    /// The op of the call that starts an agent.
    public var startAgentOp: String

    /// The ops of a file edit. A call is an edit when its op is in the set.
    public var editOps: Set<String>

    /// The ops of a code read. A call is a read when its op is in the set.
    public var readOps: Set<String>

    /// The tools whose each call is a code read. A call is a read also when
    /// its tool name, or the last word of its op, is in the set, for example
    /// each op of `code_context`.
    public var readTools: Set<String>

    /// The ops that read no code, for example the housekeeping of
    /// `code_context`. A call with one of these ops is never a read, also
    /// when ``readTools`` names its tool.
    public var nonReadOps: Set<String>

    /// The file edit that gives the hint: `1` gives it at the first edit.
    /// `nil` means that no edit count gives the hint.
    public var editsBeforeHint: Int?

    /// The code read that gives the hint: `3` gives it at the third read.
    /// `nil` means that no read count gives the hint.
    public var readsBeforeHint: Int?

    /// The words that tell a code agent. The hint names an agent only when
    /// exactly one launchable agent has one of these words in its name or
    /// its description, in any case.
    public var codeAgentKeywords: [String]

    /// The text of the hint. Each ``agentPlaceholder`` becomes the name of
    /// the agent, or ``unnamedAgent``.
    public var template: String

    /// Makes the settings. Each default fits the tools of the agents, files
    /// and code-context packages, as a model calls them direct or from a
    /// script.
    ///
    /// - Parameters:
    ///   - agentsToolName: The name of the tool that starts an agent.
    ///   - startAgentOp: The op of the call that starts an agent.
    ///   - editOps: The ops of a file edit.
    ///   - readOps: The ops of a code read.
    ///   - readTools: The tools whose each call is a code read.
    ///   - nonReadOps: The ops that read no code.
    ///   - editsBeforeHint: The file edit that gives the hint, or `nil`.
    ///   - readsBeforeHint: The code read that gives the hint, or `nil`.
    ///   - codeAgentKeywords: The words that tell a code agent.
    ///   - template: The text of the hint.
    public init(
        agentsToolName: String = "agents",
        startAgentOp: String = "start agent",
        editOps: Set<String> = [
            "edit file", "write file", "patch file", "edit files", "write files", "patch files",
        ],
        readOps: Set<String> = [
            "read file", "grep files", "search files", "read files", "grep file", "search file",
        ],
        readTools: Set<String> = ["code_context"],
        nonReadOps: Set<String> = [
            "detectProjects code_context", "getStatus code_context", "getLspStatus code_context",
            "rebuildIndex code_context", "clearStatus code_context",
            "detect projects", "get status", "lsp status", "rebuild index", "clear status",
        ],
        editsBeforeHint: Int? = 1,
        readsBeforeHint: Int? = 3,
        codeAgentKeywords: [String] = ["code", "coder", "fix", "bug"],
        template: String = defaultTemplate
    ) {
        self.agentsToolName = agentsToolName
        self.startAgentOp = startAgentOp
        self.editOps = editOps
        self.readOps = readOps
        self.readTools = readTools
        self.nonReadOps = nonReadOps
        self.editsBeforeHint = editsBeforeHint
        self.readsBeforeHint = readsBeforeHint
        self.codeAgentKeywords = codeAgentKeywords
        self.template = template
    }
}
