import FoundationModels
import FoundationModelsExtras

/// ``RoutedSessionActor``'s run journal: a long-running operation's reports
/// (progress, elicitation, completion) become transcript entries at the
/// moment they are made.
extension RoutedSessionActor: OperationEventJournal {
    /// Records one posted ``OperationEvent``, in post order. Entries of one
    /// run can interleave with the entries of a submission. Each recorded
    /// event is also delivered live (``liveEvent(for:)``): a terminal as
    /// ``SessionEvent/runSettled(_:)``, a message of a run as
    /// ``SessionEvent/runMessage(_:)``, a progress event as
    /// ``SessionEvent/runProgress(_:)``, and an elicitation as
    /// ``SessionEvent/elicitationRequested(_:)``.
    ///
    /// Each event gets its own entry, with one exception (task ^zze1067):
    /// consecutive progress events of one run share one merged entry. The
    /// first progress event of a run is its own start row. Each next
    /// progress event of the same run goes into ``openProgressRow`` and
    /// writes nothing now. The next different event or entry closes the row
    /// (``closeOpenProgressRow()``) before it is written itself, so the
    /// transcript keeps the post order and each event. A progress event that
    /// goes into the open row is also delivered live at once.
    ///
    /// The trade-off: while a run continues to post progress, its open row is
    /// only in memory. It is not on disk yet. If the process stops before a
    /// different event, a different entry or ``close()`` writes the row, the
    /// open row is lost. The start row and the events written before it stay.
    /// A progress event that has a plan (`OperationEvent.plan`) never goes
    /// into the open row (``OpenProgressRow/accepts(_:)``): it closes the row
    /// and is written at once, so a restore finds the last plan of each plan
    /// id on disk (task ^mq1js23).
    ///
    /// The live event has the origin that `origin` gives
    /// (``deliverLive(_:origin:)``): the id of the run mail of `event`, or
    /// the origin of the poster when `event` made no mail.
    ///
    /// A question of a run (`.elicitation`) is a change of the work of the
    /// session after its live event (``noteQuestionAsked(_:mailID:)``): the run can
    /// now wait only for the user.
    ///
    /// The terminal of a run sends no end of a question. The run plane posts
    /// the end of each question that it ends
    /// (``record(elicitationEnded:response:poster:)``), before the run of the
    /// question resumes. Thus the end of a question of a cancelled run comes
    /// before the terminal of that run.
    ///
    /// - Parameters:
    ///   - event: The event the outbox has just accepted.
    ///   - origin: The run mail of `event` and the work that posted it.
    func record(event: OperationEvent, origin: RunEventOrigin) async {
        guard claimJournalWrite(for: event) else { return }
        if openProgressRow?.accepts(event) == true {
            openProgressRow?.append(event)
        } else {
            await recordSessionMetaIfNeeded()
            await append(partial: makeRunEventPartial(toolName: event.tool, events: [event]))
            if event.kind == .progress {
                openProgressRow = OpenProgressRow(after: event)
            }
        }
        deliverLive(Self.liveEvent(for: event), origin: origin)
        if event.kind == .elicitation {
            await noteQuestionAsked(event, mailID: origin.mailID)
        }
    }

