import Foundation
import FoundationModels
import Tracing

/// Builds a ``RoutedSessionActor``. Each parameter forwards unchanged to the
/// ``RoutedSessionActor`` initializer.
///
/// Every session comes into existence through this one factory — vended,
/// forked, or restored from disk — so a parameter added here reaches all three
/// shapes at once. `tracer` carries no default for that reason: a site that
/// forgot it would leave its sessions silent, and the compiler says so.
///
/// - Returns: The constructed session actor.
func makeRoutedSessionActor(
    profile: LanguageModelProfile,
    routerId: ULID,
    id: ULID,
    parentId: ULID?,
    recordingDirectory: URL,
    workingDirectory: URL,
    backend: any LanguageModelSessionBackend,
    slot: ModelSlot,
    model: ModelRef,
    recorder: any TranscriptRecorder,
    instructions: String?,
    grammar: Grammar?,
    tools: [any Tool],
    originalTools: [any Tool] = [],
    outbox: SessionOutbox = SessionOutbox(),
    mailbox: SessionMailbox = SessionMailbox(),
    generationGate: AsyncSemaphore,
    forkAdmissionGate: AsyncSemaphore,
    holdsAdmissionPermit: Bool,
    persistedEntryCount: Int,
    historyOrdinal: Int,
    sidecarOrigin: SessionSidecarOrigin,
    contextTokens: Int = ProfileDefinition.defaultContext,
    usageState: ContextUsageState = .none,
    autoCompactionBudget: TokenBudget? = nil,
    autoCompactionPrompt: CompactionPrompt = .default,
    summarization: Summarization = Summarization(),
    agentSpawn: SessionSidecar.AgentSpawn? = nil,
    discoveryPriming: DiscoveryPriming? = nil,
    recordingRoot: URL? = nil,
    tracer: (any Tracer)?
) -> RoutedSessionActor {
    RoutedSessionActor(
        profile: profile,
        routerId: routerId,
        id: id,
        parentId: parentId,
        recordingDirectory: recordingDirectory,
        workingDirectory: workingDirectory,
        backend: backend,
        slot: slot,
        model: model,
        recorder: recorder,
        instructions: instructions,
        grammar: grammar,
        tools: tools,
        originalTools: originalTools,
        outbox: outbox,
        mailbox: mailbox,
        generationGate: generationGate,
        forkAdmissionGate: forkAdmissionGate,
        holdsAdmissionPermit: holdsAdmissionPermit,
        persistedEntryCount: persistedEntryCount,
        historyOrdinal: historyOrdinal,
        sidecarOrigin: sidecarOrigin,
        contextTokens: contextTokens,
        usageState: usageState,
        autoCompactionBudget: autoCompactionBudget,
        autoCompactionPrompt: autoCompactionPrompt,
        summarization: summarization,
        agentSpawn: agentSpawn,
        discoveryPriming: discoveryPriming,
        recordingRoot: recordingRoot,
        tracer: tracer
    )
}

