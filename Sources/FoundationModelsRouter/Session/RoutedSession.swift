import Foundation
import FoundationModels

/// The outcome of ``RoutedSession/cancelCurrentTurn()``.
public enum TurnCancellationResult: Sendable, Equatable {
    /// A turn was in flight and cancellation was requested of it.
    ///
    /// "Requested" rather than "stopped", deliberately: cancellation is
    /// cooperative here and advisory past the process boundary, so this reports
    /// what Router did, never what the model or an MCP server on the far side of
    /// a tool call chose to do about it. It says a turn held the session's turn
    /// lock and the cancellation was recorded against it — not that anything in
    /// flight has stopped, and not even that there was a model call to stop (a
    /// turn part-way through a fold's deterministic stages has none; see
    /// ``RoutedSession/cancelCurrentTurn()``).
    case requested

    /// No turn was in flight, so there was nothing to cancel and nothing
    /// happened — the state a second cancellation, or one arriving after the
    /// turn already finished, reports.
    case noTurnInFlight
}

/// A generation session over a resident model: the recorded surface an
/// application drives to produce text.
///
/// A session is vended only by ``RoutedModel/makeSession(instructions:workingDirectory:recordingRoot:tools:budget:compactionPrompt:agentSpawn:discoveryPriming:)``
/// — there is no public initializer — so it is born holding the router's
/// recording root (``routerId``) and the non-optional ``TranscriptRecorder`` the
/// vending handle carried, and it **retains its ``profile``** so the resident
/// models cannot be evicted out from under an in-flight session.
///
/// Every public generation method (``respond(to:)``, ``streamResponse(to:)``)
/// funnels through one internal recorder-bracketed chokepoint: the model runs,
/// then the backend's real transcript is snapshot-diffed against what was
/// already persisted and the new entries are recorded, whether the model
/// returns or throws. A turn's recorded event count is however many entries
/// the SDK's own transcript gained for it — not a fixed one-open/one-close
/// pair — except on the throwing path, which still guarantees at least one
/// trace: either a real `.response` entry the SDK appended before failing, or
/// a synthetic bodyless close when it appended none. Concurrent generations on
/// one model do not interleave: the chokepoint runs inside two nested fair FIFO
/// ``AsyncSemaphore`` gates, each at value 1 — this session's own
/// ``RoutedSessionActor/turnLock``, so one session never has two turns in
/// flight, and then the model's ``RoutedModel/generationGate``, shared with
/// every other session and fork over that model, so real model work queues
/// rather than overlaps (MLX generation runs a single GPU stream). Only the
/// generation gate is ever handed back mid-turn, and only for a wait on a
/// person (``RoutedSession/awaitingUser(_:)``). The generation itself runs
/// through Apple's own `LanguageModelSession` (`FoundationModels`, macOS 27+),
/// backed by a resident MLX model conformed to the `LanguageModel` protocol via
/// `MLXLanguageModel` (`MLXFoundationModels`) — never `MLXLMCommon`'s own
/// `ChatSession`, and never a hand-rolled generation loop of our own (see
/// plan.md's "Backends" section). The raw model/`LanguageModelSession` is never
/// vended to callers; ``RoutedSession`` is the only generation surface.
///
/// Its identity and directory accessors are `nonisolated` immutables readable
/// without awaiting.
public protocol RoutedSession: Actor {
    /// The resolved profile this session runs against, retained so its resident
    /// models stay alive for the session's lifetime.
    nonisolated var profile: LanguageModelProfile { get }

    /// The recording root id — the router instance that owns this transcript.
    nonisolated var routerId: ULID { get }

    /// This session's span id.
    nonisolated var id: ULID { get }

    /// The span id of the session that forked this one, or `nil` for a root
    /// session.
    nonisolated var parentId: ULID? { get }

    /// The directory this session's transcript is recorded under.
    nonisolated var recordingDirectory: URL { get }

    /// The directory model/tool work runs relative to; defaults to
    /// ``recordingDirectory`` and is overridable at creation without moving the
    /// recording directory.
    nonisolated var workingDirectory: URL { get }

    /// The grammar constraining every ``respond(to:)`` on this session, or `nil`
    /// for an unconstrained session.
    ///
    /// Set when the session is vended by
    /// ``RoutedModel/makeGuidedSession(grammar:instructions:workingDirectory:tools:budget:compactionPrompt:agentSpawn:discoveryPriming:)`` and
    /// `nil` for one from ``RoutedModel/makeSession(instructions:workingDirectory:recordingRoot:tools:budget:compactionPrompt:agentSpawn:discoveryPriming:)``.
    ///
    /// It travels with the session so ``fork(workingDirectory:)`` inherits it;
    /// ``streamResponse(to:)`` stays unconstrained regardless.
    nonisolated var grammar: Grammar? { get }

    /// This session's outbox: the staging area for tool events posted by
    /// long-running work and queued user prompts, both destined to enter the
    /// conversation at a future turn boundary. See ``SessionOutbox``.
    ///
    /// Fresh per session — a fork is given its own outbox rather than sharing
    /// its parent's (see ``fork(workingDirectory:)``'s doc comment for the
    /// fork-then-elevate composition that binds each session's own event
    /// route to it, so event delivery never migrates between sessions).
    nonisolated var outbox: SessionOutbox { get }