    /// Sends ``SessionEvent/elicitationCompleted(_:)`` for the accepted
    /// URL-mode question `elicitationId`, whose flow the run plane completed
    /// (task ^rkh6k6m).
    ///
    /// The record of the questions decides (``AskedQuestions/complete(_:postedBy:)``):
    /// the event goes out one time, only for a URL-mode question that the
    /// journal recorded, with the origin of the run mail that holds the
    /// question. The record takes the question out with no suspension point
    /// before the live event, so a second completion finds no question.
    ///
    /// The completion resumes the run, so it is a start of work
    /// (``noteWorkStarted()``) before the event: a session that had no work
    /// sends ``SessionEvent/workStarted`` first. A completion through
    /// ``RoutedSession/complete(elicitationId:)`` noted that start already.
    /// The change of the work is reported after the event
    /// (``workDidChange()``), so a run that settled before its completion
    /// arrived still gives its work-end event.
    ///
    /// After the event, the session reports that the journal handled the
    /// post (``questionPosts``). A cancel-all signal or ``close()`` that
    /// found this completion on its way waits for it, and sends its terminal
    /// event only after the completion
    /// (``awaitQuestionPosts(of:)``). The completion then goes out also while
    /// the answer that the signal stopped continues
    /// (``deliverQuestionPost(_:origin:)``).
    ///
    /// - Parameters:
    ///   - elicitationId: The id of the question that completed.
    ///   - poster: The origin of the work that posted the completion.
    func record(elicitationCompleted elicitationId: ULID, poster: Origin) async {
        guard let origin = askedQuestions.complete(elicitationId, postedBy: poster) else { return }
        noteWorkStarted()
        deliverQuestionPost(.elicitationCompleted(ElicitationCompletion(elicitationId: elicitationId)), origin: origin)
        questionPosts.signal()
        await workDidChange()
    }

    /// Sends ``SessionEvent/elicitationEnded(_:)`` for the question
    /// `elicitationId`, which a cancel of the run plane ended with no answer
    /// of the client (task ^fqb5rjr).
    ///
    /// The run plane decides each end, not the session. It takes the question
    /// off in one step, so an answer or a completion of the client before that
    /// step wins and gets no end, and one after it finds no question. It posts
    /// the end after the post of the question, and the run gets `response`
    /// only after this post returns.
    ///
    /// The record of the questions decides only whether the event goes out
    /// (``AskedQuestions/end(_:)``): one time, and only for a question that
    /// the journal recorded. The record takes the question out with no
    /// suspension point before the live event.
    ///
    /// The origin of the event is `poster`, the work that ended the question:
    /// the signal of ``cancelAll()``, ``Origin/system`` for ``close()``, or
    /// the work that cancelled the run of the question, for example the
    /// answer to the run mail of the question. This origin changed: before,
    /// the session sent the end of a cancelled run with the origin of the run
    /// mail of the terminal of the run, and before that terminal. No reader
    /// of the output reads this origin. The output drops the event when it
    /// drops `poster` (``deliverQuestionPost(_:origin:)``).
    ///
    /// The end of a question that a tool asked inside the answer that
    /// ``cancelAll()`` or ``close()`` stopped also goes out
    /// (``deliverQuestionPost(_:origin:)``): the stop posts that end while
    /// the stopped answer continues, because the tool of the answer waits on
    /// the question until the end post returns (task ^vkkecjt).
    ///
    /// After the event, the session reports that the journal handled the
    /// post (``questionPosts``), as for a completion.
    ///
    /// - Parameters:
    ///   - elicitationId: The id of the question that ended.
    ///   - response: The answer that the run of the question gets.
    ///   - poster: The origin of the work that ended the question.
    func record(elicitationEnded elicitationId: ULID, response: ElicitationResponse, poster: Origin) async {
        guard askedQuestions.end(elicitationId) else { return }
        let end = ElicitationEnd(elicitationId: elicitationId, response: response)
        deliverQuestionPost(.elicitationEnded(end), origin: RunEventOrigin(mailID: nil, poster: poster))
        questionPosts.signal()
    }

    /// Sends the live event of a question post (an end or a completion) with
    /// ``deliverLive(_:origin:)``, but session-scoped while the open answer
    /// is the answer that ``cancelAll()`` or ``close()`` stopped
    /// (``OpenAnswerMail/isSilenced``).
    ///
    /// The stopped answer continues until its work ends, so its event sink
    /// (``currentAnswerEventSink``) is still set. That sink gives each event
    /// the mail of the stopped answer as its audience, and the output drops
    /// each event for that audience (``SessionOutputHub/emit(_:failure:audience:)``).
    /// A question post is never output of the stopped answer: the stop
    /// itself posts the end of each open question, and a completion on its
    /// way comes from the client or from a tool. The mail of the stopped
    /// answer already has its terminal event, so no reader of that mail
    /// waits for the post. Thus the event goes to the feed of the session,
    /// with no audience: before the ``SessionEvent/signalDone(_:)`` of
    /// ``cancelAll()``, or before the end of the feeds at ``close()``.
    ///
    /// The output still drops the event when it drops the poster, as
    /// ``deliverLive(_:origin:)`` does: both use
    /// ``deliver(_:origin:through:)``. Each other live event uses
    /// ``deliverLive(_:origin:)`` with no change.
    ///
    /// - Parameters:
    ///   - event: The live event of the post.
    ///   - origin: The run mail of the question and the work that posted it.
    func deliverQuestionPost(_ event: SessionEvent, origin: RunEventOrigin) {
        guard openAnswerMail.isSilenced else {
            deliverLive(event, origin: origin)
            return
        }
        deliver(event, origin: origin) { emitSessionScopedEvent($0) }
    }

