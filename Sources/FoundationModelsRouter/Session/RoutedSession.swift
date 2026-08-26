import Foundation
import FoundationModels

/// The outcome of ``RoutedSession/cancelCurrentTurn()``.
public enum TurnCancellationResult: Sendable, Equatable {
    /// A turn was in flight, or a ``RoutedSession/respond(to:maxTokens:)`` call
    /// was draining the run plane, and cancellation was requested of it.
    ///
    /// Cancellation is cooperative. This reports that the request was recorded,
    /// not that the model or a tool has stopped.
    case requested

    /// Nothing was in flight to cancel, so nothing happened.
    case noTurnInFlight
}

/// The outcome of ``RoutedSession/cancelPrompt(id:)``.
enum PromptCancellationResult: Sendable, Equatable {
    /// The prompt was still in the queue and was withdrawn. It never produced a turn.
    case withdrawn

    /// The prompt was already dispatched, so its turn was cancelled as
    /// ``RoutedSession/cancelCurrentTurn()`` does.
    case turnCancelled

    /// Nothing was left to cancel: the turn had finished, or the id named no
    /// queued prompt on this session.
    case alreadyFinished
}

/// A generation session over a resident model: the recorded surface an
/// application drives to produce text.
///
/// A session is vended only by ``RoutedModel/makeSession(instructions:workingDirectory:recordingRoot:tools:budget:compactionPrompt:summarization:agentSpawn:discoveryPriming:)``.
/// It holds the router's recording root (``routerId``), a ``TranscriptRecorder``,
/// and retains its ``profile`` so the resident models stay loaded.
///
/// Every generation method records the turn's new transcript entries, whether
/// the model returns or throws. One session never has two turns in flight
/// (``RoutedSessionActor/turnLock``), and model work over one model does not
/// overlap (``RoutedModel/generationGate``). The generation gate is released
/// for ``RoutedSession/awaitingUser(_:)`` and lent through
/// ``GenerationPermitLoan``. The raw `LanguageModelSession` is never vended;
/// ``RoutedSession`` is the only generation surface.
///
/// The identity and directory accessors are `nonisolated` immutables.
public protocol RoutedSession: Actor {
    /// The resolved profile this session runs against.
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

    /// The directory model/tool work runs relative to. Defaults to
    /// ``recordingDirectory``.
    nonisolated var workingDirectory: URL { get }

    /// The grammar that constrains every ``respond(to:)`` on this session, or
    /// `nil` for an unconstrained session.
    ///
    /// Set by ``RoutedModel/makeGuidedSession(grammar:instructions:workingDirectory:tools:budget:compactionPrompt:summarization:agentSpawn:discoveryPriming:)``.
    /// ``fork(workingDirectory:)`` inherits it. ``streamResponse(to:)`` is
    /// not constrained.
    nonisolated var grammar: Grammar? { get }

    /// Context fill, 0...1: the newest turn's measured `(tokensIn + tokensOut)`
    /// against the profile's resolved working context.
    ///
    /// `0` before the first turn. A restored session reports its last stamped
    /// `.response` usage, or ``unknownContextFill`` when there is no stamp.
    var contextFill: Double { get async }

    /// The SDK transcript this session has accumulated so far, read under the
    /// session's turn lock.
    ///
    /// A read issued while a turn is in flight waits for that turn. A tool body
    /// reading its own session's transcript does not wait; it sees the history
    /// as it stands mid-turn.
    var transcript: Transcript { get async }

    /// Folds this session's transcript in place: same ``id``, same
    /// ``recordingDirectory``, shorter live window.
    ///
    /// Runs the deterministic compaction stages first, then the model-assisted
    /// ``Summarization`` stage only if the transcript is still over target. The
    /// summarization configuration is the one this session was vended with
    /// (``RoutedSessionActor/summarization``). When the fold changes anything,
    /// the summary entry is appended to `transcript.jsonl` and the backend is
    /// reseeded. When the transcript is already under target, nothing changes.
    ///
    /// A fold holds the turn lock, so ``cancelCurrentTurn()`` can cancel it.
    /// To recover from `LanguageModelError.contextSizeExceeded`, compact with
    /// a lower target and retry once.
    ///
    /// - Parameters:
    ///   - prompt: The compaction prompt for the summarizer. Defaults to ``CompactionPrompt/default``.
    ///   - budget: The token budget to fold against, or `nil` for this session's resolved working context.
    /// - Returns: What the fold did.
    /// - Throws: The summarizer's error; `CancellationError` when cancelled; or
    ///   ``SessionReentryError/sameSessionTurnInFlight(sessionID:)`` when called
    ///   from a tool of this session's own turn.
    @discardableResult
    func compact(prompt: CompactionPrompt, budget: TokenBudget?) async throws -> CompactionResult

