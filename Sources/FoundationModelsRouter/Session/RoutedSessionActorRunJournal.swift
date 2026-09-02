import FoundationModels

/// ``RoutedSessionActor``'s run journal: a long-running operation's reports
/// (progress, elicitation, completion) become transcript entries at the
/// moment they are made.
extension RoutedSessionActor: OperationEventJournal {
    /// Records one posted ``OperationEvent`` as its own entry, in post order.
    /// Entries of one run can interleave with a turn's entries. A terminal is
    /// also delivered live as ``SessionEvent/runSettled(_:)``.
    ///
    /// - Parameter event: The event the outbox has just accepted.
    func record(event: OperationEvent) async {
        guard claimJournalWrite(for: event) else { return }
        await recordSessionMetaIfNeeded()
        await append(partial: makeRunEventPartial(for: event))
        if event.kind == .completed {
            deliverLive(.runSettled(event))
        }
    }

    /// Hands `event` to the turn in flight, or to the session-scoped feed
    /// between turns.
    ///
    /// - Parameter event: The event to deliver.
    func deliverLive(_ event: SessionEvent) {
        if let currentTurnEventSink {
            currentTurnEventSink(event)
        } else {
            emitSessionScopedEvent(event)
        }
    }

    /// Whether `event` may be journaled. A run's one terminal (`.completed`)
    /// is claimed on first write; a second terminal for the same run is
    /// refused. Progress and elicitation events are always admitted. The
    /// claim is taken synchronously, before any suspension.
    ///
    /// - Parameter event: The event about to be journaled.
    /// - Returns: `false` when `event` is a terminal for a run whose ending is
    ///   already recorded; `true` otherwise.
    func claimJournalWrite(for event: OperationEvent) -> Bool {
        guard event.kind == .completed else { return true }
        return journaledTerminalCorrelationIDs.insert(event.correlationID).inserted
    }

    /// Builds the recorded partial for one ``OperationEvent``: a `.toolOutput`
    /// entry with a fresh ULID id and a typed ``OperationEventSegment``. The
    /// run's `correlationID` travels in the payload, not in the entry id. The
    /// body text is ``OperationEventSegment/renderedLine(for:)``.
    ///
    /// - Parameter event: The event to journal.
    /// - Returns: The partial for the recorder to stamp and append.
    func makeRunEventPartial(for event: OperationEvent) -> TranscriptEvent.Partial {
        let entry = Transcript.Entry.toolOutput(
            Transcript.ToolOutput(
                id: ULID.generate().description,
                toolName: event.tool,
                segments: [OperationEventSegment(content: event).transcriptSegment]
            )
        )
        let (kind, payload, _) = TranscriptEntryMapper.event(from: entry)
        return makePartialEvent(
            kind: kind, text: OperationEventSegment.renderedLine(for: event), entry: payload)
    }

    /// Installs this session as ``outbox``'s ``OperationEventJournal`` and
    /// ``ToolInvocationObserver``, and as ``mailbox``'s
    /// ``BackgroundRunSettlementObserver``, once. Called from ``beginTurn()``.
    /// Idempotent.
    func attachOutboxJournalIfNeeded() async {
        guard !didAttachOutboxJournal else { return }
        didAttachOutboxJournal = true
        await outbox.attach(journal: self)
        await outbox.attach(invocationObserver: self)
        await mailbox.attach(settlementObserver: self)
    }
}

/// ``RoutedSessionActor``'s settlement forwarding. A background run's own
/// terminal reaches the journal under the run's own token at the moment the
/// mailbox settles the run, whether or not the run's funnel delivered it.
extension RoutedSessionActor: BackgroundRunSettlementObserver {
    /// Journals one naturally settled run's terminal without staging it.
    ///
    /// `journalWithoutStaging`, not `post(event:)`: `post` would stage a
    /// second pending `.completed` for a top-level run whose funnel already
    /// staged one. The write joins the outbox's FIFO journal chain, and the
    /// journal refuses it when the funnel's copy already claimed the
    /// correlation. See ``claimJournalWrite(for:)``.
    ///
    /// - Parameter terminal: The terminal the mailbox forwarded.
    func deliver(settledTerminal terminal: OperationEvent) async {
        await outbox.journalWithoutStaging(event: terminal)
    }
}

/// ``RoutedSessionActor``'s live invocation delivery. A
/// ``ToolInvocationRecord`` becomes a ``SessionEvent/toolInvocation(_:)`` and
/// a ``ToolCallReport`` becomes a ``SessionEvent/toolCallReport(_:)`` the
/// moment it is posted. Delivery only: neither is ever journaled.
extension RoutedSessionActor: ToolInvocationObserver {
    /// Delivers one live ``ToolInvocationRecord`` as
    /// ``SessionEvent/toolInvocation(_:)``. See ``deliverLive(_:)``.
    ///
    /// - Parameter record: The record the outbox forwarded.
    func deliver(invocation record: ToolInvocationRecord) {
        deliverLive(.toolInvocation(record))
    }

    /// Delivers one live ``ToolCallReport`` as
    /// ``SessionEvent/toolCallReport(_:)``. See ``deliverLive(_:)``.
    ///
    /// - Parameter report: The report the outbox forwarded.
    func deliver(report: ToolCallReport) {
        deliverLive(.toolCallReport(report))
    }
}
