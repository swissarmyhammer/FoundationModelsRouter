import Foundation
import FoundationModels
import Operations
import os

/// The logger ``RoutedSessionActor`` reports a defensively-clamped transcript
/// shrink to (see ``RoutedSessionActor/recordTranscriptDelta(grammar:since:usage:)``).
private let sessionRecordingLogger = makeModuleLogger(category: "Recording")

/// A generation session over a resident model: the recorded surface an
/// application drives to produce text.
///
/// A session is vended only by ``RoutedModel/makeSession(instructions:workingDirectory:)``
/// — there is no public initializer — so it is born holding the router's
/// recording root (``routerId``) and the non-optional ``TranscriptRecorder`` the
/// vending handle carried, and it **retains its ``profile``** so the resident
/// models cannot be evicted out from under an in-flight session.
///
/// Every public generation method (``respond(to:)``, ``streamResponse(to:)``)
/// funnels through one private recorder-bracketed chokepoint: the model runs,
/// then the backend's real transcript is snapshot-diffed against what was
/// already persisted and the new entries are recorded, whether the model
/// returns or throws. A turn's recorded event count is however many entries
/// the SDK's own transcript gained for it — not a fixed one-open/one-close
/// pair — except on the throwing path, which still guarantees at least one
/// trace: either a real `.response` entry the SDK appended before failing, or
/// a synthetic bodyless close when it appended none. Concurrent generations on
/// one model do not interleave:
/// the chokepoint runs inside the model's per-model serial gate
/// (``RoutedModel/serialGate``, a fair FIFO ``AsyncSemaphore`` at value 1) that a
/// session shares with all its forks, so calls on one model queue rather than
/// overlap — MLX generation runs a single GPU stream. The generation itself runs
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
    /// ``RoutedModel/makeGuidedSession(grammar:instructions:workingDirectory:)`` and
    /// `nil` for one from ``RoutedModel/makeSession(instructions:workingDirectory:)``.
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
    /// fork-then-connect composition that wires each session's own tool
    /// instances to it, so event delivery never migrates between sessions).
    nonisolated var outbox: SessionOutbox { get }

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
    /// - Restored from disk (``RoutedModel/restoreSessionTree(root:registry:)``)
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
    /// Runs the ``Compactor/compact(_:prompt:budget:summarizer:)`` pipeline
    /// over this session's current transcript — the deterministic stages
    /// first, then, only if they alone don't land it under `budget`'s
    /// target, the model-assisted ``Summarization`` stage, summarizing with
    /// this session's own resident model by default (a consumer wanting a
    /// different summarizer — e.g. the profile's `flash` slot — drives the
    /// lower-level bare-session recipe directly:
    /// ``Compactor/compact(_:prompt:budget:summarizer:)`` +
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
    /// - Parameters:
    ///   - prompt: The compaction prompt sent to the summarizer when the
    ///     model-assisted stage runs. Defaults to ``CompactionPrompt/default``.
    ///   - budget: The token budget to fold against, or `nil` to use this
    ///     session's own resolved working context at the default
    ///     trigger/target (compaction_plan.md §1.4).
    /// - Returns: What the fold did.
    /// - Throws: Whatever the summarizer throws, when the model-assisted
    ///   stage runs and fails.
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
    /// - Returns: A stream of response fragments, finishing when generation
    ///   completes or throwing if it fails.
    func streamResponse(to prompt: String, maxTokens: Int?) -> AsyncThrowingStream<String, Error>

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
    /// - Throws: Nothing in the current implementation — the admission and
    ///   serial gates never throw and ``LanguageModelSessionBackend/makeFork()``
    ///   is non-throwing; declared `async throws` to match ``RoutedSession``'s
    ///   other generation entry points and leave room for a future conforming
    ///   backend whose fork can fail.
    func fork(workingDirectory: URL?) async throws -> RoutedSession

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
    ///   ``RoutedSession/cancel(_:)``-ed just before the drain) — any pending
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
    ///   ``pendingPrompts()``, ``cancel(_:)``, and ``replace(_:prompt:)``.
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
    ///   content, reflecting any ``replace(_:prompt:)`` applied to it since
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
    ///   A cancelled prompt never produces a turn.
    @discardableResult
    public func cancel(_ id: SessionOutbox.ItemID) async -> SessionOutbox.PromptQueueMutationResult {
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
    public func replace(_ id: SessionOutbox.ItemID, prompt: Transcript.Prompt) async -> SessionOutbox.PromptQueueMutationResult {
        await outbox.replace(id: id, prompt: prompt)
    }
}

/// Builds a ``RoutedSessionActor``, the shared construction path behind both a
/// fresh root session (``RoutedModel/makeSession(grammar:instructions:workingDirectory:)``)
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
/// - Parameters: mirror ``RoutedSessionActor/init(profile:routerId:id:parentId:recordingDirectory:workingDirectory:backend:slot:model:recorder:instructions:grammar:tools:originalTools:outbox:serialGate:forkAdmissionGate:holdsAdmissionPermit:persistedEntryCount:sidecarOrigin:)``
///   one-for-one.
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
    serialGate: AsyncSemaphore,
    forkAdmissionGate: AsyncSemaphore,
    holdsAdmissionPermit: Bool,
    persistedEntryCount: Int,
    sidecarOrigin: SessionSidecarOrigin,
    contextTokens: Int = ProfileDefinition.defaultContext,
    usageState: ContextUsageState = .none
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
        serialGate: serialGate,
        forkAdmissionGate: forkAdmissionGate,
        holdsAdmissionPermit: holdsAdmissionPermit,
        persistedEntryCount: persistedEntryCount,
        sidecarOrigin: sidecarOrigin,
        contextTokens: contextTokens,
        usageState: usageState
    )
}

/// The concrete ``RoutedSession``, backed by a ``LanguageModelSessionBackend``.
///
/// It is `internal` with an `internal` initializer so the only way to obtain one
/// is ``RoutedModel/makeSession(instructions:workingDirectory:)`` — there is no
/// public initializer. The recorder and `routerId` flow down from the vending
/// handle; the `backend`, `slot`, and `model` are what the single
/// ``generate(grammar:_:)`` chokepoint runs the model with.
///
/// Adapts a ``LanguageModelSessionBackend`` to ``CompactionSummarizer``, so
/// ``RoutedSessionActor/compact(prompt:budget:)`` can hand
/// ``Compactor/compact(_:prompt:budget:summarizer:)`` a summarizer without
/// spinning up a separate model handle — "summarizer defaults to the
/// session's own model" (compaction_plan.md §1.4).
///
/// Deliberately wraps a **fresh, blank-slate** backend
/// (``LanguageModelSessionBackend/replacingTranscript(_:)`` seeded with an
/// empty transcript) built fresh for every ``summarize(_:)`` call, rather
/// than the session's own live, accumulating backend:
///
/// - The live backend may already be at or near the context limit — that is
///   *why* compaction is running — so asking it to also answer the
///   summarization prompt (which embeds the rendered old span's own text)
///   would pile more content on top of an already-oversized context, and
///   could itself throw a context-overflow failure.
/// - Reusing the *same* live backend would additionally append the
///   summarization call's own prompt/response pair into the real
///   conversation history being folded away — corrupting it with a turn the
///   user never had.
/// - A single shared blank backend reused across ``Summarization``'s
///   map-reduce calls would leak one chunk's summarization prompt/response
///   into the next chunk's context, when each chunk must be summarized
///   independently.
///
/// A fresh blank-slate backend per call avoids all three: it is a genuine
/// one-shot text-in/text-out call over the same resident model, with no
/// accumulated history of its own.
private struct BackendCompactionSummarizer: CompactionSummarizer {
    /// The session's own backend, over the same resident model every
    /// blank-slate summarizer call is built from.
    let backend: any LanguageModelSessionBackend