    /// Generates a complete text response to a prompt, recording the call.
    ///
    /// This call drains both planes before it answers. The content plane is
    /// folded into each turn's prompt as a preamble. The run plane is drained
    /// after this call's own turn: every background run is awaited to
    /// settlement, and a further turn delivers the results to the model. The
    /// drain runs at most ``RoutedSessionActor/backgroundRunDrainRoundLimit``
    /// further turns. It does not end background runs; that is ``close()``'s job.
    ///
    /// A cancellation ends the drain and returns the last turn's answer. The
    /// runs it waited on stay running.
    ///
    /// Nothing bounds a decode: there is no timeout. A generation with no
    /// observable progress reports ``SessionEvent/generationStalled(_:)`` on
    /// ``streamSessionEvents()`` with ``GenerationProgressVisibility/wholeAnswer``
    /// visibility, and one line in this module's log.
    ///
    /// - Parameters:
    ///   - prompt: The prompt to respond to.
    ///   - maxTokens: The maximum number of tokens to generate, or `nil` for the model's default.
    /// - Returns: The model's complete text response; the last drained turn's
    ///   when this call's own turn backgrounded work.
    /// - Throws: Any error thrown by the model, or
    ///   ``SessionReentryError/sameSessionTurnInFlight(sessionID:)`` when called
    ///   from a tool of this session's own turn.
    func respond(to prompt: String, maxTokens: Int?) async throws -> String

    /// Streams a text response to a prompt as it is produced, recording the call.
    ///
    /// Abandoning the stream cancels the turn behind it, as ``cancelCurrentTurn()``
    /// does, and records it as a cancelled turn. This surface does not drain the
    /// run plane; it finishes while a backgrounded run is in flight. A stall
    /// reports ``SessionEvent/generationStalled(_:)`` on ``streamSessionEvents()``
    /// with ``GenerationProgressVisibility/fragments(observed:)`` visibility.
    ///
    /// - Parameters:
    ///   - prompt: The prompt to respond to.
    ///   - maxTokens: The maximum number of tokens to generate, or `nil` for the model's default.
    /// - Returns: A stream of response fragments. It throws if generation fails.
    func streamResponse(to prompt: String, maxTokens: Int?) -> AsyncThrowingStream<String, Error>

    /// Streams a rich event sequence for a prompt as it is produced,
    /// recording the call exactly like ``streamResponse(to:maxTokens:)``.
    ///
    /// Where ``streamResponse(to:maxTokens:)`` yields only text fragments, this
    /// surfaces the turn's tool calls, tool lifecycle, reasoning, and closing
    /// usage too.
    ///
    /// Order within one turn: ``SessionEvent/turnStarted(_:)``; then
    /// ``SessionEvent/textDelta(_:)`` fragments; then, after the turn's diff,
    /// tool call and tool status events, ``SessionEvent/reasoningDelta(_:)``,
    /// and ``SessionEvent/entryRecorded(id:kind:)`` per recorded entry; finally
    /// ``SessionEvent/turnEnded(_:)``. ``SessionEvent/compaction(_:)`` comes
    /// before the turn's events for a proactive fold, and after the failed
    /// attempt's ``SessionEvent/turnEnded(_:)`` for a reactive fold.
    /// ``SessionEvent/generationStalled(_:)`` is emitted on each interval
    /// without a fragment.
    ///
    /// Abandoning this stream cancels the turn. This surface does not drain the
    /// run plane. A run that settles before the stream ends is reported as
    /// ``SessionEvent/runSettled(_:)``; a later one is reported on
    /// ``streamSessionEvents()``.
    ///
    /// - Parameters:
    ///   - prompt: The prompt to respond to.
    ///   - maxTokens: The maximum number of tokens to generate, or `nil` for the model's default.
    /// - Returns: A stream of session events. It throws if the turn fails.
    func streamEvents(to prompt: String, maxTokens: Int?) -> AsyncThrowingStream<SessionEvent, Error>