    /// Gives `event` to `emit`, with ``RunEventOrigin/output`` of `origin`
    /// as the task-local origin (``OriginContext/current``). When the output
    /// drops the poster of `origin` (``SessionOutputHub/drops(_:)``), this
    /// call does not send the event.
    ///
    /// This is the one drop check and the one origin binding of each live
    /// event of a run. Only the audience is different:
    /// ``deliverLive(_:origin:)`` gives the event to the running answer or
    /// to the feed of the session (``deliverLive(_:)``), and
    /// ``deliverQuestionPost(_:origin:)`` gives the post of a stopped
    /// answer to the feed of the session.
    ///
    /// - Parameters:
    ///   - event: The live event.
    ///   - origin: The run mail of the event and the work that posted it.
    ///   - emit: Sends the event to its audience.
    private func deliver(_ event: SessionEvent, origin: RunEventOrigin, through emit: (SessionEvent) -> Void) {
        guard !outputHub.drops(origin.poster) else { return }
        OriginContext.$current.withValue(origin.output) {
            emit(event)
        }
    }

    /// Hands the live event of one journaled run event to
    /// ``deliverLive(_:)``, with the origin ``RunEventOrigin/output``.
    ///
    /// The journal write runs on the journal chain of the outbox, so this
    /// call binds the origin itself and does not read the task-local origin
    /// of that chain.
    ///
    /// The answer that ``RoutedSession/cancelAll()`` stopped sends no more
    /// output (``SessionOutputHub/silence(_:)``). A run event that the work of
    /// that answer posts can have the origin of its new run mail, which the
    /// output does not drop. Thus the poster of the event decides here: when
    /// the output drops the origin of the poster, the live event is not sent.
    /// The transcript and the run mail keep the event.
    ///
    /// - Parameters:
    ///   - event: The live event.
    ///   - origin: The run mail of the event and the work that posted it.
    func deliverLive(_ event: SessionEvent, origin: RunEventOrigin) {
        deliver(event, origin: origin) { deliverLive($0) }
    }

    /// The live ``SessionEvent`` that carries a recorded event to the host.
    ///
    /// - Parameter event: The event the journal records.
    /// - Returns: The session event of the kind of `event`.
    static func liveEvent(for event: OperationEvent) -> SessionEvent {
        switch event.kind {
        case .completed:
            return .runSettled(event)
        case .message:
            return .runMessage(event)
        case .progress:
            return .runProgress(event)
        case .elicitation:
            return .elicitationRequested(event)
        }
    }

    /// Hands `event` to the running answer, or to the session-scoped feed
    /// between answers.
    ///
    /// - Parameter event: The event to deliver.
    func deliverLive(_ event: SessionEvent) {
        if let currentAnswerEventSink {
            currentAnswerEventSink(event)
        } else {
            emitSessionScopedEvent(event)
        }
    }

    /// Whether `event` may be journaled. A run's one terminal (`.completed`)
    /// is claimed on first write; a second terminal for the same run is
    /// refused. Progress, elicitation and message events are always admitted,
    /// so each message of a run is journaled and delivered live. The
    /// claim is taken synchronously, before any suspension.
    ///
    /// - Parameter event: The event about to be journaled.
    /// - Returns: `false` when `event` is a terminal for a run whose ending is
    ///   already recorded; `true` otherwise.
    func claimJournalWrite(for event: OperationEvent) -> Bool {
        guard event.kind == .completed else { return true }
        return journaledTerminalCorrelationIDs.insert(event.correlationID).inserted
    }

