/// A durable destination a session's ``SessionOutbox`` records every posted
/// ``OperationEvent`` into, at the moment it is posted.
///
/// The outbox stages events for a *future* turn — that is what it is for — so
/// on its own it can only tell the model, and the transcript, about a
/// long-running run once some later prompt drains it. A detached run whose
/// work finishes minutes after its turn ended would therefore leave no trace
/// of finishing until a person happened to say something else. This protocol
/// is the second, immediate destination that closes that hole: the outbox
/// still stages the event for the next prompt, and it also hands the event
/// here, so the transcript records the run's own report when it happened.
///
/// Class-bound because ``SessionOutbox`` holds its journal *weakly*: the only
/// implementation is the ``RoutedSessionActor`` that owns the outbox for its
/// whole life, so a strong reference back would be a cycle that keeps every
/// session — and the fork-admission permit its `deinit` releases — alive
/// forever.
protocol OperationEventJournal: AnyObject, Sendable {
    /// Records one posted event in this session's transcript, as its own
    /// entry, in the order it was posted.
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
