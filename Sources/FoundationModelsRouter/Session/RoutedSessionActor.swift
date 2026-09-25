import Foundation
import FoundationModels
import Tracing

/// Writes one session's identity onto its ``RouterTracing/SpanName/session``
/// span.
///
/// One writer for all three shapes, so every session span carries the same
/// keys however the session was made. The parent key is written only when
/// there is a parent, so a vended root names none.
///
/// - Parameters:
///   - span: The open session span.
///   - origin: How the session came into existence.
///   - routerId: The recording root id of the router the session belongs to.
///   - sessionId: The new session's own span id.
///   - parentId: The id of the session it came from, or `nil` for a root.
///   - model: The model the session runs against.
private func describeSession(
    on span: any Span,
    origin: RouterTracing.SessionOrigin,
    routerId: ULID,
    sessionId: ULID,
    parentId: ULID?,
    model: ModelRef
) {
    span.attributes[RouterTracing.AttributeKey.routerId] = routerId.description
    span.attributes[RouterTracing.AttributeKey.modelRef] = model.stringValue
    span.attributes[RouterTracing.AttributeKey.sessionId] = sessionId.description
    span.attributes[RouterTracing.AttributeKey.sessionOrigin] = origin.rawValue
    if let parentId {
        span.attributes[RouterTracing.AttributeKey.parentSessionId] = parentId.description
    }
}

/// The kind every ``RouterTracing/SpanName/session`` span opens under.
///
/// Written here, and nowhere else, so the two `withSessionSpan` forms below
/// cannot drift apart on it. With the span's name and the one attribute writer
/// above, it leaves those two forms naming no value of their own: they carry a
/// different effect, and nothing else.
private let sessionSpanKind: SpanKind = .internal

/// Opens one ``RouterTracing/SpanName/session`` span around the work that
/// brings a session into existence, and writes that session's identity onto
/// it.
///
/// Every session span the package opens comes from here — the vended root, the
/// forked child and the restored node alike — so the span's name, its kind and
/// its attributes are written in one place and all three shapes report the
/// same way.
///
/// Which of the three calls this helper, and when, follows from where the cost
/// sits. A restored node is the one shape whose cost is not the construction:
/// before it can build anything it re-reads its own and its ancestors'
/// transcript files from disk
/// (``TranscriptTree/effectiveTranscript(forSession:view:)``), which is
/// exactly the work this span was added to make visible. So the restore path
/// calls this helper itself, around that read *and* the rebuild that follows
/// it, and `makeRoutedSessionActor` opens no second span for a
/// ``RouterTracing/SessionOrigin/restored`` session. The other two shapes have
/// nothing to measure before the construction, so the factory calls this
/// helper for them.
///
/// - Parameters:
///   - routerId: The recording root id of the router the session belongs to.
///   - sessionId: The new session's own span id.
///   - parentId: The id of the session it came from, or `nil` for a root.
///   - model: The model the session runs against.
///   - origin: How the session came into existence.
///   - tracer: The owning handle's tracer, or `nil` to read
///     `InstrumentationSystem.tracer` at call time.
///   - work: The work the span measures.
/// - Returns: Whatever `work` returns.
/// - Throws: Whatever `work` throws. `withSpan` records the error on the span
///   and raises it again.
func withSessionSpan<Result>(
    routerId: ULID,
    sessionId: ULID,
    parentId: ULID?,
    model: ModelRef,
    origin: RouterTracing.SessionOrigin,
    tracer: (any Tracer)?,
    _ work: () throws -> Result
) rethrows -> Result {
    try RouterTracing.tracer(explicit: tracer)
        .withSpan(RouterTracing.SpanName.session, ofKind: sessionSpanKind) { span in
            describeSession(
                on: span,
                origin: origin,
                routerId: routerId,
                sessionId: sessionId,
                parentId: parentId,
                model: model
            )
            return try work()
        }
}