    /// Streams the ``SessionEvent``s that belong to this *session* rather than
    /// to one of its turns, for as long as the session lives.
    ///
    /// Every turn-lifecycle event travels here, whichever entry point ran the
    /// turn: ``SessionEvent/turnStarted(_:)``, ``SessionEvent/reasoningDelta(_:)``,
    /// tool-lifecycle events, ``SessionEvent/entryRecorded(id:kind:)``,
    /// ``SessionEvent/compaction(_:)``, ``SessionEvent/discoveryPrimingFailed(_:)``,
    /// ``SessionEvent/generationStalled(_:)``, and ``SessionEvent/turnEnded(_:)``.
    /// ``SessionEvent/textDelta(_:)`` and ``SessionEvent/textReset`` travel only
    /// on ``streamEvents(to:maxTokens:)``.
    ///
    /// Every event belongs to the turn named by the most recent
    /// ``SessionEvent/turnStarted(_:)``. Each call vends an independent
    /// subscription, buffered without bound. Ending iteration drops the
    /// subscription; ``close()`` finishes every outstanding one.
    ///
    /// - Returns: A stream of this session's own session-scoped events.
    func streamSessionEvents() -> AsyncStream<SessionEvent>

    /// Cancels the turn currently in flight on this session. Best-effort.
    ///
    /// ``cancel(id:)`` withdraws a queued prompt; this reaches a turn already
    /// handed to the model. It cancels the `Task` that runs the model call, so
    /// cancellation propagates into the tool calls the SDK invokes. Propagation
    /// past the process boundary is advisory: an MCP server may keep working.
    ///
    /// The turn's caller receives `CancellationError` once the model work
    /// unwinds. A stream keeps the fragments it already yielded. Model work
    /// that never checks for cancellation runs to completion and the turn
    /// returns its response. A cancellation that lands before any model call
    /// starts makes the turn throw without calling the model. The transcript
    /// records a cancelled turn as a failed turn, with one close. The outbox
    /// follows the attach-or-requeue rule. The gates stay balanced, including
    /// for a turn suspended in ``awaitingUser(_:)``.
    ///
    /// Only the turn in flight is affected. A fold's model-assisted stage is
    /// cancelled where it stands; its deterministic stages are not interrupted.
    /// A ``respond(to:maxTokens:)`` draining the run plane stops draining and
    /// returns its last turn's answer; the runs it waited on stay running.
    ///
    /// Safe at any time and any number of times.
    ///
    /// - Returns: ``TurnCancellationResult/requested`` when a turn or a draining
    ///   `respond(to:maxTokens:)` was in flight; or
    ///   ``TurnCancellationResult/noTurnInFlight`` when there was nothing to cancel.
    @discardableResult
    func cancelCurrentTurn() async -> TurnCancellationResult

    /// Runs `body` with the per-model generation gate released, and re-acquires
    /// it before returning. Use it for a wait on a person, never on the model.
    ///
    /// A tool that awaits a person mid-turn would otherwise hold
    /// ``RoutedModel/generationGate`` and block every other session over that
    /// model. This session keeps its own turn lock throughout. A tool that
    /// generates on the model uses ``GenerationPermitLoan`` instead.
    ///
    /// The re-acquire happens on every exit from `body`, including a throw and
    /// a cancellation. Overlapping calls in one turn release once, on the
    /// outermost, and re-acquire once, when the last of them finishes. A wait
    /// with no turn in flight releases nothing.
    ///
    /// - Precondition: Call this from inside a tool the SDK invoked for this
    ///   session's own in-flight turn, and do not let the wait outlive that tool call.
    /// - Parameter body: The wait on a person to run with the generation gate released.
    /// - Returns: Whatever `body` returns.
    /// - Throws: Rethrows any error thrown by `body`, after re-acquiring.
    func awaitingUser<T: Sendable>(_ body: @Sendable () async throws -> T) async rethrows -> T

    /// Forks a child session over the same resident model.
    ///
    /// The child takes a fresh id with ``parentId`` set to this session's id,
    /// a ``recordingDirectory`` nested under the parent's, and the parent's
    /// ``grammar``. Its backend is seeded from this session's conversation
    /// state through ``LanguageModelSessionBackend/makeFork()``. At most the
    /// router's `maxConcurrentForks` forks over one model may be in flight; a
    /// fork past that ceiling awaits a free slot.
    ///
    /// A tool body cannot fork the session whose turn invoked it.
    ///
    /// - Parameter workingDirectory: The child's working directory, or `nil` for its recording directory.
    /// - Returns: The forked child session.
    /// - Throws: ``SessionReentryError/forkDuringSameSessionTurn(sessionID:)``
    ///   when the call comes from inside a tool call of this session's own turn.
    func fork(workingDirectory: URL?) async throws -> RoutedSession

