import Foundation
import FoundationModels

/// A generation session over a resident model: the recorded surface an
/// application drives to produce text.
///
/// A session is vended only by ``RoutedModel/makeSession(instructions:workingDirectory:recordingRoot:tools:budget:compactionPrompt:agentSpawn:discoveryPriming:toolOutputProtection:repetitionDetection:)``,
/// and it retains its ``profile`` so the resident models stay loaded. The raw
/// `LanguageModelSession` is never vended; ``RoutedSession`` is the only
/// generation surface.
///
/// A session follows the stdin/stdout model (`mailbox.md`, section 5). All
/// input is ``Mail``: ``MailSink/mail(_:)`` puts one mail in the mail queue of the
/// session and returns its output at once. All output is
/// ``SessionOutput``: each event carries the ``Origin-enum`` of the work that
/// sent it, so a caller reads the events of its mail by id. Control is
/// signals: ``cancel(_:)``, ``cancelAll()``, ``replace(_:with:)`` and
/// ``compact(prompt:budget:)`` never wait in the mail queue. Each returns a
/// ``SignalID`` at once, and the session runs the work of its signals one at
/// a time, in arrival order.
/// ``close()`` does not wait in that order.
/// ``respond(to:maxTokens:)``, ``streamEvents(to:maxTokens:)`` and
/// ``streamResponse(to:maxTokens:)`` are helpers on top of the core: each
/// sends one mail and reads its output to its terminal event.
///
/// Every generation records the new transcript entries of each submission,
/// whether the model returns or throws. A session has no lock: one pump task
/// for each session is
/// the only code that submits for that session, and it submits the next
/// item only after the result of the last one, so one session never has two
/// SDK calls. Mail that arrives while a submission runs waits for the next
/// submission, and every waiting mail that can share one submission goes
/// into it. The terminal of a settled background run is run mail: the pump
/// delivers it to the model in a later submission, with no caller call.
/// A lock must not cross over a tool call, only over the call into the
/// model. A submission is one whole SDK call, with its generation passes and
/// the tool bodies between them. Each pass is one call into the model, and a
/// local MLX model holds its FIFO lock for that one generation. The SDK runs
/// each tool body after the pass, thus a tool body, or a wait for a person
/// inside it, holds nothing: the other sessions on the same model take turns
/// at each pass. A cloud model needs no lock. An in-band tool body that asks
/// its own session for an answer is refused at once with
/// ``GenerationQueueError/waitInsideOpenSubmission(model:)``, because the
/// pump of the session runs one answer at a time. A background body asks its
/// own session and gets the answer of a later submission.
public protocol RoutedSession: Actor, MailSink where Event == SessionOutput {
    /// The resolved profile this session runs against.
    nonisolated var profile: LanguageModelProfile { get }

    /// The recording root id — the router instance that owns this transcript.
    nonisolated var routerId: ULID { get }

    /// This session's span id.
    nonisolated var id: ULID { get }

    /// The span id of the parent of this session in its recorded fork tree, or
    /// `nil` for a root session.
    nonisolated var parentId: ULID? { get }

    /// The directory this session's transcript is recorded under.
    nonisolated var recordingDirectory: URL { get }

    /// The directory model/tool work runs relative to. Defaults to
    /// ``recordingDirectory``.
    nonisolated var workingDirectory: URL { get }

    /// The grammar that constrains every answer on this session, or `nil`
    /// for an unconstrained session.
    ///
    /// ``RoutedModel/makeGuidedSession(grammar:instructions:workingDirectory:tools:budget:compactionPrompt:agentSpawn:discoveryPriming:)``
    /// sets it. A guided session
    /// never streams: a user message in stream mode runs as a reply under
    /// the grammar, sends no ``SessionEvent/textDelta(_:)``, and gives its
    /// text only in its terminal event.
    nonisolated var grammar: Grammar? { get }

    /// The mutable facts of this session: its agent, tags, title, who
    /// started it, how it started, and when it was archived (ROUTER-1).
    ///
    /// A new session takes them from its ``SessionConfiguration`` and writes
    /// them to ``SessionRecord/facts`` in its `index.md`. The value reads with
    /// no `await`, from any context, and equals the file.
    nonisolated var facts: SessionFacts { get }

    /// Context fill, 0...1: the size of the render that the session sends to
    /// the model, against the profile's resolved working context. The size is
    /// the fed and generated tokens of the newest generation call, not the sum
    /// of the calls of a tool loop. A compaction restarts it from the
    /// instructions and the new snapshot. `0` before the first submission. A restored
    /// session reports the fill the live session had at the end of its
    /// recording: the newest generation call of its newest recorded submission, or
    /// the snapshot size of a newer compaction. A recording with no generation
    /// call events reports the usage on its last stamped `.response`. It
    /// reports ``unknownContextFill`` when the recording holds no stamp.
    var contextFill: Double { get async }