/// The concrete ``RoutedSession``, backed by a ``LanguageModelSessionBackend``.
///
/// Internal, with no public initializer. A ``RoutedModel`` vends one.
actor RoutedSessionActor: RoutedSession {
    /// See ``RoutedSession/profile``.
    nonisolated let profile: LanguageModelProfile

    /// See ``RoutedSession/routerId``.
    nonisolated let routerId: ULID

    /// See ``RoutedSession/id``.
    nonisolated let id: ULID

    /// See ``RoutedSession/parentId``.
    nonisolated let parentId: ULID?

    /// See ``RoutedSession/recordingDirectory``.
    nonisolated let recordingDirectory: URL

    /// See ``RoutedSession/workingDirectory``.
    nonisolated let workingDirectory: URL

    /// The backend every generation and fork runs through. Never vended to
    /// callers. ``compact(prompt:budget:)`` replaces it after a fold.
    var backend: any LanguageModelSessionBackend

    /// See ``RoutedSession/transcript``. Reads under ``turnLock``, except from
    /// a tool call of this session's own turn (``isInsideOwnTurnToolCall``).
    var transcript: Transcript {
        get async {
            guard !isInsideOwnTurnToolCall else { return capturedTranscript() }
            await turnLock.wait()
            defer { turnLock.signal() }
            return capturedTranscript()
        }
    }

    /// Captures ``backend``'s entries in one synchronous window.
    private func capturedTranscript() -> Transcript {
        Transcript(entries: backend.transcriptEntries())
    }

    /// The slot this session's model fills, stamped onto recorded events.
    nonisolated let slot: ModelSlot

    /// The concrete model reference, stamped onto recorded events.
    nonisolated let model: ModelRef

    /// The non-optional recorder every generation brackets through.
    nonisolated let recorder: any TranscriptRecorder

    /// The tracer this session opens its spans through, or `nil` to read
    /// `InstrumentationSystem.tracer` at call time.
    ///
    /// Carried from the ``RoutedModel`` the session came off, and handed on to
    /// every fork this session takes, so a fork and a restored node report to
    /// the same backend as the handle that owns them. See
    /// ``RouterTracing/tracer(explicit:)`` for the resolution rule, and
    /// ``RouterTracing`` for the rule that keeps content off a span.
    nonisolated let tracer: (any Tracer)?

    /// The session's system instructions. A forked child inherits them.
    nonisolated let instructions: String?

    /// The grammar constraining every ``respond(to:)``, or `nil`. A fork
    /// inherits it.
    nonisolated let grammar: Grammar?

    /// The tools this session was constructed with, before per-session
    /// instancing. ``fork(workingDirectory:)`` builds the child's tools from these.
    nonisolated let originalTools: [any Tool]

    /// This session's own instanced tool list, as threaded to the backend.
    nonisolated let tools: [any Tool]

    /// The staging area for tool events and queued prompts. Fresh per session.
    nonisolated let outbox: SessionOutbox

    /// The registry of tracked background runs and pending elicitations. Fresh
    /// per session.
    nonisolated let mailbox: SessionMailbox

    /// This session's turn lock, held for the whole of every turn. Not
    /// `private` so a test can observe its ``AsyncSemaphore/waiterCount``.
    nonisolated let turnLock = AsyncSemaphore(value: 1)

    /// The per-model generation gate, shared with the owning model's other
    /// sessions. Released mid-turn for ``awaitingUser(_:)``.
    nonisolated let generationGate: AsyncSemaphore

    /// Whether the turn in flight holds a ``generationGate`` permit.
    var holdsGenerationPermit = false

    /// Whether the turn in flight runs on a permit lent by an enclosing turn
    /// (``GenerationPermitLoan``). Such a turn releases no permit at ``endTurn()``.
    var borrowsGenerationPermit = false

    /// The loan the turn in flight publishes to its model call, or `nil`
    /// between model calls. See ``GenerationPermitLoan``.
    var currentPermitLoan: GenerationPermitLoan?

    /// How many ``awaitingUser(_:)`` calls are outstanding. Only the outermost
    /// releases the permit and only the last to finish re-acquires it.
    var humanWaitDepth = 0

    /// The id of the turn holding ``turnLock``, or `nil` between turns. Ids
    /// are monotonic.
    var currentTurnId: UInt64?

    /// The last id ``beginTurn()`` handed out.
    var lastTurnId: UInt64 = 0

    /// The turn the outermost outstanding ``awaitingUser(_:)`` borrowed this
    /// session's generation permit from, or `nil` when no loan is open.
    var humanWaitLenderTurnId: UInt64?

    /// The in-flight turn's model call, the task ``cancelCurrentTurn()``
    /// cancels, or `nil` when no model call is outstanding. Only the model call
    /// runs in this task; the turn's recording runs afterwards.
    var inFlightModelCall: Task<String, Error>?

    /// The turn a ``cancelCurrentTurn()`` has been requested for, or `nil`.
    /// A cancellation recorded here lands on the turn's next model call.
    /// ``endTurn()`` clears it.
    var cancelRequestedTurnId: UInt64?

    /// How many cancellation requests ``cancelCurrentTurn()`` has recorded on
    /// this session, ever. Monotonic and never cleared, so a caller that spans
    /// more than one turn can compare it against a snapshot.
    var cancelRequestCount: UInt64 = 0

    /// How many ``respond(to:maxTokens:)`` calls are draining the run plane
    /// right now. A drain runs between turns, so ``cancelCurrentTurn()`` reads
    /// this to answer ``TurnCancellationResult/requested``.
    var runPlaneDrainCount = 0

    /// The gates of the run-plane drain waits suspended on this session, keyed
    /// by waiter id. ``cancelCurrentTurn()`` resumes them to end a suspended
    /// drain. One gate per waiter, because two callers can drain at once.
    var runPlaneDrainWaitGates: [ULID: RaceGate<RunPlaneDrainWaitOutcome>] = [:]

    /// The fork-admission gate, shared with the owning model.
    nonisolated let forkAdmissionGate: AsyncSemaphore

    /// Whether this session holds a fork-admission permit to release at
    /// deallocation. `true` for a fork, `false` for a root session.
    nonisolated let holdsAdmissionPermit: Bool

    /// Whether the session's first-line `session` meta event has been recorded.
    /// Set before the meta append, so no reentrant turn can emit it twice.
    var didRecordSessionMeta = false

    /// Whether this session has installed itself as ``outbox``'s
    /// ``OperationEventJournal``. Set by ``attachOutboxJournalIfNeeded()``.
    var didAttachOutboxJournal = false

    /// The in-flight turn's composed event sink (see ``turnEventSink(_:)``),
    /// or `nil` between turns. ``deliver(invocation:)`` uses it to hand a live
    /// ``SessionEvent/toolInvocation(_:)`` to the current turn.
    var currentTurnEventSink: ((SessionEvent) -> Void)?

    /// The stall watch over the one model call in flight, or `nil` between
    /// calls. See ``beginGenerationStallWatch()`` and ``GenerationStall``.
    var generationStallWatch: GenerationStallWatch?

    /// The last id ``beginGenerationStallWatch()`` handed out. Monotonic.
    var lastGenerationStallWatchId: UInt64 = 0

    /// How long a model call may run with no observable progress before it
    /// reports a ``GenerationStall``. Change it through
    /// ``setGenerationStallReportInterval(_:)``.
    var generationStallReportInterval: Duration = RoutedSessionActor
        .defaultGenerationStallReportInterval

    /// The `correlationID` of every background run whose ending this session has
    /// already journaled. A second write for one run is a no-op. See
    /// ``claimJournalWrite(for:)``.
    var journaledTerminalCorrelationIDs: Set<String> = []

    /// The positional diff baseline against the current ``backend`` transcript:
    /// how many entries are already persisted or inherited. `0` for a root, the
    /// parent's entry count at fork time for a fork. A fold rewinds it to the
    /// folded window's count, so it is not the session's position in its own
    /// recorded history. That coordinate is ``historyOrdinal``.
    var persistedEntryCount: Int

    /// The identity of the ``persistedEntryCount``-long backend prefix this
    /// session has already persisted (``TranscriptDiffer/Baseline``), or `nil`
    /// when no verifiable identity exists yet. `recordTranscriptDelta` verifies
    /// it before a diff (``TranscriptDiffer/divergence(from:in:)``).
    var persistedBaseline: TranscriptDiffer.Baseline?

    /// This session's position in its own append-only recorded history: how
    /// many entry-kind events its effective recorded stream holds. Starts at
    /// `0` for a root, at the parent's ordinal at fork time for a fork, and at
    /// the reconstructed count for a restored session. It never rewinds.
    var historyOrdinal: Int

    /// Where this session's `session.json` comes from. Handed on to every fork
    /// taken from this session (see ``SessionSidecarOrigin/forFork``).
    nonisolated let sidecarOrigin: SessionSidecarOrigin

    /// The resolved working context, in tokens, that ``contextFill`` divides
    /// its numerator by.
    nonisolated let contextTokens: Int

    /// The state ``contextFill`` derives its numerator from. See
    /// ``ContextUsageState``. ``finishTurn(grammar:since:usageBefore:pendingEvents:onEvent:)``
    /// updates it only when the turn's diff included a `.response` entry.
    var usageState: ContextUsageState

    /// The auto-compaction opt-in, or `nil` for manual-only compaction. When
    /// set, a turn folds automatically at ``TokenBudget/triggerTokens``, and a
    /// turn that overflows mid-generation is compacted harder and retried
    /// once. A fork carries it forward.
    nonisolated let autoCompactionBudget: TokenBudget?

    /// The compaction prompt auto-compaction's own folds send to the
    /// summarizer, when ``autoCompactionBudget`` is set. Ignored otherwise.
    nonisolated let autoCompactionPrompt: CompactionPrompt

    /// The model-assisted compaction stage every fold on this session uses,
    /// the caller-driven and the automatic fold alike. A fork carries it
    /// forward.
    nonisolated let summarization: Summarization

    /// The pre-discovery seeding opt-in, or `nil`. When set, each turn runs
    /// the named tool host-side over its prompt and reseeds ``backend``
    /// before generation (see ``primeDiscoveryIfConfigured(prompt:emit:)``).
    /// A fork carries it forward.
    nonisolated let discoveryPriming: DiscoveryPriming?

    /// The live ``streamSessionEvents()`` subscriptions, keyed by subscription
    /// id. ``emitSessionScopedEvent(_:)`` fans each session-scoped event out
    /// to them.
    var sessionEventSubscriptions: [ULID: AsyncStream<SessionEvent>.Continuation] = [:]

    /// Creates a session and writes its `session.json` when the session is new.
    /// A failed sidecar write is logged and dropped.
    ///
    /// Each parameter is documented on the stored property it initializes.
    /// `agentSpawn` and `recordingRoot` are not stored; the sidecar write reads
    /// them (see ``SessionSidecar/agentSpawn`` and ``SessionSidecar/configuration``).
    init(
        profile: LanguageModelProfile,
        routerId: ULID,
        id: ULID,
        parentId: ULID?,
        recordingDirectory: URL,
        workingDirectory: URL,
        backend: any LanguageModelSessionBackend,
        slot: ModelSlot,
        model: ModelRef,
        recorder: any TranscriptRecorder,
        instructions: String?,
        grammar: Grammar? = nil,
        tools: [any Tool] = [],
        originalTools: [any Tool] = [],
        outbox: SessionOutbox = SessionOutbox(),
        mailbox: SessionMailbox = SessionMailbox(),
        generationGate: AsyncSemaphore,
        forkAdmissionGate: AsyncSemaphore,
        holdsAdmissionPermit: Bool = false,
        persistedEntryCount: Int,
        historyOrdinal: Int,
        sidecarOrigin: SessionSidecarOrigin,
        contextTokens: Int = ProfileDefinition.defaultContext,
        usageState: ContextUsageState = .none,
        autoCompactionBudget: TokenBudget? = nil,
        autoCompactionPrompt: CompactionPrompt = .default,
        summarization: Summarization = Summarization(),
        agentSpawn: SessionSidecar.AgentSpawn? = nil,
        discoveryPriming: DiscoveryPriming? = nil,
        recordingRoot: URL? = nil,
        tracer: (any Tracer)?
    ) {
        self.profile = profile
        self.routerId = routerId
        self.id = id
        self.parentId = parentId
        self.recordingDirectory = recordingDirectory
        self.workingDirectory = workingDirectory
        self.backend = backend
        self.slot = slot
        self.model = model
        self.recorder = recorder
        self.instructions = instructions
        self.grammar = grammar
        self.tools = tools
        self.originalTools = originalTools
        self.outbox = outbox
        self.mailbox = mailbox
        self.generationGate = generationGate
        self.forkAdmissionGate = forkAdmissionGate
        self.holdsAdmissionPermit = holdsAdmissionPermit
        self.persistedEntryCount = persistedEntryCount
        self.historyOrdinal = historyOrdinal
        self.sidecarOrigin = sidecarOrigin
        self.contextTokens = contextTokens
        self.usageState = usageState
        self.autoCompactionBudget = autoCompactionBudget
        self.autoCompactionPrompt = autoCompactionPrompt
        self.summarization = summarization
        self.discoveryPriming = discoveryPriming
        self.tracer = tracer

        // The session's own directory is brought into existence here, by its
        // write-once sidecar, before the session exists to record anything into
        // it — so any transcript a reader finds always has the facts to
        // interpret it sitting beside it. A session with no parent is a root
        // and carries no cut point; a fork records both coordinates of its
        // cut, each read from the one stored value it equals at construction:
        // the legacy positional `forkedAtEntryCount` is its diff baseline
        // (`persistedEntryCount`), and the append-only
        // `forkedAtHistoryOrdinal` is its starting `historyOrdinal`.
        sidecarOrigin.writeSidecarIfNew(
            instructions: instructions,
            grammar: grammar?.source,
            forkedAtEntryCount: parentId == nil ? nil : persistedEntryCount,
            forkedAtHistoryOrdinal: parentId == nil ? nil : historyOrdinal,
            workingDirectory: workingDirectory,
            agentSpawn: agentSpawn,
            // The configuration envelope (task ^ne5g9jn), assembled here from
            // this session's own effective values so a root and a fork alike
            // record what they actually run with — `originalTools` supplies
            // the by-name tool list, never the instanced wrappers. Built
            // through `SessionConfiguration` so create time and restore time
            // share one vocabulary (see ``SessionSidecar/configuration``).
            configuration: SessionConfiguration(
                instructions: instructions,
                workingDirectory: workingDirectory,
                recordingRoot: recordingRoot,
                tools: originalTools,
                budget: autoCompactionBudget,
                compactionPrompt: autoCompactionPrompt,
                summarization: summarization,
                agentSpawn: agentSpawn,
                discoveryPriming: discoveryPriming,
                grammar: grammar
            ).persistable,
            to: recordingDirectory
        )
    }

    /// Releases this session's fork-admission permit at deallocation. Only a
    /// fork holds one. Does not run ``close()``'s mailbox sweep: a `deinit`
    /// cannot await an actor. Close a session explicitly where its life ends.
    deinit {
        if holdsAdmissionPermit {
            forkAdmissionGate.signal()
        }
    }
}
