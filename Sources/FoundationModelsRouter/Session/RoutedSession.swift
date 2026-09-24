import Foundation
import FoundationModels

/// The outcome of ``RoutedSession/cancelCurrentTurn()``.
public enum TurnCancellationResult: Sendable, Equatable {
    /// A turn was in flight, or a ``RoutedSession/respond(to:maxTokens:)`` call
    /// was draining the run plane.
    ///
    /// Cancellation is cooperative. This reports that the request was recorded,
    /// not that the model or a tool has stopped.
    case requested

    /// Nothing was in flight to cancel.
    case noTurnInFlight
}

/// The outcome of ``RoutedSession/cancelPrompt(id:)``.
public enum PromptCancellationResult: Sendable, Equatable {
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
/// A session is vended only by ``RoutedModel/makeSession(instructions:workingDirectory:recordingRoot:tools:budget:compactionPrompt:summarization:agentSpawn:discoveryPriming:toolOutputProtection:)``,
/// and it retains its ``profile`` so the resident models stay loaded. The raw
/// `LanguageModelSession` is never vended; ``RoutedSession`` is the only
/// generation surface.
///
/// Every generation method records the turn's new transcript entries, whether
/// the model returns or throws. One session never has two turns in flight
/// (``RoutedSessionActor/turnLock``), and model work over one model does not
/// overlap (``RoutedModel/generationGate``). The generation gate is released
/// for ``awaitingUser(_:)`` and lent through ``GenerationPermitLoan``.
public protocol RoutedSession: Actor {
    /// The resolved profile this session runs against.
    nonisolated var profile: LanguageModelProfile { get }

    /// The recording root id — the router instance that owns this transcript.
    nonisolated var routerId: ULID { get }

    /// This session's span id.
    nonisolated var id: ULID { get }

    /// The span id of the session that forked this one, or `nil` for a root session.
    nonisolated var parentId: ULID? { get }

    /// The directory this session's transcript is recorded under.
    nonisolated var recordingDirectory: URL { get }

    /// The directory model/tool work runs relative to. Defaults to
    /// ``recordingDirectory``.
    nonisolated var workingDirectory: URL { get }

    /// The grammar that constrains every ``respond(to:)`` on this session, or
    /// `nil` for an unconstrained session.
    ///
    /// ``RoutedModel/makeGuidedSession(grammar:instructions:workingDirectory:tools:budget:compactionPrompt:summarization:agentSpawn:discoveryPriming:)``
    /// sets it, and ``fork(workingDirectory:)`` inherits it.
    /// ``streamResponse(to:)`` is not constrained.
    nonisolated var grammar: Grammar? { get }

    /// Context fill, 0...1: the size of the render that the session sends to
    /// the model, against the profile's resolved working context. The size is
    /// the fed and generated tokens of the newest generation call, not the sum
    /// of the calls of a tool loop. A compaction restarts it from the
    /// instructions and the new snapshot. `0` before the first turn. A restored
    /// session reports its last stamped `.response` usage, or
    /// ``unknownContextFill`` when there is no stamp.
    var contextFill: Double { get async }

    /// The SDK transcript this session has accumulated so far, read under the
    /// session's turn lock: a read issued while a turn is in flight waits for
    /// that turn. A tool body reading its own session's transcript does not
    /// wait; it sees the history as it stands mid-turn.
    var transcript: Transcript { get async }