    /// The SDK transcript of this session as of its last settled point.
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
    /// The call is a signal (`mailbox.md`, section 3). It makes a new
    /// ``SignalID`` and returns it at once, and does not wait. The session
    /// runs the work of its signals one at a time, in arrival order: the work
    /// of a signal starts when the work of the earlier signal ended. A
    /// requested compaction runs the same steps as an automatic compaction:
    ///
    /// 1. The mail queue pauses.
    /// 2. The session sends ``SessionEvent/compactionStarted(_:)`` with the
    ///    reason ``CompactionReason/requested``.
    /// 3. One summarizer call runs. It goes to the flash slot of the profile
    ///    first, and to this session's own model when the flash slot fails or
    ///    its window is too small. The call reads the compaction prompt and
    ///    the whole live context, the instructions included. The summary
    ///    restarts the live context as the instructions, the summary entry
    ///    and the protected tool outputs. A compaction that applies appends
    ///    the summary entry to `transcript.jsonl` and reseeds the backend. A
    ///    transcript already under target stays as it is. A summary that
    ///    does not shrink the live context is discarded, and
    ///    ``CompactionResult/shortfall`` states why.
    /// 4. The session sends ``SessionEvent/compaction(_:)`` or
    ///    ``SessionEvent/compactionFailed(_:)``. This event is the terminal
    ///    event of the signal.
    /// 5. The mail queue resumes.
    ///
    /// The id of each of these events is the string form of the returned
    /// ``SignalID``.
    ///
    /// The compaction does not wait for a safe point, and does not stop a
    /// running answer: the next submission of that answer uses the compacted
    /// value. No signal affects a running compaction: ``cancelAll()`` runs
    /// after the compaction ends. Only ``close()`` cancels it. A tool body of
    /// this session's own submission can call it, because it waits for
    /// nothing. Use ``awaitTerminal(of:)-(SignalID)`` to wait for the end.
    ///
    /// To recover from `LanguageModelError.contextSizeExceeded`, compact to a
    /// lower target, wait for the terminal event of the signal, and retry one
    /// time:
    ///
    /// ```swift
    /// do {
    ///     return try await session.respond(to: prompt)
    /// } catch LanguageModelError.contextSizeExceeded(let context) {
    ///     let id = session.compact(budget: TokenBudget(limit: contextTokens, target: 0.35))
    ///     guard case .compaction = try await session.awaitTerminal(of: id) else {
    ///         // compactionFailed: the live context stays as it was.
    ///         throw LanguageModelError.contextSizeExceeded(context)
    ///     }
    ///     return try await session.respond(to: prompt)
    /// }
    /// ```
    ///
    /// - Parameters:
    ///   - prompt: The compaction prompt that the summarizer call reads.
    ///   - budget: The token budget to compact against, or `nil` for this
    ///     session's resolved working context.
    /// - Returns: The id of the signal.
    @discardableResult
    nonisolated func compact(prompt: CompactionPrompt, budget: TokenBudget?) -> SignalID

    /// Generates a complete text response to a prompt, recording the call.
    ///
    /// This call is a helper on top of ``MailSink/mail(_:)``: it sends the prompt as
    /// one user message in reply mode, and reads the output of that mail to
    /// its terminal event. The run mail that waits goes into the prompt of
    /// the submission too, in queue order. The answer is the final reply of the
    /// submission that carried the prompt, and of each continuation of it
    /// (a compaction, a retry, a recovery). A background run that the
    /// submission started does not hold the answer: its terminal is run
    /// mail, and the pump delivers it to the model in a later submission. A
    /// caller whose task is cancelled cancels its message while it is queued
    /// (``cancel(_:)``) and does not wait for the end of that signal, and
    /// stops its wait. It never stops an answer that runs: ``cancelAll()``
    /// does that.
    ///
    /// Nothing bounds a decode: there is no timeout. A generation with no
    /// observable progress reports ``SessionEvent/generationStalled(_:)`` on
    /// ``streamSessionEvents()`` with ``GenerationProgressVisibility/wholeAnswer``
    /// visibility, and one line in this module's log. Only the time inside a
    /// pass after its first output counts: a wait for the lock of the model
    /// and a tool body give no report. Each submission reports
    /// ``SessionEvent/submissionStarted(_:)`` when its SDK call starts, on
    /// ``streamSessionEvents()``.
    ///
    /// Each submission opens one OpenTelemetry span named
    /// ``RouterTelemetry/SpanName/submission``, of kind `client`, through the
    /// tracer ``RouterTelemetry/tracer(explicit:)`` resolves from the handle
    /// this session came off. A chain with a continuation opens one span for
    /// each submission. Unbootstrapped, the tracer is a no-op tracer, so an
    /// application that does not trace pays nothing. A failed submission
    /// records its error on its span, and a cancelled submission records
    /// `CancellationError`.
    ///
    /// The span carries these attributes, and their names are stable API:
    ///
    /// | Attribute | Value |
    /// |---|---|
    /// | `router.id` | The resolving router's recording root id. |
    /// | `session.id` | This session's span id. |
    /// | `model.ref` | The model the submission ran on, in canonical string form. |
    /// | `submission.id` | The id of the submission, unique inside this session. |
    /// | `submission.cause` | `message` for a submission that carries user-type mail (a user message, an agent message or an elicitation answer), `mail` for a submission that only run mail starts, or `continuation`. |
    /// | `tokens.in` | The fed tokens of the newest generation call of the submission, on a submission that measured the render. |
    /// | `tokens.out` | The generated tokens of the newest generation call of the submission, on a submission that measured the render. |
    ///
    /// The two token attributes are the context counter of the session (see
    /// ``contextFill``), not the sum of the generation calls of a tool loop.
    ///
    /// A submission that did not measure the render carries neither token attribute. No
    /// prompt text and no response text ever reaches the span: a span leaves
    /// the process through whatever backend the host application bootstrapped,
    /// so the payload stays free of the caller's own content.
    ///
    /// - Parameter maxTokens: The token ceiling, or `nil` for the resolved context of the model,
    ///   bounded by the pass token limit of the session (``RepetitionDetection/passTokenLimit``).
    /// - Returns: The model's complete text response: the final reply of the
    ///   answer that carried the prompt.
    /// - Throws: The error of a failed answer, `CancellationError` when the
    ///   message or its answer was cancelled, or
    ///   ``GenerationQueueError/waitInsideOpenSubmission(model:)`` when
    ///   called in band from a tool of a submission of this session.
    func respond(to prompt: String, maxTokens: Int?) async throws -> String

