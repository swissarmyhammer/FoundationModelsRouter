import FoundationModelsExtras

/// Why a wait for a terminal event ended with no terminal event
/// (``RoutedSession/awaitTerminal(of:)-(MailID)``,
/// ``RoutedSession/awaitAnswer(of:)`` and
/// ``RoutedSession/awaitTerminal(of:)-(SignalID)``).
///
/// The session has no record of the id. A record is in one of two places:
///
/// - The id waits for its terminal event: mail that is in the queue or in
///   the answer that runs, and a signal whose work waits or runs.
/// - The ledger of the terminal events keeps its terminal event. The ledger
///   keeps the 4096 most recent ids, and the oldest id leaves first.
///
/// An id in neither place left the ledger, or the session never knew it,
/// for example a new `MailID()` that no ``RoutedSession/mail(_:)`` call
/// sent. The session cannot tell these two cases apart, so both get this
/// error. No terminal event can come for such an id, so the wait ends at
/// once and does not wait until ``RoutedSession/close()``.
public enum TerminalLookupError: Error, Sendable, Equatable {
    /// The session has no record of the mail with this id: its terminal
    /// event left the ledger, or the session never knew the id.
    case unknownMail(MailID)

    /// The session has no record of the signal with this id: its terminal
    /// event left the ledger, or the session never knew the id.
    case unknownSignal(SignalID)
}