    /// Compacts this session's transcript in place: same ``id``, same
    /// ``recordingDirectory``, shorter live window.
    ///
    /// The compaction is one summarizer call on this session's own model. The
    /// call reads the compaction prompt and the whole live context, the
    /// instructions included. The summary restarts the live context as the
    /// instructions, the summary entry and the protected tool outputs. A
    /// compaction that applies appends the summary entry to `transcript.jsonl`
    /// and reseeds the backend. A transcript already under target stays as
    /// it is. A summary that does not shrink the live context is discarded,
    /// and ``CompactionResult/shortfall`` states why.
    ///
    /// A compaction holds the turn lock, so ``cancelCurrentTurn()`` can cancel it.
    /// To recover from `LanguageModelError.contextSizeExceeded`, compact with
    /// a lower target and retry once.
    ///
    /// - Parameter budget: The token budget to compact against, or `nil` for this
    ///   session's resolved working context.
    /// - Throws: The summarizer's error. A caller-driven compaction offers the
    ///   own model only, so a summarizer failure here reaches the caller.
    ///   Also `CancellationError` when cancelled, or
    ///   ``SessionReentryError/sameSessionTurnInFlight(sessionID:)`` when called
    ///   from a tool of this session's own turn.
    @discardableResult
    func compact(prompt: CompactionPrompt, budget: TokenBudget?) async throws -> CompactionResult

    /// Generates a complete text response to a prompt, recording the call.
    ///
    /// This call drains both planes before it answers. The content plane is
    /// compacted into each turn's prompt as a preamble. The run plane is drained
    /// after this call's own turn: every background run is awaited to
    /// settlement, and a further turn delivers the results to the model. Each
    /// further turn that starts new background work starts one more round. The
    /// drain ends when a round finds no background run to await; no count
    /// bounds the rounds.
    /// The drain does not end background runs; that is ``close()``'s job. A
    /// cancellation ends the drain and returns the last turn's answer, and the
    /// runs it waited on stay running.
    ///
    /// Nothing bounds a decode: there is no timeout. A generation with no
    /// observable progress reports ``SessionEvent/generationStalled(_:)`` on
    /// ``streamSessionEvents()`` with ``GenerationProgressVisibility/wholeAnswer``
    /// visibility, and one line in this module's log.
    ///
    /// Every turn this call runs — its own turn, and each further turn of the
    /// run-plane drain — opens one OpenTelemetry span named
    /// ``RouterTracing/SpanName/turn``, of kind `client`, through the tracer
    /// ``RouterTracing/tracer(explicit:)`` resolves from the handle this
    /// session came off. Unbootstrapped, that resolves to a no-op tracer, so an
    /// application that does not trace pays nothing. `withSpan` records a
    /// thrown error on the span and raises it again, and a cancelled turn
    /// records `CancellationError`.
    ///
    /// The span carries these attributes, and their names are stable API:
    ///
    /// | Attribute | Value |
    /// |---|---|
    /// | `router.id` | The resolving router's recording root id. |
    /// | `session.id` | This session's span id. |
    /// | `model.ref` | The model the turn ran on, in canonical string form. |
    /// | `turn.id` | The turn's own id, unique inside this session. |
    /// | `turn.entry_point` | `respond` for this surface. |
    /// | `tokens.in` | The fed tokens of the newest generation call of the turn, on a metered turn. |
    /// | `tokens.out` | The generated tokens of the newest generation call of the turn, on a metered turn. |
    ///
    /// The two token attributes are the context counter of the session (see
    /// ``contextFill``), not the sum of the generation calls of a tool loop.
    ///
    /// A turn the backend could not meter carries neither token attribute. No
    /// prompt text and no response text ever reaches the span: a span leaves
    /// the process through whatever backend the host application bootstrapped,
    /// so the payload stays free of the caller's own content.
    ///
    /// - Parameter maxTokens: The token ceiling, or `nil` for the resolved context of the model.
    /// - Returns: The model's complete text response; the last drained turn's
    ///   when this call's own turn backgrounded work.
    /// - Throws: ``SessionReentryError/sameSessionTurnInFlight(sessionID:)`` when
    ///   called from a tool of this session's own turn.
    func respond(to prompt: String, maxTokens: Int?) async throws -> String

