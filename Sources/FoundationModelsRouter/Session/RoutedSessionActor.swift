import Foundation
import FoundationModels

/// Builds a ``RoutedSessionActor``, the shared construction path behind both a
/// fresh root session (``RoutedModel/makeSession(grammar:instructions:workingDirectory:recordingRoot:tools:budget:compactionPrompt:summarization:agentSpawn:discoveryPriming:)``)
/// and a forked child (``RoutedSessionActor/fork(workingDirectory:)``).
///
/// The two call sites' constructor invocations used to be near-verbatim
/// duplicates of each other, differing only in the values they passed —
/// duplication that meant any change to ``RoutedSessionActor``'s initializer
/// (a new parameter, a reordering) had to be applied in two places and could
/// silently drift. Factoring the call out here means it is made in exactly
/// one place; each call site just forwards the values it already has in
/// scope (a root session's freshly computed identity/directory/zero baseline,
/// or a fork's inherited profile/gates plus its own child identity and
/// fork-time baseline).
///
/// Each parameter corresponds one-for-one with a parameter of
/// ``RoutedSessionActor/init(profile:routerId:id:parentId:recordingDirectory:workingDirectory:backend:slot:model:recorder:instructions:grammar:tools:originalTools:outbox:mailbox:generationGate:forkAdmissionGate:holdsAdmissionPermit:persistedEntryCount:historyOrdinal:sidecarOrigin:contextTokens:usageState:autoCompactionBudget:autoCompactionPrompt:summarization:agentSpawn:discoveryPriming:recordingRoot:)``
/// and forwards unchanged — see that initializer's documentation for what
/// each value means.
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
    recordingRoot: URL? = nil
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
        recordingRoot: recordingRoot
    )
}