    /// Streams a text response to a prompt as it is produced, recording the call.
    ///
    /// A helper on top of ``streamEvents(to:maxTokens:)``: it gives the text
    /// of each ``SessionEvent/textDelta(_:)`` of the message. The message is
    /// a user message in stream mode, which goes alone in its submission,
    /// because its fragments belong to this stream. A guided session never
    /// streams: its stream gives the reply of the terminal event as one
    /// element. Abandoning the stream cancels the message while it is
    /// queued (``cancel(_:)``) and does not wait for the end of that signal;
    /// it never stops an answer that runs. The stream finishes while
    /// a backgrounded run is in flight; the pump delivers its terminal later,
    /// as mail. A stall reports ``SessionEvent/generationStalled(_:)`` on
    /// ``streamSessionEvents()`` with ``GenerationProgressVisibility/fragments(observed:)``
    /// visibility. A wait for the lock of the model is not a stall. Each
    /// submission reports ``SessionEvent/submissionStarted(_:)``.
    ///
    /// Each submission opens one span, as ``respond(to:maxTokens:)`` states.
    /// The first submission has `submission.cause` reading `message`, and a
    /// continuation has `continuation`.
    ///
    /// - Parameter maxTokens: The token ceiling, or `nil` for the resolved context of the model,
    ///   bounded by the pass token limit of the session (``RepetitionDetection/passTokenLimit``).
    func streamResponse(to prompt: String, maxTokens: Int?) -> AsyncThrowingStream<String, Error>

    /// Streams the events of one message as they are produced, recording the
    /// call exactly like ``streamResponse(to:maxTokens:)``.
    ///
    /// A helper on top of ``MailSink/mail(_:)``: it sends one user message in stream
    /// mode, and gives each event whose origin holds its id, up to and
    /// including its terminal event.
    ///
    /// Order within one answer: first one ``SessionEvent/mailDelivered(_:)``
    /// for each mail that the answer delivers, then the
    /// ``SessionEvent/compactionStarted(_:)`` and the
    /// ``SessionEvent/compaction(_:)`` of a proactive compaction. Then, for
    /// each submission of the chain: one ``SessionEvent/mailDelivered(_:)``
    /// for each mail that joins a continuation,
    /// ``SessionEvent/submissionStarted(_:)``, the
    /// ``SessionEvent/textDelta(_:)`` fragments, then, after the diff of the
    /// submission, the tool call and tool status events,
    /// ``SessionEvent/reasoningDelta(_:)``, and
    /// ``SessionEvent/entryRecorded(id:kind:)`` for each recorded entry, and
    /// last ``SessionEvent/submissionEnded(_:)``. The
    /// ``SessionEvent/compactionStarted(_:)`` and the
    /// ``SessionEvent/compaction(_:)`` of a reactive compaction come between
    /// two submissions. The stream ends with ``SessionEvent/answered(_:)``, or
    /// with ``SessionEvent/answerFailed(_:)`` when the chain gives no answer:
    /// then the stream throws the error of the failed answer
    /// (`CancellationError` for a cancelled answer). A message that a cancel
    /// removed from the queue ends with ``SessionEvent/cancelled(_:)``, and
    /// the stream throws `CancellationError`.
    /// ``SessionEvent/generationStalled(_:)`` is emitted on each interval
    /// without progress: no text fragment, no transcript entry, and no tool
    /// call or tool result. Only the time inside a pass after its first
    /// output counts, so a wait for the lock of the model and a tool body
    /// between two passes emit no stall.
    ///
    /// Abandoning this stream cancels the message while it is queued
    /// (``cancel(_:)``) and does not wait for the end of that signal; it
    /// never stops an answer that runs. The stream finishes while a
    /// backgrounded run is in flight. A run that settles before the stream
    /// ends is reported as
    /// ``SessionEvent/runSettled(_:)``; a later one is reported on
    /// ``streamSessionEvents()``. A call that closes inside the answer reports
    /// its attachments here as ``SessionEvent/toolCallReport(_:)``, after its
    /// close ``SessionEvent/toolInvocation(_:toolCallID:)`` record; a call that closes
    /// later reports them on ``streamSessionEvents()``. A tool that elicits
    /// inside the answer reports its request here as
    /// ``SessionEvent/elicitationRequested(_:)`` before the tool resumes; an
    /// elicitation raised outside the answer is reported on
    /// ``streamSessionEvents()``.
    ///
    /// Each submission opens one span, as ``respond(to:maxTokens:)`` states.
    /// The first submission has `submission.cause` reading `message`, and a
    /// continuation has `continuation`.
    ///
    /// - Parameter maxTokens: The token ceiling, or `nil` for the resolved context of the model,
    ///   bounded by the pass token limit of the session (``RepetitionDetection/passTokenLimit``).
    func streamEvents(to prompt: String, maxTokens: Int?) -> AsyncThrowingStream<SessionEvent, Error>

