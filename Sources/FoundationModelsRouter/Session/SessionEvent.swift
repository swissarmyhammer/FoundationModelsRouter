import Foundation

/// One element of the event stream ``RoutedSession/streamEvents(to:maxTokens:)`` produces.
///
/// The events report each submission and each final answer
/// (`generation-queue.md`, section 5.6). A submission is one SDK call of the
/// chain that answers the messages of the session: ``submissionStarted(_:)``
/// opens it, and every event up to the ``submissionEnded(_:)`` with the same
/// ``SubmissionID`` belongs to it. The chain ends with one ``answered(_:)``,
/// or with one ``answerFailed(_:)`` when it gives no answer.
/// ``RoutedSession/streamSessionEvents()`` carries every case. This enum has
/// no library evolution: write a `default` arm to absorb new cases.
public enum SessionEvent: Sendable, Equatable {
    /// A fragment of the model's response text, in production order. A
    /// submission that streams its output sends it; a submission that gives
    /// its reply whole (``RoutedSession/respond(to:maxTokens:)``,
    /// ``RoutedSession/send(_:)-(Transcript.Prompt)``, or mail) sends none, and
    /// its reply is in ``answered(_:)``.
    case textDelta(String)

    /// Every ``textDelta(_:)`` so far in this submission is superseded. A
    /// consumer clears the accumulated text and then keeps appending.
    /// Superseded text is still recorded as its own `.response` entry.
    case textReset

    /// A fragment of the model's reasoning trace.
    case reasoningDelta(String)

    /// A tool invocation the model requested, from the SDK's `.toolCalls` entry.
    /// `id` is the call's `Transcript.ToolCall.id`; `argumentsJSON` is `GeneratedContent.jsonString`.
    case toolCall(id: String, name: String, argumentsJSON: String)

    /// A lifecycle update for a tool invocation announced by ``toolCall(id:name:argumentsJSON:)``.
    /// `summary` and `output` are non-nil only once ``ToolCallStatus/completed``;
    /// `output` carries every ``SegmentPayload`` of the answering `.toolOutput` entry.
    case toolStatus(id: String, status: ToolCallStatus, summary: String?, output: [SegmentPayload]?)

    /// A live ``ToolInvocationRecord``: an open record before a wrapped tool call
    /// starts, and a close record when it returns or throws. Delivery-only, never recorded.
    /// Its ``ToolInvocationRecord/correlationID`` is the run's `completionToken`, never a `Transcript.ToolCall.id`.
    ///
    /// `toolCallID` joins the two id spaces of one tool run. It is the
    /// `Transcript.ToolCall.id` of the SDK call that started the run: the same
    /// id that ``toolCall(id:name:argumentsJSON:)`` and
    /// ``toolStatus(id:status:summary:output:)`` carry for that call. The
    /// session finds it when the open record arrives: the SDK waits in the
    /// tool call at that time, and the `.toolCalls` entry of the call is
    /// already in the transcript. The session joins the record to the first
    /// call of that entry that has the same tool name and no run yet. The
    /// close record carries the id of its open record. The id is `nil` when
    /// no call of the submission in flight has the tool name of the record,
    /// for example for a record that opens between two answers.
    ///
    /// The id never goes into the record, and the record's
    /// `correlationID` never goes into a `toolCall` or `toolStatus` event.
    /// The event carries the two ids side by side, so a consumer can show one
    /// tool run as one tool call.
    ///
    /// The order of the events of one tool run inside its submission is:
    ///
    /// 1. ``toolInvocation(_:toolCallID:)`` with the open record, live, while
    ///    the tool runs.
    /// 2. ``toolInvocation(_:toolCallID:)`` with the close record, live, when
    ///    the tool returns or throws. A run that continues in the background
    ///    can close after the submission ended.
    /// 3. ``toolCallReport(_:)``, when the call attached records.
    /// 4. ``toolCall(id:name:argumentsJSON:)`` and the
    ///    ``ToolCallStatus/running`` ``toolStatus(id:status:summary:output:)``,
    ///    from the diff of the submission, after the SDK call returned.
    /// 5. ``toolStatus(id:status:summary:output:)`` with
    ///    ``ToolCallStatus/completed`` or ``ToolCallStatus/failed``, from the
    ///    same diff.
    /// 6. ``submissionEnded(_:)``.
    ///
    /// So a consumer sees the SDK id first on the open record, and later on
    /// the events of the diff.
    case toolInvocation(ToolInvocationRecord, toolCallID: String? = nil)