    /// Streams a text response to a prompt as it is produced, recording the call.
    ///
    /// Abandoning the stream cancels the turn behind it, as ``cancelCurrentTurn()``
    /// does, and records it as a cancelled turn. This surface does not drain the
    /// run plane; it finishes while a backgrounded run is in flight. A stall
    /// reports ``SessionEvent/generationStalled(_:)`` on ``streamSessionEvents()``
    /// with ``GenerationProgressVisibility/fragments(observed:)`` visibility.
    ///
    /// The turn opens one span, exactly as ``respond(to:maxTokens:)`` states,
    /// with `turn.entry_point` reading `stream`.
    ///
    /// - Parameter maxTokens: The token ceiling, or `nil` for the resolved context of the model.
    func streamResponse(to prompt: String, maxTokens: Int?) -> AsyncThrowingStream<String, Error>

    /// Streams a rich event sequence for a prompt as it is produced, recording
    /// the call exactly like ``streamResponse(to:maxTokens:)``.
    ///
    /// Order within one turn: ``SessionEvent/turnStarted(_:)``; then
    /// ``SessionEvent/textDelta(_:)`` fragments; then, after the turn's diff,
    /// tool call and tool status events, ``SessionEvent/reasoningDelta(_:)``,
    /// and ``SessionEvent/entryRecorded(id:kind:)`` per recorded entry; finally
    /// ``SessionEvent/turnEnded(_:)``. ``SessionEvent/compaction(_:)`` comes
    /// before the turn's events for a proactive compaction, and after the failed
    /// attempt's ``SessionEvent/turnEnded(_:)`` for a reactive compaction.
    /// ``SessionEvent/generationStalled(_:)`` is emitted on each interval
    /// without progress: no text fragment, no transcript entry, and no tool
    /// call or tool result.
    ///
    /// Abandoning this stream cancels the turn. This surface does not drain the
    /// run plane. A run that settles before the stream ends is reported as
    /// ``SessionEvent/runSettled(_:)``; a later one is reported on
    /// ``streamSessionEvents()``. A call that closes inside the turn reports
    /// its attachments here as ``SessionEvent/toolCallReport(_:)``, after its
    /// close ``SessionEvent/toolInvocation(_:)`` record; a call that closes
    /// later reports them on ``streamSessionEvents()``. A tool that elicits
    /// inside the turn reports its request here as
    /// ``SessionEvent/elicitationRequested(_:)`` before the tool resumes; an
    /// elicitation raised outside the turn is reported on
    /// ``streamSessionEvents()``.
    ///
    /// The turn opens one span, exactly as ``respond(to:maxTokens:)`` states,
    /// with `turn.entry_point` reading `stream`.
    ///
    /// - Parameter maxTokens: The token ceiling, or `nil` for the resolved context of the model.
    func streamEvents(to prompt: String, maxTokens: Int?) -> AsyncThrowingStream<SessionEvent, Error>

    /// Streams the ``SessionEvent``s that belong to this *session* rather than
    /// to one of its turns, for as long as the session lives.
    ///
    /// Every turn-lifecycle event travels here, whichever entry point ran the
    /// turn: ``SessionEvent/turnStarted(_:)``, ``SessionEvent/reasoningDelta(_:)``,
    /// tool-lifecycle events, ``SessionEvent/toolCallReport(_:)``,
    /// ``SessionEvent/elicitationRequested(_:)``,
    /// ``SessionEvent/entryRecorded(id:kind:)``,
    /// ``SessionEvent/compaction(_:)``, ``SessionEvent/discoveryPrimingFailed(_:)``,
    /// ``SessionEvent/generationStalled(_:)``, and ``SessionEvent/turnEnded(_:)``.
    /// ``SessionEvent/textDelta(_:)`` and ``SessionEvent/textReset`` travel only
    /// on ``streamEvents(to:maxTokens:)``. Every event belongs to the turn named
    /// by the most recent ``SessionEvent/turnStarted(_:)``. A run's
    /// ``SessionEvent/runSettled(_:)`` and ``SessionEvent/elicitationRequested(_:)``
    /// travel here also between turns.
    ///
    /// Each call vends an independent subscription, buffered without bound.
    /// Ending iteration drops the subscription; ``close()`` finishes every
    /// outstanding one.
    func streamSessionEvents() -> AsyncStream<SessionEvent>

