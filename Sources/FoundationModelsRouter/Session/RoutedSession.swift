import Foundation
import FoundationModels

/// The outcome of ``RoutedSession/cancelCurrentTurn()``.
public enum TurnCancellationResult: Sendable, Equatable {
    /// A turn was in flight and cancellation was requested of it — or, with no
    /// turn in flight, a ``RoutedSession/respond(to:maxTokens:)`` call was
    /// draining the run plane between its turns and was ended.
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

    /// Nothing was in flight to cancel, so nothing happened — no turn, and no
    /// `respond` draining the run plane. The state a second cancellation, or one
    /// arriving after the call already finished, reports.
    case noTurnInFlight
}

/// The outcome of ``RoutedSession/cancelPrompt(id:)``.
public enum PromptCancellationResult: Sendable, Equatable {
    /// The prompt was still waiting in the queue and was withdrawn. It never
    /// produced a turn and never will.
    case withdrawn

    /// The prompt had already been drained for dispatch, so its turn was
    /// cancelled instead — ``RoutedSession/cancelCurrentTurn()``'s outcome, with
    /// everything that method documents about it. A turn cancelled before its
    /// model call started never calls the model at all; one cancelled after is
    /// cut short cooperatively.
    case turnCancelled

    /// Nothing was left to cancel: the id's turn had already finished, or the id
    /// never named a queued prompt on this session at all.
    case alreadyFinished
}