    /// The records one tool call attached through `ToolContext.attach(_:)`.
    /// Delivery-only, never recorded. Emitted one time per call, after the
    /// call's close ``toolInvocation(_:toolCallID:)`` record, and only when the call
    /// attached at least one record. Its `ToolCallReport.correlationID` is the
    /// run's `completionToken`, the same value as the call's
    /// ``ToolInvocationRecord/correlationID``, never a `Transcript.ToolCall.id`.
    /// Always on ``RoutedSession/streamSessionEvents()``; on the stream of the
    /// answer when the call closes inside an answer.
    case toolCallReport(ToolCallReport)

    /// A display-only event of a running tool: a part of its output, all of
    /// its output, or new metadata of the call, for the client to show. The
    /// tool posts it through `ToolContext.post(display:)`,
    /// `ToolContext.emit(chunk:)` or `ToolContext.update(title:kind:locations:)`.
    /// Its `ToolDisplayEvent.correlationID` is the run's `completionToken`,
    /// the same value as the ``ToolInvocationRecord/correlationID`` of the
    /// call, never a `Transcript.ToolCall.id`.
    ///
    /// Delivery only. The session sends each display event live, at the
    /// moment the tool posts it, in post order with the
    /// ``runProgress(_:)`` events of the same run. The session never:
    ///
    /// - puts it into the input of a submission,
    /// - combines it with another display event,
    /// - records it in the journal.
    ///
    /// A background run that settles inside its settle period
    /// (``SessionConfiguration/inlineSettleGrace``) withdraws its staged
    /// events, but not its display events: the host already has them.
    ///
    /// Always on ``RoutedSession/streamSessionEvents()``; on the stream of the
    /// answer when the tool posts it inside an answer.
    case toolDisplay(ToolDisplayEvent)

    /// The diff of a submission recorded one SDK transcript entry under its durable id.
    /// Emitted once per recorded `.response`, `.reasoning`, or `.toolCalls` entry.
    /// `id` is the `Transcript.Entry.id`, never a `Transcript.ToolCall.id`.
    case entryRecorded(id: String, kind: RecordedEntryKind)

    /// An automatic compaction starts inside an answer. One
    /// ``compaction(_:)`` or one ``compactionFailed(_:)`` with the same id
    /// follows. A compaction that ``RoutedSession/compact()`` asks for sends
    /// no compaction event.
    case compactionStarted(CompactionStart)

    /// An auto-compaction completed against this session, inside an answer.
    /// Its ``CompactionResult/id`` is the id of the ``compactionStarted(_:)``
    /// before it.
    case compaction(CompactionResult)

    /// An automatic compaction that ``compactionStarted(_:)`` announced did
    /// not complete: it failed with an error, or a cancel stopped it. The live
    /// context of the session stays as it was, and the error goes on out of
    /// the answer.
    case compactionFailed(CompactionFailure)

    /// The ``DiscoveryPriming`` of this answer could not seed, so the answer generated unseeded.
    /// This is a report, not a failure.
    case discoveryPrimingFailed(DiscoveryPrimingFailure)

    /// The generation in flight has produced nothing observable for a whole reporting interval.
    /// This is a report, not a bound. It repeats once per further interval without progress.
    /// ``GenerationStall/visibility`` says what the report can claim.
    ///
    /// The session measures only the time inside a pass of the running
    /// submission. A wait for the worker of the ``GenerationQueue`` of the
    /// model (see ``submissionQueued(_:)``) and a tool body between two passes
    /// give no report. For a backend that reports no pass, the time counts
    /// from the start of the submission. ``GenerationStall`` states the
    /// meaning of each field.
    case generationStalled(GenerationStall)

    /// A submission of the session waits in the ``GenerationQueue`` of its
    /// model, because the worker of that queue runs a submission of another
    /// session. A submission is one whole SDK call, with its passes and its
    /// tool bodies. A consumer can show "waiting for the model".
    ///
    /// The session sends it only when the submission must wait. A submission
    /// that finds the worker free sends none. ``submissionStarted(_:)``
    /// with the same id follows when the worker starts the submission. A
    /// cancelled wait sends no ``submissionStarted(_:)``: its
    /// ``submissionEnded(_:)`` comes next. Only a backend that names a queue
    /// (``LanguageModelSessionBackend/generationQueue``) submits to one, so a
    /// backend with no queue never sends this event.
    case submissionQueued(SubmissionID)