/// The concrete ``RoutedSession``, backed by a ``LanguageModelSessionBackend``.
///
/// It is `internal` with an `internal` initializer so the only way to obtain one
/// is ``RoutedModel/makeSession(instructions:workingDirectory:recordingRoot:tools:budget:compactionPrompt:summarization:agentSpawn:discoveryPriming:)`` — there is no
/// public initializer. The recorder and `routerId` flow down from the vending
/// handle; the `backend`, `slot`, and `model` are what the single
/// ``generate(grammar:prompt:onEvent:_:)`` chokepoint runs the model with.
actor RoutedSessionActor: RoutedSession {
    /// The resolved profile this session runs against, retained so its
    /// resident models stay alive for the session's lifetime — see
    /// ``RoutedSession/profile``.
    nonisolated let profile: LanguageModelProfile

    /// The recording root id — the router instance that owns this transcript
    /// (see ``RoutedSession/routerId``).
    nonisolated let routerId: ULID

    /// This session's span id — see ``RoutedSession/id``.
    nonisolated let id: ULID

    /// The span id of the session that forked this one, or `nil` for a root
    /// session — see ``RoutedSession/parentId``.
    nonisolated let parentId: ULID?

    /// The directory this session's transcript is recorded under — see
    /// ``RoutedSession/recordingDirectory``.
    nonisolated let recordingDirectory: URL

    /// The directory model/tool work runs relative to; defaults to
    /// ``recordingDirectory`` and is overridable at creation — see
    /// ``RoutedSession/workingDirectory``.
    nonisolated let workingDirectory: URL

    /// The persistent backend this session drives every generation and fork
    /// through, for the session's whole lifetime.
    ///
    /// Born already carrying this session's instructions (baked in when it was
    /// manufactured by ``LoadedLLMContainer/makeSession(instructions:)``), so
    /// generation calls no longer pass `instructions` per turn, and calls
    /// accumulate conversation state across turns instead of each starting a
    /// fresh backend. Never vended to callers.
    ///
    /// Actor-isolated (not `nonisolated`) rather than a `let`: unlike every
    /// other identity/configuration field here, this one *does* change after
    /// construction — ``compact(prompt:budget:)`` swaps it for a fresh
    /// backend seeded from the folded transcript once folding actually
    /// changes something (compaction_plan.md §1.4, "swap the inner Apple
    /// session"), while every other stored property on this actor keeps this
    /// session's identity (``id``, ``recordingDirectory``, ``recorder``)
    /// fixed for its whole lifetime.
    var backend: any LanguageModelSessionBackend

    /// See ``RoutedSession/transcript``.
    ///
    /// Reads ``backend``'s own accumulated entries under ``turnLock`` — the
    /// same lock discipline ``fork(workingDirectory:)`` takes for the same
    /// read: a concurrent turn suspends across its model call while its
    /// backend mutates the underlying transcript, so an unlocked read could
    /// observe a turn mid-append. The lock is released as soon as the
    /// entries are captured.
    var transcript: Transcript {
        get async {
            await turnLock.wait()
            defer { turnLock.signal() }
            return Transcript(entries: backend.transcriptEntries())
        }
    }

    /// The slot this session's model fills, stamped onto recorded events.
    nonisolated let slot: ModelSlot

    /// The concrete model reference, stamped onto recorded events.
    nonisolated let model: ModelRef

    /// The non-optional recorder every generation brackets through.
    nonisolated let recorder: any TranscriptRecorder

    /// The session's system instructions, baked into ``backend`` at
    /// construction; retained here only to carry forward into a forked child's
    /// actor state.
    nonisolated let instructions: String?

    /// The grammar constraining every ``respond(to:)``, or `nil` for an
    /// unconstrained session.
    ///
    /// Travels with the session so a fork inherits it.
    nonisolated let grammar: Grammar?

    /// The tools this session was constructed with, before any per-session
    /// instancing — retained purely so ``fork(workingDirectory:)`` can build
    /// the child's own tool list via fork-then-detach composition, sourced
    /// from these true originals rather than from ``tools``' already-instanced
    /// copies (see ``fork(workingDirectory:)``'s doc comment).
    nonisolated let originalTools: [any Tool]

    /// This session's own per-session tool list: every String-output tool
    /// among ``originalTools`` wrapped in the ``DetachingTool`` layer — whose
    /// ambient ``ToolContext`` posts the tool's events to ``outbox`` — and,
    /// when a budget carries a `toolOutputLimit`, the capping layer, applied
    /// per the owning composition site's own chain: detach → cap at a root,
    /// fork → detach → cap at a fork, detach at
    /// restore (task ^k4nygqa); a non-String-output tool is wrapped in the
    /// binding-only ``ContextBindingTool`` — same per-call, per-tool-stamped
    /// ambient ``ToolContext``, no pending-envelope/park machinery — and
    /// passes through the capping layer unwrapped (see
    /// ``RoutedModel/makeSessionToolWiring(_:sessionID:cappedToTokenLimit:)``).
    /// This is the
    /// exact list threaded to the backend/underlying `LanguageModelSession(tools:)`
    /// — at construction for a root session (``RoutedModel/makeSession(grammar:instructions:workingDirectory:recordingRoot:tools:budget:compactionPrompt:summarization:agentSpawn:discoveryPriming:)``
    /// computes it before the backend exists), or via
    /// ``LanguageModelSessionBackend/makeFork(tools:)`` for a fork (see
    /// ``fork(workingDirectory:)``) — retained here too so it stays
    /// inspectable without a live model.
    nonisolated let tools: [any Tool]

    /// This session's own outbox: the staging area for tool events posted by
    /// long-running work and queued user prompts, both destined to enter the
    /// conversation at a future turn boundary. See ``SessionOutbox``.
    ///
    /// Fresh per session: a root session is constructed already holding a
    /// brand-new, empty outbox and its own ``tools`` instanced to it (a pure
    /// map, computed by the caller before this session exists — see
    /// ``RoutedModel/makeSession(grammar:instructions:workingDirectory:recordingRoot:tools:budget:compactionPrompt:summarization:agentSpawn:discoveryPriming:)``);
    /// ``fork(workingDirectory:)`` builds another fresh outbox for the child
    /// and its own fork-then-detach composed tool list instead — deliberately
    /// not sharing this session's outbox with the fork. Because this
    /// session's own already-instanced ``tools`` carry their own detachment
    /// layer bound to this outbox, they keep posting to this outbox
    /// forever, regardless of how many further forks are taken: event
    /// delivery never migrates between sessions.
    nonisolated let outbox: SessionOutbox

    /// This session's own mailbox: the registry of parked detached runs and
    /// pending elicitations. See ``SessionMailbox``.
    ///
    /// Fresh per session, with the same scope rule as ``outbox``: a root
    /// session is constructed already holding a brand-new, empty mailbox,
    /// ``fork(workingDirectory:)`` builds another fresh one for the child,
    /// and a restored session gets a brand-new one — so parked runs and
    /// pending elicitations never migrate between sessions.
    nonisolated let mailbox: SessionMailbox

    /// This session's own turn lock (a fair FIFO ``AsyncSemaphore`` at value 1)
    /// — the correctness half of the split gate.
    ///
    /// Taken for the whole of every turn and never handed back early, so this
    /// session never has two turns in flight and a concurrent
    /// ``fork(workingDirectory:)``'s read of ``backend``'s conversation state is
    /// serialized against any turn still in flight — including one parked in
    /// ``awaitingUser(_:)``. Fresh per session: a fork gets its own, since it
    /// drives its own backend.
    ///
    /// Not `private` only so a test can observe its
    /// ``AsyncSemaphore/waiterCount``, exactly as ``RoutedModel/generationGate``
    /// is; only ``beginTurn()``, ``endTurn()``, and ``fork(workingDirectory:)`` take it.
    nonisolated let turnLock = AsyncSemaphore(value: 1)

    /// The per-model generation gate, shared with the owning model's other
    /// sessions and forks — the throughput half of the split gate.
    ///
    /// Serializes real model work across one model's whole family of sessions
    /// and forks, so generations queue rather than interleave. Unlike
    /// ``turnLock`` this one *is* handed back mid-turn, for a wait on a person
    /// — see ``awaitingUser(_:)``.
    nonisolated let generationGate: AsyncSemaphore

    /// Whether the turn in flight on this session holds a ``generationGate``
    /// permit.
    ///
    /// `false` between turns and while a human wait has handed the permit back,
    /// so ``awaitingUser(_:)`` can tell a real mid-turn release from a call made
    /// with no turn in flight at all — where signalling would mint a permit this
    /// session never acquired.
    var holdsGenerationPermit = false

    /// How many ``awaitingUser(_:)`` calls are currently outstanding on this
    /// session.
    ///
    /// Only the outermost releases the generation permit and only the last to
    /// finish re-acquires it, so two tools of one turn both awaiting a person
    /// cannot double-signal the gate.
    var humanWaitDepth = 0

    /// The id of the turn currently holding ``turnLock``, or `nil` between turns.
    ///
    /// Identities rather than a flag because the question a human wait has to
    /// answer is not "was a permit released?" but "is the turn that lent it still
    /// the one in flight?" — and it has to answer that *after* its re-acquire
    /// suspends, by which time the answer may have changed. Monotonic, so a later
    /// turn can never be mistaken for the one that lent (no ABA).
    var currentTurnId: UInt64?

    /// The last id ``beginTurn()`` handed out.
    var lastTurnId: UInt64 = 0

    /// The turn the outermost outstanding ``awaitingUser(_:)`` borrowed this
    /// session's generation permit from, or `nil` when no loan is open.
    var humanWaitLenderTurnId: UInt64?

    /// The in-flight turn's model call — the task ``cancelCurrentTurn()`` cancels
    /// — or `nil` whenever no model call is outstanding.
    ///
    /// Only the model call itself runs in this task, never the turn's recording:
    /// cancelling it unwinds `body` and every tool the SDK invoked from inside
    /// it, while the snapshot diff, the synthetic close, and the
    /// attach-or-requeue decision all run afterwards on the ordinary throwing
    /// path. That is what makes a cancelled turn a *recorded* turn rather than a
    /// half-written one.
    var inFlightModelCall: Task<String, Error>?

    /// The turn a ``cancelCurrentTurn()`` has been requested for, or `nil` when
    /// none is outstanding.
    ///
    /// A cancellation can land while a turn holds ``turnLock`` with no model call
    /// outstanding to cancel — inside the deterministic stages of an
    /// auto-compaction fold, between two of a fold's summarizer calls, or between
    /// a failed attempt and its overflow retry. Recording it here is what
    /// makes that cancellation land on the turn's next model call instead of
    /// being dropped. Keyed by turn identity rather than a bare flag, so it can
    /// never bleed into a later turn (ids are monotonic, and ``endTurn()`` clears
    /// it regardless).
    var cancelRequestedTurnId: UInt64?

    /// How many cancellation requests ``cancelCurrentTurn()`` has recorded on
    /// this session, ever.
    ///
    /// Monotonic and never cleared, unlike ``cancelRequestedTurnId``, which
    /// ``endTurn()`` clears the moment its turn ends. That is what a caller
    /// spanning more than one turn needs: ``respond(to:maxTokens:)``'s
    /// run-plane drain asks, after its turn has already ended, whether a
    /// cancellation landed on that turn — and by then the turn's id is gone.
    /// Comparing this count against the one it snapshotted answers that
    /// without reviving the turn's identity.
    var cancelRequestCount: UInt64 = 0

    /// The fork-admission gate, shared with the owning model.
    ///
    /// ``fork(workingDirectory:)`` acquires a permit to admit the child; a fork
    /// releases it on deinit (see ``holdsAdmissionPermit``).
    nonisolated let forkAdmissionGate: AsyncSemaphore

    /// Whether this session holds a fork-admission permit to release when it is
    /// deallocated.
    ///
    /// `true` for a fork admitted through ``fork(workingDirectory:)``, `false`
    /// for a root session, which consumes no admission permit.
    nonisolated let holdsAdmissionPermit: Bool

    /// Whether the session's first-line `session` meta event has been recorded.
    ///
    /// The chokepoint emits the meta event lazily, before the first turn's open
    /// event, so a session that never generates writes no file at all while one
    /// that does always opens its transcript with a `session` line. Guarded by the
    /// actor's isolation and flipped before the meta append, so no reentrant turn
    /// can emit it twice.
    var didRecordSessionMeta = false

    /// Whether this session has installed itself as ``outbox``'s
    /// ``OperationEventJournal``.
    ///
    /// Flipped by ``attachOutboxJournalIfNeeded()`` at the top of the first
    /// turn — the earliest point at which a tool of this session's own could
    /// post a run event. Guarded by the actor's isolation, so a reentrant turn
    /// cannot attach twice.
    var didAttachOutboxJournal = false

    /// The in-flight turn's composed event sink — the ``turnEventSink(_:)``
    /// closure `runTurn` builds, which reaches the turn's own stream (when the
    /// turn has one) and every session-scoped subscription — or `nil` between
    /// turns.
    ///
    /// Installed by `runTurn` for exactly the turn's duration and cleared by
    /// its `defer`, so ``deliver(invocation:)`` can hand a live
    /// ``SessionEvent/toolInvocation(_:)`` to the current turn the moment a
    /// binding layer posts its record: the actor is free while the turn
    /// awaits its model call, so the delivery interleaves mid-turn by actor
    /// reentrancy. Guarded by the actor's isolation, and a session runs one
    /// turn at a time (``turnLock``), so the sink can never belong to any
    /// turn but the current one.
    var currentTurnEventSink: ((SessionEvent) -> Void)?

    /// The `correlationID` of every detached run whose ending this session has
    /// already journaled.
    ///
    /// A run's ending reaches the journal from two independent writers — the
    /// run's own terminal, posted through ``outbox``, and the one
    /// ``SessionMailbox/sweep()`` produces at ``close()`` — and they can both
    /// fire for one run, with contradicting outcomes. This is what makes the
    /// second write a no-op instead of a second recorded ending. Guarded by the
    /// actor's isolation and claimed before any suspension, so the two writers
    /// cannot both claim one run. See ``claimJournalWrite(for:)`` for the races
    /// and for why the set is deliberately unbounded.
    var journaledTerminalCorrelationIDs: Set<String> = []

    /// The positional diff baseline against the *current* ``backend``
    /// transcript: how many of ``LanguageModelSessionBackend/transcriptEntries()``
    /// have already been persisted (or were inherited), so each turn's
    /// post-generation snapshot can diff against it to find only what the SDK
    /// appended *this* turn.
    ///
    /// `0` for a root session — nothing has been persisted yet. For a fork,
    /// this is the parent's entry count *at fork time*
    /// (``fork(workingDirectory:)`` captures it inside the turn-lock window it
    /// takes, before ``LanguageModelSessionBackend/makeFork()`` seeds
    /// the child), so the inherited history the child's backend starts holding
    /// is never re-persisted into the child's own transcript.
    ///
    /// **Positional, not append-only.** This legitimately resets whenever the
    /// backend transcript is swapped — a fold rewinds it to the folded
    /// window's count — so it must never be read as the session's position in
    /// its own recorded history. That coordinate is ``historyOrdinal``, which
    /// only grows.
    var persistedEntryCount: Int

    /// The identity of the ``persistedEntryCount``-long backend prefix this
    /// session has already persisted — the recorded entry ids plus the
    /// boundary entry's mapped payload (``TranscriptDiffer/Baseline``) — or
    /// `nil` when no verifiable identity exists yet.
    ///
    /// ``persistedEntryCount`` alone cannot detect a non-append backend
    /// change: the chokepoint reads its "last seen" prefix out of the
    /// *current* backend transcript, so a rewritten or displaced prefix
    /// entry trivially matches itself. This captures what the prefix looked
    /// like when it was recorded, so `recordTranscriptDelta` can verify it
    /// still stands (``TranscriptDiffer/divergence(from:in:)``) before
    /// diffing.
    ///
    /// `nil` at construction — a root has recorded nothing, and a fork's or
    /// restored session's inherited prefix is established by its first
    /// successful diff — and reset to `nil` by the shrink guard, whose count
    /// reset makes the prefix name entries this session never recorded, so
    /// there is no identity to verify until the next successful diff
    /// re-establishes one. Refreshed wherever ``persistedEntryCount`` is
    /// refreshed otherwise: after every successful diff, after a detected
    /// divergence (to the current transcript, so later turns verify against
    /// reality), and after a compaction fold (to the folded window).
    var persistedBaseline: TranscriptDiffer.Baseline?

    /// This session's position in its own append-only recorded history: how
    /// many entry-kind events (``TranscriptEvent/Kind/isEntryKind``) its
    /// effective recorded stream holds — the inherited prefix it started
    /// from, plus every entry-kind event ``append(partial:)`` has recorded
    /// since. Counted at that one choke point, so it counts exactly what
    /// ``TranscriptTree/effectiveEntryEvents(forSession:)`` counts.
    ///
    /// Starts at `0` for a vended root, at the parent's ordinal at fork time
    /// for a fork (which is also the cut point its sidecar records — see
    /// ``SessionSidecar/forkedAtHistoryOrdinal``), and at the reconstructed
    /// effective entry-event count for a restored session. Unlike
    /// ``persistedEntryCount``, it never rewinds: compaction is append-only,
    /// so a fold *grows* it by the recorded boundary entry while the
    /// positional baseline shrinks to the folded window.
    var historyOrdinal: Int

    /// Where this session's `session.json` comes from: its own write at init
    /// when the session is new, or the tree it was restored from.
    ///
    /// Inherited from the vending handle — so a fork's sidecar states the same
    /// slot/model/context this session's does — and handed on to every fork
    /// taken from this session (see ``SessionSidecarOrigin/forFork``).
    nonisolated let sidecarOrigin: SessionSidecarOrigin

    /// The resolved working context, in tokens, ``contextFill`` divides its
    /// numerator by — the profile's ``SlotResolution/contextTokens`` for this
    /// session's slot (compaction_plan.md §1.5).
    nonisolated let contextTokens: Int

    /// The state ``contextFill`` derives its numerator from: nothing yet, a
    /// measured usage, or (restored, unstamped) unknown. See
    /// ``ContextUsageState``.
    ///
    /// Updated by ``finishTurn(grammar:since:usageBefore:pendingEvents:onEvent:)``
    /// only when the SDK's own transcript diff actually included a
    /// `.response`-kind entry for the turn — a turn rejected before ever
    /// touching the backend (e.g. a guided turn whose grammar validation
    /// throws pre-flight) leaves this session's last known fill untouched
    /// rather than resetting it to a meaningless zero delta.
    var usageState: ContextUsageState

    /// The auto-compaction opt-in (the "session manages its own
    /// window", task 8213x39), or `nil` for the default manual-only
    /// behavior. When set, ``runTurn(grammar:turnId:promptId:pendingEvents:ownPrompt:onEvent:_:)``
    /// checks measured context usage against ``TokenBudget/triggerTokens``
    /// before every turn and folds automatically once it has been reached, and a
    /// turn that still overflows mid-generation
    /// (`LanguageModelError.contextSizeExceeded`) is compacted harder and
    /// retried exactly once before the error surfaces. Set at construction
    /// (``RoutedModel/makeSession(instructions:workingDirectory:recordingRoot:tools:budget:compactionPrompt:summarization:agentSpawn:discoveryPriming:)``)
    /// and carried forward by ``fork(workingDirectory:)`` — a fork manages
    /// its own window exactly like its parent.
    nonisolated let autoCompactionBudget: TokenBudget?

    /// The compaction prompt auto-compaction's own folds send to the
    /// summarizer, when ``autoCompactionBudget`` is set. Ignored otherwise.
    nonisolated let autoCompactionPrompt: CompactionPrompt

    /// The model-assisted compaction stage every fold this session runs uses —
    /// the caller-driven ``compact(prompt:budget:)`` and the automatic
    /// ``performAutoCompaction(prompt:budget:)`` alike, since both reach
    /// ``Compactor/compact(_:prompt:budget:summarizer:summarization:pendingRuns:)``
    /// through the one shared ``fold(prompt:budget:summarizer:)``. Its three
    /// knobs — ``Summarization/keepRecentTurns``,
    /// ``Summarization/maxChunkTokens``, ``Summarization/summaryTokenRatio`` —
    /// are how a caller trades compression against summary fidelity, and how it
    /// sizes chunking for the model that actually summarizes.
    ///
    /// Session-scoped rather than per-call, and deliberately so. A `summarization:`
    /// argument on ``RoutedSession/compact(prompt:budget:)`` would reach the
    /// caller-driven fold alone: an automatic fold is driven from inside
    /// ``runTurn(grammar:turnId:promptId:pendingEvents:ownPrompt:onEvent:_:)``, which has no
    /// caller to thread one from, so the folds a long-running session actually
    /// takes — its automatic ones — would go on running at ``Summarization``'s
    /// own defaults however carefully the manual path was tuned. Widening the
    /// protocol is not the alternative either: ``RoutedSession`` is public, so a
    /// new requirement, or a re-signed one, breaks every conformer outside this
    /// package. One value stored here and read inside `fold` reaches every fold
    /// this session will ever run, and adds no protocol surface at all.
    ///
    /// Wider in scope than ``autoCompactionPrompt``, whose name says it
    /// configures the automatic fold alone: a caller-driven fold carries its own
    /// `prompt:` argument, while both folds share this one stage.
    ///
    /// Set at construction
    /// (``RoutedModel/makeSession(instructions:workingDirectory:recordingRoot:tools:budget:compactionPrompt:summarization:agentSpawn:discoveryPriming:)``)
    /// and carried forward by ``fork(workingDirectory:)`` — a fold on a fork
    /// condenses exactly like a fold on its parent. A session vended with no
    /// opinion carries `Summarization()`, every default.
    nonisolated let summarization: Summarization

    /// The pre-discovery seeding opt-in (`^s4405wc`), or `nil` (the default)
    /// for a session whose transcript construction is untouched.
    ///
    /// When set, ``runTurn(grammar:turnId:promptId:pendingEvents:ownPrompt:onEvent:_:)`` runs
    /// the named mounted tool host-side over the turn's own prompt and reseeds
    /// ``backend`` from its current transcript plus the real call it made,
    /// before the turn's own generate call ever submits (see
    /// ``primeDiscoveryIfConfigured(prompt:emit:)``). Set at construction
    /// (``RoutedModel/makeSession(instructions:workingDirectory:recordingRoot:tools:budget:compactionPrompt:summarization:agentSpawn:discoveryPriming:)``)
    /// and carried forward by ``fork(workingDirectory:)`` — a fork primes its
    /// turns exactly like its parent.
    nonisolated let discoveryPriming: DiscoveryPriming?

    /// The live ``streamSessionEvents()`` subscriptions
    /// ``emitSessionScopedEvent(_:)`` fans a session-scoped event out to, keyed
    /// by the subscription's own id so a finished stream removes exactly its own
    /// continuation and no other.
    ///
    /// Empty for a session nobody subscribed to, which is what makes the fan-out
    /// cost nothing on the path a session-scoped event is not being watched.
    var sessionEventSubscriptions: [ULID: AsyncStream<SessionEvent>.Continuation] = [:]

    /// Creates a session, landing its own `session.json` when it is a new one.
    ///
    /// The sidecar write happens here, synchronously, rather than at each
    /// creation site: a session records its own facts as it comes into
    /// existence, so no builder can produce a durable session directory that a
    /// transcript can land in with no sidecar beside it (see
    /// ``SessionSidecarOrigin``). It runs before the session exists to record
    /// anything, which is what makes "a session's facts are on disk before any
    /// of its transcript is" true by construction rather than by an awaited
    /// handshake. Failure is logged and dropped, so it can never fail a
    /// `makeSession` or a `fork`.
    ///
    /// Internal: construction is only via
    /// ``RoutedModel/makeSession(instructions:workingDirectory:recordingRoot:tools:budget:compactionPrompt:summarization:agentSpawn:discoveryPriming:)`` /
    /// ``RoutedModel/makeGuidedSession(grammar:instructions:workingDirectory:tools:budget:compactionPrompt:summarization:agentSpawn:discoveryPriming:)``,
    /// ``fork(workingDirectory:)``, or
    /// ``RoutedModel/restoreSessionTree(root:recordingRoot:registry:tools:)``.
    ///
    /// Every parameter here is documented on the stored property it
    /// initializes, above — no separate `Parameters:` block, so there is
    /// nowhere for the two to drift apart. The ones this initializer's own
    /// behavior actually turns on are ``persistedEntryCount`` (`0` for a root
    /// session, or the parent's backend entry count at fork time for a fork —
    /// the positional diff baseline, recorded into a new fork's sidecar as
    /// the legacy `forkedAtEntryCount`), ``historyOrdinal`` (the session's
    /// starting position in its own append-only recorded history — for a new
    /// fork this IS the cut point recorded into its sidecar, so the lineage
    /// cut and the starting ordinal are one fact),
    /// ``sidecarOrigin`` (where this session's `session.json` comes from — a
    /// write of its own at init, a tree it was restored from, or nothing
    /// durable at all), and `agentSpawn` (the parent session/tool-call this
    /// session was spawned from — see ``SessionSidecar/agentSpawn``), all
    /// three read directly in the sidecar write below rather than stored:
    /// nothing after construction needs any of them again, unlike
    /// ``instructions``/``grammar``, which a fork also carries forward.
    /// `recordingRoot` (a root session's per-session recording root override,
    /// or `nil` — a fork never carries one) is read the same way: it exists
    /// only so the sidecar's configuration envelope records the override the
    /// session was vended with (see ``SessionSidecar/configuration``).
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
        recordingRoot: URL? = nil
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

    /// Releases this session's fork-admission permit when it is deallocated, so a
    /// fork blocked on the ceiling can proceed.
    ///
    /// Only a fork holds a permit; a root session's `deinit` is a no-op here. The
    /// session's backend is freed by ARC as the actor is torn down — releasing a
    /// fork frees whatever conversation state it holds.
    ///
    /// Deliberately does **not** run ``close()``'s mailbox sweep — it cannot:
    /// a `deinit` can neither await an actor nor journal events. A session
    /// must be closed explicitly where its life ends; an unclosed crashed
    /// session's parked runs are the `.lost` restoration path's territory,
    /// never silently reconciled here.
    deinit {
        if holdsAdmissionPermit {
            forkAdmissionGate.signal()
        }
    }
}
