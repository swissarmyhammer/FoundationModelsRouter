import Foundation
import FoundationModels
import FoundationModelsExtras
import Logging
import Metrics
import Synchronization
import Tracing

/// Writes one session's identity onto its ``RouterTelemetry/SpanName/session``
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
    origin: RouterTelemetry.SessionOrigin,
    routerId: ULID,
    sessionId: ULID,
    parentId: ULID?,
    model: ModelRef
) {
    span.attributes[RouterTelemetry.AttributeKey.routerId] = routerId.description
    span.attributes[RouterTelemetry.AttributeKey.modelRef] = model.stringValue
    span.attributes[RouterTelemetry.AttributeKey.sessionId] = sessionId.description
    span.attributes[RouterTelemetry.AttributeKey.sessionOrigin] = origin.rawValue
    if let parentId {
        span.attributes[RouterTelemetry.AttributeKey.parentSessionId] = parentId.description
    }
}

/// The kind every ``RouterTelemetry/SpanName/session`` span opens under.
///
/// Written here, and nowhere else, so the two `withSessionSpan` forms below
/// cannot drift apart on it. With the span's name and the one attribute writer
/// above, it leaves those two forms naming no value of their own: they carry a
/// different effect, and nothing else.
private let sessionSpanKind: SpanKind = .internal