    /// Waits for the terminal event of the mail `id`:
    /// ``SessionEvent/answered(_:)`` or ``SessionEvent/answerFailed(_:)`` of
    /// the answer that delivered it, ``SessionEvent/cancelled(_:)``, or
    /// ``SessionEvent/lost(_:)``.
    ///
    /// The call returns at once when the terminal event already came. The
    /// session keeps the terminal events of the 4096 most recent ids. A call
    /// for an id that left that record, or for an id that the session never
    /// knew, throws ``TerminalLookupError/unknownMail(_:)`` at once: no
    /// terminal event can come for it. A call for mail that waits in the
    /// queue or in the answer that runs waits for its terminal event. A
    /// cancel of the calling task cancels the mail while it is queued
    /// (``cancel(_:)``), does not wait for the end of that signal, and ends
    /// the wait; it never stops an answer that runs.
    ///
    /// - Parameter id: The id of the mail.
    /// - Returns: The terminal event of the mail.
    /// - Throws: ``TerminalLookupError/unknownMail(_:)`` at once when the
    ///   session has no record of the id, `CancellationError` when the
    ///   calling task is cancelled first, ``MailRefusal/closed`` when the
    ///   session closes first, or
    ///   ``GenerationQueueError/waitInsideOpenSubmission(model:)`` when
    ///   called in band from a tool of a submission of this session.
    func awaitTerminal(of id: MailID) async throws -> SessionEvent

    /// Waits for the terminal event of the mail `id`, and gives the answer of
    /// the mail, or throws the error of its failed answer.
    ///
    /// Use this call after ``MailSink/mail(_:)`` or
    /// ``send(_:)-(Transcript.Prompt)`` to get the same result that
    /// ``respond(to:maxTokens:)`` gives, with the typed error, for example
    /// `LanguageModelError.contextSizeExceeded`. The public event
    /// ``SessionEvent/answerFailed(_:)`` does not carry that error.
    ///
    /// Each terminal event of the mail gives this result:
    ///
    /// | Terminal event | Result |
    /// |---|---|
    /// | ``SessionEvent/answered(_:)`` | The ``SessionAnswer``. |
    /// | ``SessionEvent/answerFailed(_:)`` | Throws the original error of the answer, the same error that ``respond(to:maxTokens:)`` throws. When the session kept no error, it throws the ``AnswerFailure``. An answer that ``cancelAll()`` or ``close()`` stopped throws `CancellationError`. |
    /// | ``SessionEvent/cancelled(_:)`` | Throws `CancellationError`. |
    /// | ``SessionEvent/lost(_:)`` | Throws `CancellationError`. ``awaitTerminal(of:)-(MailID)`` returns this event and throws nothing for it; this call throws what the helpers throw for it. |
    ///
    /// Mail has no answer of its own: one answer can deliver more than one
    /// mail (``SessionAnswer/mailIds``), and run mail can go into the answer
    /// of a user message. Each mail that one answer delivered gets the same
    /// ``SessionAnswer``, or the same error. Thus ``SessionAnswer/reply`` is
    /// the reply to all the mail of the answer, not to this mail alone. A mail
    /// that a continuation of an answer takes gets the end of that answer.
    ///
    /// The call returns at once when the terminal event already came, also
    /// after ``close()``. The session keeps the terminal events, and the
    /// error of each failed answer, of the 4096 most recent ids. Mail ids and
    /// signal ids count together, and the oldest id leaves first. A call for
    /// an id that left that record, or for an id that the session never knew,
    /// does not get the answer or the error: it throws
    /// ``TerminalLookupError/unknownMail(_:)`` at once. The session cannot
    /// tell these two cases apart. A call for mail that waits in the queue or
    /// in the answer that runs waits for its terminal event. After
    /// ``close()``, a call for an id with no terminal event throws
    /// ``MailRefusal/closed`` at once.
    ///
    /// A cancel of the calling task cancels the mail while it is queued
    /// (``cancel(_:)``), does not wait for the end of that signal, and ends
    /// the wait with `CancellationError`; it never stops an answer that runs.
    ///
    /// - Parameter id: The id of the mail.
    /// - Returns: The ``SessionAnswer`` of the answer that delivered the mail.
    /// - Throws: The original error of a failed answer (see the table),
    ///   `CancellationError` for a cancelled or lost mail and when the calling
    ///   task is cancelled first, ``TerminalLookupError/unknownMail(_:)`` at
    ///   once when the session has no record of the id,
    ///   ``MailRefusal/closed`` when the session closes first, or
    ///   ``GenerationQueueError/waitInsideOpenSubmission(model:)`` when
    ///   called in band from a tool of a submission of this session.
    func awaitAnswer(of id: MailID) async throws -> SessionAnswer

    /// Waits for the terminal event of the signal `id`:
    /// ``SessionEvent/signalDone(_:)``, or for a compaction
    /// ``SessionEvent/compaction(_:)`` or ``SessionEvent/compactionFailed(_:)``
    /// whose id is the signal id.
    ///
    /// The call returns at once when the terminal event already came. The
    /// session keeps the terminal events of the 4096 most recent ids. A call
    /// for an id that left that record, or for an id that the session never
    /// knew, throws ``TerminalLookupError/unknownSignal(_:)`` at once. A call
    /// for a signal whose work waits or runs waits for its terminal event. A
    /// signal that ``close()`` skips sends no terminal event, so a wait for
    /// it ends with ``MailRefusal/closed``.
    ///
    /// - Parameter id: The id of the signal.
    /// - Returns: The terminal event of the signal.
    /// - Throws: ``TerminalLookupError/unknownSignal(_:)`` at once when the
    ///   session has no record of the id, `CancellationError` when the
    ///   calling task is cancelled first, ``MailRefusal/closed`` when the
    ///   session closes first, or
    ///   ``GenerationQueueError/waitInsideOpenSubmission(model:)``.
    func awaitTerminal(of id: SignalID) async throws -> SessionEvent