    /// This session's mailbox: the registry of parked detached runs and
    /// pending elicitations. See ``SessionMailbox``.
    ///
    /// Fresh per session, exactly like ``outbox`` — a fork is given its own
    /// mailbox rather than sharing its parent's, and a restored session gets
    /// a brand-new one — so a run parked on one session can never be waited
    /// on, cancelled, or swept through another.
    nonisolated var mailbox: SessionMailbox { get }

    /// Context fill, 0...1 — measured token usage against the profile's
    /// resolved working context (compaction_plan.md §1.5).
    ///
    /// The numerator is always a *measured* per-turn delta, never the
    /// backend's cumulative running total — reading the raw cumulative value
    /// would overestimate fill monotonically and trip a compaction trigger
    /// far too early. Concretely:
    ///
    /// - Before this session's first turn: `0` — nothing sent yet.
    /// - After a live turn whose backend metered usage: the newest turn's
    ///   `(tokensIn + tokensOut) / contextTokens` — the newest turn's own
    ///   count already *is* the whole transcript, tokenized by the actual
    ///   model, because generation is stateless over transcripts.
    /// - Restored from disk (``RoutedModel/restoreSessionTree(root:recordingRoot:registry:tools:)``)
    ///   with a stamped `.response` event recorded before the restore: that
    ///   stamp's `(tokensIn + tokensOut) / contextTokens`.
    /// - Restored from disk with no stamp at all (a pre-metering recording,
    ///   or one with metadata stripped): ``unknownContextFill`` — never a
    ///   guess — until the first live turn re-measures.
    var contextFill: Double { get async }

    /// Folds this session's transcript in place: same ``id``, same
    /// ``recordingDirectory``/``recorder`` identity, shorter live window
    /// (compaction_plan.md §1.4).
    ///
    /// Runs the ``Compactor/compact(_:prompt:budget:summarizer:pendingRuns:)`` pipeline
    /// over this session's current transcript — the deterministic stages
    /// first, then, only if they alone don't land it under `budget`'s
    /// target, the model-assisted ``Summarization`` stage, summarizing with
    /// this session's own resident model by default (a consumer wanting a
    /// different summarizer — e.g. the profile's `flash` slot — drives the
    /// lower-level bare-session recipe directly:
    /// ``Compactor/compact(_:prompt:budget:summarizer:pendingRuns:)`` +
    /// ``RecordingLanguageModel/noteCompaction(_:)``). When folding changes
    /// anything, the synthesized summary entry (with its
    /// ``CompactionSegment``) is appended to the same `transcript.jsonl` this
    /// session has recorded to all along — append-only, nothing before it
    /// touched (requirement 2) — and this session's inner generation backend
    /// is swapped for a fresh one seeded from the folded transcript, in
    /// place: same actor, same nonisolated ``id``, same ``recorder``, same
    /// ``recordingDirectory`` (requirement 4). When the transcript is
    /// already under target — or every stage ran and still couldn't land it,
    /// the oversized-tail case — nothing changes.
    ///
    /// **Proactive use** (preferred): check ``contextFill`` between turns and
    /// compact before it gets too high — turns never die:
    ///
    /// ```swift
    /// if await session.contextFill >= 0.80 {
    ///     try await session.compact()
    /// }
    /// ```
    ///
    /// **Reactive use** (the documented recovery path, compaction_plan.md
    /// §1.5): catch `LanguageModelError.contextSizeExceeded` — the SDK's own
    /// context-overflow failure (macOS 27; the deprecated
    /// `LanguageModelSession.GenerationError.exceededContextWindowSize`
    /// predates it) — compact with a lowered target, and retry once.
    /// `contextTokens` below is this session's own resolved working context —
    /// for a session vended from a resolved profile, its slot's
    /// `SlotResolution/contextTokens` (e.g. `profile.standard.resolution.contextTokens`):
    ///
    /// ```swift
    /// do {
    ///     return try await session.respond(to: prompt)
    /// } catch LanguageModelError.contextSizeExceeded {
    ///     // The backend ran out of context; fold harder than the default
    ///     // 50% target and retry exactly once.
    ///     try await session.compact(budget: TokenBudget(limit: contextTokens, target: 0.35))
    ///     return try await session.respond(to: prompt)
    /// }
    /// ```
    ///
    /// A fold takes this session's turn lock for its duration, so it is a turn as
    /// far as ``cancelCurrentTurn()`` is concerned: a stop landing in its
    /// model-assisted stage abandons it and throws `CancellationError` here,
    /// leaving this session exactly as it was — see that method for what a
    /// cancelled fold does and does not interrupt.
    ///
    /// - Parameters:
    ///   - prompt: The compaction prompt sent to the summarizer when the
    ///     model-assisted stage runs. Defaults to ``CompactionPrompt/default``.
    ///   - budget: The token budget to fold against, or `nil` to use this
    ///     session's own resolved working context at the default
    ///     trigger/target (compaction_plan.md §1.4).
    /// - Returns: What the fold did.
    /// - Throws: Whatever the summarizer throws, when the model-assisted
    ///   stage runs and fails, or `CancellationError` when this fold was
    ///   cancelled.
    @discardableResult
    func compact(prompt: CompactionPrompt, budget: TokenBudget?) async throws -> CompactionResult