    /// A submission of the session started, and it generates now: the worker
    /// of the ``GenerationQueue`` of its model started it, or, for a backend
    /// with no queue, its SDK call started. It comes after
    /// ``submissionQueued(_:)`` when the submission had to wait, and before
    /// any other event of the submission.
    ///
    /// A submission that never started sends none: the hard ceiling of the
    /// ``TokenBudget`` refused it, or a cancel came before its call or during
    /// its wait. Its ``submissionEnded(_:)`` still comes.
    case submissionStarted(SubmissionStart)

    /// A submission of the session ended, with its measured usage and its
    /// finish reason. The session sends one for each submission it made, also
    /// for one that failed or was cancelled. A chain that retries after a
    /// recovered context overflow sends two of these, and one
    /// ``answered(_:)``.
    case submissionEnded(SubmissionEnd)

    /// The chain of submissions that answers one or more messages gave its
    /// final answer. The session sends one for each final answer, after the
    /// ``submissionEnded(_:)`` of the last submission of the chain.
    case answered(SessionAnswer)

    /// The chain of submissions that answers one or more messages ended with
    /// no answer: a cancel stopped it, or it failed with an error. The
    /// callers of the messages get the error. It comes in place of
    /// ``answered(_:)``.
    case answerFailed(AnswerFailure)

    /// The session stopped the generate call in flight because the call no
    /// longer wrote new lines. The event comes before the
    /// ``submissionEnded(_:)`` of the stopped submission, whose finish reason
    /// is ``FinishReason/repeatedLines``. See ``RepetitionDetection``.
    case repetitionStopped(RepetitionStop)

    /// One pass of the answer reasoned and did not act (task ^hm9trt5): the
    /// watch stopped the call because its reasoning reached
    /// ``RepetitionDetection/reasoningTokenLimit``, or the pass ended inside
    /// its reasoning with no tool call and no text. The report gives the
    /// reasoning tokens, the limit and the number of the recovery that
    /// follows. See ``ReasoningStop`` for where the event comes among the
    /// submission events.
    case reasoningStopped(ReasoningStop)

    /// A background run of this session settled: its one terminal ``OperationEvent``.
    /// Always on ``RoutedSession/streamSessionEvents()``; on the stream of the answer when it settles inside an answer.
    case runSettled(OperationEvent)

    /// A background run of this session sent a message to the session through
    /// `ToolContext.message(_:)`. The run is still open, and its terminal
    /// comes later as ``runSettled(_:)``. Carries the `.message`
    /// ``OperationEvent`` the run posted, at the moment the session journals
    /// it. The event's `detail` is the text of the message, and its
    /// `correlationID` is the run's `completionToken`.
    ///
    /// Always on ``RoutedSession/streamSessionEvents()``; on the stream of the
    /// answer when the message arrives inside an answer.
    case runMessage(OperationEvent)

    /// A run of this session reported its progress through
    /// `ToolContext.progress(_:plan:)`. The run is still open. Carries the
    /// `.progress` ``OperationEvent`` the run posted, at the moment the
    /// session journals it. The session sends one for each progress event,
    /// also for an event that the journal merges into the open progress row
    /// of the run (task ^mq1js23).
    ///
    /// The event's `detail` is the short text line that the model also gets.
    /// The event's `plan` is the agent plan for the host, or `nil`. The plan
    /// goes only to the host: no model input holds it. A plan replaces the
    /// earlier plan that has the same `PlanSnapshot.id`.
    ///
    /// Always on ``RoutedSession/streamSessionEvents()``; on the stream of the
    /// answer when the progress arrives inside an answer.
    case runProgress(OperationEvent)

    /// A run of this session asked the user a question through
    /// `ToolContext.elicit(_:)` and is suspended until a host answers it.
    /// Carries the `.elicitation` ``OperationEvent`` the run posted, at the
    /// moment the session journals it. The mailbox registers the pending
    /// entry before the run posts, so a host can answer as soon as it sees
    /// this event.
    ///
    /// The event's `elicitation` is the typed ``ElicitationRequest``. Its
    /// `elicitationId` is the id ``RoutedSession/respond(elicitationId:response:)``
    /// and ``RoutedSession/complete(elicitationId:)`` take. The event's
    /// `correlationID` is the posting run's `completionToken`; for a run
    /// mounted through `ToolContext.mount(_:op:as:)` it is the mounting
    /// run's token.
    ///
    /// Always on ``RoutedSession/streamSessionEvents()``; on the stream of the
    /// answer when the elicitation is raised inside an answer.
    ///
    /// Known limit: an elicitation posted through
    /// `ToolContext.mount(_:op:as:postingTo:)` with a sink that does not
    /// forward to the session's outbox never reaches the session's journal,
    /// so it never reaches this event.
    case elicitationRequested(OperationEvent)