/// The suspending form of the session span, for a caller whose work awaits.
///
/// Swift carries no effect polymorphism: one function cannot be `async` for an
/// `async` caller and synchronous for a synchronous one, and `withSpan` itself
/// is a pair of overloads for the same reason. So this helper is a pair too.
/// The two forms are one helper in every respect a reader cares about — the
/// same span name, the same kind, and the same attributes through the same one
/// writer — and they differ only in the effect they carry, so the restore path
/// can suspend inside its span while the synchronous factory can still open
/// one. Read the synchronous form above for which shape opens its span where.
///
/// - Parameters:
///   - routerId: The recording root id of the router the session belongs to.
///   - sessionId: The new session's own span id.
///   - parentId: The id of the session it came from, or `nil` for a root.
///   - model: The model the session runs against.
///   - origin: How the session came into existence.
///   - tracer: The owning handle's tracer, or `nil` to read
///     `InstrumentationSystem.tracer` at call time.
///   - work: The work the span measures.
/// - Returns: Whatever `work` returns.
/// - Throws: Whatever `work` throws. `withSpan` records the error on the span
///   and raises it again.
func withSessionSpan<Result>(
    routerId: ULID,
    sessionId: ULID,
    parentId: ULID?,
    model: ModelRef,
    origin: RouterTracing.SessionOrigin,
    tracer: (any Tracer)?,
    _ work: () async throws -> Result
) async rethrows -> Result {
    try await RouterTracing.tracer(explicit: tracer)
        .withSpan(RouterTracing.SpanName.session, ofKind: sessionSpanKind) { span in
            describeSession(
                on: span,
                origin: origin,
                routerId: routerId,
                sessionId: sessionId,
                parentId: parentId,
                model: model
            )
            return try await work()
        }
}

