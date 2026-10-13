import FoundationModelsExtras

extension TranscriptTree {
    /// The ids of the mail of the session `id` that a crash cut off: each
    /// mail that the transcript holds as queued (``MailRecord/mailQueued(_:)``)
    /// or delivered (``MailRecord/mailDelivered(_:)``), and that no later
    /// terminal record ends (``MailRecord/isTerminal``). A restore sends one
    /// ``SessionEvent/lost(_:)`` for each (`mailbox.md`, section 5, problem
    /// 14).
    ///
    /// The scan reads the records in transcript order, so a caller that used
    /// an id again after its terminal event opens a new mail with that id.
    /// Only the records of the session itself count: the prefix that a fork
    /// inherits from its parent holds the mail of the parent, and the parent
    /// reports its own mail.
    ///
    /// - Parameters:
    ///   - events: The effective events of the session, in `seq` order, with
    ///     the ``TranscriptEvent/Kind/mail`` events.
    ///   - id: The id of the session.
    /// - Returns: The ids of the lost mail, in the order of their last open
    ///   record.
    static func lostMail(in events: [TranscriptEvent], ofSession id: ULID) -> [MailID] {
        var open: [MailID] = []
        for record in events.filter({ $0.sessionId == id }).flatMap(\.mailRecords) {
            open.removeAll { $0 == record.mailID }
            if !record.isTerminal {
                open.append(record.mailID)
            }
        }
        return open
    }
}
