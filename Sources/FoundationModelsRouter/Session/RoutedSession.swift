import Foundation
import FoundationModels

/// The outcome of ``RoutedSession/cancel()``.
public enum CancellationResult: Sendable, Equatable {
    /// The pump of the session ran work, or a caller message waited for it.
    ///
    /// Cancellation is cooperative. This reports that the request was recorded,
    /// not that the model or a tool has stopped.
    case requested

    /// The pump ran no work, and no caller message waited.
    case nothingToCancel
}

/// A generation session over a resident model: the recorded surface an
/// application drives to produce text.
///
/// A session is vended only by ``RoutedModel/makeSession(instructions:workingDirectory:recordingRoot:tools:budget:compactionPrompt:summarization:agentSpawn:discoveryPriming:toolOutputProtection:repetitionDetection:)``,
/// and it retains its ``profile`` so the resident models stay loaded. The raw
/// `LanguageModelSession` is never vended; ``RoutedSession`` is the only
/// generation surface.
///
/// Every generation method records the turn's new transcript entries, whether
/// the model returns or throws. A session is a queue of messages with no lock
/// (`generation-queue.md`, section 5.4): each generation method sends one
/// message and waits only for its answer. One pump task for each session is
/// the only code that submits for that session, and it submits the next
/// item only after the result of the last one, so one session never has two
/// SDK calls. A message that arrives while a submission runs waits for the
/// next submission, and every waiting message that can share one submission
/// goes into it. The terminal of a settled background run is mail: the pump
/// delivers it to the model in a later submission, with no caller call. Model
/// work over one model does not overlap: each model call of a turn is one
/// submission to the ``GenerationQueue`` of that model, and the one worker of
/// the queue runs the submissions one at a time, first in first out. A
/// submission is one whole SDK call, with its generation passes and the tool
/// bodies between them. So a tool body, or a wait for a person inside it,
/// holds the model for every other session on it. A tool that starts long
/// work, or waits for a child session on the same model, is a background
/// tool: it returns at once, and its result comes back as mail. An in-band
/// tool body that asks its own session, or a session on the same model, for
/// an answer is refused at once with
/// ``GenerationQueueError/waitInsideOpenSubmission(model:)``. A background
/// body asks its own session and gets the answer of a later submission.
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
    /// session reports the fill the live session had at the end of its
    /// recording: the newest generation call of its newest recorded turn, or
    /// the snapshot size of a newer compaction. A recording with no generation
    /// call events reports the usage on its last stamped `.response`. It
    /// reports ``unknownContextFill`` when the recording holds no stamp.
    var contextFill: Double { get async }

    /// The SDK transcript of this session as of its last settled point
    /// (`generation-queue.md`, section 5.8).
    ///
    /// A settled point is the end of a submission, after its recording; a
    /// tool-result boundary of the session's own submission; and a compaction.
    /// The read returns at once, from any task: it waits for no submission,
    /// and a tool body of this session's own submission gets the same value.
    /// While a submission runs, the read does not show the entries that the
    /// submission appended after the last settled point.
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
    /// The pump runs the compaction between two submissions, so it never runs
    /// beside a submission of this session, and ``cancel()`` can
    /// cancel it. To recover from `LanguageModelError.contextSizeExceeded`,
    /// compact with a lower target and retry once.
    ///
    /// - Parameter budget: The token budget to compact against, or `nil` for this
    ///   session's resolved working context.
    /// - Throws: The summarizer's error. A caller-driven compaction offers the
    ///   own model only, so a summarizer failure here reaches the caller.
    ///   Also `CancellationError` when cancelled, or
    ///   ``GenerationQueueError/waitInsideOpenSubmission(model:)`` when called
    ///   from an in-band tool of this session's own submission.
    @discardableResult
    func compact(prompt: CompactionPrompt, budget: TokenBudget?) async throws -> CompactionResult

    /// Generates a complete text response to a prompt, recording the call.
    ///
    /// This call is a helper: it sends the prompt as one message, and waits
    /// for its answer. The mail that waits goes into the prompt of the
    /// submission as a preamble. The answer is the final reply of the
    /// submission that carried the prompt, and of each continuation of it
    /// (a compaction, a retry, a recovery). A background run that the
    /// submission started does not hold the answer: its terminal is mail, and
    /// the pump delivers it to the model in a later submission. A caller whose
    /// task is cancelled withdraws its message, or stops the submission that
    /// carries it.
    ///
    /// Nothing bounds a decode: there is no timeout. A generation with no
    /// observable progress reports ``SessionEvent/generationStalled(_:)`` on
    /// ``streamSessionEvents()`` with ``GenerationProgressVisibility/wholeAnswer``
    /// visibility, and one line in this module's log. Only the time inside a
    /// pass of the running submission counts: a wait for the worker of the
    /// ``GenerationQueue`` of the model and a tool body give no report. A
    /// submission that waits for the worker reports
    /// ``SessionEvent/submissionQueued``, and each submission reports
    /// ``SessionEvent/submissionStarted`` when the worker starts it, on
    /// ``streamSessionEvents()``.
    ///
    /// Each answer the pump runs opens one OpenTelemetry span named
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
    /// - Returns: The model's complete text response: the final reply of the
    ///   answer that carried the prompt.
    /// - Throws: ``GenerationQueueError/waitInsideOpenSubmission(model:)`` when
    ///   called in band from a tool of a submission of this session, or of a
    ///   submission on the same model.
    func respond(to prompt: String, maxTokens: Int?) async throws -> String

    /// Streams a text response to a prompt as it is produced, recording the call.
    ///
    /// The prompt is one message that goes alone in its submission, because
    /// its fragments belong to this stream. Abandoning the stream cancels the
    /// submission behind it, as ``cancel(message:)`` does, and records it
    /// as a cancelled turn. The stream finishes while a backgrounded run is in
    /// flight; the pump delivers its terminal later, as mail. A stall
    /// reports ``SessionEvent/generationStalled(_:)`` on ``streamSessionEvents()``
    /// with ``GenerationProgressVisibility/fragments(observed:)`` visibility.
    /// A wait for the worker of the generation queue is not a stall; it
    /// reports ``SessionEvent/submissionQueued`` there, and each submission
    /// reports ``SessionEvent/submissionStarted``.
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
    /// call or tool result. Only the time inside a pass of the running
    /// submission counts, so a wait for the worker of the ``GenerationQueue``
    /// of the model and a tool body between two passes emit no stall. A
    /// submission that must wait for the worker emits
    /// ``SessionEvent/submissionQueued``, and each submission emits
    /// ``SessionEvent/submissionStarted`` when the worker starts it.
    ///
    /// Abandoning this stream cancels the turn. The stream finishes while a
    /// backgrounded run is in flight. A run that settles before the stream
    /// ends is reported as
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
    /// ``SessionEvent/generationStalled(_:)``, ``SessionEvent/submissionQueued``,
    /// ``SessionEvent/submissionStarted``, and ``SessionEvent/turnEnded(_:)``.
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

    /// Stops the work of this session (`generation-queue.md`, section 5.6).
    /// Best-effort, and safe at any time and any number of times.
    ///
    /// ``cancel(message:)`` takes back one message; this stops the running
    /// submission and withdraws every waiting caller message. It cancels the
    /// `Task` that runs the model call, so cancellation propagates into the
    /// tool calls the SDK invokes. Propagation past the process boundary is
    /// advisory: an MCP server may keep working.
    ///
    /// The callers of the messages of the running submission receive
    /// `CancellationError` once the model work unwinds. A stream keeps the
    /// fragments it already yielded. Model work that never checks for
    /// cancellation runs to completion, and the submission gives its answer.
    /// A cancellation that lands before any model call starts ends the answer
    /// without calling the model. The transcript records a cancelled
    /// submission as a failed one, with one close. The outbox follows the
    /// attach-or-requeue rule. A submission that still waits for the worker
    /// of the generation queue is removed from the queue at once: it never
    /// runs, and the worker runs the next item. A running submission is
    /// cancelled on the task that runs it.
    ///
    /// Every caller message that waits for the pump is withdrawn: its caller
    /// gets `CancellationError`, and it never reaches the model. The mail is
    /// not withdrawn: it stays in the outbox for a later submission, because a
    /// run terminal must not be lost. It waits there for new mail or a new
    /// message, so the cancel does not start a submission of its own. A
    /// compaction's summarizer call is cancelled where it stands. A background
    /// run keeps running.
    ///
    /// - Returns: ``CancellationResult/requested`` when the pump ran work or
    ///   a caller message waited, and ``CancellationResult/nothingToCancel``
    ///   otherwise.
    @discardableResult
    func cancel() async -> CancellationResult

    /// Takes back one message (`generation-queue.md`, section 5.6).
    ///
    /// A message that waits is withdrawn: it never reaches a prompt, and a
    /// caller that waits for its answer (``respond(to:maxTokens:)``, a
    /// stream) gets `CancellationError`. A message that a submission carries
    /// cancels that submission, as ``cancel()`` does; the other messages of
    /// that submission share its answer, so they end with it. Safe at any
    /// time and any number of times.
    ///
    /// - Parameter message: The id ``send(_:)-(Transcript.Prompt)`` returned.
    /// - Returns: ``MessageCancellationResult/withdrawn``,
    ///   ``MessageCancellationResult/cancelledInSubmission``, or
    ///   ``MessageCancellationResult/alreadyAnswered`` when the message has no
    ///   open answer.
    @discardableResult
    func cancel(message: MessageID) async -> MessageCancellationResult

    /// Runs `body`, a wait on a person, and returns what it returns.
    ///
    /// A tool body runs inside its submission, so the wait holds the worker of
    /// the ``GenerationQueue`` of the model: every other session on that model
    /// waits for the end of the submission. To wait for a person without
    /// holding the model, raise an elicitation from a background run
    /// (``ToolContext/elicit(_:)``). The pump of this session keeps the answer
    /// running throughout, so a message that arrives during the wait goes into
    /// a later submission.
    ///
    /// The call releases nothing and acquires nothing, so a throw or a
    /// cancellation from `body` leaves every lock as it was, and overlapping
    /// calls, or a call with no turn in flight, need no bookkeeping.
    ///
    /// - Precondition: Call this from inside a tool the SDK invoked for this
    ///   session's own in-flight turn, and do not let the wait outlive that tool call.
    func awaitingUser<T: Sendable>(_ body: @Sendable () async throws -> T) async rethrows -> T

    /// Forks a child session over the same resident model.
    ///
    /// The child takes a fresh id with ``parentId`` set to this session's id,
    /// a ``recordingDirectory`` nested under the parent's, and the parent's
    /// ``grammar``. Its backend is seeded from the settled transcript of this
    /// session (see ``transcript``) through
    /// ``LanguageModelSessionBackend/makeFork(tools:seededFrom:)``. When that
    /// transcript ends in a round of tool calls with no output, the fork
    /// removes those calls, so the child starts from a valid transcript.
    /// Forks are not counted: any number of forks over one model can exist at
    /// once.
    ///
    /// The fork returns at once, from any task: it waits for no submission of
    /// this session. A tool body of this session's own submission can fork it.
    ///
    /// - Parameter workingDirectory: The child's working directory, or `nil` for its recording directory.
    /// - Throws: Nothing now. The requirement keeps `throws`, so a later
    ///   version can refuse a fork without a change of the API.
    func fork(workingDirectory: URL?) async throws -> RoutedSession

    /// Installs how long a model call on this session may run with no
    /// observable progress before it reports
    /// ``SessionEvent/generationStalled(_:)``. The change takes effect on the
    /// next model call. The interval counts only the time inside a pass of the
    /// running submission, and never the wait for the worker of the
    /// ``GenerationQueue`` of the model; ``GenerationStall`` states the
    /// meaning of each field of a report.
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

    /// Sends one message to this session, and returns its id at once
    /// (`generation-queue.md`, section 5.4).
    ///
    /// The message waits in the queue of the session. When no submission of
    /// the session runs, the pump starts one for it with no other call; when a
    /// submission runs, the message goes into the next one. Every waiting
    /// message that can share one submission goes into it, in the order the
    /// messages arrived, after the preamble of the waiting mail. The
    /// `Transcript.Prompt` goes to the model as the text of its `.text`
    /// segments, joined with no separator.
    ///
    /// The call waits for no submission and for no answer, and it throws
    /// nothing, from any task: a tool body of this session's own submission
    /// can send, and its message goes into a later submission.
    /// ``respond(to:maxTokens:)`` is this call followed by a wait for the
    /// answer.
    ///
    /// The answer of a sent message is visible on ``streamSessionEvents()``.
    /// Its submission opens one span, exactly as ``respond(to:maxTokens:)``
    /// states, with `turn.entry_point` reading `send`.
    ///
    /// - Parameter prompt: The prompt of the message.
    /// - Returns: The stable id of the message, usable with
    ///   ``cancel(message:)``, ``replace(id:prompt:)``, ``pendingMessages()``
    ///   and ``messageQueueDepth()``.
    @discardableResult
    func send(_ prompt: Transcript.Prompt) async -> MessageID

    /// A snapshot of every caller message that waits for a submission, in the
    /// order the messages arrived. A message that a submission took is not in
    /// it.
    func pendingMessages() async -> [(id: MessageID, prompt: Transcript.Prompt)]

    /// Replaces the prompt of a message that waits, in place. The message
    /// keeps its place in the queue.
    ///
    /// - Parameters:
    ///   - id: The id ``send(_:)-(Transcript.Prompt)`` returned.
    ///   - prompt: The new prompt of the message.
    /// - Returns: ``MessageQueueMutationResult/applied`` when the message
    ///   waited, and ``MessageQueueMutationResult/alreadySent`` otherwise.
    @discardableResult
    func replace(id: MessageID, prompt: Transcript.Prompt) async -> MessageQueueMutationResult

    /// How much caller-message work this session carries: the messages that
    /// wait, and the messages of the running answer.
    func messageQueueDepth() async -> MessageQueueDepth

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

    /// See ``send(_:)-(Transcript.Prompt)``, with the plain text of the
    /// message as one `.text` segment.
    ///
    /// - Parameter prompt: The prompt text of the message.
    /// - Returns: The stable id of the message.
    @discardableResult
    public func send(_ prompt: String) async -> MessageID {
        await send(.plainText(prompt))
    }
}
