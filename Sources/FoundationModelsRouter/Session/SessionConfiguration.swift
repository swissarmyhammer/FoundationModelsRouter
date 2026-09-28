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

    /// The compaction settings: the auto-compaction budget, the compaction
    /// prompt and the tool output protection. The default is manual-only
    /// compaction with the default prompt, and no protected output.
    ///
    /// ``persistable`` records the budget and the prompt in flat keys. It
    /// does not hold the tool output protection, because that is a closure.
    /// A host gives it again when it restores the session, as it gives the
    /// tools. A fork inherits it. See ``CompactionSettings``.
    public var compaction: CompactionSettings

    /// The parent session/tool-call the session was spawned from, or `nil`.
    public var agentSpawn: SessionSidecar.AgentSpawn?

    /// The pre-discovery seeding opt-in, or `nil` (the default) to leave it off.
    public var discoveryPriming: DiscoveryPriming?

    /// The grammar that constrains every `respond` on the vended session,
    /// or `nil` for an unconstrained session.
    public var grammar: Grammar?

    /// The settings of the detector that stops a generate call that repeats
    /// itself. The default is on, with the named defaults of
    /// ``RepetitionDetection``. The sidecar records it, a restore applies it
    /// again, and a fork inherits it.
    public var repetitionDetection: RepetitionDetection

    /// The default of ``mailOnlyAnswerLimit``: 100 answers in a row.
    ///
    /// A normal chain is short: a model starts some background runs, and each
    /// settled run starts one answer. 100 answers in a row with no caller
    /// message is far past such a chain, and each of them holds the model for
    /// a whole submission. So only a chain with no end reaches it.
    public static let defaultMailOnlyAnswerLimit = 100

    /// The most answers in a row that mail alone starts, with no caller
    /// message between them (`generation-queue.md`, section 5.4).
    ///
    /// Mail causes the next submission of the session with no caller call.
    /// So a model that starts one more background run in each answer gets one
    /// more answer for each run, with no end. When this many answers in a row
    /// had no caller message, the session holds new mail in its queue and
    /// starts no answer for it. The next caller message carries the held mail
    /// into its submission, and the count starts again. The mail is never
    /// lost. The session reports each hold with
    /// ``SessionEvent/mailDeliveryPaused(_:)`` and a log line.
    ///
    /// `0` holds all mail for the next caller message. A negative value acts
    /// as `0`. The sidecar records the value, a restore applies it again, and
    /// a fork inherits it.
    public var mailOnlyAnswerLimit: Int

    /// Creates a session configuration. Every parameter defaults to the
    /// matching default of `RoutedModel.makeSession`, and
    /// `mailOnlyAnswerLimit` defaults to ``defaultMailOnlyAnswerLimit``.
    public init(
        instructions: String? = nil,
        workingDirectory: URL? = nil,
        recordingRoot: URL? = nil,
        tools: [any Tool] = [],
        compaction: CompactionSettings = CompactionSettings(),
        agentSpawn: SessionSidecar.AgentSpawn? = nil,
        discoveryPriming: DiscoveryPriming? = nil,
        grammar: Grammar? = nil,
        repetitionDetection: RepetitionDetection = RepetitionDetection(),
        mailOnlyAnswerLimit: Int = defaultMailOnlyAnswerLimit
    ) {
        self.instructions = instructions
        self.workingDirectory = workingDirectory
        self.recordingRoot = recordingRoot
        self.tools = tools
        self.compaction = compaction
        self.agentSpawn = agentSpawn
        self.discoveryPriming = discoveryPriming
        self.grammar = grammar
        self.repetitionDetection = repetitionDetection
        self.mailOnlyAnswerLimit = mailOnlyAnswerLimit
    }

    /// The `Codable` slice of this configuration, persisted in the session sidecar.
    /// ``tools`` is represented by each tool's ``FoundationModels/Tool/name``, in order.
    /// ``compaction`` gives the flat `budget` and `compactionPrompt` keys. Its
    /// ``CompactionSettings/toolOutputProtection`` is a closure and has no
    /// place in the slice.
    var persistable: Persistable {
        Persistable(
            instructions: instructions,
            workingDirectory: workingDirectory,
            recordingRoot: recordingRoot,
            toolNames: tools.map { $0.name },
            budget: compaction.budget,
            compactionPrompt: compaction.prompt,
            agentSpawn: agentSpawn,
            discoveryPriming: discoveryPriming,
            grammar: grammar,
            repetitionDetection: repetitionDetection,
            mailOnlyAnswerLimit: mailOnlyAnswerLimit
        )
    }

    /// The `Codable`, `Equatable` snapshot of a ``SessionConfiguration``.
    /// It mirrors the parent value field for field, except ``toolNames``, and
    /// except the parent's ``SessionConfiguration/compaction``. The slice
    /// keeps the flat ``budget`` and ``compactionPrompt`` keys of the sidecars
    /// written before task ^83r6105, so old and new sidecars decode the same.
    /// It does not hold the ``CompactionSettings/toolOutputProtection``.
    ///
    /// A sidecar written before task ^mvm7zjy also holds a `summarization`
    /// key. The stage has no settings, so the slice does not write the key.
    /// The synthesized decoder ignores a key that has no property, so an old
    /// sidecar still decodes.
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

        /// The compaction prompt for automatic compactions.
        let compactionPrompt: CompactionPrompt

        /// The spawn context, or `nil`.
        let agentSpawn: SessionSidecar.AgentSpawn?

        /// The pre-discovery seeding opt-in, or `nil`.
        let discoveryPriming: DiscoveryPriming?

        /// The constraining grammar, or `nil`.
        let grammar: Grammar?

        /// The repetition detection settings, or `nil` in a sidecar written
        /// before the setting existed. A restore reads `nil` as the default.
        let repetitionDetection: RepetitionDetection?

        /// The most answers in a row that mail alone starts, or `nil` in a
        /// sidecar written before the setting existed. A restore reads `nil`
        /// as ``SessionConfiguration/defaultMailOnlyAnswerLimit``.
        let mailOnlyAnswerLimit: Int?
    }
}