    /// Tears the session down: runs ``SessionMailbox/sweep()``, which cancels
    /// every background run and rejects every pending elicitation, and journals
    /// the resulting terminal events before it returns.
    ///
    /// Call it where a session's life ends. `deinit` does not run this sweep.
    /// It also finishes every ``streamSessionEvents()`` subscription. Idempotent.
    func close() async

    /// Runs the earliest pending prompt in this session's queue as one recorded
    /// turn, with any pending turn-riding events, and returns the model's response.
    ///
    /// Nothing in this package drains the queue automatically. A driver waits
    /// on ``awaitQueuedWork()`` and then calls this method. When no prompt is
    /// queued but a background run has settled, this runs a delivery turn that
    /// reports the run's terminal to the model.
    ///
    /// Within the queue, prompts dispatch in enqueue order. Between the queue
    /// and the direct ``respond(to:maxTokens:)`` path there is no order; a
    /// client that needs one sequences the calls itself. The turn lock is a
    /// strict FIFO ``AsyncSemaphore``, and a cancelled caller keeps its place
    /// in line.
    ///
    /// - Returns: The model's response text, or `nil` if no prompt was queued
    ///   and no run had settled when this call drained the outbox.
    /// - Throws: Any error thrown by the model.
    func dispatchNextPrompt() async throws -> String?

    /// Suspends until this session holds work for a future turn: a queued
    /// prompt, a pending tool event, or a settled background run. Returns at
    /// once when it already does. One wake-up per call.
    func awaitQueuedWork() async

    /// Stages a queued user prompt for a future turn. Nothing here touches the
    /// recorded transcript.
    ///
    /// - Parameter prompt: The prompt to stage.
    /// - Returns: The stable id of this queued prompt, usable with
    ///   ``pendingPrompts()``, ``cancel(id:)``, and ``replace(id:prompt:)``.
    @discardableResult
    func enqueue(prompt: Transcript.Prompt) async -> SessionOutbox.ItemID

    /// A snapshot of every prompt currently queued for a future turn, in FIFO
    /// dispatch order.
    ///
    /// - Returns: Each queued prompt's stable id with its current content.
    func pendingPrompts() async -> [(id: SessionOutbox.ItemID, prompt: Transcript.Prompt)]

    /// Cancels a still-pending queued prompt. See ``cancelCurrentTurn()`` for a
    /// turn already in flight, and ``cancelPrompt(id:)`` for both in one call.
    ///
    /// - Parameter id: The id ``enqueue(prompt:)-(Transcript.Prompt)`` returned.
    /// - Returns: Whether the prompt was removed, or was already drained for
    ///   dispatch. See ``SessionOutbox/PromptQueueMutationResult``.
    @discardableResult
    func cancel(id: SessionOutbox.ItemID) async -> SessionOutbox.PromptQueueMutationResult

    /// Replaces a still-pending queued prompt's content in place. The prompt
    /// keeps its FIFO dispatch position.
    ///
    /// - Parameters:
    ///   - id: The id ``enqueue(prompt:)-(Transcript.Prompt)`` returned.
    ///   - prompt: The prompt's new content.
    /// - Returns: Whether the prompt was updated, or was already drained for
    ///   dispatch. See ``SessionOutbox/PromptQueueMutationResult``.
    @discardableResult
    func replace(id: SessionOutbox.ItemID, prompt: Transcript.Prompt) async -> SessionOutbox.PromptQueueMutationResult

    /// How much queued user-prompt work this session carries: the prompts
    /// still waiting and the one whose turn is running.
    ///
    /// - Returns: The current ``SessionOutbox/QueueDepth``.
    func promptQueueDepth() async -> SessionOutbox.QueueDepth