    /// Streams the ``SessionEvent``s of this *session*, for as long as the
    /// session lives.
    ///
    /// Every event travels here, whichever helper sent the mail:
    /// ``SessionEvent/submissionStarted(_:)``,
    /// ``SessionEvent/submissionEnded(_:)``, ``SessionEvent/answered(_:)``,
    /// ``SessionEvent/answerFailed(_:)``, ``SessionEvent/textDelta(_:)``,
    /// ``SessionEvent/textReset``, ``SessionEvent/reasoningDelta(_:)``,
    /// tool-lifecycle events, ``SessionEvent/toolCallReport(_:)``,
    /// ``SessionEvent/elicitationRequested(_:)``,
    /// ``SessionEvent/entryRecorded(id:kind:)``,
    /// ``SessionEvent/compactionStarted(_:)``, ``SessionEvent/compaction(_:)``,
    /// ``SessionEvent/compactionFailed(_:)``,
    /// ``SessionEvent/discoveryPrimingFailed(_:)``,
    /// and ``SessionEvent/generationStalled(_:)``. A run's
    /// ``SessionEvent/runSettled(_:)`` and
    /// ``SessionEvent/elicitationRequested(_:)`` travel here also between
    /// submissions.
    ///
    /// Each element is a ``SessionOutput``: the event, and the
    /// ``SessionOutput/origin`` of the work that sent it. The events of an
    /// answer have the origin ``Origin/mail(_:)`` with the ids of all mail of
    /// the answer, user-type mail and run mail. Mail that joins a
    /// continuation adds its id to the origin of the later events of the
    /// answer. The events of a compaction have the origin
    /// ``Origin/signal(_:)`` of its compaction signal, also for an automatic
    /// compaction inside an answer; the readers of the mail of that answer
    /// also get them. The ``SessionEvent/cancelled(_:)`` of a mail
    /// has the origin ``Origin/signal(_:)`` of the signal that removed it
    /// (``cancel(_:)``, ``cancelAll()``), else the origin of that mail alone.
    /// Each signal ends with ``SessionEvent/signalDone(_:)``, with the origin
    /// of the signal. Other events, for example the events of a run that
    /// settles between answers, have the origin of the work that started
    /// them, or ``Origin/system``. The work events
    /// ``SessionEvent/workStarted`` and ``SessionEvent/workEnded`` have the
    /// origin ``Origin/system``, and only this stream carries them.
    ///
    /// An answer that ``cancelAll()`` stopped sends nothing after its
    /// ``SessionEvent/answerFailed(_:)``.
    ///
    /// Each call vends an independent subscription, buffered without bound.
    /// Ending iteration drops the subscription; ``close()`` finishes every
    /// outstanding one.
    func streamSessionEvents() -> AsyncStream<SessionOutput>

    /// Removes one mail from the mail queue, and sends its terminal event
    /// ``SessionEvent/cancelled(_:)`` (`mailbox.md`, section 5).
    ///
    /// The call is a signal. It makes a new ``SignalID`` and returns it at
    /// once. The session runs the work of its signals one at a time, in
    /// arrival order: the work of a signal starts when the work of the
    /// earlier signal ended. The result shows only as events. The removed
    /// mail gets ``SessionEvent/cancelled(_:)`` with the origin
    /// ``Origin/signal(_:)`` of the signal, and the signal ends with
    /// ``SessionEvent/signalDone(_:)`` after all its other events. Use
    /// ``awaitTerminal(of:)-(SignalID)`` to wait for the end.
    ///
    /// The signal acts only on queued mail. It never examines or stops work
    /// in progress: no running answer, tool call, run or compaction. Mail
    /// that is not queued when the signal runs (delivered or unknown) gets
    /// nothing, and the signal then sends only
    /// ``SessionEvent/signalDone(_:)``. ``cancelAll()`` stops the running
    /// answer. Safe at any time and any number of times, from any task.
    ///
    /// - Parameter id: The id of the mail.
    /// - Returns: The id of the signal.
    @discardableResult
    nonisolated func cancel(_ id: MailID) -> SignalID

    /// Stops all work of this session (`mailbox.md`, section 5, "Decision:
    /// cancelAll() stops all of it"). It is the stop button of a host.
    ///
    /// The call is a signal. It makes a new ``SignalID`` and returns it at
    /// once. The session runs the work of its signals one at a time, in
    /// arrival order: the work of a signal starts when the work of the
    /// earlier signal ended. The result shows only as events, and the
    /// removed mail gets ``SessionEvent/cancelled(_:)`` with the origin
    /// ``Origin/signal(_:)`` of the signal. Use
    /// ``awaitTerminal(of:)-(SignalID)`` to wait for the end. The work:
    ///
    /// 1. Each queued mail of all kinds, also run mail, leaves the queue and
    ///    gets ``SessionEvent/cancelled(_:)``.
    /// 2. The running answer stops: its mail gets
    ///    ``SessionEvent/answerFailed(_:)`` with the reason
    ///    ``AnswerFailure/Reason/cancelled`` at once, and the output of the
    ///    session drops each later event of that answer and of its runs.
    ///    Each event of other work, for example of a run that an earlier
    ///    answer started, still goes out while the stopped answer winds down.
    ///    Each mail subscription and each helper stream of that mail ends.
    ///    The model call gets a cancel, so the cancel reaches the tool calls
    ///    that the SDK runs; work that does not check for a cancel can run
    ///    on for a time, but nobody sees its output.
    /// 3. Each background run gets a cancel, and each open elicitation is
    ///    rejected. The call does not wait for the cancel of a run; each run
    ///    gets its terminal event when its cancel ends. A stopped run makes
    ///    no more mail.
    ///
    /// The signal ends with ``SessionEvent/signalDone(_:)``. It comes after
    /// the ``SessionEvent/cancelled(_:)`` events of the signal and after the
    /// ``SessionEvent/answerFailed(_:)`` of the stopped answer. It does not
    /// wait for slow run cancels.
    ///
    /// The signal never interferes with signal work: it never changes the
    /// pause of the mail queue, and never drops an output of a signal. It
    /// does not stop a running compaction: signals run in order, so the
    /// running compaction ends first, and the work of this signal runs after
    /// it. After the signal, the session is usable:
    /// ``MailSink/mail(_:)`` and the other signals work as usual, and the pump takes
    /// new mail when the stopped work ended. Safe at any time and any number
    /// of times, from any task.
    ///
    /// - Returns: The id of the signal.
    @discardableResult
    nonisolated func cancelAll() -> SignalID

