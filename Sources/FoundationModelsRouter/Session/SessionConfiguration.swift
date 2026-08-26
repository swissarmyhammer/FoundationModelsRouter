import Foundation
import FoundationModels

/// One value that carries everything a session is vended with.
///
/// ``RoutedModel/makeSession(configuration:)`` reads this value and vends a
/// ``RoutedSession``. `SessionConfiguration()` is the empty default.
/// A configuration with a ``grammar`` vends a guided session.
public struct SessionConfiguration: Sendable {
    /// The session's system instructions, or `nil`.
    public var instructions: String?

    /// A working directory override, or `nil` to default to the recording directory.
    public var workingDirectory: URL?

    /// A per-session recording root override, or `nil` for the router-level default layout.
    public var recordingRoot: URL?

    /// The tools the model can call during the session.
    /// Instances are held by reference; ``persistable`` represents them by name.
    public var tools: [any Tool]

    /// The auto-compaction opt-in, or `nil` (the default) for manual-only compaction.
    public var budget: TokenBudget?

    /// The compaction prompt automatic folds send to the summarizer, when ``budget`` is set.
    public var compactionPrompt: CompactionPrompt

    /// The model-assisted compaction stage every fold on the vended session runs.
    public var summarization: Summarization

    /// The parent session/tool-call the session was spawned from, or `nil`.
    public var agentSpawn: SessionSidecar.AgentSpawn?

    /// The pre-discovery seeding opt-in, or `nil` (the default) to leave it off.
    public var discoveryPriming: DiscoveryPriming?

    /// The grammar that constrains every `respond` on the vended session,
    /// or `nil` for an unconstrained session.
    public var grammar: Grammar?

    /// Creates a session configuration. Every parameter defaults to the
    /// matching default of `RoutedModel.makeSession`.
    public init(
        instructions: String? = nil,
        workingDirectory: URL? = nil,
        recordingRoot: URL? = nil,
        tools: [any Tool] = [],
        budget: TokenBudget? = nil,
        compactionPrompt: CompactionPrompt = .default,
        summarization: Summarization = Summarization(),
        agentSpawn: SessionSidecar.AgentSpawn? = nil,
        discoveryPriming: DiscoveryPriming? = nil,
        grammar: Grammar? = nil
    ) {
        self.instructions = instructions
        self.workingDirectory = workingDirectory
        self.recordingRoot = recordingRoot
        self.tools = tools
        self.budget = budget
        self.compactionPrompt = compactionPrompt
        self.summarization = summarization
        self.agentSpawn = agentSpawn
        self.discoveryPriming = discoveryPriming
        self.grammar = grammar
    }

    /// The `Codable` slice of this configuration, persisted in the session sidecar.
    /// ``tools`` is represented by each tool's ``FoundationModels/Tool/name``, in order.
    var persistable: Persistable {
        Persistable(
            instructions: instructions,
            workingDirectory: workingDirectory,
            recordingRoot: recordingRoot,
            toolNames: tools.map { $0.name },
            budget: budget,
            compactionPrompt: compactionPrompt,
            summarization: summarization,
            agentSpawn: agentSpawn,
            discoveryPriming: discoveryPriming,
            grammar: grammar
        )
    }

    /// The `Codable`, `Equatable` snapshot of a ``SessionConfiguration``.
    /// It mirrors the parent value field for field, except ``toolNames``.
    // sah:allow duplication mirrors SessionConfiguration field for field by design; the one difference is toolNames standing in for the tool instances
    struct Persistable: Codable, Equatable, Sendable {
        /// The session's system instructions, or `nil`.
        let instructions: String?

        /// The working directory override, or `nil`.
        let workingDirectory: URL?

        /// The per-session recording root override, or `nil`.
        let recordingRoot: URL?

        /// The ``FoundationModels/Tool/name`` of each configured tool, in order.
        let toolNames: [String]

        /// The auto-compaction opt-in, or `nil`.
        let budget: TokenBudget?

        /// The compaction prompt for automatic folds.
        let compactionPrompt: CompactionPrompt

        /// The model-assisted compaction stage.
        let summarization: Summarization

        /// The spawn context, or `nil`.
        let agentSpawn: SessionSidecar.AgentSpawn?

        /// The pre-discovery seeding opt-in, or `nil`.
        let discoveryPriming: DiscoveryPriming?

        /// The constraining grammar, or `nil`.
        let grammar: Grammar?
    }
}