/// A generation session over a resident model: the recorded surface an
/// application drives to produce text.
///
/// A session is vended only by ``RoutedModel/makeSession(instructions:workingDirectory:recordingRoot:tools:budget:compactionPrompt:summarization:agentSpawn:discoveryPriming:)``
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
    /// ``RoutedModel/makeGuidedSession(grammar:instructions:workingDirectory:tools:budget:compactionPrompt:summarization:agentSpawn:discoveryPriming:)`` and
    /// `nil` for one from ``RoutedModel/makeSession(instructions:workingDirectory:recordingRoot:tools:budget:compactionPrompt:summarization:agentSpawn:discoveryPriming:)``.
    ///
    /// It travels with the session so ``fork(workingDirectory:)`` inherits it;
    /// ``streamResponse(to:)`` stays unconstrained regardless.
    nonisolated var grammar: Grammar? { get }

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
    /// - Restored from disk (``RoutedModel/restoreSessionTree(root:recordingRoot:tools:)``)
    ///   with a stamped `.response` event recorded before the restore: that
    ///   stamp's `(tokensIn + tokensOut) / contextTokens`.
    /// - Restored from disk with no stamp at all (a pre-metering recording,
    ///   or one with metadata stripped): ``unknownContextFill`` — never a
    ///   guess — until the first live turn re-measures.
    var contextFill: Double { get async }

    /// The SDK transcript this session has accumulated so far — read-only,
    /// and read under the session's own turn lock, so it never observes a
    /// turn mid-append.
    ///
    /// This is the supported way to read the entries a session's history
    /// holds — most importantly for seeding a ``SessionProjection`` via
    /// ``SessionProjection/seed(from:)`` after
    /// ``RoutedModel/restoreSessionTree(root:recordingRoot:tools:)``,
    /// whose restored sessions carry a full transcript while a fresh
    /// projection starts empty. A restored session reports the reconstructed
    /// effective transcript its backend was seeded with (the same entries
    /// ``TranscriptTree/effectiveTranscript(forSession:view:)``
    /// produces), plus whatever live turns appended since.
    ///
    /// Waiting on the turn lock means a read issued while a turn is in
    /// flight suspends until that turn finishes, exactly as
    /// ``fork(workingDirectory:)`` does for the same reason.
    var transcript: Transcript { get async }

    /// Folds this session's transcript in place: same ``id``, same
    /// ``recordingDirectory``/``recorder`` identity, shorter live window
    /// (compaction_plan.md §1.4).
    ///
    /// Runs the ``Compactor/compact(_:prompt:budget:summarizer:summarization:pendingRuns:)`` pipeline
    /// over this session's current transcript — the deterministic stages
    /// first, then, only if they alone don't land it under `budget`'s
    /// target, the model-assisted ``Summarization`` stage, summarizing with
    /// this session's own resident model by default (a consumer wanting a
    /// different summarizer — e.g. the profile's `flash` slot — drives the
    /// lower-level bare-session recipe directly:
    /// ``Compactor/compact(_:prompt:budget:summarizer:summarization:pendingRuns:)`` +
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
    /// The model-assisted stage a fold runs — its recency window, its chunk
    /// ceiling, and how much of what it condenses a summary may occupy — is the
    /// one this session was vended with
    /// (``RoutedModel/makeSession(instructions:workingDirectory:recordingRoot:tools:budget:compactionPrompt:summarization:agentSpawn:discoveryPriming:)``'s
    /// `summarization`) rather than an argument here: a session's *automatic*
    /// folds have no caller to pass one to, so the configuration lives on the
    /// session and both folds condense the same way. See
    /// ``RoutedSessionActor/summarization``.
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
    /// **What this call drains, and what it does not.** A session carries two
    /// planes, and they drain at different times — this is the surface where
    /// both are drained before the caller is answered:
    ///
    /// - The **content plane** (the events long-running work has posted) is
    ///   drained at the top of each of this call's turns and folded into that
    ///   turn's prompt as a plain-text preamble, exactly as every generation
    ///   surface drains it.
    /// - The **run plane** (the runs a detached tool call parked) is drained
    ///   *after* this call's own turn: every parked run is awaited to
    ///   settlement, and a further turn is run so those results reach the model
    ///   in this same call. So the answer is written from what the backgrounded
    ///   work returned rather than from the completion token it handed back,
    ///   nothing is left parked when this call returns, and no caller has to
    ///   make the model call a `wait` tool to get there. Every run parked at
    ///   each round is drained, not just the first.
    /// - It **does not sweep**: ending parked runs is teardown, and belongs to
    ///   ``close()``.
    /// - It **does not change the streaming surfaces**.
    ///   ``streamResponse(to:maxTokens:)`` and ``streamEvents(to:maxTokens:)``
    ///   still return while a run they parked is in flight — backgrounding is
    ///   the feature there.
    ///
    /// The drain terminates by a stated rule: it runs at most
    /// ``RoutedSessionActor/parkedRunDrainRoundLimit`` drained turns after this
    /// call's own, so a model that keeps starting background work from inside a
    /// drained turn is answered early rather than awaited forever.
    ///
    /// **How often the drain runs — it is a safety net, not the usual path.** A
    /// tool call that parks its run returns ``PendingRunEnvelope``, and that
    /// envelope tells the model to collect the run itself, with a `wait` call,
    /// before it answers. ``DetachingTool`` writes that instruction on every
    /// park, so every host hands it to the model and no host can turn it off. A
    /// model that obeys it collects its own runs; this call then finds the run
    /// plane empty and runs no drained turn at all. The drain answers the other
    /// case: the turn ends with a run still parked, because the model ignored
    /// the instruction or because its own `wait` ran out. So how often the drain
    /// runs is a property of the model, not of the host, and the guarantee above
    /// — nothing is left parked when this call returns — holds in both cases.
    /// The Router's own tests park the runs the drain collects, so they prove
    /// what the drain does and not how often a real model leaves a run behind
    /// (task ^466d38p).
    ///
    /// A cancellation ends the drain too, from either route —
    /// ``cancelCurrentTurn()`` or the caller's own task — and it lands whether
    /// the call is inside a turn or already parked on a run between turns
    /// (task ^h3efdrc). A cancelled drain **returns the last turn's answer
    /// rather than throwing**, which is what a cancellation reaching a detached
    /// tool call already produces: the turn answers with its pending envelope.
    /// It stops waiting and nothing else — the runs it was waiting on stay
    /// parked, since ending them is ``close()``'s job.
    ///
    /// - Parameters:
    ///   - prompt: The prompt to respond to.
    ///   - maxTokens: The maximum number of tokens to generate, or `nil` to use
    ///     the underlying model's own default ceiling.
    /// - Returns: The model's complete text response — the last drained turn's,
    ///   when this call's own turn backgrounded work.
    /// - Throws: Any error thrown by the model. A turn that throws is never
    ///   drained.
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
    /// This surface drains the content plane at the top of its turn like every
    /// other, and deliberately does **not** drain the run plane: it finishes
    /// while a run the turn parked is still in flight. Backgrounding is the
    /// feature here — a consumer watching a stream watches the run plane too.
    /// ``respond(to:maxTokens:)`` is the surface that waits.
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
    /// Emission order within one turn: ``SessionEvent/turnStarted(_:)`` first,
    /// before any of this turn's work — the correlation frame every later event
    /// of the turn belongs to, naming no queued prompt because this turn's
    /// prompt came straight from its caller; then
    /// ``SessionEvent/textDelta(_:)``
    /// fragments as the model produces them; then, once generation finishes
    /// and the turn's diff runs, ``SessionEvent/toolCall(id:name:argumentsJSON:)``
    /// paired with a ``SessionEvent/toolStatus(id:status:summary:output:)`` of
    /// ``ToolCallStatus/running`` for each call the model requested (in diff
    /// order), a ``SessionEvent/toolStatus(id:status:summary:output:)`` of
    /// ``ToolCallStatus/completed`` as each call's output lands (or
    /// ``ToolCallStatus/failed`` for a call whose matching `.toolOutput`
    /// never arrived within this turn's diff), any
    /// ``SessionEvent/reasoningDelta(_:)`` the backend recorded, and one
    /// ``SessionEvent/entryRecorded(id:kind:)`` per recorded
    /// `.response`/`.reasoning`/`.toolCalls` entry, right after that entry's
    /// own derived events, carrying its durable SDK id; finally
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
    /// Like ``streamResponse(to:maxTokens:)``, and unlike
    /// ``respond(to:maxTokens:)``, this surface does **not** drain the run
    /// plane: the stream finishes while a run the turn parked is still in
    /// flight, and that run's result reaches the model on a later turn.
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
    /// **Every turn-lifecycle event travels here**, whichever entry point ran
    /// the turn — the correlation frame ``SessionEvent/turnStarted(_:)`` that
    /// opens it, the ``SessionEvent/reasoningDelta(_:)``, tool-lifecycle, and
    /// ``SessionEvent/entryRecorded(id:kind:)`` events its diff derives, any
    /// ``SessionEvent/compaction(_:)`` it folds,
    /// the ``SessionEvent/discoveryPrimingFailed(_:)`` report that its
    /// pre-discovery seeding could not run (see ``DiscoveryPriming``), and its
    /// closing ``SessionEvent/turnEnded(_:)``.
    ///
    /// **Excluded, deliberately: the live text increments.**
    /// ``SessionEvent/textDelta(_:)`` and ``SessionEvent/textReset`` travel
    /// only on the turn's own ``streamEvents(to:maxTokens:)`` stream, never
    /// here. This feed buffers every subscription without bound so a slow
    /// consumer drops nothing, and that guarantee is affordable precisely
    /// because a turn contributes a handful of lifecycle events here rather
    /// than its per-token text. A consumer that needs the response text live
    /// starts the turn with ``streamEvents(to:maxTokens:)`` (or
    /// ``streamResponse(to:maxTokens:)``); a turn run through
    /// ``respond(to:maxTokens:)`` or ``dispatchNextPrompt()`` hands its full
    /// text to its own caller as the return value.
    ///
    /// Attribution is by frame, not by a repeated id: a session runs one turn at
    /// a time, so every event here belongs to the turn named by the most recent
    /// ``SessionEvent/turnStarted(_:)`` — and, through
    /// ``TurnStart/promptId``, to the queued prompt that caused it where there
    /// was one. See that case for why no turn id is stamped onto the tool
    /// events.
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
    ///   are re-queued onto the session's ``SessionOutbox`` for a future turn
    ///   rather than lost. A
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
    /// A **`respond(to:maxTokens:)` draining the run plane** is reached as well,
    /// and it is the one thing this cancels that is not a turn. That call drains
    /// *between* its turns, so it can be waiting on a parked run with no turn in
    /// flight at all — and the run plane's own wait ignores task cancellation,
    /// with a ceiling of a day, so before this there was no way out of such a
    /// call short of ``close()`` (task ^h3efdrc). A cancellation arriving then
    /// ends the wait: the call stops draining and returns its last turn's answer
    /// rather than throwing, and the runs it was waiting on stay parked, exactly
    /// as they were. Ending them is ``close()``'s job, never this one's.
    ///
    /// Safe at any time and any number of times: a second cancellation of the
    /// same turn requests what was already requested, and a cancellation with
    /// nothing in flight — no turn, and no draining call — does nothing at all.
    ///
    /// - Returns: ``TurnCancellationResult/requested`` when a turn was in flight
    ///   and cancellation was requested of it, or when a draining
    ///   `respond(to:maxTokens:)` was ended; or
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
    /// ``ToolContext/elicit(_:)`` parks the run in this session's ``SessionMailbox``
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

    /// Tears the session down explicitly: runs the session mailbox's
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

    /// Runs the earliest still-pending prompt in this session's queue as one
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
    /// intended driver-loop shape, using ``awaitQueuedWork()``
    /// as the idle-wakeup signal (it resumes for a queued prompt exactly as
    /// it does for a pending event):
    ///
    /// ```swift
    /// while !Task.isCancelled {
    ///     await session.awaitQueuedWork()
    ///     if let response = try await session.dispatchNextPrompt() {
    ///         // handle `response`
    ///     }
    /// }
    /// ```
    ///
    /// An opt-in mode that runs this loop automatically inside the session is
    /// a recorded non-goal for now.
    ///
    /// ## Ordering against the direct path
    ///
    /// A session has two submission paths, and they are deliberately
    /// independent: this queue, and the direct
    /// ``respond(to:maxTokens:)``/``streamResponse(to:maxTokens:)``/``streamEvents(to:maxTokens:)``
    /// calls, which never touch the queue (``SessionOutbox/drainPendingEvents()``,
    /// not ``SessionOutbox/drainForDispatch()``). What is and is not guaranteed:
    ///
    /// - **Within the queue, order is total.** Prompts dispatch strictly in
    ///   enqueue order, one turn each, however many dispatch calls are in
    ///   flight — each drains the FIFO front under the turn lock.
    /// - **Between the two paths, there is no order.** A direct turn never
    ///   dequeues a waiting prompt and a dispatch never absorbs a direct
    ///   caller's prompt, so neither path can starve or reorder the other's
    ///   work; but which of two concurrent callers reaches the turn lock first
    ///   is the actor executor's scheduling decision, not a rule this package
    ///   states. A client that needs "this queued prompt runs before that direct
    ///   prompt" must sequence the two calls itself, by awaiting the first.
    /// - **Once a caller reaches the turn lock, order is total and fair.** The
    ///   lock is a strict FIFO ``AsyncSemaphore``, so turns run in the order
    ///   they parked on it and no caller can be starved by later arrivals.
    /// - **``streamEvents(to:maxTokens:)`` and ``streamResponse(to:maxTokens:)``
    ///   reach that lock from a task of their own**, spawned when the stream is
    ///   created rather than when it is first iterated. Their position in line
    ///   is therefore taken at creation, and is not ordered against a
    ///   ``respond(to:maxTokens:)`` or ``dispatchNextPrompt()`` call the same
    ///   client makes around it.
    /// - **Cancelling a caller's own `Task` does not surrender its place in
    ///   line.** Gate acquisition is deliberately cancellation-immune (see
    ///   ``AsyncSemaphore``), so a cancelled turn still reaches the lock — and
    ///   then throws `CancellationError` without calling the model. That is what
    ///   keeps the queue's fairness intact rather than letting a cancelled turn
    ///   corrupt the count.
    ///
    /// - Returns: The model's response text, or `nil` if no prompt was queued
    ///   at the moment this call drained the outbox (including a prompt
    ///   ``RoutedSession/cancel(id:)``-ed just before the drain) — any pending
    ///   events this drain also claimed in that case are re-queued rather
    ///   than lost.
    /// - Throws: Any error thrown by the model.
    func dispatchNextPrompt() async throws -> String?

    /// Suspends until this session's staging area holds work for a future
    /// turn — a queued prompt or a pending tool event — and returns
    /// immediately when it already does.
    ///
    /// The idle-wakeup signal of the ``dispatchNextPrompt()`` driver loop
    /// (see that method's doc comment for the loop's shape): a driver parks
    /// here instead of polling, wakes when
    /// ``enqueue(prompt:)-(Transcript.Prompt)`` stages a prompt or a
    /// long-running tool posts an event, and asks ``dispatchNextPrompt()``
    /// to run whatever arrived. One wake-up per call — a driver loops,
    /// re-parking after each dispatch.
    func awaitQueuedWork() async

    /// Stages a queued user prompt for a future turn.
    ///
    /// Queued prompts are app state until ``dispatchNextPrompt()`` actually
    /// dispatches one: nothing here touches the recorded transcript, which
    /// stays the record of committed turns only.
    ///
    /// - Parameter prompt: The prompt to stage.
    /// - Returns: The stable id assigned to this queued prompt, usable with
    ///   ``pendingPrompts()``, ``cancel(id:)``, and ``replace(id:prompt:)``.
    @discardableResult
    func enqueue(prompt: Transcript.Prompt) async -> SessionOutbox.ItemID

    /// A snapshot of every prompt currently queued for a future turn, in
    /// FIFO dispatch order.
    ///
    /// - Returns: Each queued prompt's stable id paired with its current
    ///   content, reflecting any ``replace(id:prompt:)`` applied to it since
    ///   it was enqueued.
    func pendingPrompts() async -> [(id: SessionOutbox.ItemID, prompt: Transcript.Prompt)]

    /// Cancels a still-pending queued prompt.
    ///
    /// - Parameter id: The id ``enqueue(prompt:)-(Transcript.Prompt)``
    ///   returned for the prompt to cancel.
    /// - Returns: Whether the prompt was still pending and was removed, or
    ///   had already been drained for dispatch by
    ///   ``dispatchNextPrompt()`` — see ``SessionOutbox/PromptQueueMutationResult``.
    ///   A cancelled prompt never produces a turn. For the in-flight
    ///   counterpart — stopping a turn already handed to the model — see
    ///   ``cancelCurrentTurn()``, and for the two composed into one call that
    ///   covers a prompt's whole life before it generates, ``cancelPrompt(id:)``.
    @discardableResult
    func cancel(id: SessionOutbox.ItemID) async -> SessionOutbox.PromptQueueMutationResult

    /// Replaces a still-pending queued prompt's content, in place —
    /// preserving its FIFO dispatch position.
    ///
    /// - Parameters:
    ///   - id: The id ``enqueue(prompt:)-(Transcript.Prompt)`` returned for
    ///     the prompt to replace.
    ///   - prompt: The prompt's new content.
    /// - Returns: Whether the prompt was still pending and was updated, or
    ///   had already been drained for dispatch by
    ///   ``dispatchNextPrompt()`` — see ``SessionOutbox/PromptQueueMutationResult``.
    ///   A replaced prompt dispatches its edited content.
    @discardableResult
    func replace(id: SessionOutbox.ItemID, prompt: Transcript.Prompt) async -> SessionOutbox.PromptQueueMutationResult

    /// How much queued user-prompt work this session is carrying — the prompts
    /// still waiting *and* the one whose turn is already running.
    ///
    /// ``pendingPrompts()`` reports only what is still waiting. Between
    /// ``SessionOutbox/drainForDispatch()`` and the end of the turn it started, a
    /// prompt is in neither the queue nor the transcript, and this is the surface
    /// that names it there — so a driver's backlog reading never dips by one for
    /// the length of every turn.
    ///
    /// - Returns: The current ``SessionOutbox/QueueDepth``.
    func promptQueueDepth() async -> SessionOutbox.QueueDepth

    /// Delivers the user's answer to a pending elicitation raised by a run on
    /// **this** session — the inbound answer route: app host → session → this
    /// session's own ``SessionMailbox`` → the parked ``ToolContext/elicit(_:)``
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
    /// session's ``SessionMailbox`` by reference, so two sessions sharing a
    /// registry can never cross-route — an id pending on another session is
    /// simply unknown here. Unknown, malformed, and already-answered ids are
    /// safe no-ops per the MCP spec.
    ///
    /// - Parameters:
    ///   - elicitationId: The pending elicitation's id — the string form of
    ///     the ``ElicitationRequest/elicitationId`` the request carried.
    ///   - response: The user's answer.
    /// - Returns: The ``SessionMailbox/ElicitationAnswerDelivery``.
    @discardableResult
    func respond(elicitationId: String, response: ElicitationResponse) async -> SessionMailbox.ElicitationAnswerDelivery

    /// Signals that an accepted URL-mode elicitation's out-of-band flow
    /// finished — the second step of the URL-mode two-step: the accept
    /// delivered through ``respond(elicitationId:response:)`` only meant the
    /// user agreed to open the URL, and this completion is what resumes the
    /// run that stayed parked past it.
    ///
    /// Routes by reference to this session's own ``SessionMailbox`` exactly
    /// as ``respond(elicitationId:response:)`` does. Unknown, malformed,
    /// not-yet-accepted, and already-completed (duplicate) ids are safe
    /// no-ops per the MCP spec.
    ///
    /// - Parameter elicitationId: The accepted URL-mode elicitation's id.
    /// - Returns: The ``SessionMailbox/ElicitationCompletionDelivery``.
    @discardableResult
    func complete(elicitationId: String) async -> SessionMailbox.ElicitationCompletionDelivery
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
    /// Drains this session's run plane before it returns, exactly as
    /// ``respond(to:maxTokens:)`` does — see that method for what each plane
    /// drains, and for the drain's termination rule.
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

    /// Cancels a submitted prompt, whether it is still queued or already
    /// drained for dispatch — withdrawal is guaranteed while it is queued, and
    /// best-effort cooperative cancellation covers its turn after that.
    ///
    /// ``cancel(id:)`` covers only the first half of a prompt's life: once
    /// ``dispatchNextPrompt()`` has drained the prompt it reports
    /// ``SessionOutbox/PromptQueueMutationResult/alreadySent``, which is honest
    /// but leaves a client with no way to stop work it just asked for. This
    /// composes the two primitives that together cover the whole life:
    ///
    /// - **Still queued** — withdrawn through ``cancel(id:)``. It never produces
    ///   a turn. This is also what a prompt whose ``dispatchNextPrompt()`` is
    ///   parked behind another turn reports, because a dispatch drains the queue
    ///   only *after* it holds the turn lock: the parked call never touches the
    ///   withdrawn prompt — it dispatches the next queued prompt instead, or
    ///   returns `nil` when the withdrawn prompt was the only one queued.
    /// - **Already dispatched** — its turn is the one in flight (a session runs
    ///   one turn at a time), so ``cancelCurrentTurn()`` is asked to cancel it.
    ///   A turn cancelled before its model call started never calls the model,
    ///   which is what closes the drained-but-not-yet-generating window.
    /// - **Neither** — the turn already finished, or the id never named a prompt
    ///   here.
    ///
    /// It inherits ``cancelCurrentTurn()``'s aim as well as its semantics: this
    /// cancels the turn that is in flight at the moment it asks. A driver that
    /// lets the *next* dispatch start between this call's two steps can
    /// therefore have that next turn cancelled instead — the same hazard
    /// ``cancelCurrentTurn()`` carries on its own, and the reason a driver
    /// cancels from a task that knows what it dispatched.
    ///
    /// ``PromptCancellationResult/turnCancelled`` is a *request* report, not an
    /// outcome — exactly ``TurnCancellationResult/requested``'s semantics. One
    /// window makes that concrete: a dispatched turn's response is decided
    /// before ``dispatchNextPrompt()`` releases the outbox's dispatched slot,
    /// and that release is a suspension. A cancellation landing inside it still
    /// finds the id dispatched and a turn in flight, so this reports
    /// `turnCancelled` while the turn's response is nonetheless returned to its
    /// caller. So a `turnCancelled` report says the request was recorded
    /// against the prompt's turn — never that the turn failed, which only its
    /// own caller observes.
    ///
    /// - Parameter id: The id ``enqueue(prompt:)-(Transcript.Prompt)`` returned.
    /// - Returns: Which of the three ``PromptCancellationResult`` states applied.
    @discardableResult
    public func cancelPrompt(id: SessionOutbox.ItemID) async -> PromptCancellationResult {
        if await cancel(id: id) == .applied {
            return .withdrawn
        }
        guard await promptQueueDepth().dispatched == id else {
            return .alreadyFinished
        }
        return await cancelCurrentTurn() == .requested ? .turnCancelled : .alreadyFinished
    }

}