    func summarize(_ prompt: String) async throws -> String {
        try await backend.replacingTranscript(Transcript(entries: [])).respond(to: prompt, maxTokens: nil)
    }
}

actor RoutedSessionActor: RoutedSession {
    nonisolated let profile: LanguageModelProfile
    nonisolated let routerId: ULID
    nonisolated let id: ULID
    nonisolated let parentId: ULID?
    nonisolated let recordingDirectory: URL
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
    private var backend: any LanguageModelSessionBackend

    /// The slot this session's model fills, stamped onto recorded events.
    private nonisolated let slot: ModelSlot

    /// The concrete model reference, stamped onto recorded events.
    private nonisolated let model: ModelRef

    /// The non-optional recorder every generation brackets through.
    private nonisolated let recorder: any TranscriptRecorder

    /// The session's system instructions, baked into ``backend`` at
    /// construction; retained here only to carry forward into a forked child's
    /// actor state.
    private nonisolated let instructions: String?

    /// The grammar constraining every ``respond(to:)``, or `nil` for an
    /// unconstrained session.
    ///
    /// Travels with the session so a fork inherits it.
    nonisolated let grammar: Grammar?

    /// The tools this session was constructed with, before any per-session
    /// instancing — retained purely so ``fork(workingDirectory:)`` can build
    /// the child's own tool list via fork-then-connect composition, sourced
    /// from these true originals rather than from ``tools``' already-instanced
    /// copies (see ``fork(workingDirectory:)``'s doc comment).
    private nonisolated let originalTools: [any Tool]

    /// This session's own per-session tool list: every ``EventEmittingTool``
    /// among ``originalTools`` bound to ``outbox`` via a pure
    /// ``EventEmittingTool/connecting(_:)`` copy (a root session), or the
    /// fork-then-connect composition ``fork(workingDirectory:)`` builds (a
    /// fork) — a non-conforming tool passes through unchanged. This is the
    /// exact list threaded to the backend/underlying `LanguageModelSession(tools:)`
    /// — at construction for a root session (``RoutedModel/makeSession(grammar:instructions:workingDirectory:tools:)``
    /// computes it before the backend exists), or via
    /// ``LanguageModelSessionBackend/makeFork(tools:)`` for a fork (see
    /// ``fork(workingDirectory:)``) — retained here too so it stays
    /// inspectable without a live model.
    nonisolated let tools: [any Tool]

    /// This session's own outbox — see ``RoutedSession/outbox``.
    ///
    /// Fresh per session: a root session is constructed already holding a
    /// brand-new, empty outbox and its own ``tools`` instanced to it (a pure
    /// map, computed by the caller before this session exists — see
    /// ``RoutedModel/makeSession(grammar:instructions:workingDirectory:tools:)``);
    /// ``fork(workingDirectory:)`` builds another fresh outbox for the child
    /// and its own fork-then-connect composed tool list instead — deliberately
    /// not sharing this session's outbox with the fork. Because
    /// ``EventEmittingTool/connecting(_:)`` is pure rather than mutating, this
    /// session's own already-instanced ``tools`` keep posting to this outbox
    /// forever, regardless of how many further forks are taken: event
    /// delivery never migrates between sessions.
    nonisolated let outbox: SessionOutbox

    /// The per-model serial generation gate, shared with the owning model's other
    /// sessions and forks.
    ///
    /// Every ``generate(grammar:_:)`` runs inside it, so generations on one
    /// model serialize rather than interleave.
    private nonisolated let serialGate: AsyncSemaphore

    /// The fork-admission gate, shared with the owning model.
    ///
    /// ``fork(workingDirectory:)`` acquires a permit to admit the child; a fork
    /// releases it on deinit (see ``holdsAdmissionPermit``).
    private nonisolated let forkAdmissionGate: AsyncSemaphore

    /// Whether this session holds a fork-admission permit to release when it is
    /// deallocated.
    ///
    /// `true` for a fork admitted through ``fork(workingDirectory:)``, `false`
    /// for a root session, which consumes no admission permit.
    private nonisolated let holdsAdmissionPermit: Bool

    /// Whether the session's first-line `session` meta event has been recorded.
    ///
    /// The chokepoint emits the meta event lazily, before the first turn's open
    /// event, so a session that never generates writes no file at all while one
    /// that does always opens its transcript with a `session` line. Guarded by the
    /// actor's isolation and flipped before the meta append, so no reentrant turn
    /// can emit it twice.
    private var didRecordSessionMeta = false

    /// How many of ``backend``'s ``LanguageModelSessionBackend/transcriptEntries()``
    /// have already been persisted, so each turn's post-generation snapshot can
    /// diff against it to find only what the SDK appended *this* turn.
    ///
    /// `0` for a root session — nothing has been persisted yet. For a fork,
    /// this is the parent's entry count *at fork time*
    /// (``fork(workingDirectory:)`` captures it inside the serial gate it
    /// already holds, before ``LanguageModelSessionBackend/makeFork()`` seeds
    /// the child), so the inherited history the child's backend starts holding
    /// is never re-persisted into the child's own transcript.
    private var persistedEntryCount: Int

    /// Where this session's `session.json` comes from: its own write at init
    /// when the session is new, or the tree it was restored from.
    ///
    /// Inherited from the vending handle — so a fork's sidecar states the same
    /// slot/model/context this session's does — and handed on to every fork
    /// taken from this session (see ``SessionSidecarOrigin/forFork``).
    private nonisolated let sidecarOrigin: SessionSidecarOrigin

    /// The resolved working context, in tokens, ``contextFill`` divides its
    /// numerator by — the profile's ``SlotResolution/contextTokens`` for this
    /// session's slot (compaction_plan.md §1.5).
    nonisolated let contextTokens: Int

    /// The state ``contextFill`` derives its numerator from: nothing yet, a
    /// measured usage, or (restored, unstamped) unknown. See
    /// ``ContextUsageState``.
    ///
    /// Updated by ``finishTurn(grammar:since:usageBefore:pendingEvents:)``
    /// only when the SDK's own transcript diff actually included a
    /// `.response`-kind entry for the turn — a turn rejected before ever
    /// touching the backend (e.g. a guided turn whose grammar validation
    /// throws pre-flight) leaves this session's last known fill untouched
    /// rather than resetting it to a meaningless zero delta.
    private var usageState: ContextUsageState

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
    /// ``RoutedModel/makeSession(instructions:workingDirectory:)`` /
    /// ``RoutedModel/makeGuidedSession(grammar:instructions:workingDirectory:)``,
    /// ``fork(workingDirectory:)``, or
    /// ``RoutedModel/restoreSessionTree(root:registry:)``.
    ///
    /// Every parameter here is documented on the stored property it
    /// initializes, above — no separate `Parameters:` block, so there is
    /// nowhere for the two to drift apart. The two this initializer's own
    /// behavior actually turns on are ``persistedEntryCount`` (`0` for a root
    /// session, or the parent's entry count at fork time for a fork — for a
    /// new fork this doubles as the cut point recorded into its sidecar, so
    /// the lineage cut point and the diff baseline are one fact) and
    /// ``sidecarOrigin`` (where this session's `session.json` comes from — a
    /// write of its own at init, a tree it was restored from, or nothing
    /// durable at all), both read directly in the sidecar write below.
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
        serialGate: AsyncSemaphore,
        forkAdmissionGate: AsyncSemaphore,
        holdsAdmissionPermit: Bool = false,
        persistedEntryCount: Int,
        sidecarOrigin: SessionSidecarOrigin,
        contextTokens: Int = ProfileDefinition.defaultContext,
        usageState: ContextUsageState = .none
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
        self.serialGate = serialGate
        self.forkAdmissionGate = forkAdmissionGate
        self.holdsAdmissionPermit = holdsAdmissionPermit
        self.persistedEntryCount = persistedEntryCount
        self.sidecarOrigin = sidecarOrigin
        self.contextTokens = contextTokens
        self.usageState = usageState

        // The session's own directory is brought into existence here, by its
        // write-once sidecar, before the session exists to record anything into
        // it — so any transcript a reader finds always has the facts to
        // interpret it sitting beside it. A session with no parent is a root and
        // carries no cut point; a fork's cut point *is* its diff baseline, read
        // from the one `persistedEntryCount` rather than passed a second time.
        sidecarOrigin.writeSidecarIfNew(
            instructions: instructions,
            grammar: grammar?.source,
            forkedAtEntryCount: parentId == nil ? nil : persistedEntryCount,
            to: recordingDirectory
        )
    }

    /// Releases this session's fork-admission permit when it is deallocated, so a
    /// fork blocked on the ceiling can proceed.
    ///
    /// Only a fork holds a permit; a root session's `deinit` is a no-op here. The
    /// session's backend is freed by ARC as the actor is torn down — releasing a
    /// fork frees whatever conversation state it holds.
    deinit {
        if holdsAdmissionPermit {
            forkAdmissionGate.signal()
        }
    }

    /// See ``RoutedSession/contextFill``.
    ///
    /// Synchronous here even though the protocol declares `{ get async }`:
    /// this getter runs on the actor's own executor and reads only
    /// actor-isolated state (``usageState``, ``contextTokens``), so it needs
    /// no `await` from inside the actor. A synchronous actor-isolated getter
    /// satisfies an `async` protocol requirement — every access from outside
    /// this actor still goes through an implicit `await` at the call site
    /// (see the `await session.contextFill` example on
    /// ``RoutedSession/contextFill``), so isolation is never bypassed. There
    /// is no data race: every read or write of ``usageState`` in this file
    /// (init, here, ``compact(prompt:budget:)``, ``fork(workingDirectory:)``,
    /// ``finishTurn(grammar:since:usageBefore:pendingEvents:)``) executes
    /// inside this actor's isolation domain.
    var contextFill: Double {
        usageState.fill(contextTokens: contextTokens)
    }

    /// See ``RoutedSession/compact(prompt:budget:)``.
    ///
    /// Runs ``Compactor/compact(_:prompt:budget:summarizer:)`` over
    /// ``backend``'s current transcript, summarizing (when the deterministic
    /// stages alone don't land it under target) with a fresh, disposable
    /// backend over this session's own model (``BackendCompactionSummarizer``).
    /// When folding actually changed anything
    /// (`result.stagesApplied` non-empty), the fold's never-before-recorded
    /// entries are persisted — identified by id, mirroring
    /// ``RecordingLanguageModel/noteCompaction(_:)``'s own id-based diff,
    /// since a fold's live window is typically *shorter* than what came
    /// before it and a positional diff cannot say what is new — and
    /// ``backend`` is swapped for a fresh one seeded from the folded
    /// transcript (``LanguageModelSessionBackend/replacingTranscript(_:)``).
    /// When the transcript was already under target, or every stage ran and
    /// still couldn't land it (the oversized-tail case), the pipeline
    /// returns the original transcript unchanged and this method leaves
    /// ``backend`` exactly as it was.
    @discardableResult
    func compact(
        prompt: CompactionPrompt = .default,
        budget: TokenBudget? = nil
    ) async throws -> CompactionResult {
        await serialGate.wait()
        defer { serialGate.signal() }

        let entries = backend.transcriptEntries()
        let resolvedBudget = budget ?? TokenBudget(limit: contextTokens)

        let (folded, result) = try await Compactor.compact(
            Transcript(entries: entries),
            prompt: prompt,
            budget: resolvedBudget,
            summarizer: BackendCompactionSummarizer(backend: backend)
        )

        // Nothing to fold (already under target) or every stage ran and
        // still couldn't land it (the oversized-tail case): `folded` is
        // `currentTranscript` verbatim, so there is nothing new to record and
        // no reason to swap `backend`.
        guard !result.stagesApplied.isEmpty else { return result }

        await recordSessionMetaIfNeeded()

        // `entries.prefix(persistedEntryCount)` is exactly what this
        // session has already recorded to `transcript.jsonl` — the same
        // baseline `recordTranscriptDelta(grammar:since:usage:pendingEvents:)`
        // diffs an ordinary turn's positional growth against. A fold is not
        // a mere extension of it (`folded` is typically shorter and
        // reorders entries relative to it), so the diff here is by entry id
        // rather than position — see ``TranscriptDiffer/diffByEntryId(lastSeen:current:routerId:sessionId:parentId:slot:model:)``.
        let alreadyRecorded = Transcript(entries: entries.prefix(persistedEntryCount))
        let diffPartials = TranscriptDiffer.diffByEntryId(
            lastSeen: alreadyRecorded,
            current: folded,
            routerId: routerId,
            sessionId: id,
            parentId: parentId,
            slot: slot,
            model: model
        )
        for diffPartial in diffPartials {
            await append(
                partial: makePartialEvent(
                    kind: diffPartial.kind,
                    grammar: grammar,
                    text: diffPartial.text,
                    entry: diffPartial.entry
                )
            )
        }

        // Swap the inner session in place: same actor, same nonisolated
        // `id`, same `recorder`, same `recordingDirectory` — only the
        // backend driving generation changes (compaction_plan.md
        // requirement 4).
        backend = backend.replacingTranscript(folded)
        persistedEntryCount = folded.count
        // `result.tokensAfter` is this fold's own measured/estimated size of
        // what `backend` now holds — reported as `contextFill`'s numerator
        // immediately, the same way a restored session whose newest event is
        // a compaction checkpoint reports its segment's own `tokensAfter`
        // (compaction_plan.md §1.5); the next live turn re-measures exactly
        // and replaces it, same as any other measured state.
        usageState = .measured(input: result.tokensAfter, output: 0)

        return result
    }

    /// Generates a complete text response to a prompt, recording the call.
    ///
    /// Routes through the guided path when ``grammar`` is set, constraining the
    /// response to it through the backend's whole-chunk xgrammar entry point;
    /// otherwise runs the plain path. Both funnel through the same
    /// ``generate(grammar:_:)`` chokepoint.
    ///
    /// - Parameters:
    ///   - prompt: The prompt to respond to.
    ///   - maxTokens: The maximum number of tokens to generate, or `nil` to use
    ///     the underlying model's own default ceiling.
    /// - Returns: The model's complete text response.
    /// - Throws: Any error thrown by the model.
    func respond(to prompt: String, maxTokens: Int?) async throws -> String {
        // `backend` is this session's own persistent generation object — never
        // recreated per call — so turns accumulate conversation state. A guided
        // session constrains every response to its grammar, through the
        // backend's whole-chunk xgrammar entry point; an unguided session takes
        // the plain path. Both funnel through the same chokepoint, which stamps
        // the grammar (or `nil`) onto each event and composes `prompt` with
        // whatever the outbox drains for this turn (see
        // ``generate(grammar:prompt:_:)``).
        try await generate(grammar: grammar, prompt: prompt, respondBody(grammar: grammar, maxTokens: maxTokens))
    }

    /// Streams a text response to a prompt as it is produced, recording the call.
    ///
    /// Wraps ``streamGenerating(prompt:maxTokens:into:)`` in an
    /// `AsyncThrowingStream`, forwarding each produced chunk to the stream's
    /// continuation and finishing it when generation completes or throws;
    /// cancelling the stream cancels the underlying `Task`.
    ///
    /// - Parameters:
    ///   - prompt: The prompt to respond to.
    ///   - maxTokens: The maximum number of tokens to generate, or `nil` to use
    ///     the underlying model's own default ceiling.
    /// - Returns: A stream of response fragments, finishing when generation
    ///   completes or throwing if it fails.
    func streamResponse(to prompt: String, maxTokens: Int?) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await self.streamGenerating(prompt: prompt, maxTokens: maxTokens, into: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    /// Runs the recorder-bracketed streaming generation, forwarding each chunk
    /// the model produces to `continuation`.
    ///
    /// Extracted from ``streamResponse(to:)`` so that method's stream/`Task`
    /// scaffolding stays shallow: the bracketed `for`-loop lives here instead of
    /// nesting inside the continuation closure.
    ///
    /// - Parameters:
    ///   - prompt: The prompt to respond to.
    ///   - maxTokens: The maximum number of tokens to generate, or `nil` to use
    ///     the underlying model's own default ceiling.
    ///   - continuation: The stream continuation each produced chunk is yielded to.
    /// - Throws: Any error thrown by the model, after the chokepoint records the
    ///   close event.
    private func streamGenerating(
        prompt: String,
        maxTokens: Int?,
        into continuation: AsyncThrowingStream<String, Error>.Continuation
    ) async throws {
        // Accumulate the streamed chunks so the close event can carry the full
        // response body; the accumulated text is the recorded response, while the
        // caller has already received each chunk through the continuation.
        _ = try await generate(prompt: prompt) { composedPrompt in
            var response = ""
            for try await chunk in backend.streamResponse(to: composedPrompt, maxTokens: maxTokens) {
                continuation.yield(chunk)
                response += chunk
            }
            return response
        }
    }

    /// Forks a child session over the same resident model. See
    /// ``RoutedSession/fork(workingDirectory:)`` for the full contract.
    ///
    /// Waits on ``forkAdmissionGate`` for a free slot, then builds the child's
    /// tools from ``originalTools`` (never this session's own already-instanced
    /// ``tools``) so a ``ForkableTool`` conformer forks exactly once from its
    /// pristine state before being wired to the child's fresh outbox. Acquires
    /// ``serialGate`` just long enough to read `backend`'s conversation state
    /// and entry count together, closing the race against a concurrent
    /// in-flight turn mutating that same state. The child's
    /// ``recordingDirectory`` nests directly under this session's, and it
    /// inherits this session's ``contextTokens``/``usageState`` so its fill
    /// reporting starts from the parent's fill at fork time rather than zero.
    ///
    /// - Parameter workingDirectory: The child's working directory, or `nil` to
    ///   default to its recording directory.
    /// - Returns: The forked child session.
    /// - Throws: Nothing in the current implementation — see the protocol
    ///   doc's ``RoutedSession/fork(workingDirectory:)`` `Throws:` note.
    func fork(workingDirectory: URL?) async throws -> RoutedSession {
        // Admission: at most the router's `maxConcurrentForks` fork sessions over
        // this model may be in flight at once. Past the ceiling this suspends
        // (FIFO) until an outstanding fork is released and frees its slot. The
        // permit is held for the child's lifetime and released in its `deinit`.
        await forkAdmissionGate.wait()

        // Fresh-per-session outbox plus fork-then-connect tool composition
        // (see ``outbox``'s doc comment): built from ``originalTools`` — the
        // true originals, never this session's own already-instanced
        // ``tools`` — so a ``ForkableTool`` conformer is forked exactly once,
        // from its pristine state, rather than from a copy already wired to
        // this session's outbox. Composition order matters: a tool is forked
        // first via its own `forked()` (falling back to sharing the original
        // unchanged when it doesn't conform to `ForkableTool`), *then* the
        // forked result is wired to `childOutbox` via `connecting(_:)` if it
        // also emits. Since `connecting(_:)` is pure rather than mutating,
        // this session's own already-instanced `tools` are entirely
        // untouched by this and keep posting to this session's own `outbox`
        // — including any detached work that captured this session's sink
        // before the fork — so event delivery never migrates to the child.
        // Computed before the serial-gate window below purely because it has
        // no dependency on `backend`'s state; `childTools` is then threaded
        // into `backend.makeFork(tools:)` itself, so the live model backing
        // the fork actually calls these child-instanced tools rather than
        // silently carrying forward whatever this session's backend was
        // built with (see ``LanguageModelSessionBackend/makeFork(tools:)``).
        let childOutbox = SessionOutbox()
        let childTools = originalTools.map { tool in
            let forked = (tool as? any ForkableTool)?.forked() ?? tool
            return (forked as? any EventEmittingTool)?.connecting(childOutbox) ?? forked
        }

        // Acquire the serial gate before reading `backend`'s conversation state to
        // fork it. `generate(grammar:_:)` releases this same gate only
        // *after* `body()` returns, but `body()` itself suspends across an await
        // while the model generates — so a concurrent turn can be mid-flight,
        // outside the gate's protection window as far as `backend` internals are
        // concerned, mutating the underlying `LanguageModelSession.transcript` at
        // the exact moment `makeFork(tools:)` would otherwise read it. Taking the
        // gate here serializes the fork's read against any in-flight generation,
        // closing that data race; releasing it immediately after capturing the
        // forked backend keeps the hold no longer than necessary.
        await serialGate.wait()
        // Captured in the same gate window as `makeFork(tools:)`, so it names
        // exactly the entry count the child's seeded backend starts holding —
        // the child's own `persistedEntryCount` baseline, so the parent's history
        // inherited into the fork is never re-persisted into the child's
        // transcript (see ``persistedEntryCount``).
        let entryCountAtFork = backend.transcriptEntries().count
        let forkedBackend = backend.makeFork(tools: childTools)
        serialGate.signal()

        let childId = ULID.generate()
        // The child's transcript nests directly *under this session's* directory,
        // so the on-disk tree mirrors the fork lineage: a root session lives at
        // `<base>/<routerId>/<rootId>/`, its fork at `.../<rootId>/<childId>/`, a
        // grandfork one level deeper again. Nesting is derived purely from the
        // parent chain — the child's `workingDirectory` override never moves it.
        let childRecordingDirectory = recordingDirectory
            .appendingPathComponent(childId.description, isDirectory: true)
        // The child lands its own sidecar as it is constructed, from the
        // `entryCountAtFork` baseline passed below — so `fork()` never returns a
        // durable child directory a transcript can land in with no sidecar
        // beside it, and needs no sidecar call of its own to say so (see
        // ``SessionSidecarOrigin``).

        return makeRoutedSessionActor(
            profile: profile,
            routerId: routerId,
            id: childId,
            parentId: id,
            recordingDirectory: childRecordingDirectory,
            workingDirectory: workingDirectory ?? childRecordingDirectory,
            backend: forkedBackend,
            slot: slot,
            model: model,
            recorder: recorder,
            instructions: instructions,
            grammar: grammar,
            tools: childTools,
            originalTools: originalTools,
            outbox: childOutbox,
            serialGate: serialGate,
            forkAdmissionGate: forkAdmissionGate,
            holdsAdmissionPermit: true,
            persistedEntryCount: entryCountAtFork,
            // A fork is a brand-new session wherever its parent could record
            // one — including a fork of a restored session.
            sidecarOrigin: sidecarOrigin.forFork,
            // Same profile/slot, so the same resolved context; the child's
            // backend is seeded from this session's accumulated transcript
            // (``LanguageModelSessionBackend/makeFork(tools:)``), so it also
            // inherits this session's own fill state as of fork time rather
            // than starting from a misleading "nothing sent yet" zero.
            contextTokens: contextTokens,
            usageState: usageState
        )
    }

    /// Builds the closure that submits a turn's composed prompt to `backend`,
    /// honoring `grammar` when present — the if-let-grammar branch between
    /// the plain and grammar-guided `backend.respond(to:maxTokens:)` entry
    /// points that ``respond(to:maxTokens:)`` (a caller-supplied prompt) and
    /// ``dispatchNextPrompt()`` (a queue-sourced prompt) both need, so that
    /// branch lives in exactly one place regardless of where the turn's
    /// prompt came from.
    ///
    /// - Parameters:
    ///   - grammar: The guided-generation grammar in force for this turn, or
    ///     `nil` for an unguided turn.
    ///   - maxTokens: The maximum number of tokens to generate, or `nil` to
    ///     use the underlying model's own default ceiling.
    /// - Returns: A closure that, given this turn's composed prompt, submits
    ///   it to `backend.respond` — following `grammar` when present.
    private func respondBody(grammar: Grammar?, maxTokens: Int?) -> (String) async throws -> String {
        guard let grammar else {
            return { composedPrompt in
                try await self.backend.respond(to: composedPrompt, maxTokens: maxTokens)
            }
        }
        return { composedPrompt in
            try await self.backend.respond(to: composedPrompt, following: grammar, maxTokens: maxTokens)
        }
    }

    /// The single recorder-bracketed generation chokepoint every public method
    /// funnels through.
    ///
    /// The whole bracket runs inside the model's per-model serial gate
    /// (``RoutedModel/serialGate``), so concurrent generations on one model —
    /// including from forks that share the gate — queue in FIFO order rather than
    /// interleave. Inside the gate it first lazily records the session's
    /// first-line `session` meta event (once per session), drains ``outbox``
    /// and composes this turn's prompt (see below), then runs `body`, then
    /// snapshot-diffs ``backend``'s real transcript (see
    /// ``recordTranscriptDelta(grammar:since:usage:pendingEvents:)``) so what
    /// lands on disk mirrors the SDK's own `Transcript.Entry` values rather
    /// than a hand-built paraphrase of the prompt/response strings — on the
    /// success path and the throwing path alike, so a transcript always
    /// gains whatever the SDK durably appended for the turn. A throwing turn
    /// additionally gets a bodyless `.response`-kind close event carrying the
    /// turn's `ms`, so every failed turn still leaves a trace even when the
    /// SDK appended no `.response` entry of its own. On both exits, if the
    /// turn's diff produced no `.prompt`-kind partial for the drained events
    /// to attach to — nothing was durably delivered, so the events never
    /// actually rode any turn — they are re-queued onto ``outbox`` (see
    /// ``requeueUnattachedPendingEvents(_:)``) rather than lost, since
    /// ``SessionOutbox/drainForDispatch()`` already destructively removed
    /// them up front. Every event is routed to this session's
    /// ``recordingDirectory``, so the on-disk transcript tree mirrors the fork
    /// lineage; the single recorder stamps a globally monotonic `seq` at append.
    ///
    /// - Parameters:
    ///   - grammar: The guided-generation grammar in force for this turn, stamped
    ///     onto every event this turn appends.
    ///   - prompt: The caller's own prompt, before this turn's drain-on-turn
    ///     composition (see below).
    ///   - body: The model work to run inside the bracket, given this turn's
    ///     composed prompt and returning the response text callers receive
    ///     (still returned directly; no longer the source of any recorded
    ///     event body).
    /// - Returns: The response text `body` produced.
    /// - Throws: Whatever `body` throws, after recording whatever the SDK
    ///   appended plus the bodyless close event.
    private func generate(
        grammar: Grammar? = nil,
        prompt: String,
        _ body: (String) async throws -> String
    ) async throws -> String {
        // Acquire the serial permit for the whole bracket, releasing it on every
        // path with a `defer` (the recording bracket stays in this actor's
        // isolation region, so the gated work is not sent across an isolation
        // boundary as a `withPermit` closure would be). `wait()`/`signal()` pair
        // exactly like `withPermit`, so no permit can leak.
        await serialGate.wait()
        defer { serialGate.signal() }

        await recordSessionMetaIfNeeded()

        // Drain-on-turn: everything staged in `outbox` since the last turn is
        // folded into *this* turn's prompt, here inside the serial gate so a
        // drain never interleaves with a concurrent turn. This caller supplies
        // its own prompt directly, so only events are drained — never the
        // queued-prompt FIFO (see ``SessionOutbox/drainPendingEvents()``, as
        // opposed to ``SessionOutbox/drainForDispatch()``, which only
        // ``dispatchNextPrompt()`` uses): a prompt waiting in the queue is left
        // exactly where it is rather than silently dequeued and discarded by
        // an unrelated ad hoc turn. An empty outbox drains to an empty
        // `pendingEvents`, so ``composePrompt(pendingEvents:prompt:)`` returns
        // `prompt` unchanged and ``appendingOperationEventSegments(_:to:)`` is
        // never invoked below — byte-identical to a session that never used
        // an outbox.
        let pendingEvents = await outbox.drainPendingEvents().map(\.event)
        return try await runTurn(grammar: grammar, pendingEvents: pendingEvents, ownPrompt: prompt, body)
    }

    /// Runs one turn's model work and recording, given its already-resolved
    /// prompt text and pending events — the common tail ``generate(grammar:prompt:_:)``
    /// (a caller-supplied prompt) and ``dispatchNextPrompt()`` (a queue-sourced
    /// prompt) share once each has resolved its own prompt text and drained
    /// its own pending events, so composing the preamble, timing the turn,
    /// and the finish/requeue/synthetic-close handling live in exactly one
    /// place regardless of where the turn's prompt came from.
    ///
    /// - Parameters:
    ///   - grammar: The guided-generation grammar in force for this turn,
    ///     stamped onto every event this turn appends.
    ///   - pendingEvents: The events already drained from the outbox for this
    ///     turn, in outbox order.
    ///   - ownPrompt: This turn's own prompt text, before composing in
    ///     `pendingEvents`.
    ///   - body: The model work to run inside the bracket, given this turn's
    ///     composed prompt and returning the response text callers receive.
    /// - Returns: The response text `body` produced.
    /// - Throws: Whatever `body` throws, after recording whatever the SDK
    ///   appended plus the bodyless close event.
    private func runTurn(
        grammar: Grammar?,
        pendingEvents: [OperationEvent],
        ownPrompt: String,
        _ body: (String) async throws -> String
    ) async throws -> String {
        let composedPrompt = Self.composePrompt(pendingEvents: pendingEvents, prompt: ownPrompt)

        let started = Date()
        let usageBefore = backend.usageTokenCounts()
        do {
            let response = try await body(composedPrompt)
            // A turn can succeed (return a response) yet still leave the SDK's
            // transcript unchanged for some future conformer — attach-or-requeue
            // applies uniformly on both exits (see the catch branch's matching
            // comment), not just the throwing one; that uniform check lives in
            // ``finishTurnAndRequeueIfUnattached(grammar:since:usageBefore:pendingEvents:)``.
            _ = await finishTurnAndRequeueIfUnattached(
                grammar: grammar, since: started, usageBefore: usageBefore, pendingEvents: pendingEvents)
            return response
        } catch {
            // Whatever the SDK durably appended before failing is still diffed
            // and persisted, with `ms` stamped the same way as the success path
            // (on the diff's own last `.response`-kind entry, if any) — a
            // post-generation failure can still leave the SDK having appended a
            // genuine `.response` entry before throwing.
            let (diffIncludedResponse, usage) = await finishTurnAndRequeueIfUnattached(
                grammar: grammar, since: started, usageBefore: usageBefore, pendingEvents: pendingEvents)
            // Only synthesize the router-only bodyless close when the SDK's own
            // diff did *not* already include a `.response`-kind entry — otherwise
            // this would double up two `.response` events for one turn, breaking
            // the "exactly one close per turn" invariant. This still guarantees
            // every failed turn leaves a trace: either the SDK's own `.response`
            // entry (mapped above) or this synthetic one.
            if !diffIncludedResponse {
                await append(
                    partial: makePartialEvent(
                        kind: .response,
                        grammar: grammar,
                        since: started,
                        tokensIn: usage?.input,
                        tokensOut: usage?.output
                    )
                )
            }
            throw error
        }
    }

    /// Runs the earliest still-pending queued prompt as one normal recorded
    /// turn — the driver's pull surface over ``outbox``'s prompt queue. See
    /// ``RoutedSession/dispatchNextPrompt()`` for the full contract and the
    /// intended driver-loop shape.
    ///
    /// Dequeues the front queued prompt together with any pending
    /// turn-riding events in one atomic ``SessionOutbox/drainForDispatch()``
    /// call, inside the same serial gate ``generate(grammar:prompt:_:)`` runs
    /// its own bracket in — so a dispatch never interleaves with a concurrent
    /// ``respond(to:maxTokens:)``/``streamResponse(to:maxTokens:)`` turn, and
    /// races ``cancel(_:)``/``replace(_:prompt:)`` exactly at the drain: once
    /// this call has drained an id, a `cancel`/`replace` racing it on that id
    /// finds it already gone from the queue and reports
    /// ``SessionOutbox/PromptQueueMutationResult/alreadySent``, leaving this
    /// in-flight turn unaffected.
    ///
    /// Honors ``grammar`` exactly like ``respond(to:maxTokens:)``: a guided
    /// session constrains this turn's response too.
    func dispatchNextPrompt() async throws -> String? {
        await serialGate.wait()
        defer { serialGate.signal() }

        let drained = await outbox.drainForDispatch()
        let pendingEvents = drained.events.map(\.event)
        guard let queued = drained.prompt else {
            // Nothing was queued to dispatch — including the case where a
            // concurrent `cancel(_:)` won the race for the only queued
            // prompt just before this drain. Any events this drain still
            // claimed were never actually delivered on any turn, so
            // re-queue them rather than let this drain silently destroy
            // them (the same "claimed but never delivered" situation
            // ``finishTurnAndRequeueIfUnattached(grammar:since:usageBefore:pendingEvents:)``
            // guards against on the ordinary respond/streamResponse path).
            //
            // Deliberately does NOT call `recordSessionMetaIfNeeded()` on
            // this path: a session that never actually runs a turn must
            // never write its `session` meta line either — the same
            // "writes no file at all until it generates" invariant
            // `generate(grammar:prompt:_:)` upholds, load-bearing for
            // ``TranscriptTree``/``recordSessionMetaIfNeeded()``'s own
            // contract. A driver following the documented
            // `outbox.nextEvent()`-then-dispatch loop can reach this guard
            // on a wakeup caused by a plain posted event with no prompt
            // queued at all, so this must stay a true no-op.
            await requeueUnattachedPendingEvents(pendingEvents)
            return nil
        }

        // Only now — with a prompt confirmed to actually dispatch as a turn
        // — is it safe to record the session's first-line meta event.
        await recordSessionMetaIfNeeded()
        let ownPrompt = Self.flattenedPromptText(queued.prompt)

        return try await runTurn(
            grammar: grammar, pendingEvents: pendingEvents, ownPrompt: ownPrompt,
            respondBody(grammar: grammar, maxTokens: nil)
        )
    }

    /// Runs ``finishTurn(grammar:since:usageBefore:pendingEvents:)`` and, on
    /// either of its exits, re-queues `pendingEvents` whenever the turn's diff
    /// produced no `.prompt`-kind partial to attach them to — the single
    /// attach-or-requeue check ``generate(grammar:prompt:_:)``'s success and
    /// throwing paths both need, so the two exits can't drift out of sync.
    ///
    /// - Parameters:
    ///   - grammar: The guided-generation grammar in force for this turn.
    ///   - since: The turn's start time, forwarded to `finishTurn`.
    ///   - usageBefore: The token-usage snapshot taken before the turn ran.
    ///   - pendingEvents: The events drained from ``outbox`` for this turn.
    /// - Returns: `finishTurn`'s `diffIncludedResponse` and `usage`, for the
    ///   caller's own post-processing; `pendingEventsAttached` is consumed
    ///   here and not returned, since both callers handle it identically.
    private func finishTurnAndRequeueIfUnattached(
        grammar: Grammar?,
        since started: Date,
        usageBefore: (input: Int, output: Int)?,
        pendingEvents: [OperationEvent]
    ) async -> (diffIncludedResponse: Bool, usage: (input: Int, output: Int)?) {
        let (diffIncludedResponse, usage, pendingEventsAttached) = await finishTurn(
            grammar: grammar, since: started, usageBefore: usageBefore, pendingEvents: pendingEvents)
        // `drainForDispatch()` already destructively removed `pendingEvents`
        // from `outbox` before `body()` ran. When this turn's diff produced no
        // `.prompt`-kind partial to attach them to — every `.ebnf`-guided
        // turn, whose backend validates and throws before touching its live
        // session at all (see `MLXFoundationModelsSessionBackend.respond(to:
        // following:maxTokens:)`), or a transcript-shrink guard — the
        // composed preamble was never actually delivered to the model and the
        // events were never persisted either. Re-queue them so a future turn
        // gets another chance, instead of the drain silently destroying state
        // a failed turn never got to deliver.
        if !pendingEventsAttached {
            await requeueUnattachedPendingEvents(pendingEvents)
        }
        return (diffIncludedResponse, usage)
    }

    /// Re-posts `events` back onto ``outbox`` when a turn's diff produced no
    /// `.prompt`-kind partial to attach them to.
    ///
    /// A no-op when `events` is empty, so an empty outbox never touches
    /// ``outbox`` here — preserving byte-identical behavior for the common
    /// case. Re-posted events go back through ``SessionOutbox/post(_:)``'s
    /// normal coalescing policy and are assigned fresh ``SessionOutbox/ItemID``s
    /// (the drain that removed them was already the commit point for their
    /// original ids); what matters is that no event this method is reached
    /// with is ever silently destroyed.
    ///
    /// - Parameter events: The events to re-queue, in outbox order.
    private func requeueUnattachedPendingEvents(_ events: [OperationEvent]) async {
        for event in events {
            await outbox.post(event)
        }
    }

    /// Composes this turn's actual model-visible prompt: `pendingEvents`
    /// rendered as a plain-text preamble (one line per event, in outbox order
    /// — see ``OperationEventSegment/renderedLine(for:)``), a blank line, then
    /// the caller's own `prompt` — or `prompt` unchanged when `pendingEvents`
    /// is empty, so an empty outbox produces byte-identical behavior to a
    /// session that never used one.
    ///
    /// - Parameters:
    ///   - pendingEvents: The events drained from the outbox for this turn, in
    ///     outbox order.
    ///   - prompt: The caller's own prompt.
    /// - Returns: The composed, model-visible prompt string.
    private static func composePrompt(pendingEvents: [OperationEvent], prompt: String) -> String {
        guard !pendingEvents.isEmpty else { return prompt }
        let preamble = pendingEvents.map(OperationEventSegment.renderedLine(for:)).joined(separator: "\n")
        return preamble + "\n\n" + prompt
    }

    /// The joined content of every `.text` segment in `prompt`, in order —
    /// the plain-text form ``dispatchNextPrompt()`` hands to
    /// ``LanguageModelSessionBackend/respond(to:maxTokens:)``/
    /// ``LanguageModelSessionBackend/respond(to:following:maxTokens:)`` for a
    /// queued prompt, since the backend's generation surface takes a
    /// `String`, not a `Transcript.Prompt`. Non-text segments (e.g. a
    /// `.custom` segment) are silently skipped: queuing anything richer than
    /// plain text is not supported by this dispatch path.
    ///
    /// - Parameter prompt: The queued prompt to flatten.
    /// - Returns: The joined text, or `""` if `prompt` carries no `.text`
    ///   segment.
    private static func flattenedPromptText(_ prompt: Transcript.Prompt) -> String {
        let textContents = prompt.segments.compactMap { segment -> String? in
            guard case .text(let text) = segment else { return nil }
            return text.content
        }
        return textContents.joined()
    }

    /// Returns a copy of `partial` with one ``OperationEventSegment`` appended
    /// to its recorded entry per event in `events`, in outbox order — the
    /// durable counterpart to ``composePrompt(pendingEvents:prompt:)``'s text
    /// preamble, attached only to what gets persisted, never to the SDK's own
    /// live transcript.
    ///
    /// - Parameters:
    ///   - events: The events to attach, in outbox order.
    ///   - partial: The turn's `.prompt`-kind partial to augment.
    /// - Returns: `partial` unchanged if it carries no ``TranscriptEvent/Partial/entry``
    ///   (nothing to attach a segment to); otherwise a copy with the segments
    ///   appended.
    private static func appendingOperationEventSegments(
        _ events: [OperationEvent],
        to partial: TranscriptEvent.Partial
    ) -> TranscriptEvent.Partial {
        guard let entry = partial.entry else { return partial }
        let segments = events.map { event in
            TranscriptEntryMapper.segmentPayload(.custom(OperationEventSegment(content: event)))
        }
        return partial.mapBody { text, _ in (text, entry.appendingSegments(segments)) }
    }

    /// Computes this turn's usage delta and records whatever the SDK's
    /// transcript diff contains — the one place both of ``generate(grammar:_:)``'s
    /// success and throwing exits go through, so the usage-delta computation
    /// and the ``recordTranscriptDelta(grammar:since:usage:)`` call are made in
    /// exactly one place rather than duplicated per branch.
    ///
    /// - Parameters:
    ///   - grammar: The guided-generation grammar in force, forwarded to
    ///     ``recordTranscriptDelta(grammar:since:usage:pendingEvents:)``.
    ///   - since: The turn's start instant, forwarded to
    ///     ``recordTranscriptDelta(grammar:since:usage:pendingEvents:)`` to
    ///     stamp `ms`.
    ///   - usageBefore: The pre-turn snapshot captured immediately before
    ///     `body()` ran.
    ///   - pendingEvents: The events this turn drained from the outbox,
    ///     forwarded to ``recordTranscriptDelta(grammar:since:usage:pendingEvents:)``
    ///     to attach as persisted segments on the turn's `.prompt` entry.
    /// - Returns: Whether the diff included a `.response`-kind entry — the
    ///   throwing path uses this to decide whether a synthetic bodyless close
    ///   is still needed; the turn's own usage delta (`nil` if the backend
    ///   cannot report usage), which the throwing path stamps onto that
    ///   synthetic close; and whether `pendingEvents` were actually attached
    ///   to a persisted `.prompt` entry — `generate(grammar:prompt:_:)` uses
    ///   this to decide whether they must be re-queued instead of lost.
    private func finishTurn(
        grammar: Grammar?,
        since: Date,
        usageBefore: (input: Int, output: Int)?,
        pendingEvents: [OperationEvent]
    ) async -> (diffIncludedResponse: Bool, usage: (input: Int, output: Int)?, pendingEventsAttached: Bool) {
        let usage = Self.usageDelta(before: usageBefore, after: backend.usageTokenCounts())
        let (diffIncludedResponse, pendingEventsAttached) = await recordTranscriptDelta(
            grammar: grammar, since: since, usage: usage, pendingEvents: pendingEvents)
        // Only a turn whose diff actually included a `.response`-kind entry
        // measured the whole transcript (generation is stateless, so that
        // turn's own delta *is* the whole transcript's size) — a turn
        // rejected before ever touching `backend` (e.g. a guided turn whose
        // grammar validation throws pre-flight) leaves the last known fill
        // untouched instead of resetting it to a meaningless zero delta. See
        // ``usageState``.
        if diffIncludedResponse {
            usageState = usage.map { .measured(input: $0.input, output: $0.output) } ?? .unknown
        }
        return (diffIncludedResponse, usage, pendingEventsAttached)
    }

    /// The per-turn token usage delta between two ``LanguageModelSessionBackend/usageTokenCounts()``
    /// snapshots taken immediately before and after a turn's `body()` ran.
    ///
    /// `nil` when either snapshot is `nil` — a backend that cannot report
    /// usage at all, or one that stopped being able to mid-turn — rather than
    /// synthesizing a delta from a partial reading.
    ///
    /// - Parameters:
    ///   - before: The snapshot taken immediately before `body()` ran.
    ///   - after: The snapshot taken immediately after `body()` returned or
    ///     threw.
    /// - Returns: The turn's own `(input, output)` token counts, or `nil`.
    private static func usageDelta(
        before: (input: Int, output: Int)?,
        after: (input: Int, output: Int)?
    ) -> (input: Int, output: Int)? {
        guard let before, let after else { return nil }
        return (after.input - before.input, after.output - before.output)
    }

    /// Snapshot-diffs ``backend``'s real transcript against ``persistedEntryCount``
    /// and persists exactly what the SDK appended since the last diff — the core
    /// of the "persist the SDK's own `Transcript`, not a paraphrase" design (see
    /// plan.md's "Transcript fidelity" section).
    ///
    /// Reads `backend.transcriptEntries()` once. If a shrink is detected
    /// (`entries.count < persistedEntryCount` — nothing guarantees the SDK
    /// transcript stays strictly append-only forever; a future
    /// `TranscriptErrorHandlingPolicy` opt-in could condense or rewrite it),
    /// this logs a warning, records nothing for this turn's diff, and resets
    /// ``persistedEntryCount`` to the smaller count so the next turn diffs from
    /// reality instead of tripping the same guard again. Otherwise the
    /// last-seen (the first ``persistedEntryCount`` entries) and current (all
    /// of `entries`) states are diffed via ``TranscriptDiffer/diff(lastSeen:current:routerId:sessionId:parentId:slot:model:)``
    /// — the one diff implementation this session shares with the upcoming
    /// recording handle — which maps every new entry through
    /// ``TranscriptEntryMapper/event(from:)`` and stamps this session's
    /// identity onto each produced partial.
    ///
    /// Each produced partial is then re-stamped with this turn's `grammar`
    /// and appended as its own event. When `since` is non-nil, the turn's
    /// measured `ms` is stamped only on the *last* `.response`-kind event the
    /// diff produced — not on every appended event — on the success path and
    /// the throwing path alike, so an SDK-appended `.response` entry from a
    /// turn that failed *after* generating still gets the turn's `ms`.
    /// `usage` (the turn's own `tokensIn`/`tokensOut` delta, or `nil` when the
    /// backend cannot report usage) is stamped the same way, on that same
    /// last `.response`-kind event — mirroring `ms`, since both are per-turn
    /// totals that only make sense attributed to the turn's one closing
    /// event, not every entry it appended.
    ///
    /// - Parameters:
    ///   - grammar: The guided-generation grammar in force, stamped onto every
    ///     appended event.
    ///   - since: The turn's start instant to stamp `ms` with on the diff's last
    ///     `.response`-kind event, or `nil` to leave `ms` unset on every
    ///     appended event.
    ///   - usage: The turn's own `(input, output)` token usage delta to stamp
    ///     as `tokensIn`/`tokensOut` on the diff's last `.response`-kind
    ///     event, or `nil` to leave both unset on every appended event.
    ///   - pendingEvents: The events this turn drained from the outbox, in
    ///     outbox order. When non-empty, one ``OperationEventSegment`` per
    ///     event is appended (via ``appendingOperationEventSegments(_:to:)``)
    ///     onto the turn's `.prompt`-kind diff partial — the first one, since
    ///     a turn submits exactly one prompt — before it is persisted; the
    ///     SDK's own live transcript is never touched. Empty means no
    ///     augmentation at all, so this method's output is byte-identical to
    ///     before this feature existed.
    /// - Returns: Whether this diff included a `.response`-kind entry — the
    ///   throwing path in ``generate(grammar:prompt:_:)`` uses this to decide
    ///   whether a synthetic bodyless close is still needed, so a turn whose
    ///   SDK transcript already gained a real `.response` entry before
    ///   failing never gets two `.response` events — and whether
    ///   `pendingEvents` (when non-empty) actually found a `.prompt`-kind
    ///   partial to attach to. The latter is `true` whenever `pendingEvents`
    ///   is empty (nothing to attach, so nothing was missed) and `false`
    ///   whenever it is non-empty but no `.prompt`-kind partial existed —
    ///   e.g. the shrink guard below, or a backend (like an `.ebnf`-guided
    ///   one) that throws before appending anything at all — so the caller
    ///   knows to re-queue them rather than let the drain silently destroy
    ///   them.
    private func recordTranscriptDelta(
        grammar: Grammar?,
        since: Date?,
        usage: (input: Int, output: Int)?,
        pendingEvents: [OperationEvent]
    ) async -> (diffIncludedResponse: Bool, pendingEventsAttached: Bool) {
        let entries = backend.transcriptEntries()
        guard entries.count >= persistedEntryCount else {
            sessionRecordingLogger.warning(
                """
                transcript shrank from \(self.persistedEntryCount, privacy: .public) to \
                \(entries.count, privacy: .public) entries for session \
                \(self.id.description, privacy: .public); recording no entries for this turn and \
                resetting the baseline
                """
            )
            persistedEntryCount = entries.count
            return (false, pendingEvents.isEmpty)
        }

        let diffPartials = TranscriptDiffer.diff(
            lastSeen: Transcript(entries: entries.prefix(persistedEntryCount)),
            current: Transcript(entries: entries),
            routerId: routerId,
            sessionId: id,
            parentId: parentId,
            slot: slot,
            model: model
        )
        guard !diffPartials.isEmpty else { return (false, pendingEvents.isEmpty) }

        let lastResponseIndex = diffPartials.lastIndex { $0.kind == .response }
        let promptIndexToAugment = pendingEvents.isEmpty ? nil : diffPartials.firstIndex { $0.kind == .prompt }

        for (index, diffPartial) in diffPartials.enumerated() {
            let isTurnClose = index == lastResponseIndex
            let stampSince = (since != nil && isTurnClose) ? since : nil
            let stampUsage = (usage != nil && isTurnClose) ? usage : nil
            let recordedPartial = (index == promptIndexToAugment)
                ? Self.appendingOperationEventSegments(pendingEvents, to: diffPartial)
                : diffPartial
            await append(
                partial: makePartialEvent(
                    kind: recordedPartial.kind,
                    grammar: grammar,
                    text: recordedPartial.text,
                    since: stampSince,
                    entry: recordedPartial.entry,
                    tokensIn: stampUsage?.input,
                    tokensOut: stampUsage?.output
                )
            )
        }
        persistedEntryCount = entries.count
        let pendingEventsAttached = pendingEvents.isEmpty || promptIndexToAugment != nil
        return (lastResponseIndex != nil, pendingEventsAttached)
    }

    /// Records the session's first-line `session` meta event the first time this
    /// session records anything, so a generating session's transcript always opens
    /// with a `session` line while a session that never generates writes no file.
    ///
    /// The flag is flipped before the append so a reentrant turn during the meta
    /// append's suspension cannot emit a second meta event.
    private func recordSessionMetaIfNeeded() async {
        guard !didRecordSessionMeta else { return }
        didRecordSessionMeta = true
        await append(partial: makePartialEvent(kind: .session, grammar: grammar))
    }

    /// Appends a partial event through the recorder into this session's own
    /// transcript directory, so siblings write separate files and the on-disk tree
    /// mirrors the fork lineage.
    ///
    /// - Parameter partial: The event to record, minus its recorder-owned `seq`
    ///   and `ts`.
    private func append(partial: TranscriptEvent.Partial) async {
        await recorder.append(partial, to: recordingDirectory)
    }

    /// Builds an event of the given kind stamped with this session's provenance.
    ///
    /// The `session` meta event, every entry-derived event
    /// ``recordTranscriptDelta(grammar:since:usage:)`` appends, and the throwing
    /// path's bodyless close event all share this one helper; a close-carrying
    /// call passes `since` to record the turn's measured duration.
    ///
    /// - Parameters:
    ///   - kind: The event kind to stamp — `.session` for meta, or the mapped
    ///     ``TranscriptEntryMapper/event(from:)`` kind for an entry-derived event.
    ///   - grammar: The guided-generation grammar in force, recorded as its
    ///     source, or `nil` for an unconstrained turn.
    ///   - text: The event's flattened body text from the mapper, or `nil` for
    ///     the bodyless `session` meta event or a bodyless close. Recording-level
    ///     and redaction trimming happen later, in the recorder.
    ///   - since: The turn's start instant to stamp `ms` with, or `nil` to leave
    ///     `ms` unset.
    ///   - entry: The structural payload mirroring the SDK's own
    ///     `Transcript.Entry`, or `nil` for the `session` meta event and the
    ///     throwing path's bodyless close.
    ///   - tokensIn: The turn's input token usage delta to stamp, or `nil` to
    ///     leave it unset.
    ///   - tokensOut: The turn's output token usage delta to stamp, or `nil`
    ///     to leave it unset.
    /// - Returns: The partial event for the recorder to stamp and append.
    private func makePartialEvent(
        kind: TranscriptEvent.Kind,
        grammar: Grammar? = nil,
        text: String? = nil,
        since: Date? = nil,
        entry: TranscriptEntryPayload? = nil,
        tokensIn: Int? = nil,
        tokensOut: Int? = nil
    ) -> TranscriptEvent.Partial {
        TranscriptEvent.Partial(
            routerId: routerId,
            sessionId: id,
            parentId: parentId,
            slot: slot,
            model: model,
            kind: kind,
            grammar: grammar?.source,
            text: text,
            tokensIn: tokensIn,
            tokensOut: tokensOut,
            ms: since.map { Int(Date().timeIntervalSince($0) * 1_000) },
            entry: entry
        )
    }
}