    /// Delivers the user's answer to a pending elicitation raised by a run on
    /// this session.
    ///
    /// The answer addresses one elicitation by id. A form-mode `accept` resumes
    /// the run with its `content`; `decline` and `cancel` resume with those
    /// actions. A URL-mode `accept` keeps the run running until
    /// ``complete(elicitationId:)`` arrives. Unknown, malformed, and
    /// already-answered ids are safe no-ops.
    ///
    /// - Parameters:
    ///   - elicitationId: The pending elicitation's id, the string form of ``ElicitationRequest/elicitationId``.
    ///   - response: The user's answer.
    /// - Returns: The ``SessionMailbox/ElicitationAnswerDelivery``.
    @discardableResult
    func respond(elicitationId: String, response: ElicitationResponse) async -> SessionMailbox.ElicitationAnswerDelivery

    /// Signals that an accepted URL-mode elicitation's out-of-band flow
    /// finished, and resumes the run. Unknown, malformed, not-yet-accepted, and
    /// already-completed ids are safe no-ops.
    ///
    /// - Parameter elicitationId: The accepted URL-mode elicitation's id.
    /// - Returns: The ``SessionMailbox/ElicitationCompletionDelivery``.
    @discardableResult
    func complete(elicitationId: String) async -> SessionMailbox.ElicitationCompletionDelivery
}

extension RoutedSession {
    /// See ``compact(prompt:budget:)``, with both parameters at their defaults.
    ///
    /// - Returns: What the fold did.
    /// - Throws: The summarizer's error.
    @discardableResult
    func compact() async throws -> CompactionResult {
        try await compact(prompt: .default, budget: nil)
    }

    /// See ``compact(prompt:budget:)``, with `prompt` at ``CompactionPrompt/default``.
    ///
    /// - Parameter budget: The token budget to fold against, or `nil` for this session's resolved working context.
    /// - Returns: What the fold did.
    /// - Throws: The summarizer's error.
    @discardableResult
    func compact(budget: TokenBudget?) async throws -> CompactionResult {
        try await compact(prompt: .default, budget: budget)
    }

    /// See ``respond(to:maxTokens:)``, with the model's default token ceiling.
    ///
    /// - Parameter prompt: The prompt to respond to.
    /// - Returns: The model's complete text response.
    /// - Throws: Any error thrown by the model.
    public func respond(to prompt: String) async throws -> String {
        try await respond(to: prompt, maxTokens: nil)
    }

    /// See ``streamResponse(to:maxTokens:)``, with the model's default token ceiling.
    ///
    /// - Parameter prompt: The prompt to respond to.
    /// - Returns: A stream of response fragments.
    public func streamResponse(to prompt: String) -> AsyncThrowingStream<String, Error> {
        streamResponse(to: prompt, maxTokens: nil)
    }

    /// See ``streamEvents(to:maxTokens:)``, with the model's default token ceiling.
    ///
    /// - Parameter prompt: The prompt to respond to.
    /// - Returns: A stream of session events.
    public func streamEvents(to prompt: String) -> AsyncThrowingStream<SessionEvent, Error> {
        streamEvents(to: prompt, maxTokens: nil)
    }

    /// Stages a plain-text queued user prompt for a future turn, as one `.text`
    /// segment.
    ///
    /// - Parameter prompt: The prompt text to stage.
    /// - Returns: The stable id of this queued prompt.
    @discardableResult
    func enqueue(prompt: String) async -> SessionOutbox.ItemID {
        await enqueue(prompt: Transcript.Prompt(segments: [.text(Transcript.TextSegment(content: prompt))]))
    }

    /// Cancels a submitted prompt, whether it is still queued or already
    /// dispatched.
    ///
    /// A queued prompt is withdrawn through ``cancel(id:)``. A dispatched
    /// prompt's turn is cancelled through ``cancelCurrentTurn()``, which cancels
    /// the turn in flight at that moment. ``PromptCancellationResult/turnCancelled``
    /// reports that the request was recorded, not that the turn failed.
    ///
    /// - Parameter id: The id ``enqueue(prompt:)-(Transcript.Prompt)`` returned.
    /// - Returns: Which of the three ``PromptCancellationResult`` states applied.
    @discardableResult
    func cancelPrompt(id: SessionOutbox.ItemID) async -> PromptCancellationResult {
        if await cancel(id: id) == .applied {
            return .withdrawn
        }
        guard await promptQueueDepth().dispatched == id else {
            return .alreadyFinished
        }
        return await cancelCurrentTurn() == .requested ? .turnCancelled : .alreadyFinished
    }

}