    /// Changes the body of one queued mail. The id, the sender and the place
    /// in the queue do not change.
    ///
    /// The call is a signal. It makes a new ``SignalID`` and returns it at
    /// once. The session runs the work of its signals one at a time, in
    /// arrival order: the work of a signal starts when the work of the
    /// earlier signal ended. The result shows only as events, and the
    /// signal ends with ``SessionEvent/signalDone(_:)`` after all its other
    /// events. Use ``awaitTerminal(of:)-(SignalID)`` to wait for the end.
    /// Mail that is not queued when the signal runs (delivered or unknown)
    /// does not change, and the signal then sends only
    /// ``SessionEvent/signalDone(_:)``.
    ///
    /// A replace is not screened. The new body goes to the model as you give
    /// it, with no new `PrePrompt` hook event, so a guard visitor does not
    /// see the replaced text. When the `PrePrompt` chain of the mail runs
    /// at the time of the replace, the new body wins over the text of the
    /// chain, but a block of the chain still blocks the mail. The mail still
    /// gets one `PostPrompt`.
    ///
    /// - Parameters:
    ///   - id: The id of the mail.
    ///   - body: The new body.
    /// - Returns: The id of the signal.
    @discardableResult
    nonisolated func replace(_ id: MailID, with body: MailBody) -> SignalID

    /// Installs how long a model call on this session may run with no
    /// observable progress before it reports
    /// ``SessionEvent/generationStalled(_:)``. The change takes effect on the
    /// next model call. The interval counts only the time inside a pass after
    /// its first output, and never the wait for the lock of the model;
    /// ``GenerationStall`` states the meaning of each field of a report.
    ///
    /// Stall reports are off until the host calls this. The session has no
    /// interval of its own: the host that shows the report names the interval.
    ///
    /// - Parameter interval: The interval to install. A non-positive interval
    ///   turns reporting off for later calls.
    func setGenerationStallReportInterval(_ interval: Duration)

    /// Waits until this session has no more work, and stops nothing. A host
    /// calls it when the stream of an answer ended while a background run of
    /// that answer is open: the result of the run comes back as mail, and
    /// the answer that the mail starts is visible only on
    /// ``streamSessionEvents()``.
    ///
    /// The session is idle when it has no work. The work of a session is the
    /// set of the open leases of its own work registry (`WorkRegistry`): one
    /// registry for each session, also for each restored session and each
    /// child session. The session is idle when no lease is open:
    ///
    /// 1. Nothing is queued to generate: no answer runs (a generation lease),
    ///    and no requested compaction waits or runs.
    /// 2. Nothing in the mailbox can start work: no user-type mail waits, and
    ///    no queued run mail can start an answer by itself. Run mail that the
    ///    session holds, for example after
    ///    ``SessionEvent/mailDeliveryPaused(_:)``, waits for the next
    ///    user-type mail, so it is no work.
    /// 3. No background tool work is open: no background run, no pending
    ///    shell command, no unawaited inner call, no notice that waits for
    ///    its delivery, no MCP call, and no child session that a tool call
    ///    started. Each one holds a lease of the tooling. A run that waits
    ///    only for the user (a run whose question
    ///    ``SessionEvent/elicitationRequested(_:)`` is open) is no work: only
    ///    the user can move it. Its result still comes to the model later. A
    ///    run that drives a subagent through a ``SubagentQuestionRelay`` is
    ///    work while the subagent works, also when the run has an open
    ///    question. So a session whose subagents wait only for the user is
    ///    idle, level by level up to the root.
    ///
    /// The work of a child session is in the registry of that
    /// session, never in the registry of its parent.
    ///
    /// A run that settles inside the answer that runs can ride that answer,
    /// or start an answer of its own. The call waits for the answer of the
    /// mail in both cases, so when it returns `true`, the
    /// ``SessionEvent/answered(_:)`` or ``SessionEvent/answerFailed(_:)`` of
    /// the last answer is already on ``streamSessionEvents()``.
    ///
    /// The call returns at once when the session is idle. Else it waits
    /// until the registry has no open lease, with no poll and no timer. When
    /// the call returns `true`, ``SessionEvent/workEnded`` of the last work is
    /// already on ``streamSessionEvents()``. A consumer of
    /// ``streamSessionEvents()`` can follow the same rules with no call:
    /// ``SessionEvent/workStarted`` and ``SessionEvent/workEnded`` report
    /// each change, in order with the other outputs.
    /// A cancel of the calling task ends the wait at once. ``close()`` ends
    /// each wait with `false`. A call after
    /// ``close()`` started, also a call after ``close()`` returned, returns
    /// `false` at once and does not wait.
    ///
    /// - Returns: `true` when the session is idle, and `false` when the
    ///   calling task was cancelled, or ``close()`` started, before that.
    @discardableResult
    func awaitIdle() async -> Bool