    /// Generates a complete text response to a prompt, recording the call.
    ///
    /// - Parameters:
    ///   - prompt: The prompt to respond to.
    ///   - maxTokens: The maximum number of tokens to generate, or `nil` to use
    ///     the underlying model's own default ceiling.
    /// - Returns: The model's complete text response.
    /// - Throws: Any error thrown by the model.
    func respond(to prompt: String, maxTokens: Int?) async throws -> String

    /// Streams a text response to a prompt as it is produced, recording the call.
    ///
    /// - Parameters:
    ///   - prompt: The prompt to respond to.
    ///   - maxTokens: The maximum number of tokens to generate, or `nil` to use
    ///     the underlying model's own default ceiling.
    /// Abandoning the stream — breaking out of the loop, or dropping the
    /// iterator — cancels the turn behind it, exactly as ``cancelCurrentTurn()``
    /// would and by the same machinery: the turn is cut short, the error it
    /// unwinds with goes nowhere (the stream that would carry it is already
    /// terminated), and it is *recorded* as a cancelled turn rather than a
    /// completed one — whatever the SDK durably appended, plus the synthetic
    /// bodyless close, with its drained outbox events following the same
    /// attach-or-requeue rule. A consumer that wants the turn recorded as a whole
    /// turn has to drain the stream to its end. Fragments already yielded stay
    /// yielded either way.
    ///
    /// - Returns: A stream of response fragments, finishing when generation
    ///   completes or throwing if it fails.
    func streamResponse(to prompt: String, maxTokens: Int?) -> AsyncThrowingStream<String, Error>

    /// Streams a rich event sequence for a prompt as it is produced,
    /// recording the call exactly like ``streamResponse(to:maxTokens:)``.
    ///
    /// The full-fidelity session event stream:
    /// where ``streamResponse(to:maxTokens:)`` only ever yields the model's
    /// text fragments, this surfaces the same turn's tool calls, tool
    /// lifecycle, reasoning, and closing usage too — everything the
    /// chokepoint already observes as transcript entries once the turn's
    /// snapshot diff runs (see
    /// ``RoutedSessionActor/recordTranscriptDelta(grammar:since:usage:pendingEvents:onEvent:)``),
    /// interleaved with the same live text fragments as
    /// ``streamResponse(to:maxTokens:)``.
    ///
    /// Emission order within one turn: ``SessionEvent/textDelta(_:)``
    /// fragments as the model produces them; then, once generation finishes
    /// and the turn's diff runs, ``SessionEvent/toolCall(id:name:argumentsJSON:)``
    /// paired with a ``SessionEvent/toolStatus(id:status:summary:)`` of
    /// ``ToolCallStatus/running`` for each call the model requested (in diff
    /// order), a ``SessionEvent/toolStatus(id:status:summary:)`` of
    /// ``ToolCallStatus/completed`` as each call's output lands (or
    /// ``ToolCallStatus/failed`` for a call whose matching `.toolOutput`
    /// never arrived within this turn's diff), and any
    /// ``SessionEvent/reasoningDelta(_:)`` the backend recorded; finally
    /// ``SessionEvent/turnEnded(_:)`` once the turn's own usage delta is
    /// known. ``SessionEvent/compaction(_:)`` is emitted whenever this
    /// session auto-compacts itself mid-turn (only possible when it was
    /// vended with a `budget` — see that case's own documentation), but
    /// *where* in the sequence depends on which trigger fired: a **proactive**
    /// fold (measured fill already over `budget.trigger` at turn start) runs
    /// before generation begins, so its ``SessionEvent/compaction(_:)`` comes
    /// before this turn's own textDelta/toolCall/toolStatus/turnEnded events;
    /// a **reactive** fold (the turn overflowed the context window and is
    /// being retried once) is only discovered after the failed attempt has
    /// already run its course, so its ``SessionEvent/compaction(_:)`` is
    /// emitted *after* that failed attempt's own ``SessionEvent/turnEnded(_:)``
    /// and before the retried attempt's events. A session with no `budget`
    /// set never emits it here.
    ///
    /// - Parameters:
    ///   - prompt: The prompt to respond to.
    ///   - maxTokens: The maximum number of tokens to generate, or `nil` to
    ///     use the underlying model's own default ceiling.
    /// Abandoning this stream cancels the turn behind it and has it recorded as a
    /// cancelled turn, exactly as described on ``streamResponse(to:maxTokens:)``.
    ///
    /// - Returns: A stream of session events, finishing when the turn
    ///   completes or throwing if it fails (after yielding whatever the turn
    ///   produced first).
    func streamEvents(to prompt: String, maxTokens: Int?) -> AsyncThrowingStream<SessionEvent, Error>

