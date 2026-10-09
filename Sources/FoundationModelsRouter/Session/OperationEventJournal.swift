/// A durable destination a session's `SessionOutbox` records every posted
/// ``OperationEvent`` into, at the moment it is posted.
///
/// The outbox stages events for a *future* submission — that is what it is for — so
/// on its own it can only tell the model, and the transcript, about a
/// long-running run once some later prompt drains it. A background run whose
/// work finishes minutes after its answer ended would therefore leave no trace
/// of finishing until a person happened to say something else. This protocol
/// is the second, immediate destination that closes that hole: the outbox
/// still stages the event for the next prompt, and it also hands the event
/// here, so the transcript records the run's own report when it happened.
///
/// Class-bound because `SessionOutbox` holds its journal *weakly*: the only
/// implementation is the ``RoutedSessionActor`` that owns the outbox for its
/// whole life, so a strong reference back would be a cycle that keeps every
/// session alive forever.
protocol OperationEventJournal: AnyObject, Sendable {
    /// Records one posted event in this session's transcript, in the order it
    /// was posted. Consecutive progress events of one run can share one
    /// merged entry; each event stays whole in it (task ^zze1067).
    ///
    /// Idempotent per run *ending*: a run reports exactly one terminal
    /// (`.completed`) event, so a second terminal for a `correlationID` whose
    /// ending is already recorded is refused rather than appended. Nothing
    /// already appended is ever mutated or removed to achieve that — see
    /// ``RoutedSessionActor/claimJournalWrite(for:)`` for the two independent
    /// writers this exists to reconcile.
    ///
    /// - Parameter event: The event the outbox has just accepted.
    func record(event: OperationEvent) async
}

/// A live destination a session's `SessionOutbox` forwards every posted
/// ``ToolInvocationRecord`` and ``ToolCallReport`` to, at the moment it is
/// posted.
///
/// The delivery-only counterpart of ``OperationEventJournal``, and installed
/// at the same attach point (``RoutedSessionActor/attachOutboxJournalIfNeeded()``,
/// at the top of every answer): where the journal *records* an event in the
/// transcript, this observer only *delivers* the record live, as
/// ``SessionEvent/toolInvocation(_:toolCallID:)`` or ``SessionEvent/toolCallReport(_:)``
/// — neither is ever staged or recorded, so the post-submission diff stays the one
/// recording authority.
///
/// Class-bound because `SessionOutbox` holds its observer *weakly*, for the
/// same reference-cycle reason ``OperationEventJournal`` documents: the only
/// implementation is the ``RoutedSessionActor`` that owns the outbox for its
/// whole life.
///
/// The tool decorators of FoundationModelsExtras post each report to the
/// outbox through the Extras protocol `ToolCallReportSink`, and each settled
/// background run to the session through the Extras protocol
/// `BackgroundRunSettlementObserver`. The router conforms to both and
/// declares neither.
protocol ToolInvocationObserver: AnyObject, Sendable {
    /// Delivers one posted invocation record live to this session's event
    /// consumers.
    ///
    /// - Parameter record: The record the outbox has just received.
    func deliver(invocation record: ToolInvocationRecord) async

    /// Delivers one posted tool call report live to this session's event
    /// consumers.
    ///
    /// - Parameter report: The report the outbox has just received.
    func deliver(report: ToolCallReport) async
}