    /// Cancels the turn currently in flight on this session. Best-effort, and
    /// safe at any time and any number of times.
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
    /// Only the turn in flight is affected. A compaction's summarizer call is
    /// cancelled where it stands.
    /// A ``respond(to:maxTokens:)`` draining the run plane stops draining and
    /// returns its last turn's answer; the runs it waited on stay running.
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
    func awaitingUser<T: Sendable>(_ body: @Sendable () async throws -> T) async rethrows -> T

    /// Forks a child session over the same resident model.
    ///
    /// The child takes a fresh id with ``parentId`` set to this session's id,
    /// a ``recordingDirectory`` nested under the parent's, and the parent's
    /// ``grammar``. Its backend is seeded from this session's conversation
    /// state through ``LanguageModelSessionBackend/makeFork()``. Forks are
    /// not counted: any number of forks over one model can exist at once.
    ///
    /// - Parameter workingDirectory: The child's working directory, or `nil` for its recording directory.
    /// - Throws: ``SessionReentryError/forkDuringSameSessionTurn(sessionID:)``
    ///   when the call comes from inside a tool call of this session's own turn.
    func fork(workingDirectory: URL?) async throws -> RoutedSession

    /// Installs how long a model call on this session may run with no
    /// observable progress before it reports
    /// ``SessionEvent/generationStalled(_:)``. The change takes effect on the
    /// next model call.
    ///
    /// Stall reports are off until the host calls this. The session has no
    /// interval of its own: the host that shows the report names the interval.
    /// A ``fork(workingDirectory:)`` child starts with this session's interval.
    ///
    /// - Parameter interval: The interval to install. A non-positive interval
    ///   turns reporting off for later calls.
    func setGenerationStallReportInterval(_ interval: Duration)

    /// Tears the session down: runs `SessionMailbox.sweep()`, which cancels
    /// every background run and rejects every pending elicitation, and journals
    /// the resulting terminal events before it returns. It also finishes every
    /// ``streamSessionEvents()`` subscription.
    ///
    /// Call it where a session's life ends. `deinit` does not run this sweep.
    /// Idempotent.
    func close() async

    /// Runs the earliest pending prompt in this session's queue as one recorded
    /// turn, with any pending turn-riding events.
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
    /// A turn this call runs opens one span, exactly as
    /// ``respond(to:maxTokens:)`` states, with `turn.entry_point` reading
    /// `dispatch`. A call that runs no turn opens no span.
    ///
    /// - Returns: The model's response text, or `nil` if no prompt was queued
    ///   and no run had settled when this call drained the outbox.
    func dispatchNextPrompt() async throws -> String?

    /// Suspends until this session holds work for a future turn: a queued
    /// prompt, a pending tool event, or a settled background run. Returns at
    /// once when it already does. One wake-up per call.
    func awaitQueuedWork() async

    /// Stages a queued user prompt for a future turn. Nothing here touches the
    /// recorded transcript.
    ///
    /// - Returns: The stable id of this queued prompt, usable with
    ///   ``pendingPrompts()``, ``cancel(id:)``, and ``replace(id:prompt:)``.
    @discardableResult
    func enqueue(prompt: Transcript.Prompt) async -> PromptID

    /// A snapshot of every prompt currently queued for a future turn, in FIFO
    /// dispatch order.
    func pendingPrompts() async -> [(id: PromptID, prompt: Transcript.Prompt)]

    /// Cancels a still-pending queued prompt. See ``cancelCurrentTurn()`` for a
    /// turn already in flight, and ``cancelPrompt(id:)`` for both in one call.
    ///
    /// - Parameter id: The id ``enqueue(prompt:)-(Transcript.Prompt)`` returned.
    @discardableResult
    func cancel(id: PromptID) async -> PromptQueueMutationResult