    /// Streams the ``SessionEvent``s that belong to this *session* rather than
    /// to one of its turns, for as long as the session lives.
    ///
    /// ``streamEvents(to:maxTokens:)`` is one turn's stream: it exists only
    /// while that turn runs, and only the caller that started the turn *that
    /// way* has one. A session-scoped event can arise on any turn, including the
    /// ones ``respond(to:maxTokens:)`` and ``dispatchNextPrompt()`` run — those
    /// hand their caller a response, not a stream, so a turn-scoped sink cannot
    /// reach them. This is the route that does: subscribe once, when the session
    /// is vended, and observe every such event whichever entry point ran the
    /// turn that produced it.
    ///
    /// Exactly one event travels here today:
    /// ``SessionEvent/discoveryPrimingFailed(_:)``, the report that a turn's
    /// pre-discovery seeding could not run and the turn therefore generated
    /// unseeded (see ``DiscoveryPriming``). Priming happens on every turn a
    /// primed session runs, so its failure has to be observable on every one.
    ///
    /// Each call vends its own independent subscription, buffered without bound
    /// so a slow consumer drops nothing, and every subscription sees every
    /// event. A turn started by ``streamEvents(to:maxTokens:)`` still yields the
    /// same event on that turn's own stream as well, unchanged — a caller
    /// holding both sees it once per stream, which is what each subscription
    /// asked for. Ending iteration (or cancelling the task iterating) drops the
    /// subscription; ``close()`` finishes every outstanding one, so a consumer
    /// looping over this stream ends when the session does.
    ///
    /// - Returns: A stream of this session's own session-scoped events.
    func streamSessionEvents() -> AsyncStream<SessionEvent>

    /// Cancels the turn currently in flight on this session — best-effort, and
    /// additive to ``cancel(id:)`` rather than a replacement for it.
    ///
    /// ``cancel(id:)`` withdraws a *queued* prompt before it is ever dispatched;
    /// this reaches a turn already handed to the model. What it actually does is
    /// cancel the `Task` Router runs the model call in, so cancellation
    /// propagates *into* the tool calls the SDK invokes from inside that call —
    /// which is the whole point of it existing. A tool awaiting a long-running
    /// MCP call sees `CancellationError` at its own `await`, and
    /// `FoundationModelsMCP` turns that Swift-level cancellation into a
    /// protocol-level `notifications/cancelled` for the server behind it.
    ///
    /// **Propagation past the process boundary is advisory.** MCP's
    /// `notifications/cancelled` is a notification, not a command: a server may
    /// keep working, and nothing on this side can make it stop. The honest
    /// report is "we stopped listening", never "it stopped".
    ///
    /// What is observable afterwards:
    ///
    /// - **The turn's caller** — whoever awaits ``respond(to:maxTokens:)``,
    ///   ``streamResponse(to:maxTokens:)``, ``streamEvents(to:maxTokens:)``, or
    ///   ``dispatchNextPrompt()`` — receives `CancellationError` once the model
    ///   work unwinds. A stream stops mid-flight and finishes with that error,
    ///   keeping every fragment it had already yielded: a cancelled stream is
    ///   truncated, never retracted. Once a model call is under way on the
    ///   whole-response path, cancellation is cooperative all the way down: model
    ///   work and tools that never check it run to completion and the turn returns
    ///   its response normally, because Router does not fabricate a failure it did
    ///   not observe. A cancellation that lands *before* any model call starts is
    ///   the other case — nothing is under way to observe it, so the turn throws
    ///   `CancellationError` and never calls the model at all. Both routes behave
    ///   that way, and both windows are real: a turn can sit on this session's turn
    ///   lock behind another turn (gate acquisition is cancellation-immune by
    ///   design, so a cancelled turn still takes its place in line rather than
    ///   vanishing from it), and a turn can sit between its own attempts. Mapping
    ///   either outcome onto a
    ///   client-facing stop reason (ACP's `cancelled`, say) belongs to whichever
    ///   coordinator owns the channel to the user — Router owns none and invents
    ///   no stop reason of its own.
    /// - **The transcript** records a cancelled turn exactly like any other
    ///   failed turn, and never half-written: recording runs *outside* the
    ///   cancelled region, so the turn's post-generation snapshot diff still
    ///   persists whatever the SDK durably appended before unwinding, and the
    ///   synthetic bodyless `.response` close still lands when the SDK appended
    ///   no `.response` of its own — exactly one close per turn, as ever. The
    ///   session stays usable: the next turn on it runs normally.
    /// - **The outbox** follows the same attach-or-requeue rule as any other
    ///   turn: a cancelled turn whose diff produced a `.prompt`-kind partial did
    ///   durably deliver the events it drained, so they are recorded as
    ///   delivered; one whose diff produced none never delivered them, so they
    ///   are re-queued onto ``outbox`` for a future turn rather than lost. A
    ///   cancelled ``dispatchNextPrompt()`` turn's *prompt* is a separate question
    ///   with a separate answer: ``SessionOutbox/drainForDispatch()`` is that
    ///   prompt's commit point — the very boundary that makes a racing
    ///   ``cancel(id:)`` report ``SessionOutbox/PromptQueueMutationResult/alreadySent``
    ///   — and a cancellation does not roll it back. The prompt is spent, because
    ///   re-queueing it would resurrect an id the caller has already been told was
    ///   sent.
    /// - **The gates** stay exactly balanced, including when the cancellation
    ///   lands on a turn parked in ``awaitingUser(_:)``: the wait re-acquires the
    ///   permit it lent (``AsyncSemaphore``'s acquire completes even for a
    ///   cancelled task) and the turn releases it on the way out, so no permit is
    ///   minted or stranded and no other session over the model is blocked.
    ///
    /// Only the turn *in flight* is affected. A turn queued behind it (a
    /// concurrent ``respond(to:maxTokens:)`` parked on this session's turn lock)
    /// is untouched and will still run — cancelling that one remains its own
    /// caller's `Task`'s business, exactly as before, and cancelling a turn's
    /// enclosing `Task` still propagates into the model call the way it always
    /// did — and past this point the two routes are equivalent, since neither
    /// lets the model be re-entered on behalf of a turn already cancelled.
    ///
    /// A cancellation that lands while the in-flight turn holds no model call at
    /// all — between a failed attempt and its overflow retry, say — is remembered
    /// against that turn and honored by its next model call: that next call is
    /// never made, so a cancelled turn never re-runs the model or the tool calls
    /// that come with it.
    ///
    /// A turn **folding its own transcript** is reached too, by both routes. A
    /// fold's model-assisted summarization is a model call the turn owns, so it is
    /// cancelled where it stands instead of waited out — each of a map-reduced
    /// fold's several calls included, and a caller-driven
    /// ``compact(prompt:budget:)``, which holds the turn lock the same way,
    /// included as well. What is *not* interrupted is a fold's deterministic
    /// stages: they call no model, finish in bounded local work, and are left
    /// alone rather than made slower and nondeterministic for no gain. An
    /// abandoned fold leaves this session exactly as it was — never a half-applied
    /// fold, since a fold records its new entries, swaps its transcript, and
    /// re-reports its fill only once summarization has returned.
    ///
    /// What the caller then sees depends on whose fold it was. A **turn's** own fold
    /// throws `CancellationError` without the model ever being called for that
    /// turn's prompt, and the turn is recorded exactly like any other cut-short one:
    /// the same lone bodyless close, and its drained outbox events treated by the
    /// same attach-or-requeue rule. A cancelled **``compact(prompt:budget:)``**
    /// throws `CancellationError` and nothing else: it drained no outbox and owns no
    /// turn recording of its own, so it leaves no trace beyond the gates it hands
    /// back.
    ///
    /// Safe at any time and any number of times: a second cancellation of the
    /// same turn requests what was already requested, and a cancellation with no
    /// turn in flight does nothing at all.
    ///
    /// - Returns: ``TurnCancellationResult/requested`` when a turn was in flight
    ///   and cancellation was requested of it, or
    ///   ``TurnCancellationResult/noTurnInFlight`` when there was nothing to
    ///   cancel.
    @discardableResult
    func cancelCurrentTurn() async -> TurnCancellationResult