    /// Builds the recorded partial for the ``OperationEvent``s of one row: a
    /// `.toolOutput` entry with a fresh ULID id and one typed
    /// ``OperationEventSegment`` for each event, in order. The run's
    /// `correlationID` travels in the payload, not in the entry id. The body
    /// text is the ``OperationEventSegment/renderedLine(for:)`` of each event,
    /// one line for each event.
    ///
    /// - Parameters:
    ///   - toolName: The name of the tool that posted the events.
    ///   - events: The events of the row: one event, or the merged progress
    ///     events of one run.
    /// - Returns: The partial for the recorder to stamp and append.
    func makeRunEventPartial(toolName: String, events: [OperationEvent]) -> TranscriptEvent.Partial {
        let entry = Transcript.Entry.toolOutput(
            Transcript.ToolOutput(
                id: ULID.generate().description,
                toolName: toolName,
                segments: events.map { OperationEventSegment(content: $0).transcriptSegment }
            )
        )
        let (kind, payload, _) = TranscriptEntryMapper.event(from: entry)
        return makePartialEvent(
            kind: kind,
            text: events.map(OperationEventSegment.renderedLine(for:)).joined(separator: "\n"),
            entry: payload)
    }

    /// Writes the merged row of ``openProgressRow``, when it holds events,
    /// and closes it. Each write to the transcript calls this first
    /// (``append(partial:)``), so the merged row comes before the different
    /// entry that closes it. ``close()`` calls it last, so a row that is open
    /// at the end of the session is not lost.
    ///
    /// The row is taken before the write suspends, so a second call that
    /// starts during the write finds no row and writes it no second time.
    func closeOpenProgressRow() async {
        guard let row = openProgressRow else { return }
        openProgressRow = nil
        guard !row.events.isEmpty else { return }
        await appendToRecorder(makeRunEventPartial(toolName: row.toolName, events: row.events))
    }

    /// Installs this session as ``outbox``'s ``OperationEventJournal``,
    /// ``ToolInvocationObserver`` and ``SessionMailObserver``, and as
    /// ``runPlane``'s settlement observer (the Extras
    /// `BackgroundRunSettlementObserver`), once. Called by each
    /// helper that sends a message and by the pump. Idempotent.
    func attachOutboxJournalIfNeeded() async {
        guard !didAttachOutboxJournal else { return }
        didAttachOutboxJournal = true
        await outbox.attach(journal: self)
        await outbox.attach(invocationObserver: self)
        await outbox.attach(mailObserver: self)
        await runPlane.attach(settlementObserver: self)
    }
}

