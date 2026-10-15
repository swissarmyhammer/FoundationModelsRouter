import Foundation
import FoundationModels
import Logging

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
    /// settled run starts one answer. 100 answers in a row with no user-type
    /// mail is far past such a chain, and each of them holds the model for
    /// a whole submission. So only a chain with no end reaches it.
    public static let defaultMailOnlyAnswerLimit = 100

    /// The most answers in a row that run mail alone starts, with no
    /// user-type mail between them (`generation-queue.md`, section 5.4).
    ///
    /// Run mail causes the next submission of the session with no caller call.
    /// So a model that starts one more background run in each answer gets one
    /// more answer for each run, with no end. When this many answers in a row
    /// had no user-type mail (a user message, an agent message or an
    /// elicitation answer), the session holds new run mail in its queue and
    /// starts no answer for it. The next user-type mail carries the held mail
    /// into its submission, and the count starts again. The mail is never
    /// lost. The session reports each hold with
    /// ``SessionEvent/mailDeliveryPaused(_:)`` and a log line.
    ///
    /// `0` holds all run mail for the next user-type mail. A negative value acts
    /// as `0`. The sidecar records the value, a restore applies it again, and
    /// a fork inherits it.
    public var mailOnlyAnswerLimit: Int

    /// How long a background tool call waits for its own run before it
    /// answers, in seconds.
    ///
    /// A run that ends in this time answers with its own result, the same as
    /// a synchronous call: the output of the tool, or the error that it
    /// threw. A run that continues answers with a `PendingRunEnvelope`, and
    /// its result arrives later as mail. The model waits this long on each
    /// background call, so keep the value small.
    ///
    /// The default is `ToolMount.defaultInlineSettleGrace`. `0` answers with
    /// the pending envelope at once. A negative value acts as `0`. A tool
    /// that states its own `BackgroundTool.inlineSettleGrace` uses its own
    /// value. The sidecar records the value, a restore applies it again, and
    /// a fork inherits it.
    public var inlineSettleGrace: TimeInterval

    /// The default of ``isNoOpToolCall``: no tool call is a no-op, so the
    /// session runs each call as it did before the check existed.
    public static let defaultIsNoOpToolCall: NoOpToolCallCheck = { _, _ in false }

    /// The host check that marks a tool call as a no-op (task ^rw72f4j).
    ///
    /// While at least one operation of the session is pending, the session
    /// does not run a call that this check marks, does not answer it, and
    /// does not put it in the context. Every other call of the same round
    /// runs. A round of only marked calls stops the generation, and the
    /// injected result of the pending operation is the next message that
    /// starts the model. See ``NoOpToolCallCheck``.
    ///
    /// The default is ``defaultIsNoOpToolCall``. The check is a closure, so
    /// ``persistable`` does not record it. A fork inherits it. A restore gets
    /// it again from the host, through the `isNoOpToolCall` argument of
    /// ``RoutedModel/restoreSession(id:recordingRoot:instructions:tools:toolOutputProtection:isNoOpToolCall:)``.
    public var isNoOpToolCall: NoOpToolCallCheck

    /// Tells if a user can answer the questions of the session.
    ///
    /// The session gives this value to its run plane one time, when the
    /// session starts. The value does not change for the life of the session.
    ///
    /// - ``UserPresence/interactive`` (the default): a question of a tool goes
    ///   to the host as ``SessionEvent/elicitationRequested(_:)``, and the run
    ///   that asked it waits for the answer.
    /// - ``UserPresence/headless``: no user is present. Each question ends at
    ///   once with a cancel that gives `RunPlane.noUserPresentReason`. The
    ///   session sends no ``SessionEvent/elicitationRequested(_:)`` and no
    ///   ``SessionEvent/elicitationEnded(_:)`` for it, and keeps no pending
    ///   question. The run continues with the cancel, and the session sends
    ///   ``SessionEvent/workEnded`` as usual.
    ///
    /// The sidecar records the value, a restore applies it again, and a fork
    /// inherits it.
    public var userPresence: UserPresence

    /// Creates a session configuration. Every parameter defaults to the
    /// matching default of `RoutedModel.makeSession`,
    /// `mailOnlyAnswerLimit` defaults to ``defaultMailOnlyAnswerLimit``,
    /// `inlineSettleGrace` defaults to `ToolMount.defaultInlineSettleGrace`,
    /// `isNoOpToolCall` defaults to ``defaultIsNoOpToolCall``, and
    /// `userPresence` defaults to ``UserPresence/interactive``.
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
        mailOnlyAnswerLimit: Int = defaultMailOnlyAnswerLimit,
        inlineSettleGrace: TimeInterval = ToolMount.defaultInlineSettleGrace,
        isNoOpToolCall: @escaping NoOpToolCallCheck = defaultIsNoOpToolCall,
        userPresence: UserPresence = .interactive
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
        self.inlineSettleGrace = inlineSettleGrace
        self.isNoOpToolCall = isNoOpToolCall
        self.userPresence = userPresence
    }

    /// The `Codable` slice of this configuration, persisted in the session sidecar.
    /// ``tools`` is represented by each tool's ``FoundationModels/Tool/name``, in order.
    /// ``compaction`` gives the flat `budget` and `compactionPrompt` keys. Its
    /// ``CompactionSettings/toolOutputProtection`` is a closure and has no
    /// place in the slice, and ``isNoOpToolCall`` is a closure as well.
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
            mailOnlyAnswerLimit: mailOnlyAnswerLimit,
            inlineSettleGrace: inlineSettleGrace,
            userPresence: Persistable.UserPresenceName(userPresence).rawValue
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

        /// How long a background call waits for its own run, in seconds, or
        /// `nil` in a sidecar written before the setting existed. A restore
        /// reads `nil` as `ToolMount.defaultInlineSettleGrace`.
        let inlineSettleGrace: TimeInterval?

        /// The name of the user presence (``UserPresenceName``), or `nil` in a
        /// sidecar written before the setting existed. The slice holds the
        /// name as text, so a sidecar with a name that this version does not
        /// know still decodes. ``restoredUserPresence`` reads it.
        let userPresence: String?

        /// The name of a ``UserPresence`` in a sidecar. The raw value is the
        /// text that the sidecar holds.
        ///
        /// The two switches below have no `default`, so the compiler makes
        /// each new case of ``UserPresence`` get a name here.
        enum UserPresenceName: String {
            /// The name of ``UserPresence/interactive``.
            case interactive

            /// The name of ``UserPresence/headless``.
            case headless

            /// Makes the name of `presence`.
            ///
            /// - Parameter presence: The user presence to name.
            init(_ presence: UserPresence) {
                switch presence {
                case .interactive: self = .interactive
                case .headless: self = .headless
                }
            }

            /// The user presence that this name gives.
            var presence: UserPresence {
                switch self {
                case .interactive: .interactive
                case .headless: .headless
                }
            }
        }

        /// The user presence that a restore gives to the run plane of the
        /// session.
        ///
        /// A sidecar written before the setting existed has no name. It gives
        /// ``UserPresence/interactive``, the default of a new session. A name
        /// that this version does not know can come from a sidecar that a
        /// newer version wrote. It also gives ``UserPresence/interactive``,
        /// and a warning log records the name. The restore does not fail.
        var restoredUserPresence: UserPresence {
            guard let userPresence else { return .interactive }
            guard let name = UserPresenceName(rawValue: userPresence) else {
                RouterTelemetry.makeLogger(.recording).warning(
                    "the sidecar records a user presence that this version does not know; the session restores interactive",
                    metadata: [RouterTelemetry.LogMetadataKey.userPresence: "\(userPresence)"])
                return .interactive
            }
            return name.presence
        }

        /// The compaction settings this slice records, the inverse of the
        /// flat keys that ``SessionConfiguration/persistable`` writes.
        ///
        /// The slice holds no tool output protection, because that is a
        /// closure. The caller gives it again, as a restore does.
        ///
        /// - Parameter toolOutputProtection: The host rule to put in the
        ///   settings, or `nil` to protect nothing.
        /// - Returns: The settings with the recorded ``budget`` and
        ///   ``compactionPrompt``, and `toolOutputProtection`.
        func compaction(toolOutputProtection: ToolOutputProtection?) -> CompactionSettings {
            CompactionSettings(
                budget: budget, prompt: compactionPrompt, toolOutputProtection: toolOutputProtection)
        }
    }
}