    /// Runs `body` with the per-model generation gate released, re-acquiring it
    /// before returning — for a wait on a **human**, never on the model.
    ///
    /// A tool invoked mid-turn that awaits a person (an MCP elicitation, a
    /// permission prompt) is not waiting on the model, but the SDK calls tools
    /// from *inside* the model call, so without this the wait would be served
    /// holding the model's ``RoutedModel/generationGate`` — head-of-line
    /// blocking every other session and fork over that model for however long
    /// the person takes. Wrapping the wait in this hands the generation gate
    /// back for its duration, so other sessions generate meanwhile.
    ///
    /// This is sound precisely because no model work is in flight while `body`
    /// runs: the SDK is suspended awaiting the tool call. Correctness does not
    /// rest on the generation gate anyway — this session keeps its own turn
    /// lock throughout, so a second turn here still cannot start and a
    /// concurrent ``fork(workingDirectory:)``'s transcript read is still
    /// serialized against this turn.
    ///
    /// Re-acquiring is itself a wait: a tool resuming after a long pause may
    /// queue behind other sessions' turns. That is the point — it becomes an
    /// ordinary competitor for the model rather than its owner. The
    /// re-acquire happens on every exit from `body`, including a throw and a
    /// cancellation, so a permit can never leak.
    ///
    /// Overlapping calls — two tools of one turn both awaiting a person — release
    /// once, on the outermost, and re-acquire once, when the last of them
    /// finishes. That rests on an assumption about the SDK, recorded here as one:
    /// **empirical status unverified in this environment** — that FoundationModels
    /// resumes a turn's parallel tool calls together, so no model work runs until
    /// the last of them returns. Were that wrong, generation would resume after
    /// the first tool returned while a sibling wait still held the loan open, and
    /// the release would need to be per-tool rather than per-turn. The gate's
    /// count does not depend on it either way.
    ///
    /// Misuse cannot corrupt the gate's count, but it does forfeit the
    /// serialization the gate exists for, so mind the precondition below. A wait
    /// with no turn in flight has no permit to hand back and releases nothing
    /// rather than signalling one that was never acquired; a wait whose lending
    /// turn ends before the wait does hands the permit straight back instead of
    /// stranding it, even when the turn ends mid-re-acquire (see
    /// ``RoutedSessionActor/endHumanWait()``). The count stays exact in every
    /// ordering — but a wait that overlaps a turn it is not part of hands that
    /// turn's permit back while the model is still generating, and nothing can
    /// detect that from here. An out-of-turn wait also inflates the wait depth, so
    /// a *legitimate* in-turn wait arriving while it is outstanding is no longer
    /// the outermost one and releases nothing at all: that turn silently goes back
    /// to blocking the model for the length of its human wait. Accounting survives
    /// misuse; the optimization does not.
    ///
    /// Router carries elicitation's typed envelope and resume plumbing —
    /// ``ToolContext/elicit(_:)`` parks the run in this session's ``mailbox``
    /// and ``respond(elicitationId:response:)``/``complete(elicitationId:)``
    /// deliver the answer — while the presenting UI stays the host app's.
    /// This method's contribution is orthogonal: making the wait on the
    /// person cheap by releasing the generation gate for its duration.
    ///
    /// - Precondition: Call this from inside a tool the SDK invoked for *this*
    ///   session's own in-flight turn, and do not let the wait outlive that tool
    ///   call. That is what makes the release sound — the turn is suspended
    ///   awaiting the tool, so there is no model work left for the gate to
    ///   protect.
    /// - Parameter body: The wait on a person to run with the generation gate
    ///   released.
    /// - Returns: Whatever `body` returns.
    /// - Throws: Rethrows any error thrown by `body`, after re-acquiring.
    func awaitingUser<T: Sendable>(_ body: @Sendable () async throws -> T) async rethrows -> T