/// Builds a ``RoutedSessionActor`` inside its own
/// ``RouterTracing/SpanName/session`` span. Each parameter but `origin`
/// forwards unchanged to the ``RoutedSessionActor`` initializer.
///
/// Every session comes into existence through this one factory — vended,
/// forked, or restored from disk — so a parameter added here reaches all three
/// shapes at once. `tracer` carries no default for that reason: a site that
/// forgot it would leave its sessions silent, and the compiler says so.
/// `origin` carries none for the same reason: a shape that cannot say how it
/// was made would leave its span unreadable.
///
/// **A forked child carries two spans, and they are not two costs.** The
/// enclosing ``RouterTracing/SpanName/fork`` span measures the whole fork;
/// the session span opened here measures only the construction inside it.
/// The session span is a child of the fork span — the fork opened its own
/// before it reached this factory, and the task-local `ServiceContext`
/// carries it here — so a reader sees one nested inside the other and never
/// adds the two together.
///
/// A ``RouterTracing/SessionOrigin/restored`` session gets no span from this
/// factory: its span is already open around the transcript read that precedes
/// this call. See `withSessionSpan`, the one helper both paths open their span
/// through.
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
    persistedEntryCount: Int,
    historyOrdinal: Int,
    sidecarOrigin: SessionSidecarOrigin,
    origin: RouterTracing.SessionOrigin,
    contextTokens: Int,
    usageState: ContextUsageState = .none,
    autoCompactionBudget: TokenBudget? = nil,
    autoCompactionPrompt: CompactionPrompt = .default,
    summarization: Summarization = Summarization(),
    agentSpawn: SessionSidecar.AgentSpawn? = nil,
    discoveryPriming: DiscoveryPriming? = nil,
    toolOutputProtection: ToolOutputProtection? = nil,
    repetitionDetection: RepetitionDetection = RepetitionDetection(),
    recordingRoot: URL? = nil,
    tokenCounter: any TokenCounter,
    tracer: (any Tracer)?
) -> RoutedSessionActor {
    // The construction itself, so the one parameter list below is written once
    // whether or not this factory is the site that opens the session's span.
    let construct = {
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
            toolOutputProtection: toolOutputProtection,
            repetitionDetection: repetitionDetection,
            recordingRoot: recordingRoot,
            tokenCounter: tokenCounter,
            tracer: tracer
        )
    }
    // A restored node's span is already open around the transcript read that
    // runs before this call, so it gets no second span here. See this
    // function's own doc comment.
    guard origin != .restored else { return construct() }
    return withSessionSpan(
        routerId: routerId,
        sessionId: id,
        parentId: parentId,
        model: model,
        origin: origin,
        tracer: tracer,
        construct
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
    /// callers. ``compact(prompt:budget:)`` replaces it after a compaction.
    /// Each replacement reports its passes to ``generationPassObserver``. Each
    /// model call of it is one submission to its ``LanguageModelSessionBackend/generationQueue``.
    var backend: any LanguageModelSessionBackend {
        didSet { observeGenerationPasses(of: backend) }
    }

    /// The observer every backend of this session reports its passes to, and
    /// each submission of this session reports its wait and its start to
    /// (tasks ^ake8sax and ^1psqdm9). See ``drainGenerationPassPhases()``.
    nonisolated let generationPassObserver = GenerationPassObserver()

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

    /// The id of the turn holding ``turnLock``, or `nil` between turns. Ids
    /// are monotonic.
    var currentTurnId: UInt64?

    /// The last id ``beginTurn()`` handed out.
    var lastTurnId: UInt64 = 0

    /// The in-flight turn's model call, the task ``cancelCurrentTurn()``
    /// cancels, or `nil` when no model call is outstanding. Only the model call
    /// runs in this task; the turn's recording runs afterwards. A cancel of the
    /// task removes a submission that waits for the worker, or cancels the
    /// running submission.
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

    /// The ledger of the generate attempt in flight, or `nil` between
    /// attempts and when the backend reports no usage. See
    /// ``GenerationCallLedger``.
    var generationCallLedger: GenerationCallLedger?

    /// What the generate attempt in flight saw at its tool-result
    /// boundaries. See ``ToolResultWatch`` and ``noteToolResult(_:)``.
    var toolResultWatch = ToolResultWatch()

    /// Whether the turn in flight stops compacting inside the turn, at a tool
    /// result or at a ceiling stop: set when such a compaction applied no
    /// summary (``compactAndContinue(attempt:continuationPrompt:body:)``), and
    /// cleared by ``beginTurn()`` for each new turn.
    var compactionYieldsStopped = false

    /// The repetition watch of this session: the watch of the model call in
    /// flight, its stop marker, and the recoveries of the turn in flight.
    /// See ``runWatchedModelCall(composedPrompt:_:)``.
    var repetitionWatch = RepetitionWatchState()

    /// The settings of the repetition watch this session was vended,
    /// forked or restored with. A fork carries it forward, and the sidecar
    /// records it. See ``RepetitionDetection``.
    nonisolated let repetitionDetection: RepetitionDetection

    /// The stall watch over the one model call in flight, or `nil` between
    /// calls. See ``beginGenerationStallWatch()`` and ``GenerationStall``.
    var generationStallWatch: GenerationStallWatch?

    /// The last id ``beginGenerationStallWatch()`` handed out. Monotonic.
    var lastGenerationStallWatchId: UInt64 = 0

    /// How long a model call may run with no observable progress before it
    /// reports a ``GenerationStall``. It is `.zero`, which means off, until the
    /// host installs an interval through
    /// ``setGenerationStallReportInterval(_:)``. A fork starts with its
    /// parent's interval.
    var generationStallReportInterval: Duration = .zero

    /// The `correlationID` of every background run whose ending this session has
    /// already journaled. A second write for one run is a no-op. See
    /// ``claimJournalWrite(for:)``.
    var journaledTerminalCorrelationIDs: Set<String> = []

    /// The positional diff baseline against the current ``backend`` transcript:
    /// how many entries are already persisted or inherited. `0` for a root, the
    /// parent's entry count at fork time for a fork. A compaction rewinds it to the
    /// compacted window's count, so it is not the session's position in its own
    /// recorded history. That coordinate is ``historyOrdinal``.
    var persistedEntryCount: Int

    /// The identity of the ``persistedEntryCount``-long backend prefix this
    /// session has already persisted or inherited (``TranscriptDiffer/Baseline``).
    /// `recordTranscriptDelta` verifies it before a diff
    /// (``TranscriptDiffer/divergence(from:in:)``) and takes the whole
    /// current transcript as the next baseline after every recorded diff.
    /// Set at construction from the backend's own prefix, so an identity
    /// exists before the first turn: empty for a root, the parent's entries
    /// for a fork, the seed transcript for a restore.
    var persistedBaseline: TranscriptDiffer.Baseline

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

    /// The context token counter of the session: the size of the render that
    /// the session sends to the model (the instructions, the latest compaction
    /// snapshot, and the messages since that snapshot). ``contextFill`` derives
    /// its numerator from it. See ``ContextUsageState``.
    ///
    /// ``finishTurn(grammar:since:usageBefore:responseTokenCeiling:pendingEvents:onEvent:)``
    /// sets it to the fed and generated tokens of the newest generation call of
    /// the attempt, never to the sum of the calls, and only when the turn's diff
    /// included a `.response` entry. A compaction restarts it from the
    /// instructions and the new snapshot (task ^tpsc0nf).
    var usageState: ContextUsageState

    /// The auto-compaction opt-in, or `nil` for manual-only compaction. When
    /// set, a turn compacts automatically at ``TokenBudget/triggerTokens``, and a
    /// turn that overflows mid-generation is compacted harder and retried
    /// once. A fork carries it forward.
    nonisolated let autoCompactionBudget: TokenBudget?

    /// The compaction prompt auto-compaction's own compactions send to the
    /// summarizer, when ``autoCompactionBudget`` is set. Ignored otherwise.
    nonisolated let autoCompactionPrompt: CompactionPrompt

    /// The summarization stage every compaction on this session uses,
    /// the caller-driven and the automatic compaction alike. A fork carries it
    /// forward.
    nonisolated let summarization: Summarization

    /// The pre-discovery seeding opt-in, or `nil`. When set, each turn runs
    /// the named tool host-side over its prompt and reseeds ``backend``
    /// before generation (see ``primeDiscoveryIfConfigured(prompt:emit:)``).
    /// A fork carries it forward.
    nonisolated let discoveryPriming: DiscoveryPriming?

    /// The host rule whose protected tool outputs every compaction on this session
    /// keeps word for word, or `nil` to protect nothing. A fork carries it
    /// forward. The sidecar never records it, because it is a closure; a
    /// restore takes it from the host again. See ``ToolOutputProtection``.
    nonisolated let toolOutputProtection: ToolOutputProtection?

    /// The counter that counts tokens the way this session's model counts
    /// them, backed by the tokenizer of the loaded container. Every
    /// compaction on this session measures with it, and so does the capping
    /// layer of its tools. A fork carries it forward; a restore takes it from
    /// the container again. See ``TokenCounter``.
    nonisolated let tokenCounter: any TokenCounter

    /// The parent session and tool call that spawned this session, or `nil`.
    /// Stamped on this session's `session` meta event
    /// (``TranscriptEvent/agentSpawn``) and written to its sidecar
    /// (``SessionSidecar/agentSpawn``). A fork's is always `nil`.
    nonisolated let agentSpawn: SessionSidecar.AgentSpawn?

    /// The live ``streamSessionEvents()`` subscriptions, keyed by subscription
    /// id. ``emitSessionScopedEvent(_:)`` fans each session-scoped event out
    /// to them.
    var sessionEventSubscriptions: [ULID: AsyncStream<SessionEvent>.Continuation] = [:]

    /// Creates a session and writes its `session.json` when the session is new.
    /// A failed sidecar write is logged and dropped.
    ///
    /// Each parameter is documented on the stored property it initializes.
    /// `recordingRoot` is not stored; the sidecar write reads it (see
    /// ``SessionSidecar/configuration``).
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
        persistedEntryCount: Int,
        historyOrdinal: Int,
        sidecarOrigin: SessionSidecarOrigin,
        contextTokens: Int,
        usageState: ContextUsageState = .none,
        autoCompactionBudget: TokenBudget? = nil,
        autoCompactionPrompt: CompactionPrompt = .default,
        summarization: Summarization = Summarization(),
        agentSpawn: SessionSidecar.AgentSpawn? = nil,
        discoveryPriming: DiscoveryPriming? = nil,
        toolOutputProtection: ToolOutputProtection? = nil,
        repetitionDetection: RepetitionDetection = RepetitionDetection(),
        recordingRoot: URL? = nil,
        tokenCounter: any TokenCounter,
        tracer: (any Tracer)?
    ) {
        self.toolOutputProtection = toolOutputProtection
        self.repetitionDetection = repetitionDetection
        self.tokenCounter = tokenCounter
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
        self.persistedEntryCount = persistedEntryCount
        self.persistedBaseline = TranscriptDiffer.Baseline(
            transcript: Transcript(entries: backend.transcriptEntries().prefix(persistedEntryCount)))
        self.historyOrdinal = historyOrdinal
        self.sidecarOrigin = sidecarOrigin
        self.contextTokens = contextTokens
        self.usageState = usageState
        self.autoCompactionBudget = autoCompactionBudget
        self.autoCompactionPrompt = autoCompactionPrompt
        self.summarization = summarization
        self.discoveryPriming = discoveryPriming
        self.agentSpawn = agentSpawn
        self.tracer = tracer
        // The initializer does not run the `didSet` of `backend`, so the
        // first backend gets this session's pass observer here.
        observeGenerationPasses(of: backend)

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
                grammar: grammar,
                repetitionDetection: repetitionDetection
            ).persistable,
            to: recordingDirectory
        )
    }
}
