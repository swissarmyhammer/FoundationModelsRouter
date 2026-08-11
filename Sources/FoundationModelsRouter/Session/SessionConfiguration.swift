import Foundation
import FoundationModels

/// One value that carries everything a session is vended with.
///
/// ``RoutedModel/makeSession(configuration:)`` reads this value and vends a
/// ``RoutedSession``. Each field is one knob of the nine-parameter
/// ``RoutedModel/makeSession(instructions:workingDirectory:recordingRoot:tools:budget:compactionPrompt:summarization:agentSpawn:discoveryPriming:)``
/// — that overload's parameter docs are the authoritative story for each
/// knob's semantics — plus ``grammar``, which merges the guided surface
/// (``RoutedModel/makeGuidedSession(grammar:instructions:workingDirectory:tools:budget:compactionPrompt:summarization:agentSpawn:discoveryPriming:)``)
/// into the same vocabulary: a configuration with a grammar vends a guided
/// session.
///
/// `SessionConfiguration()` is the empty default. A session vended with it is
/// identical to one vended by a zero-argument `makeSession()` call. Because
/// this is a plain value, a caller can hold it, inspect it, mutate one field
/// at a time, and reuse it across sessions.
///
/// The value-typed fields also travel: ``persistable`` derives the `Codable`
/// slice of this value, with ``tools`` represented by name. Task ^ne5g9jn
/// persists that slice in the session sidecar and re-applies it at restore
/// time, so create-time and restore-time configuration stay one vocabulary.
public struct SessionConfiguration: Sendable {
    /// The session's system instructions, or `nil`.
    public var instructions: String?

    /// A working directory override, or `nil` to default to the recording
    /// directory.
    public var workingDirectory: URL?

    /// A per-session recording root override, or `nil` for the router-level
    /// default layout — see
    /// ``RoutedModel/recordingDirectory(forSessionId:recordingRoot:)``.
    public var recordingRoot: URL?

    /// The tools the model can call during the session.
    ///
    /// Instances are held by reference and never encoded; ``persistable``
    /// represents them by ``FoundationModels/Tool/name`` for persistence.
    public var tools: [any Tool]

    /// The auto-compaction opt-in, or `nil` (the default) for manual-only
    /// compaction.
    public var budget: TokenBudget?

    /// The compaction prompt auto-compaction's own folds send to the
    /// summarizer, when ``budget`` is set.
    public var compactionPrompt: CompactionPrompt

    /// The model-assisted compaction stage every fold on the vended session
    /// runs.
    public var summarization: Summarization

    /// The parent session/tool-call the session was spawned from, or `nil`
    /// for a session vended with no spawn context.
    public var agentSpawn: SessionSidecar.AgentSpawn?

    /// The pre-discovery seeding opt-in, or `nil` (the default) to leave it
    /// off.
    public var discoveryPriming: DiscoveryPriming?

    /// The grammar constraining every `respond` on the vended session, or
    /// `nil` for an unconstrained session.
    ///
    /// A non-`nil` grammar makes ``RoutedModel/makeSession(configuration:)``
    /// vend the same guided session
    /// ``RoutedModel/makeGuidedSession(grammar:instructions:workingDirectory:tools:budget:compactionPrompt:summarization:agentSpawn:discoveryPriming:)``
    /// vends.
    public var grammar: Grammar?

    /// Creates a session configuration.
    ///
    /// Every parameter defaults to the matching default of the nine-parameter
    /// ``RoutedModel/makeSession(instructions:workingDirectory:recordingRoot:tools:budget:compactionPrompt:summarization:agentSpawn:discoveryPriming:)``,
    /// so `SessionConfiguration()` is the empty default.
    ///
    /// - Parameters:
    ///   - instructions: The session's system instructions, or `nil`.
    ///   - workingDirectory: A working directory override, or `nil`.
    ///   - recordingRoot: A per-session recording root override, or `nil`.
    ///   - tools: The tools the model can call. Defaults to no tools.
    ///   - budget: The auto-compaction opt-in, or `nil`.
    ///   - compactionPrompt: The compaction prompt for automatic folds.
    ///     Defaults to ``CompactionPrompt/default``.
    ///   - summarization: The model-assisted compaction stage. Defaults to
    ///     `Summarization()`, every default.
    ///   - agentSpawn: The spawn context, or `nil`.
    ///   - discoveryPriming: The pre-discovery seeding opt-in, or `nil`.
    ///   - grammar: The constraining grammar, or `nil` for an unconstrained
    ///     session.
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

    /// The `Codable` slice of this configuration — the envelope task ^ne5g9jn
    /// persists in the session sidecar for restore re-application.
    ///
    /// Every value-typed field carries over as it is. ``tools`` — the one
    /// field held by reference — is represented by each tool's
    /// ``FoundationModels/Tool/name``, in order; the restore-time rehydration
    /// hook matches those names against app-supplied instances.
    public var persistable: Persistable {
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
    ///
    /// This mirrors the parent value field for field on purpose — one
    /// vocabulary for create time and restore time — except ``toolNames``,
    /// which stands in for the non-codable tool instances. Encode-decode
    /// round-trips losslessly, tool names included, so a decoded snapshot can
    /// be re-encoded without losing what the session was configured with.
    // sah:allow duplication mirrors SessionConfiguration field for field by design; the one difference is toolNames standing in for the tool instances
    public struct Persistable: Codable, Equatable, Sendable {
        /// The session's system instructions, or `nil`.
        public let instructions: String?

        /// The working directory override, or `nil`.
        public let workingDirectory: URL?

        /// The per-session recording root override, or `nil`.
        public let recordingRoot: URL?

        /// The ``FoundationModels/Tool/name`` of each configured tool, in
        /// order — the by-name representation of
        /// ``SessionConfiguration/tools``.
        public let toolNames: [String]

        /// The auto-compaction opt-in, or `nil`.
        public let budget: TokenBudget?

        /// The compaction prompt for automatic folds.
        public let compactionPrompt: CompactionPrompt

        /// The model-assisted compaction stage.
        public let summarization: Summarization

        /// The spawn context, or `nil`.
        public let agentSpawn: SessionSidecar.AgentSpawn?

        /// The pre-discovery seeding opt-in, or `nil`.
        public let discoveryPriming: DiscoveryPriming?

        /// The constraining grammar, or `nil`.
        public let grammar: Grammar?
    }
}