    /// One generation call of the submission in flight ended, with its own
    /// measured usage. A submission that calls a tool makes more than one
    /// generation call, and ``submissionEnded(_:)`` sums them. This event
    /// reports each call alone: one when a tool call of the session's own
    /// submission opens, for the call that asked for the tool, and one when
    /// the submission closes, for the last call. A backend that reports no
    /// usage gives none. The run journal records each one as a
    /// ``TranscriptEvent/Kind/generationCall`` event.
    case generationCall(GenerationCallUsage)

    /// The session held new mail and started no answer for it, because
    /// ``SessionConfiguration/mailOnlyAnswerLimit`` answers in a row had no
    /// caller message (`generation-queue.md`, section 5.4). The held mail
    /// waits in the queue of the session, and the next caller message
    /// carries it into its submission. Only
    /// ``RoutedSession/streamSessionEvents()`` carries this event, because no
    /// answer runs when the session holds the mail. The session sends one for
    /// each hold.
    case mailDeliveryPaused(MailDeliveryPause)
}

/// The kind of SDK transcript entry a ``SessionEvent/entryRecorded(id:kind:)`` names.
public enum RecordedEntryKind: Sendable, Equatable {
    /// A `.response` entry, the model's answer text.
    case response

    /// A `.reasoning` entry, the model's reasoning trace.
    case reasoning

    /// A `.toolCalls` entry, one batch of tool invocations the model requested.
    case toolCalls
}

/// The lifecycle of one tool invocation a model requested, as observed through the SDK's transcript.
public enum ToolCallStatus: String, Sendable, Equatable, Codable {
    /// The SDK recorded a `.toolCalls` entry naming the call.
    case running

    /// The SDK recorded a matching `.toolOutput` entry, correlated by id.
    case completed

    /// The submission ended with no matching `.toolOutput` recorded for this call.
    case failed
}

/// One submission's measured token usage, carried by ``SubmissionEnd/usage``,
/// and the usage of a whole chain, carried by ``SessionAnswer/usage``.
public struct TokenUsage: Sendable, Equatable {
    /// Input (prompt) tokens this attempt consumed.
    public let tokensIn: Int

    /// Output (completion) tokens this attempt produced.
    public let tokensOut: Int

    /// The session's measured ``RoutedSession/contextFill`` immediately after this attempt closed.
    public let contextFill: Double

    /// Why this attempt stopped. ``FinishReason/maxTokens`` when the response
    /// reached the token ceiling before the model ended it, and
    /// ``FinishReason/endedInsideReasoning`` when the output ended inside the
    /// reasoning before the ceiling.
    ///
    /// The session reports ``FinishReason/maxTokens`` only when the last
    /// generation call of the attempt spent an output token count equal to or
    /// more than the ceiling the attempt gave the backend. An attempt that
    /// called a tool made more than one generation call, and its
    /// ``tokensOut`` is their sum. The session reads the count of the last
    /// call from
    /// ``LanguageModelSessionBackend/lastGenerationCallOutputTokenCount()``.
    /// When the backend marks the response entry as incomplete and the count
    /// does not reach the ceiling, or is not known, the session reports
    /// ``FinishReason/endedInsideReasoning``. When the session stopped the
    /// attempt because it no longer wrote new lines, the session reports
    /// ``FinishReason/repeatedLines``. When the session stopped the attempt
    /// because the reasoning of one pass reached
    /// ``RepetitionDetection/reasoningTokenLimit``, the session reports
    /// ``FinishReason/reasoningTokenLimit``.
    public let finishReason: FinishReason

    /// Creates a token usage value.
    ///
    /// - Parameters:
    ///   - tokensIn: Input (prompt) tokens this attempt consumed.
    ///   - tokensOut: Output (completion) tokens this attempt produced.
    ///   - contextFill: The session's measured fill after this attempt closed.
    ///   - finishReason: Why this attempt stopped. Defaults to ``FinishReason/completed``.
    public init(tokensIn: Int, tokensOut: Int, contextFill: Double, finishReason: FinishReason = .completed) {
        self.tokensIn = tokensIn
        self.tokensOut = tokensOut
        self.contextFill = contextFill
        self.finishReason = finishReason
    }
}