    /// Replaces a still-pending queued prompt's content in place. The prompt
    /// keeps its FIFO dispatch position.
    ///
    /// - Parameter id: The id ``enqueue(prompt:)-(Transcript.Prompt)`` returned.
    @discardableResult
    func replace(id: PromptID, prompt: Transcript.Prompt) async -> PromptQueueMutationResult

    /// How much queued user-prompt work this session carries: the prompts
    /// still waiting and the one whose turn is running.
    func promptQueueDepth() async -> PromptQueueDepth

    /// Delivers the user's answer to a pending elicitation raised by a run on
    /// this session.
    ///
    /// A form-mode `accept` resumes the run with its `content`; `decline` and
    /// `cancel` resume with those actions. A URL-mode `accept` keeps the run
    /// running until ``complete(elicitationId:)`` arrives. Unknown, malformed,
    /// and already-answered ids are safe no-ops.
    ///
    /// - Parameter elicitationId: The pending elicitation's id, the string form of ``ElicitationRequest/elicitationId``.
    @discardableResult
    func respond(elicitationId: String, response: ElicitationResponse) async -> ElicitationAnswerDelivery

    /// Signals that an accepted URL-mode elicitation's out-of-band flow
    /// finished, and resumes the run. Unknown, malformed, not-yet-accepted, and
    /// already-completed ids are safe no-ops.
    @discardableResult
    func complete(elicitationId: String) async -> ElicitationCompletionDelivery
}

extension RoutedSession {
    /// See ``compact(prompt:budget:)``, with both parameters at their defaults.
    @discardableResult
    public func compact() async throws -> CompactionResult {
        try await compact(prompt: .default, budget: nil)
    }

    /// See ``compact(prompt:budget:)``, with `prompt` at ``CompactionPrompt/default``.
    ///
    /// - Parameter budget: The token budget to compact against, or `nil` for this
    ///   session's resolved working context.
    @discardableResult
    public func compact(budget: TokenBudget?) async throws -> CompactionResult {
        try await compact(prompt: .default, budget: budget)
    }

    /// See ``respond(to:maxTokens:)``, with the resolved context of the model as the token ceiling.
    public func respond(to prompt: String) async throws -> String {
        try await respond(to: prompt, maxTokens: nil)
    }

    /// See ``streamResponse(to:maxTokens:)``, with the resolved context of the model as the token ceiling.
    public func streamResponse(to prompt: String) -> AsyncThrowingStream<String, Error> {
        streamResponse(to: prompt, maxTokens: nil)
    }

    /// See ``streamEvents(to:maxTokens:)``, with the resolved context of the model as the token ceiling.
    public func streamEvents(to prompt: String) -> AsyncThrowingStream<SessionEvent, Error> {
        streamEvents(to: prompt, maxTokens: nil)
    }

    /// Stages a plain-text queued user prompt for a future turn, as one `.text`
    /// segment.
    @discardableResult
    public func enqueue(prompt: String) async -> PromptID {
        await enqueue(prompt: Transcript.Prompt(segments: [.text(Transcript.TextSegment(content: prompt))]))
    }

    /// Cancels a submitted prompt, whether it is still queued or already
    /// dispatched.
    ///
    /// A dispatched prompt is cancelled through ``cancelCurrentTurn()``, which
    /// cancels the turn in flight at that moment.
    /// ``PromptCancellationResult/turnCancelled`` reports that the request was
    /// recorded, not that the turn failed.
    ///
    /// - Parameter id: The id ``enqueue(prompt:)-(Transcript.Prompt)`` returned.
    @discardableResult
    public func cancelPrompt(id: PromptID) async -> PromptCancellationResult {
        if await cancel(id: id) == .applied {
            return .withdrawn
        }
        guard await promptQueueDepth().dispatched == id else {
            return .alreadyFinished
        }
        return await cancelCurrentTurn() == .requested ? .turnCancelled : .alreadyFinished
    }

}