    /// Forks a child session over the same resident model.
    ///
    /// The child takes a fresh id with ``parentId`` set to this session's id and
    /// its ``recordingDirectory`` nested directly under the parent's, so the
    /// on-disk transcript tree mirrors the fork lineage regardless of
    /// `workingDirectory`; a guided session's fork inherits its ``grammar``. The
    /// child retains the ``profile`` so resident models stay alive, and its
    /// ``LanguageModelSessionBackend`` is seeded from this session's accumulated
    /// conversation state via ``LanguageModelSessionBackend/makeFork()``, so the
    /// child sees the parent's turns so far and then diverges independently.
    ///
    /// At most the router's `maxConcurrentForks` fork sessions over one model may
    /// be in flight at once; a fork past that ceiling awaits a free slot, freed
    /// when an outstanding fork is released.
    ///
    /// - Parameter workingDirectory: The child's working directory, or `nil` to
    ///   default to its recording directory.
    /// - Returns: The forked child session.
    /// - Throws: Nothing in the current implementation — the admission gate and
    ///   turn lock never throw and ``LanguageModelSessionBackend/makeFork()``
    ///   is non-throwing; declared `async throws` to match ``RoutedSession``'s
    ///   other generation entry points and leave room for a future conforming
    ///   backend whose fork can fail.
    func fork(workingDirectory: URL?) async throws -> RoutedSession

    /// Tears the session down explicitly: runs ``mailbox``'s
    /// ``SessionMailbox/sweep()`` — cancelling every parked run per its
    /// kind's semantics and rejecting every pending elicitation — and drains
    /// the resulting terminal events into the journal (exactly one per
    /// parked run, no orphans, no holes) before returning.
    ///
    /// Call it wherever a session's life actually ends: a host app ending a
    /// conversation, `multitool-cli` teardown, and fork/restore paths that
    /// discard a session. `deinit` cannot and does not run this sweep — it
    /// can neither await an actor nor journal events — so an unclosed
    /// crashed session's runs are the `.lost` restoration path's territory,
    /// never silently reconciled here.
    ///
    /// It also finishes every outstanding ``streamSessionEvents()``
    /// subscription, so a consumer looping over one ends here rather than
    /// awaiting an event the closed session can no longer produce.
    ///
    /// Idempotent: a second call finds the mailbox already empty and
    /// journals nothing, and has no subscriptions left to finish.
    func close() async

    /// Runs the earliest still-pending prompt in ``outbox``'s queue as one
    /// normal recorded turn: dequeues it together with any pending
    /// turn-riding events (both drained atomically — see
    /// ``SessionOutbox/drainForDispatch()``), composes them into the turn
    /// exactly like ``respond(to:maxTokens:)`` does through the shared
    /// recorder-bracketed chokepoint, and returns the model's response.
    ///
    /// This is the driver's pull surface over the queue populated by
    /// ``RoutedSession/enqueue(prompt:)-(Transcript.Prompt)``/
    /// ``RoutedSession/enqueue(prompt:)-(String)``: nothing in this package
    /// auto-drains it — consistent with Router's current character, which has
    /// no hidden auto-turn loop (see this type's own doc comment). The
    /// intended driver-loop shape, using ``outbox``'s ``SessionOutbox/nextEvent()``
    /// as the idle-wakeup signal (it resumes for a queued prompt exactly as
    /// it does for a pending event):
    ///
    /// ```swift
    /// while !Task.isCancelled {
    ///     await session.outbox.nextEvent()
    ///     if let response = try await session.dispatchNextPrompt() {
    ///         // handle `response`
    ///     }
    /// }
    /// ```
    ///
    /// An opt-in mode that runs this loop automatically inside the session is
    /// a recorded non-goal for now.
    ///
    /// - Returns: The model's response text, or `nil` if no prompt was queued
    ///   at the moment this call drained the outbox (including a prompt
    ///   ``RoutedSession/cancel(id:)``-ed just before the drain) — any pending
    ///   events this drain also claimed in that case are re-queued rather
    ///   than lost.
    /// - Throws: Any error thrown by the model.
    func dispatchNextPrompt() async throws -> String?
}