/// ``RoutedSessionActor``'s settlement forwarding. A background run's own
/// terminal reaches the journal under the run's own token at the moment the
/// run plane settles the run, whether or not the run's funnel delivered it.
extension RoutedSessionActor: BackgroundRunSettlementObserver {
    /// Journals one naturally settled run's terminal without staging it, and
    /// wakes the pump, which delivers the terminal that the run's funnel
    /// staged (``wakePump()``).
    ///
    /// `journalWithoutStaging`, not `post(event:)`: `post` would stage a
    /// second pending `.completed` for a run whose funnel already staged one.
    /// Each background run has such a funnel: a top-level run, and also a run
    /// that a synchronous call starts through `ToolContext.mount(_:op:as:)`,
    /// because the Extras mount layer posts each background run to the sink
    /// of the session, which is ``outbox`` (task ^3rr9rn4). The write joins
    /// the outbox's FIFO journal chain, and the journal refuses it when the
    /// funnel's copy already claimed the correlation. See
    /// ``claimJournalWrite(for:)``.
    ///
    /// The funnel of a run stages the terminal before the run plane settles the
    /// run: the body of the run posts the terminal, waits until the post
    /// ends, and only then returns, and the run plane settles the run when the
    /// body returns. So the terminal is staged before this call, and the
    /// wake of this call finds it. The idle check (``isIdle()``) needs this
    /// order. A sweep (of ``cancelAll()`` or of the end of all work of
    /// ``close()``) is the one case where the terminal comes after the
    /// settlement: the sweep settles the run with no call here, and the body
    /// of the run posts its own terminal when it ends. A stopped run makes no
    /// mail (``SessionOutbox/ignoreRunMail(of:)``), so that terminal is
    /// journaled and not staged. The end of all work of ``close()`` waits
    /// for that body. The pump delivers a terminal only when it is both
    /// staged and settled.
    ///
    /// A held terminal (``SessionOutbox/PendingEvent/isHeld``) stays held: a
    /// settlement is no new mail, and the forward of it can come after a
    /// submission already took the terminal and gave it back.
    ///
    /// The settlement is a change of the work of the session
    /// (``workDidChange()``): a run that settles while the end of all work
    /// of ``close()`` runs starts no pump, so the pump does not report it.
    ///
    /// - Parameter terminal: The terminal the run plane forwarded.
    func deliver(settledTerminal terminal: OperationEvent) async {
        await outbox.journalWithoutStaging(event: terminal)
        wakePump()
        await workDidChange()
    }
}

/// ``RoutedSessionActor``'s live invocation delivery. A
/// ``ToolInvocationRecord`` becomes a ``SessionEvent/toolInvocation(_:toolCallID:)``,
/// a ``ToolCallReport`` becomes a ``SessionEvent/toolCallReport(_:)``, and a
/// ``ToolDisplayEvent`` becomes a ``SessionEvent/toolDisplay(_:)``, the moment
/// it is posted. Delivery only: none is ever journaled.
extension RoutedSessionActor: ToolInvocationObserver {
    /// Delivers one live ``ToolInvocationRecord`` as
    /// ``SessionEvent/toolInvocation(_:toolCallID:)``. See ``deliverLive(_:)``.
    ///
    /// An open record ends the generation call that asked for the tool, so
    /// that call's usage is reported first, and a close record starts the
    /// clock of the next generation call (see
    /// ``noteGenerationCallBoundary(at:)``).
    ///
    /// Each record is progress for the stall watch of the model call in
    /// flight: an open record is a tool call, and a close record is a tool
    /// result (task ^4799jxg).
    ///
    /// The event carries the SDK tool-call id of the call that started the
    /// run, which ``toolCallRunJoin`` finds (task ^xhmws92). For an open
    /// record, the join reads the entries that the submission in flight
    /// appended. An open record arrives while the SDK waits in the tool call,
    /// so the `.toolCalls` entry of the call is in those entries, and no call
    /// of the backend writes the transcript. A close record reads no entries:
    /// the SDK can continue when the tool returns, and the close record
    /// carries the id that its open record joined.
    ///
    /// - Parameter record: The record the outbox forwarded.
    func deliver(invocation record: ToolInvocationRecord) async {
        noteGenerationProgress(record.closedAt == nil ? .toolCall : .toolResult)
        let submissionEntries = record.closedAt == nil ? unrecordedTranscriptEntries() : []
        let toolCallID = toolCallRunJoin.toolCallID(for: record, in: submissionEntries)
        await noteGenerationCallBoundary(at: record)
        deliverLive(.toolInvocation(record, toolCallID: toolCallID))
    }

    /// Delivers one live ``ToolCallReport`` as
    /// ``SessionEvent/toolCallReport(_:)``. See ``deliverLive(_:)``.
    ///
    /// - Parameter report: The report the outbox forwarded.
    func deliver(report: ToolCallReport) {
        deliverLive(.toolCallReport(report))
    }

    /// Delivers one live ``ToolDisplayEvent`` as
    /// ``SessionEvent/toolDisplay(_:)``. See ``deliverLive(_:)``.
    ///
    /// - Parameter event: The display event the outbox forwarded.
    func deliver(display event: ToolDisplayEvent) {
        deliverLive(.toolDisplay(event))
    }
}