/// Opens one ``RouterTelemetry/SpanName/session`` span around the work that
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
/// ``RouterTelemetry/SessionOrigin/restored`` session. The other two shapes have
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
/// - Throws: Whatever `work` throws, after the span records the error status
///   and the type of the error, never its description
///   (``RouterTelemetry/withSpan(_:ofKind:tracer:_:)``). A `work` that does
///   not throw makes this function throw nothing.
func withSessionSpan<Result, Failure: Error>(
    routerId: ULID,
    sessionId: ULID,
    parentId: ULID?,
    model: ModelRef,
    origin: RouterTelemetry.SessionOrigin,
    tracer: (any Tracer)?,
    _ work: () throws(Failure) -> Result
) throws(Failure) -> Result {
    try RouterTelemetry
        .withSpan(RouterTelemetry.SpanName.session, ofKind: sessionSpanKind, tracer: tracer) { span throws(Failure) in
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
/// - Throws: Whatever `work` throws, after the span records the error status
///   and the type of the error, never its description
///   (``RouterTelemetry/withSpan(_:ofKind:tracer:isolation:_:)``). A `work`
///   that does not throw makes this function throw nothing.
func withSessionSpan<Result, Failure: Error>(
    routerId: ULID,
    sessionId: ULID,
    parentId: ULID?,
    model: ModelRef,
    origin: RouterTelemetry.SessionOrigin,
    tracer: (any Tracer)?,
    _ work: () async throws(Failure) -> Result
) async throws(Failure) -> Result {
    try await RouterTelemetry
        .withSpan(RouterTelemetry.SpanName.session, ofKind: sessionSpanKind, tracer: tracer) { span async throws(Failure) in
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
/// ``RouterTelemetry/SpanName/session`` span. Each parameter but `origin`
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
/// enclosing ``RouterTelemetry/SpanName/fork`` span measures the whole fork;
/// the session span opened here measures only the construction inside it.
/// The session span is a child of the fork span — the fork opened its own
/// before it reached this factory, and the task-local `ServiceContext`
/// carries it here — so a reader sees one nested inside the other and never
/// adds the two together.
///
/// A ``RouterTelemetry/SessionOrigin/restored`` session gets no span from this
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
    runPlane: RunPlane = RunPlane(),
    persistedEntryCount: Int,
    historyOrdinal: Int,
    sidecarOrigin: SessionSidecarOrigin,
    origin: RouterTelemetry.SessionOrigin,
    contextTokens: Int,
    usageState: ContextUsageState = .none,
    autoCompactionBudget: TokenBudget? = nil,
    autoCompactionPrompt: CompactionPrompt = .default,
    agentSpawn: SessionSidecar.AgentSpawn? = nil,
    discoveryPriming: DiscoveryPriming? = nil,
    toolOutputProtection: ToolOutputProtection? = nil,
    repetitionDetection: RepetitionDetection = RepetitionDetection(),
    mailOnlyAnswerLimit: Int = SessionConfiguration.defaultMailOnlyAnswerLimit,
    inlineSettleGrace: TimeInterval = ToolMount.defaultInlineSettleGrace,
    isNoOpToolCall: @escaping NoOpToolCallCheck = SessionConfiguration.defaultIsNoOpToolCall,
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
            runPlane: runPlane,
            persistedEntryCount: persistedEntryCount,
            historyOrdinal: historyOrdinal,
            sidecarOrigin: sidecarOrigin,
            contextTokens: contextTokens,
            usageState: usageState,
            autoCompactionBudget: autoCompactionBudget,
            autoCompactionPrompt: autoCompactionPrompt,
            agentSpawn: agentSpawn,
            discoveryPriming: discoveryPriming,
            toolOutputProtection: toolOutputProtection,
            repetitionDetection: repetitionDetection,
            mailOnlyAnswerLimit: mailOnlyAnswerLimit,
            inlineSettleGrace: inlineSettleGrace,
            isNoOpToolCall: isNoOpToolCall,
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
    /// Each replacement reports its passes to ``generationPassObserver``, and
    /// keys the prompt cache by ``promptCacheSessionID`` (``adopt(_:)``). Each
    /// model call of it is one submission to its ``LanguageModelSessionBackend/generationQueue``.
    var backend: any LanguageModelSessionBackend {
        didSet { adopt(backend) }
    }

    /// The observer every backend of this session reports its passes to, and
    /// each submission of this session reports its wait and its start to
    /// (tasks ^ake8sax and ^1psqdm9). See ``drainGenerationPassPhases()``.
    ///
    /// It reads the clock of ``runPlane``, so one clock drives the stall
    /// watch of this session and the timers of its runs.
    nonisolated let generationPassObserver: GenerationPassObserver

    /// The helper tasks of this session: the stall watchdog, the reader of
    /// the pass reports and the repetition watch of each model call, and the
    /// wake of the pump after a mail (``mail(_:)``) and after a compaction
    /// (``performCompaction(_:_:)``). The drain of ``close()`` waits until
    /// each of them ended, so no helper task keeps the profile of this
    /// session when close returns.
    nonisolated let helperTasks = HelperTaskTracker()

    /// See ``RoutedSession/transcript``. Gives ``settledTranscript`` at once,
    /// from any task: it waits for nothing and reads nothing of ``backend``.
    var transcript: Transcript {
        get async { settledTranscript.transcript }
    }

    /// The transcript as of the last settled point, with the recording cut
    /// of that point (`generation-queue.md`, section 5.8). Each transcript
    /// read and each fork is served from it, so neither waits for a
    /// submission. ``settleTranscript()`` updates it.
    var settledTranscript: SettledTranscript

    /// Takes the transcript of ``backend`` as the new settled point, with the
    /// current recording cut.
    ///
    /// Call it only where no call of ``backend`` writes the transcript: at the
    /// end of a submission after its recording diff, after a reseed of
    /// ``backend``, and at a tool-result boundary of this session's own open
    /// model call (``noteToolResult(_:)``).
    func settleTranscript() {
        settledTranscript = SettledTranscript(
            entries: backend.transcriptEntries(), recordedEntryCount: persistedEntryCount,
            historyOrdinal: historyOrdinal)
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
    /// ``RouterTelemetry/tracer(explicit:)`` for the resolution rule, and
    /// ``RouterTelemetry`` for the rule that keeps content off a span.
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

    /// The mail queue of this session, of all kinds, and the held mail.
    /// Fresh per session.
    nonisolated let outbox: SessionOutbox

    /// The run plane of this session: the registry of tracked background runs
    /// and pending elicitations, from FoundationModelsExtras. Fresh per
    /// session.
    nonisolated let runPlane: RunPlane

    /// The pump of this session while it runs, or `nil` when no pump runs.
    /// See ``wakePump()``.
    var pumpTask: Task<Void, Never>?

    /// The end of all work of this session while it runs (``close()``), or
    /// `nil`. While it runs, no pump starts. See ``startDrainIfNeeded()``.
    var drainTask: Task<Void, Never>?

    /// Wakes each ``awaitIdle()`` call that waits for the next change of the
    /// work of this session. See ``signalWorkChange()``.
    ///
    /// It reports each change of its waiters (``ChangeSignal/waiterChanges``),
    /// so a test can wait until an ``awaitIdle()`` call waits.
    nonisolated let idleChanges = ChangeSignal(observingWaiters: true)

    /// Reports each change of a state of this session that sends no event of
    /// its own: a mail that ``mail(_:)`` put in the queue, a stop of the
    /// running work (``requestCancelOfRunningWork()``), a cancel of the
    /// running compaction (``cancelActiveCompaction()``), and an end of a
    /// question that waits for an answer on its way
    /// (``AskedQuestions/hasDeferredEnd(of:)``).
    ///
    /// Only the tests read it. A test reads the state, and waits on this
    /// signal for the next change when the state is not the state it wants.
    nonisolated let stateChanges = ChangeSignal()

    /// Reports each return of an answer of the client from the run plane
    /// (``noteAnswer(to:outcome:startedWork:)``). An end check that found a
    /// question gone while an answer was on its way waits on it until the
    /// answer returned (``awaitAnswersOnTheirWay(to:)``), and only then sends
    /// the terminal event that the end of the question must come before.
    /// ``close()`` waits on it until no end check holds an end
    /// (``awaitDeferredEnds()``) before the feeds end.
    ///
    /// It reports each change of its waiters (``ChangeSignal/waiterChanges``),
    /// so a test can wait until ``close()`` waits for such an answer.
    nonisolated let questionAnswerReturns = ChangeSignal(observingWaiters: true)

    /// Reports each read of the repetition watch that found no stop
    /// (``startRepetitionWatch()``). The watch first stores the texts of
    /// that read in ``lastRepetitionWatchRead``, then signals.
    ///
    /// Only the tests read it. A test that checks that the watch does not
    /// stop a call waits on this signal until the watch read the whole
    /// reasoning, and only then lets the call end.
    nonisolated let repetitionWatchReads = ChangeSignal()

    /// The texts of the attempt that the last read of the repetition watch
    /// gave to the detector, when that read found no stop. Empty before the
    /// first such read.
    ///
    /// Only the tests read it, with ``repetitionWatchReads``.
    nonisolated let lastRepetitionWatchRead = Mutex<[WatchedText]>([])

    /// Whether ``close()`` started. It stays set, so each ``awaitIdle()``
    /// call after it returns `false` at once, and the work of no signal
    /// starts after it (``runSignalWork(_:skipped:)``). See ``endIdleWaits()``.
    var isClosed = false

    /// Whether mail arrived since the pump last looked, so the pump takes
    /// one more cycle before it ends.
    var pumpWakeRequested = false

    /// The work the pump runs now, or `nil` between works.
    var pumpWork: PumpWork?

    /// The id of the last work the pump started. Ids are monotonic.
    var lastWorkId: UInt64 = 0

    /// The count of the requested compactions
    /// (``RoutedSession/compact(prompt:budget:)``) that wait in ``signals``
    /// or run. The idle check reads it (``awaitIdle()``).
    nonisolated let openRequestedCompactions = Mutex(0)

    /// The work state that the work events of this session reported last
    /// (``SessionEvent/workStarted`` and ``SessionEvent/workEnded``), and the
    /// count of the work starts. See ``noteWorkStarted()``.
    ///
    /// A lock keeps it, because ``mail(_:)`` and ``compact(prompt:budget:)``
    /// start work from any task. Each work event goes out while the lock is
    /// held, so the order of the events on the output is the order of the
    /// changes of this state.
    nonisolated let workEvents = Mutex(WorkEventState())

    /// The questions of the runs of this session that the journal recorded
    /// and that are possibly open, with the state of each one. See
    /// ``AskedQuestions``.
    var askedQuestions = AskedQuestions()

    /// The task of the compaction that runs now, or `nil`. Only the
    /// compaction handler (``performCompaction(_:_:)``) sets it, and only
    /// ``close()`` cancels it (``cancelActiveCompaction()``).
    var activeCompaction: Task<Result<CompactionResult, any Error>, Never>?

    /// Wakes each wait for the end of the running compaction
    /// (``awaitActiveCompaction()``).
    nonisolated let compactionEnds = ChangeSignal()

    /// Wakes each wait of a compaction for the end of the open submission
    /// (``endSubmission(usage:finishReason:measuredRender:onEvent:)``).
    nonisolated let submissionCloses = ChangeSignal()

    /// The ids of the mail of the open answer, in delivery order: the mail
    /// of its first submission and the mail that joined a continuation. A
    /// mail that a failed submission gave back to the queue leaves it. The
    /// pump sets it at the take and clears it after the terminal event of
    /// the answer. ``mail(_:)`` reads it from any task to refuse a duplicate
    /// id.
    nonisolated let openAnswerMail = OpenAnswerMail()

    /// The run mail of the open answer, in delivery order. A failed
    /// submission gives its run mail back with the same ids
    /// (``requeueUndeliveredRunMail(_:)``).
    var openAnswerRunMail: [Mail] = []

    /// Whether the open answer delivered user-type mail, also mail that
    /// joined a continuation. ``countAnswer()`` reads it.
    var openAnswerDeliveredUserMail = false

    /// The output of this session: the feeds, the mail subscriptions and the
    /// ledger of the terminal events. See ``emitSessionScopedEvent(_:)``.
    nonisolated let outputHub = SessionOutputHub()

    /// The serial chain that writes the mail records of this session in the
    /// order of the calls (``recordMail(_:)``). See
    /// `RoutedSessionActorMailRecords.swift`.
    nonisolated let mailRecordChain = Mutex(SerialAsyncChain())

    /// The serial executor of the signals of this session. Each signal runs
    /// after the earlier one.
    nonisolated let signals = SignalExecutor()

    /// The sweep of the background runs that ``cancelAll()`` started, or
    /// `nil`. ``cancelAll()`` does not wait for it, because the canceler of a
    /// run can be slow. ``close()`` waits for it. A later sweep waits for the
    /// earlier one.
    var sweepTask: Task<Void, Never>?

    /// The in-flight model call of the work the pump runs, the task
    /// ``requestCancelOfRunningWork()`` cancels, or `nil` when no model call
    /// is outstanding. Only the model call runs in this task; the recording
    /// of its submission runs afterwards. A cancel of the task removes a
    /// submission that waits for the worker, or cancels the running
    /// submission.
    var inFlightModelCall: Task<String, Error>?

    /// The work a cancel has been requested for, or `nil`. A cancellation
    /// recorded here lands on the next model call of the work. The pump
    /// clears it when the work ends. ``isWorkCancelled`` is its one read
    /// site.
    var cancelRequestedWorkId: UInt64?

    /// Whether the session's first-line `session` meta event has been recorded.
    /// Set before the meta append, so no reentrant call can emit it twice.
    var didRecordSessionMeta = false

    /// Whether this session has installed itself as ``outbox``'s
    /// ``OperationEventJournal``. Set by ``attachOutboxJournalIfNeeded()``.
    var didAttachOutboxJournal = false

    /// The composed event sink of the running answer (see
    /// ``answerEventSink()``), or `nil` between answers.
    /// ``deliver(invocation:)`` uses it to hand a live
    /// ``SessionEvent/toolInvocation(_:toolCallID:)`` to the running answer.
    var currentAnswerEventSink: ((SessionEvent) -> Void)?

    /// The join of the live tool run records of this session to the SDK tool
    /// calls that started them. ``deliver(invocation:)`` reads it for each
    /// record. See ``ToolCallRunJoin``.
    var toolCallRunJoin = ToolCallRunJoin()

    /// The number of the last submission this session opened. The next
    /// ``SubmissionID`` takes the next number. See
    /// ``beginSubmission(cause:mailIds:)``.
    var lastSubmissionNumber: UInt64 = 0

    /// The submission of the running answer that is open now, or `nil`
    /// between two submissions and between answers.
    var runningSubmission: RunningSubmission?

    /// The reducer of the running answer: each event of the answer goes
    /// through it (``answerEventSink()``), and the pump makes the
    /// ``SessionAnswer`` from it when the chain ends. The pump resets it for
    /// each answer.
    var answerReducer = SessionAnswerReducer()

    /// The ledger of the generate attempt in flight, or `nil` between
    /// attempts and when the backend reports no usage. See
    /// ``GenerationCallLedger``.
    var generationCallLedger: GenerationCallLedger?

    /// What the generate attempt in flight saw at its tool-result
    /// boundaries. See ``ToolResultWatch`` and ``noteToolResult(_:)``.
    var toolResultWatch = ToolResultWatch()

    /// Whether the running answer stops compacting inside the answer, at a
    /// tool result or at a ceiling stop: set when such a compaction applied
    /// no summary (``compactAndContinue(attempt:reason:continuationPrompt:reasoningOff:body:)``),
    /// and cleared by the pump for each new answer.
    var compactionYieldsStopped = false

    /// The repetition watch of this session: the watch of the model call in
    /// flight, its stop marker, and the recoveries of the running answer.
    /// See ``runWatchedModelCall(composedPrompt:_:)``.
    var repetitionWatch = RepetitionWatchState()

    /// The settings of the repetition watch this session was vended,
    /// forked or restored with. A fork carries it forward, and the sidecar
    /// records it. See ``RepetitionDetection``.
    nonisolated let repetitionDetection: RepetitionDetection

    /// The most answers in a row that mail alone starts, which this session
    /// was vended, forked or restored with. A fork carries it forward, and
    /// the sidecar records it. See ``SessionConfiguration/mailOnlyAnswerLimit``.
    nonisolated let mailOnlyAnswerLimit: Int

    /// How long each background tool call of this session waits for its own
    /// run, in seconds, which this session was vended, forked or restored
    /// with. Never negative. The mount site of each tool of the session holds
    /// it. A fork carries it forward, and the sidecar records it. See
    /// ``SessionConfiguration/inlineSettleGrace``.
    nonisolated let inlineSettleGrace: TimeInterval

    /// The host check that marks a tool call as a no-op, which this session
    /// was vended or forked with. A fork carries it forward. The sidecar never
    /// records it, because it is a closure. See ``NoOpToolCallCheck`` and
    /// ``checkToolCallForNoOp(toolName:arguments:)``.
    nonisolated let isNoOpToolCall: NoOpToolCallCheck

    /// The stop marker of the model call in flight when a no-op tool call
    /// stopped it, else `nil`. ``openGenerationCallLedger(usageBefore:responseTokenCeiling:)``
    /// clears it for each attempt. See ``NoOpToolCallStop``.
    var noOpToolCallStop: NoOpToolCallStop?

    /// The round of tool calls in flight, as the no-op check reads it: its
    /// real results and the count of its real calls. See
    /// ``NoOpToolCallRound``.
    var noOpToolCallRound = NoOpToolCallRound()

    /// Wakes each no-op tool call that waits for the real calls of its round
    /// (``noteRealToolResult(_:)``).
    nonisolated let noOpRoundChanges = ChangeSignal()

    /// How many answers in a row run mail alone started since the last
    /// answer that delivered user-type mail. The pump counts it, and holds
    /// new mail when it reaches ``mailOnlyAnswerLimit`` (``countAnswer()``).
    var mailOnlyAnswersInARow = 0

    /// The stall watch over the one model call in flight, or `nil` between
    /// calls. See ``beginGenerationStallWatch()`` and ``GenerationStall``.
    var generationStallWatch: GenerationStallWatch?

    /// Reports each append that the stall watch of the model call in flight
    /// noted (``noteGenerationProgress(_:)``).
    ///
    /// Only the tests read it. An append with no text sends no event, so a
    /// test reads the watch, and waits on this signal for the next append
    /// when the watch does not yet name the append it wants.
    nonisolated let generationProgressChanges = ChangeSignal()

    /// The last id ``beginGenerationStallWatch()`` handed out. Monotonic.
    var lastGenerationStallWatchId: UInt64 = 0

    /// How long a model call may run with no observable progress before it
    /// reports a ``GenerationStall``. It is `.zero`, which means off, until the
    /// host installs an interval through
    /// ``setGenerationStallReportInterval(_:)``. A fork starts with its
    /// parent's interval.
    var generationStallReportInterval: Duration = .zero

    /// The explicit logger of this session, or `nil` for the loggers of the
    /// module. See ``useLogger(_:)`` and ``sessionLogger(_:)``.
    ///
    /// The pump is a `Task.detached` and inherits no task-local of the
    /// caller, so a task-local logging context never reaches its records. A
    /// test or a host gives an explicit logger so that each record of the
    /// session, also a record of the pump, goes to it. A fork starts with the
    /// explicit logger of its parent. The pump also binds it as
    /// ``RouterTelemetry/pumpJobLogger`` around each job
    /// (``withSessionLogger(_:)``), so a log call that the job reaches and
    /// that has no session to ask, for example a log call of the transcript
    /// recording, goes to it. A compaction gives it to ``Compactor``, so the
    /// record of a ``CompactionShortfall`` goes to it.
    var explicitLogger: Logging.Logger?

    /// The explicit metrics factory of this session, or `nil` to read
    /// `MetricsSystem.factory` at each record call. See
    /// ``useMetricsFactory(_:)`` and ``sessionMetrics``.
    ///
    /// The same reason as for ``explicitLogger``: the pump is a
    /// `Task.detached`, so the task-local factory of a caller never reaches
    /// its metrics. A fork starts with the explicit factory of its parent.
    /// The pump also binds it as the task-local factory around each job
    /// (``withSessionMetricsFactory(_:)``), so the metrics of a dependency,
    /// for example the tool-call metrics of FoundationModelsExtras, go to it.
    ///
    /// It is behind a lock and not actor state, because the output of the
    /// session (``emitSessionScopedEvent(_:failure:audience:)``) is
    /// nonisolated and records metrics too. Write it through
    /// ``explicitMetricsFactoryState``.
    nonisolated var explicitMetricsFactory: (any MetricsFactory)? {
        explicitMetricsFactoryState.withLock { $0 }
    }

    /// The lock and the value of ``explicitMetricsFactory``.
    nonisolated let explicitMetricsFactoryState = Mutex<(any MetricsFactory)?>(nil)

    /// The `correlationID` of every background run whose ending this session has
    /// already journaled. A second write for one run is a no-op. See
    /// ``claimJournalWrite(for:)``.
    var journaledTerminalCorrelationIDs: Set<String> = []

    /// The progress row that is open: the consecutive progress events of one
    /// run that the journal writes as one merged transcript row, or `nil`
    /// when no row is open. The next different event closes it. See
    /// ``record(event:)`` and ``closeOpenProgressRow()``.
    var openProgressRow: OpenProgressRow?

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
    /// exists before the first submission: empty for a root, the parent's
    /// entries for a fork, the seed transcript for a restore.
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
    /// ``finishSubmission(grammar:since:usageBefore:responseTokenCeiling:deliveredMail:onEvent:stopReason:replacedBackend:)``
    /// sets it to the fed and generated tokens of the newest generation call of
    /// the attempt, never to the sum of the calls, and only when the diff of
    /// the submission included a `.response` entry. A compaction restarts it
    /// from the instructions and the new snapshot (task ^tpsc0nf).
    var usageState: ContextUsageState

    /// The auto-compaction opt-in, or `nil` for manual-only compaction. When
    /// set, an answer compacts automatically at ``TokenBudget/triggerTokens``,
    /// and a submission that overflows mid-generation is compacted harder and
    /// retried once. A fork carries it forward.
    nonisolated let autoCompactionBudget: TokenBudget?

    /// The compaction prompt auto-compaction's own compactions send to the
    /// summarizer, when ``autoCompactionBudget`` is set. Ignored otherwise.
    nonisolated let autoCompactionPrompt: CompactionPrompt

    /// The pre-discovery seeding opt-in, or `nil`. When set, each answer runs
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
        runPlane: RunPlane = RunPlane(),
        persistedEntryCount: Int,
        historyOrdinal: Int,
        sidecarOrigin: SessionSidecarOrigin,
        contextTokens: Int,
        usageState: ContextUsageState = .none,
        autoCompactionBudget: TokenBudget? = nil,
        autoCompactionPrompt: CompactionPrompt = .default,
        agentSpawn: SessionSidecar.AgentSpawn? = nil,
        discoveryPriming: DiscoveryPriming? = nil,
        toolOutputProtection: ToolOutputProtection? = nil,
        repetitionDetection: RepetitionDetection = RepetitionDetection(),
        mailOnlyAnswerLimit: Int = SessionConfiguration.defaultMailOnlyAnswerLimit,
        inlineSettleGrace: TimeInterval = ToolMount.defaultInlineSettleGrace,
        isNoOpToolCall: @escaping NoOpToolCallCheck = SessionConfiguration.defaultIsNoOpToolCall,
        recordingRoot: URL? = nil,
        tokenCounter: any TokenCounter,
        tracer: (any Tracer)?
    ) {
        self.toolOutputProtection = toolOutputProtection
        self.isNoOpToolCall = isNoOpToolCall
        self.repetitionDetection = repetitionDetection
        self.mailOnlyAnswerLimit = mailOnlyAnswerLimit
        self.inlineSettleGrace = max(0, inlineSettleGrace)
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
        self.runPlane = runPlane
        self.generationPassObserver = GenerationPassObserver(clock: runPlane.clock)
        self.persistedEntryCount = persistedEntryCount
        // A new backend runs no call yet, so its transcript is the first
        // settled point of the session.
        let seedEntries = backend.transcriptEntries()
        self.persistedBaseline = TranscriptDiffer.Baseline(
            transcript: Transcript(entries: seedEntries.prefix(persistedEntryCount)))
        self.historyOrdinal = historyOrdinal
        self.settledTranscript = SettledTranscript(
            entries: seedEntries, recordedEntryCount: persistedEntryCount, historyOrdinal: historyOrdinal)
        self.sidecarOrigin = sidecarOrigin
        self.contextTokens = contextTokens
        self.usageState = usageState
        self.autoCompactionBudget = autoCompactionBudget
        self.autoCompactionPrompt = autoCompactionPrompt
        self.discoveryPriming = discoveryPriming
        self.agentSpawn = agentSpawn
        self.tracer = tracer
        // The initializer does not run the `didSet` of `backend`, so the
        // first backend gets this session's pass observer and prompt-cache
        // key here.
        adopt(backend)
        // Before any pump or signal runs: from here on, each run mail of the
        // outbox is pending in the output of this session before its put.
        outbox.bind(outputHub: outputHub)

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
                compaction: CompactionSettings(budget: autoCompactionBudget, prompt: autoCompactionPrompt),
                agentSpawn: agentSpawn,
                discoveryPriming: discoveryPriming,
                grammar: grammar,
                repetitionDetection: repetitionDetection,
                mailOnlyAnswerLimit: mailOnlyAnswerLimit,
                inlineSettleGrace: self.inlineSettleGrace,
                // The run plane holds the one copy of the user presence, so
                // the sidecar records the presence that the session runs with.
                userPresence: self.runPlane.userPresence
            ).persistable,
            to: recordingDirectory
        )
    }
}
