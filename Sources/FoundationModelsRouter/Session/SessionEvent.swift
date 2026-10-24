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

    /// A compaction starts: a requested compaction
    /// (``RoutedSession/compact(prompt:budget:)``), or an automatic
    /// compaction inside an answer. One ``compaction(_:)`` or one
    /// ``compactionFailed(_:)`` with the same id follows. That event is the
    /// terminal event of the compaction signal. The id is the string form of
    /// the ``SignalID`` of the compaction, and the origin is
    /// ``Origin/signal(_:)`` of that id.
    case compactionStarted(CompactionStart)

    /// A compaction that ``compactionStarted(_:)`` announced completed
    /// against this session. It is the terminal event of the compaction
    /// signal. Its ``CompactionResult/id`` is the id of the
    /// ``compactionStarted(_:)`` before it: the string form of the
    /// ``SignalID`` of the compaction. The origin is ``Origin/signal(_:)`` of
    /// that id.
    case compaction(CompactionResult)

    /// A compaction that ``compactionStarted(_:)`` announced did not
    /// complete: it failed with an error, or a cancel (only
    /// ``RoutedSession/close()``) stopped it. The live context stays as it
    /// was. For an automatic compaction, the error goes on out of the answer.
    /// It is the terminal event of the compaction signal. Its id is the id
    /// of the ``compactionStarted(_:)`` before it: the string form of the
    /// ``SignalID`` of the compaction. The origin is ``Origin/signal(_:)`` of
    /// that id.
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
    ///
    /// The origin of the event (``SessionOutput/origin``) is ``Origin/mail(_:)``
    /// with the ``MailID`` of the run mail that holds the terminal. The
    /// ``mailDelivered(_:)`` of the same id tells when the model sees the
    /// terminal, and the ``SessionAnswer/mailIds`` of the answer that
    /// delivered it hold that id. ``mailDelivered(_:)`` can come before this
    /// event: the session queues the run mail at once, and sends this event
    /// when the transcript holds the terminal. A terminal that makes no run
    /// mail has the origin of the work that sent it. These terminals make no
    /// run mail: the terminal of a run that ``RoutedSession/cancelAll()`` or
    /// ``RoutedSession/close()`` stopped (the sweep of that stop sends it,
    /// with the origin of the stop), and a terminal that arrives after the
    /// session closed.
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
    ///
    /// The origin of the event (``SessionOutput/origin``) is ``Origin/mail(_:)``
    /// with the ``MailID`` of the run mail that holds the message. Thus a
    /// reader waits for the ``mailDelivered(_:)`` of that id to know that the
    /// model sees the message, and the ``SessionAnswer/mailIds`` of the answer
    /// that delivered it hold that id. ``mailDelivered(_:)`` can come before
    /// this event: the session queues the run mail at once, and sends this
    /// event when the transcript holds the message. A message of a run that
    /// ``RoutedSession/cancelAll()`` stopped, or a message that arrives after
    /// the session closed, makes no run mail: its origin is the origin of the
    /// work that posted it.
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
    ///
    /// The origin of the event (``SessionOutput/origin``) is ``Origin/mail(_:)``
    /// with the ``MailID`` of the run mail that holds the progress. A progress
    /// event that replaces the queued progress mail of the same run has the id
    /// of that queued mail, so each progress event of one queued mail has the
    /// same id. ``mailDelivered(_:)`` of that id can come before this event. A
    /// progress event of a run that ``RoutedSession/cancelAll()`` stopped, or
    /// a progress event that arrives after the session closed, makes no run
    /// mail: its origin is the origin of the work that posted it.
    case runProgress(OperationEvent)

    /// A run of this session asked the user a question through
    /// `ToolContext.elicit(_:)` and is suspended until a host answers it.
    /// Carries the `.elicitation` ``OperationEvent`` the run posted, at the
    /// moment the session journals it. The run plane registers the pending
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
    /// The origin of the event (``SessionOutput/origin``) is ``Origin/mail(_:)``
    /// with the ``MailID`` of the run mail that holds the elicitation. The
    /// ``mailDelivered(_:)`` of that id tells when the model sees the
    /// question, and ``mailDelivered(_:)`` can come before this event. An
    /// elicitation of a run that ``RoutedSession/cancelAll()`` stopped, or an
    /// elicitation that arrives after the session closed, makes no run mail:
    /// its origin is the origin of the work that posted it.
    ///
    /// A question of a subagent that a ``SubagentQuestionRelay`` sent up to a
    /// run of this session also comes as this event. Its `elicitationId` is
    /// the id that the run that asked gave, at each level. Its `tool`, `op`
    /// and `correlationID` are those of the run of this session that drives
    /// the subagent. `ElicitationRequest.agentPath` names the agents from this
    /// level to the agent that asked, and `ElicitationRequest.source` names
    /// the tool that asked. Such a question makes no run mail, so the model of
    /// this session does not see it: only the level whose own run asked a
    /// question puts it in the prompt of its model. Its origin is
    /// ``Origin/system``.
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
    /// ``SessionConfiguration/mailOnlyAnswerLimit`` answers that only run mail
    /// started each started a new background run, with no user-type mail
    /// between them (`generation-queue.md`, section 5.4). The held mail
    /// waits in the queue of the session, and the next user-type mail
    /// carries it into its submission. Only
    /// ``RoutedSession/streamSessionEvents()`` carries this event, because no
    /// answer runs when the session holds the mail. The session sends one for
    /// each hold.
    case mailDeliveryPaused(MailDeliveryPause)

    /// The pump took the mail with this id for a submission. From now on the
    /// model sees the mail. The event comes before the events of the
    /// submission that carries the mail, and its origin is the answer that
    /// delivers it. It is not a terminal event: ``answered(_:)`` or
    /// ``answerFailed(_:)`` of the same answer follows.
    case mailDelivered(MailID)

    /// The mail with this id left the queue before the pump took it:
    /// ``RoutedSession/cancel(_:)``, ``RoutedSession/cancelAll()`` or
    /// ``RoutedSession/close()`` removed it. The model never sees it. This is
    /// the terminal event of the mail: no other event of the mail follows.
    case cancelled(MailID)

    /// The work of the signal with this id ended. This is the terminal event
    /// of the signal. It comes after each other event of the signal, for
    /// example after the ``cancelled(_:)`` events of
    /// ``RoutedSession/cancelAll()``. A compaction ends with
    /// ``compaction(_:)`` or ``compactionFailed(_:)`` instead.
    case signalDone(SignalID)

    /// The mail with this id was queued or delivered when the process
    /// stopped, and its answer never ended. The session sends it at restore.
    /// This is the terminal event of the mail.
    case lost(MailID)

    /// The session had no work, and now it has work: the first lease of the
    /// work registry of the session opened. The rules of the work are the
    /// rules of ``RoutedSession/awaitIdle()``: an answer that runs, a queued
    /// mail that can start an answer, a requested compaction, or open
    /// background tool work. A background run that waits only for the user
    /// (an open question of ``elicitationRequested(_:)``) is no work, unless
    /// a subagent that the run drives works: the ``SubagentQuestionRelay`` of
    /// the run reads the work events of the subagent, and the run is work
    /// while the subagent works.
    ///
    /// The event comes before each output of the new work. Its origin
    /// (``SessionOutput/origin``) is ``Origin/system``, and only
    /// ``RoutedSession/streamSessionEvents()`` carries it. The session sends
    /// one for each change from no work to work, so ``workStarted`` and
    /// ``workEnded`` come in turns, and ``workStarted`` comes first. A
    /// session that has no work when a feed starts sends nothing until work
    /// starts. A consumer needs no clock and no poll to know the work state.
    /// Each session sends its own events: the work of a child session never
    /// makes its parent send one.
    ///
    /// After ``RoutedSession/close()`` starts, the session sends no work
    /// event. The feed ends when the close finishes it.
    case workStarted

    /// The session has no work: nothing is queued to generate, nothing in
    /// the mailbox can start work, and no background tool work is open. The
    /// last lease of the work registry of the session ended. This is the
    /// no-work event of the session. The rules of the work are the rules of
    /// ``workStarted``. When this event comes, ``RoutedSession/awaitIdle()``
    /// returns `true`.
    ///
    /// The event comes after each output of the work that ended: for
    /// example after the ``answered(_:)`` of the last answer, after the
    /// ``runSettled(_:)`` of the last run, and after the
    /// ``elicitationRequested(_:)`` of a run that now waits only for the
    /// user. Its origin is ``Origin/system``, and only
    /// ``RoutedSession/streamSessionEvents()`` carries it. The session sends
    /// one for each change from work to no work.
    case workEnded

    /// A question of a run that ``elicitationRequested(_:)`` announced ended
    /// with no answer of the client. Its ``ElicitationEnd/elicitationId`` is
    /// the `elicitationId` of that ``elicitationRequested(_:)``, and its
    /// ``ElicitationEnd/response`` is the cancel or decline that the run got,
    /// with the reason. The session sends one for each such question, and
    /// none for a question that the client answered
    /// (``RoutedSession/respond(elicitationId:response:)``, or
    /// ``RoutedSession/complete(elicitationId:)`` of an accepted URL-mode
    /// question).
    ///
    /// The run plane decides each end, and it ends a question only in one
    /// step that a cancel of the run plane makes: an answer or a completion
    /// of the client before that step wins, and the question gets no end.
    /// The run gets its cancel only after the session got the end, so this
    /// event comes before each later event of that run.
    ///
    /// The origin (``SessionOutput/origin``) is the origin of the work that
    /// ended the question, and the place of the event follows that work:
    ///
    /// - A cancel of the run (`ToolContext.cancel(completionToken:)`): the
    ///   origin of the work that cancelled the run, for example
    ///   ``Origin/mail(_:)`` of the answer whose tool cancelled it. The event
    ///   comes before the ``runSettled(_:)`` of the run.
    /// - ``RoutedSession/cancelAll()``: ``Origin/signal(_:)`` of the
    ///   cancel-all signal. The event comes before the
    ///   ``signalDone(_:)`` of that signal.
    /// - ``RoutedSession/close()``: ``Origin/system``. The event comes
    ///   before the end of ``RoutedSession/streamSessionEvents()``, also for
    ///   a question that a run asked while the close stopped the work.
    /// - An end that comes up from a subagent (``SubagentQuestionRelay``):
    ///   ``Origin/system``. The event comes before the ``runSettled(_:)`` of
    ///   the run that drives the subagent.
    ///
    /// A question that a ``SubagentQuestionRelay`` sent up ends one time at
    /// each level, with the same response: an end at one level goes up to
    /// each parent and down to each child.
    ///
    /// Always on ``RoutedSession/streamSessionEvents()``; on the stream of
    /// the answer when the question ends inside an answer.
    case elicitationEnded(ElicitationEnd)

    /// The out-of-band flow of an accepted URL-mode question of a run that
    /// ``elicitationRequested(_:)`` announced completed, and the run resumed.
    /// Its ``ElicitationCompletion/elicitationId`` is the `elicitationId` of
    /// that ``elicitationRequested(_:)``.
    ///
    /// The completion can come from each source: the client
    /// (``RoutedSession/complete(elicitationId:)``), or the tool that asked
    /// (`ToolContext.complete(elicitationId:)`). The session sends one for
    /// each such question, and only for a question that its journal recorded.
    /// A question that completed gets no ``elicitationEnded(_:)``. A form-mode
    /// question, and a second completion of the same question, get none.
    ///
    /// A completion that is on its way when ``RoutedSession/cancelAll()`` or
    /// ``RoutedSession/close()`` runs still comes: before the
    /// ``signalDone(_:)`` of that signal, and before the end of
    /// ``RoutedSession/streamSessionEvents()``. The question then gets no
    /// ``elicitationEnded(_:)``.
    ///
    /// The origin (``SessionOutput/origin``) is ``Origin/mail(_:)`` with the
    /// ``MailID`` of the run mail that holds the question, as the
    /// ``elicitationRequested(_:)`` of the question. A question with no run
    /// mail, for example a question that a ``SubagentQuestionRelay`` sent up,
    /// has the origin of the work that completed it. When the session had no
    /// work, ``workStarted`` comes before this event. The run resumes only
    /// after the session got the completion, so this event comes before each
    /// event of the resumed run.
    ///
    /// Always on ``RoutedSession/streamSessionEvents()``; on the stream of
    /// the answer when the question completes inside an answer.
    case elicitationCompleted(ElicitationCompletion)
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