    /// Tears the session down: closes the mail queue, runs the work of
    /// ``cancelAll()`` directly (it does not wait in the order of the
    /// signals, and sends no ``SessionEvent/signalDone(_:)``), and waits
    /// until all work ended, also when the calling task is
    /// cancelled. Each queued mail gets its terminal event
    /// ``SessionEvent/cancelled(_:)``, and ``MailSink/mail(_:)`` refuses later mail
    /// with ``MailRefusal/closed``. Close waits for the pump, for the sweep of
    /// the background runs, for the body of each run, and for the end of each
    /// generation pass of a stopped model call. The framework resumes a
    /// cancelled model call before its pass ends, and that pass keeps the
    /// model handles of the session until it ends. Close also waits for the
    /// end of the task of each signal, and for the end of each helper task of
    /// the session (the stall watch, the reader of the pass reports and the
    /// repetition watch of a model call, and the wake of the pump after a
    /// mail or after a compaction), because each of them keeps the session
    /// and its profile. After close began, no pump starts. So when this call
    /// returns, no work of the session runs: no submission, no background
    /// run, no signal work, and no generation on the model, and no task of
    /// the session keeps the profile.
    /// The sweep runs
    /// `RunPlane.sweep()`, which cancels every background run and rejects
    /// every pending elicitation, and journals the resulting terminal events.
    /// Close also finishes every ``streamSessionEvents()`` subscription,
    /// finishes each mail subscription that is left, ends each wait for a
    /// terminal event with ``MailRefusal/closed``, and releases the prompt
    /// cache that the model keeps for this session. Each session has a cache
    /// of its own, so the close of one session does not release the cache of
    /// another.
    /// Before it waits for the end of all work, close ends each
    /// ``awaitIdle()`` wait with `false`.
    ///
    /// Close is the one exception to the rule that no signal affects a
    /// running compaction. It does not wait in the order of the signals: it
    /// cancels the summarizer call of a running compaction, and that
    /// compaction ends with ``SessionEvent/compactionFailed(_:)``
    /// (``CompactionFailure/Outcome/cancelled``) before the event streams
    /// finish. Close does not wait for the compaction to finish its work.
    /// Nothing is lost: the transcript keeps no compacted value, so a restore
    /// uses the full transcript. A signal that waits behind the running
    /// signal work does not run after close: it sends no event, and a wait
    /// for its terminal event ends with ``MailRefusal/closed``.
    ///
    /// If a tool or a run body of this session calls close(), close() returns
    /// before the close ends. The close ends after that work returns. Close
    /// waits for all work of the session, and that work includes the caller,
    /// so a close that waited would never return. A `Task {}` that a tool
    /// body or a run body of this session starts copies the task-locals of
    /// that work, so a close from that task also returns before the close
    /// ends. That is correct: the task is still the own work of the session.
    /// A task that `Task.detached` starts copies no task-local, so a close
    /// from it waits as a close from outside the session does.
    ///
    /// Mail carries the own work of its sender into the answer that delivers
    /// it. When a tool or a run body of this session sends mail to another
    /// session (for example with `respond(to:)` or `send(_:)` on a child
    /// session), each tool and each run body of the
    /// answer of the other session is also the own work of this session. So
    /// a close of this session from such a tool also returns before the close
    /// ends: the tool of this session waits for that answer, so a close that
    /// waited for the tool would never return. The close stops the tool of
    /// this session, and the close ends after that tool and the answer that
    /// it waits for return. A tool body that already ran when the mail joined
    /// a running answer of the other session does not get the own work of the
    /// sender: only the model calls of that answer that start after the join
    /// get it.
    ///
    /// A caller outside the session gets the contract above: when close
    /// returns, the session is closed. A close from outside also waits for a
    /// close that the own work of the session started. A tool or a run body
    /// of another session that no mail of this session started is outside
    /// this session, also a tool of a child session of this session that a
    /// host asked.
    ///
    /// Call it where a session's life ends. `deinit` does not run this sweep.
    /// Idempotent.
    func close() async

    /// Sends one user message to this session, and returns its id at once.
    ///
    /// A helper on top of ``MailSink/mail(_:)``: the message is a user message in
    /// reply mode, with the text of the `.text` segments of `prompt`, joined
    /// with no separator. It waits in the mail queue of the session. When no
    /// submission of the session runs, the pump starts one for it with no
    /// other call; when a submission runs, the message goes into the next
    /// one. Every waiting mail that can share one submission goes into it, in
    /// queue order, with the waiting run mail.
    ///
    /// The call waits for no submission and for no answer, from any task: a
    /// tool body of this session's own submission can send, and its message
    /// goes into a later submission. ``respond(to:maxTokens:)`` is this call
    /// followed by a wait for the terminal event.
    ///
    /// The answer of a sent message is visible on ``streamSessionEvents()``
    /// as ``SessionEvent/answered(_:)``, and ``awaitTerminal(of:)-(MailID)``
    /// waits for it. Its submission opens one span, as
    /// ``respond(to:maxTokens:)`` states, with `submission.cause` reading
    /// `message`.
    ///
    /// - Parameter prompt: The prompt of the message.
    /// - Returns: The id of the mail, usable with ``cancel(_:)``,
    ///   ``replace(_:with:)``, ``pendingMessages()``,
    ///   ``mailQueueDepth()`` and ``awaitTerminal(of:)-(MailID)``. The
    ///   ``SessionOutput/origin`` of each event of its answer holds it.
    /// - Throws: ``PromptRefusal/noTextSegment`` when `prompt` has no `.text`
    ///   segment, or ``MailRefusal/closed`` after ``close()``.
    @discardableResult
    nonisolated func send(_ prompt: Transcript.Prompt) throws -> MailID