extension RoutedSession {
    /// See ``compact(prompt:budget:)``, defaulting both parameters —
    /// ``CompactionPrompt/default`` and `nil` (this session's own resolved
    /// working context at the default trigger/target).
    ///
    /// - Returns: What the fold did.
    /// - Throws: Whatever the summarizer throws, when the model-assisted
    ///   stage runs and fails.
    @discardableResult
    public func compact() async throws -> CompactionResult {
        try await compact(prompt: .default, budget: nil)
    }

    /// See ``compact(prompt:budget:)``, defaulting `budget` to `nil` (this
    /// session's own resolved working context at the default trigger/target).
    ///
    /// - Parameter prompt: The compaction prompt sent to the summarizer when
    ///   the model-assisted stage runs.
    /// - Returns: What the fold did.
    /// - Throws: Whatever the summarizer throws, when the model-assisted
    ///   stage runs and fails.
    @discardableResult
    public func compact(prompt: CompactionPrompt) async throws -> CompactionResult {
        try await compact(prompt: prompt, budget: nil)
    }

    /// See ``compact(prompt:budget:)``, defaulting `prompt` to
    /// ``CompactionPrompt/default``.
    ///
    /// - Parameter budget: The token budget to fold against, or `nil` to use
    ///   this session's own resolved working context at the default
    ///   trigger/target.
    /// - Returns: What the fold did.
    /// - Throws: Whatever the summarizer throws, when the model-assisted
    ///   stage runs and fails.
    @discardableResult
    public func compact(budget: TokenBudget?) async throws -> CompactionResult {
        try await compact(prompt: .default, budget: budget)
    }

    /// Generates a complete text response to a prompt using the underlying
    /// model's own default token ceiling, recording the call.
    ///
    /// - Parameter prompt: The prompt to respond to.
    /// - Returns: The model's complete text response.
    /// - Throws: Any error thrown by the model.
    public func respond(to prompt: String) async throws -> String {
        try await respond(to: prompt, maxTokens: nil)
    }

    /// Streams a text response to a prompt as it is produced, using the
    /// underlying model's own default token ceiling, recording the call.
    ///
    /// - Parameter prompt: The prompt to respond to.
    /// - Returns: A stream of response fragments, finishing when generation
    ///   completes or throwing if it fails.
    public func streamResponse(to prompt: String) -> AsyncThrowingStream<String, Error> {
        streamResponse(to: prompt, maxTokens: nil)
    }

    /// Streams a rich event sequence for a prompt as it is produced, using
    /// the underlying model's own default token ceiling, recording the call.
    ///
    /// - Parameter prompt: The prompt to respond to.
    /// - Returns: A stream of session events; see ``streamEvents(to:maxTokens:)``.
    public func streamEvents(to prompt: String) -> AsyncThrowingStream<SessionEvent, Error> {
        streamEvents(to: prompt, maxTokens: nil)
    }

    /// Stages a queued user prompt for a future turn — the ``RoutedSession``
    /// convenience over this session's own ``outbox`` (see
    /// ``SessionOutbox/enqueue(prompt:)``).
    ///
    /// Queued prompts are app state until ``dispatchNextPrompt()`` actually
    /// dispatches one: nothing here touches the recorded transcript, which
    /// stays the record of committed turns only.
    ///
    /// - Parameter prompt: The prompt to stage.
    /// - Returns: The stable id assigned to this queued prompt, usable with
    ///   ``pendingPrompts()``, ``cancel(id:)``, and ``replace(id:prompt:)``.
    @discardableResult
    public func enqueue(prompt: Transcript.Prompt) async -> SessionOutbox.ItemID {
        await outbox.enqueue(prompt: prompt)
    }

    /// Stages a plain-text queued user prompt for a future turn — the
    /// `String` convenience over ``enqueue(prompt:)-(Transcript.Prompt)``,
    /// wrapping `prompt` in a single `.text` segment.
    ///
    /// - Parameter prompt: The prompt text to stage.
    /// - Returns: The stable id assigned to this queued prompt.
    @discardableResult
    public func enqueue(prompt: String) async -> SessionOutbox.ItemID {
        await enqueue(prompt: Transcript.Prompt(segments: [.text(Transcript.TextSegment(content: prompt))]))
    }

    /// A snapshot of every prompt currently queued for a future turn, in
    /// FIFO dispatch order.
    ///
    /// - Returns: Each queued prompt's stable id paired with its current
    ///   content, reflecting any ``replace(id:prompt:)`` applied to it since
    ///   it was enqueued.
    public func pendingPrompts() async -> [(id: SessionOutbox.ItemID, prompt: Transcript.Prompt)] {
        await outbox.pending().prompts.map { (id: $0.id, prompt: $0.prompt) }
    }

