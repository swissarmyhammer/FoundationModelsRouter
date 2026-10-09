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
    /// - Parameter event: The event the outbox has just accepted.
    func record(event: OperationEvent) async {
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
        deliverLive(Self.liveEvent(for: event))
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
    /// ``mailbox``'s settlement observer (the Extras
    /// `BackgroundRunSettlementObserver`), once. Called by each
    /// helper that sends a message and by the pump. Idempotent.
    func attachOutboxJournalIfNeeded() async {
        guard !didAttachOutboxJournal else { return }
        didAttachOutboxJournal = true
        await outbox.attach(journal: self)
        await outbox.attach(invocationObserver: self)
        await outbox.attach(mailObserver: self)
        await mailbox.attach(settlementObserver: self)
    }
}

/// ``RoutedSessionActor``'s settlement forwarding. A background run's own
/// terminal reaches the journal under the run's own token at the moment the
/// mailbox settles the run, whether or not the run's funnel delivered it.
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
    /// The funnel of a run stages the terminal before the mailbox settles the
    /// run: the body of the run posts the terminal, waits until the post
    /// ends, and only then returns, and the mailbox settles the run when the
    /// body returns. So the terminal is staged before this call, and the
    /// wake of this call finds it. The idle check (``isIdle()``) needs this
    /// order. The sweep of a drain is the one case where the terminal is
    /// staged after the settlement: the sweep settles the run with no call
    /// here, and the body of the run stages its own terminal when it ends.
    /// The drain waits for that body, and holds that mail at its end
    /// (``drain()``). The pump delivers a terminal only when it is both
    /// staged and settled.
    ///
    /// A held terminal (``SessionOutbox/PendingEvent/isHeld``) stays held: a
    /// settlement is no new mail, and the forward of it can come after a
    /// submission already took the terminal and gave it back.
    ///
    /// The settlement is a change of the work of the session
    /// (``signalWorkChange()``): a run that settles while a drain runs
    /// starts no pump, so the pump does not report it.
    ///
    /// - Parameter terminal: The terminal the mailbox forwarded.
    func deliver(settledTerminal terminal: OperationEvent) async {
        await outbox.journalWithoutStaging(event: terminal)
        wakePump()
        signalWorkChange()
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