    /// A snapshot of every mail that waits in the mail queue, of all kinds,
    /// in queue order. Mail that the pump took is not in it.
    func pendingMessages() async -> [Mail]

    /// How much mail work this session carries: the mail that waits, by
    /// kind, and the ids of the mail of the running answer.
    func mailQueueDepth() async -> MailQueueDepth

    /// Delivers the user's answer to a pending elicitation raised by a run on
    /// this session.
    ///
    /// A form-mode `accept` resumes the run with its `content`; `decline` and
    /// `cancel` resume with those actions. A URL-mode `accept` keeps the run
    /// running until ``complete(elicitationId:)`` arrives. Unknown, malformed,
    /// and already-answered ids are safe no-ops. So is the id of a question
    /// that ended with no answer of the client
    /// (``SessionEvent/elicitationEnded(_:)``): the answer goes no further,
    /// and the result is ``ElicitationAnswerDelivery/noPendingElicitation``.
    ///
    /// When the answer reached the waiting run
    /// (``ElicitationAnswerDelivery/delivered``), it also goes to the session
    /// as ``MailBody/elicitationAnswer(id:response:)`` mail, as if the user
    /// made one more post. That mail starts an answer, so the model also
    /// sees the answer. The mail carries the answer that the run gets: for
    /// an accepted form answer whose content does not agree with the
    /// requested schema (``ElicitationRequestedSchema/validationFailure(of:)``),
    /// the run and the mail both get a decline whose reason is
    /// ``ElicitationRequestedSchema/invalidAnswerReasonPrefix`` followed by
    /// the failure.
    ///
    /// A question that a ``SubagentQuestionRelay`` sent up from a subagent
    /// gives no answer mail to this session: the answer goes down to the
    /// subagent, and only the level whose own run asked the question gets the
    /// mail. A URL-mode accept of such a question goes down at once.
    ///
    /// - Parameter elicitationId: The pending elicitation's id, the string form of ``ElicitationRequest/elicitationId``.
    @discardableResult
    func respond(elicitationId: String, response: ElicitationResponse) async -> ElicitationAnswerDelivery

    /// Signals that an accepted URL-mode elicitation's out-of-band flow
    /// finished, and resumes the run. Unknown, malformed, not-yet-accepted, and
    /// already-completed ids are safe no-ops. So is the id of a question that
    /// ended with no answer of the client (``SessionEvent/elicitationEnded(_:)``).
    @discardableResult
    func complete(elicitationId: String) async -> ElicitationCompletionDelivery

    /// The ids of the questions of this session that are open now: their
    /// ``SessionEvent/elicitationRequested(_:)`` went out, and no answer that
    /// resumed the run, no completion and no end came yet. A URL-mode
    /// question that the user accepted is open until its completion. A
    /// question that a ``SubagentQuestionRelay`` sent up to this session
    /// counts, the same as a question of a run of this session.
    ///
    /// An owner of a subagent reads it to know whether the subagent waits for
    /// the user: a session with no work (``awaitIdle()``) and one or more open
    /// questions waits only for external input.
    ///
    /// - Returns: The ids, in the string form that
    ///   ``respond(elicitationId:response:)`` takes, in the order the
    ///   questions came.
    func openElicitationIds() async -> [String]
}

extension RoutedSession {
    /// See ``compact(prompt:budget:)``, with both parameters at their defaults.
    ///
    /// - Returns: The id of the signal.
    @discardableResult
    public nonisolated func compact() -> SignalID {
        compact(prompt: .default, budget: nil)
    }

    /// See ``compact(prompt:budget:)``, with `prompt` at ``CompactionPrompt/default``.
    ///
    /// - Parameter budget: The token budget to compact against, or `nil` for this
    ///   session's resolved working context.
    /// - Returns: The id of the signal.
    @discardableResult
    public nonisolated func compact(budget: TokenBudget?) -> SignalID {
        compact(prompt: .default, budget: budget)
    }

    /// See ``respond(to:maxTokens:)``, with no ceiling from the caller: the resolved context of the
    /// model, bounded by the pass token limit of the session, is the token ceiling.
    public func respond(to prompt: String) async throws -> String {
        try await respond(to: prompt, maxTokens: nil)
    }

    /// See ``streamResponse(to:maxTokens:)``, with no ceiling from the caller: the resolved context of
    /// the model, bounded by the pass token limit of the session, is the token ceiling.
    public func streamResponse(to prompt: String) -> AsyncThrowingStream<String, Error> {
        streamResponse(to: prompt, maxTokens: nil)
    }

    /// See ``streamEvents(to:maxTokens:)``, with no ceiling from the caller: the resolved context of
    /// the model, bounded by the pass token limit of the session, is the token ceiling.
    public func streamEvents(to prompt: String) -> AsyncThrowingStream<SessionEvent, Error> {
        streamEvents(to: prompt, maxTokens: nil)
    }

    /// See ``send(_:)-(Transcript.Prompt)``, with the plain text of the
    /// message as one `.text` segment.
    ///
    /// - Parameter prompt: The prompt text of the message.
    /// - Returns: The id of the mail.
    /// - Throws: ``MailRefusal/closed`` after ``close()``.
    @discardableResult
    public nonisolated func send(_ prompt: String) throws -> MailID {
        try send(.plainText(prompt))
    }
}