    /// Cancels a still-pending queued prompt.
    ///
    /// - Parameter id: The id ``enqueue(prompt:)`` returned for the prompt to
    ///   cancel.
    /// - Returns: Whether the prompt was still pending and was removed, or
    ///   had already been drained for dispatch by
    ///   ``dispatchNextPrompt()`` — see ``SessionOutbox/PromptQueueMutationResult``.
    ///   A cancelled prompt never produces a turn. For the in-flight
    ///   counterpart — stopping a turn already handed to the model — see
    ///   ``cancelCurrentTurn()``.
    @discardableResult
    public func cancel(id: SessionOutbox.ItemID) async -> SessionOutbox.PromptQueueMutationResult {
        await outbox.cancel(id: id)
    }

    /// Replaces a still-pending queued prompt's content, in place —
    /// preserving its FIFO dispatch position.
    ///
    /// - Parameters:
    ///   - id: The id ``enqueue(prompt:)`` returned for the prompt to
    ///     replace.
    ///   - prompt: The prompt's new content.
    /// - Returns: Whether the prompt was still pending and was updated, or
    ///   had already been drained for dispatch by
    ///   ``dispatchNextPrompt()`` — see ``SessionOutbox/PromptQueueMutationResult``.
    ///   A replaced prompt dispatches its edited content.
    @discardableResult
    public func replace(id: SessionOutbox.ItemID, prompt: Transcript.Prompt) async -> SessionOutbox.PromptQueueMutationResult {
        await outbox.replace(id: id, prompt: prompt)
    }

    /// Delivers the user's answer to a pending elicitation raised by a run on
    /// **this** session — the inbound answer route: app host → session → this
    /// session's own ``mailbox`` → the parked ``ToolContext/elicit(_:)``
    /// continuation.
    ///
    /// The answer addresses the elicitation, never the run: one run can hold
    /// several pending elicitations at once, each resolved by its own id. A
    /// form-mode `accept` resumes the run with its `content`; `decline` and
    /// `cancel` resume with those actions — a declined elicitation is not a
    /// cancelled run, the tool decides what to do with the answer. A URL-mode
    /// `accept` only records that the user agreed to open the URL: the entry
    /// stays open, and the run stays parked, until
    /// ``complete(elicitationId:)`` arrives.
    ///
    /// The route uses no task locals: this call reaches exactly this
    /// session's ``mailbox`` by reference, so two sessions sharing a registry
    /// can never cross-route — an id pending on another session is simply
    /// unknown here. Unknown, malformed, and already-answered ids are safe
    /// no-ops per the MCP spec.
    ///
    /// - Parameters:
    ///   - elicitationId: The pending elicitation's id — the string form of
    ///     the ``ElicitationRequest/elicitationId`` the request carried.
    ///   - response: The user's answer.
    /// - Returns: The ``SessionMailbox/ElicitationAnswerDelivery``.
    @discardableResult
    public func respond(elicitationId: String, response: ElicitationResponse) async -> SessionMailbox.ElicitationAnswerDelivery {
        await deliver(toElicitation: elicitationId, orReturn: .noPendingElicitation) {
            await mailbox.respond(elicitationId: $0, response)
        }
    }

    /// Signals that an accepted URL-mode elicitation's out-of-band flow
    /// finished — the second step of the URL-mode two-step: the accept
    /// delivered through ``respond(elicitationId:response:)`` only meant the
    /// user agreed to open the URL, and this completion is what resumes the
    /// run that stayed parked past it.
    ///
    /// Routes by reference to this session's own ``mailbox`` exactly as
    /// ``respond(elicitationId:response:)`` does. Unknown, malformed,
    /// not-yet-accepted, and already-completed (duplicate) ids are safe
    /// no-ops per the MCP spec.
    ///
    /// - Parameter elicitationId: The accepted URL-mode elicitation's id.
    /// - Returns: The ``SessionMailbox/ElicitationCompletionDelivery``.
    @discardableResult
    public func complete(elicitationId: String) async -> SessionMailbox.ElicitationCompletionDelivery {
        await deliver(toElicitation: elicitationId, orReturn: .noPendingElicitation) {
            await mailbox.complete(elicitationId: $0)
        }
    }

    /// Parses an inbound elicitation id and hands the parsed id to `delivery` —
    /// the one place either inbound elicitation route decides what an
    /// unparseable id means.
    ///
    /// ``respond(elicitationId:response:)`` and ``complete(elicitationId:)``
    /// both take the id as a `String`, because it reaches Router from a host
    /// app across a boundary that carries text, and both owe the MCP spec the
    /// same safe no-op when that text is not a ``ULID`` at all. Routing both
    /// through here keeps that one decision in one place: neither route can be
    /// changed to treat an unparseable id differently without the other
    /// following.
    ///
    /// - Parameters:
    ///   - elicitationId: The elicitation's id as the caller supplied it.
    ///   - unparseableResult: What to report when `elicitationId` is not a
    ///     parseable ``ULID`` — each route's own `noPendingElicitation`.
    ///   - delivery: Delivers the parsed id to this session's ``mailbox``.
    /// - Returns: Whatever `delivery` reported, or `unparseableResult` when the
    ///   id could not be parsed.
    private func deliver<Delivery>(
        toElicitation elicitationId: String,
        orReturn unparseableResult: Delivery,
        using delivery: (ULID) async -> Delivery
    ) async -> Delivery {
        guard let id = ULID(elicitationId) else {
            return unparseableResult
        }
        return await delivery(id)
    }
}
