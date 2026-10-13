import FoundationModelsExtras

/// ``RoutedSessionActor``'s mail records (`mailbox.md`, section 5, problems
/// 10 and 14): the transcript keeps each fact about the mail of the session.
///
/// - ``mail(_:)`` records ``MailRecord/mailQueued(_:)``.
/// - The signal ``replace(_:with:)`` records ``MailRecord/replaced(_:body:)``.
/// - Each terminal event of a mail that the output of the session sends
///   records ``MailRecord/answerEnded(_:)``, ``MailRecord/cancelled(_:)`` or
///   ``MailRecord/lost(_:)`` (``emitSessionScopedEvent(_:failure:audience:)``).
/// - The delivery of a mail is a segment of the recorded `.prompt` entry of
///   its submission, not a record of this chain
///   (``RoutedSessionActor/attachingDeliveredMailRecords(_:to:)``).
///
/// The callers of these records are often not on the actor, and they do not
/// wait. So each record goes on one serial chain (``mailRecordChain``), and
/// the chain writes the records in the order of the calls. The diff of a
/// submission and ``close()`` wait for the chain first
/// (``flushMailRecords()``), so each record that came before them is on disk
/// before them.
extension RoutedSessionActor {
    /// Puts `records` on the chain, as one ``TranscriptEvent/Kind/mail``
    /// event. The call does not wait for the write.
    ///
    /// - Parameter records: The records, in order. No event is written when
    ///   it is empty.
    nonisolated func recordMail(_ records: [MailRecord]) {
        guard !records.isEmpty else { return }
        mailRecordChain.withLock { chain in
            _ = chain.enqueue { await self.appendMailRecords(records) }
        }
    }

    /// Waits until each record that came before this call is written.
    func flushMailRecords() async {
        let tail = mailRecordChain.withLock { chain in chain.enqueue {} }
        await tail.value
    }

    /// Sends the terminal event ``SessionEvent/lost(_:)`` of each mail of
    /// `ids`, and waits until each record of a lost mail is written. A
    /// restore calls it for each mail that a crash cut off
    /// (``TranscriptTree/lostMail(in:ofSession:)``), so a second restore
    /// finds the record and sends no second terminal event.
    ///
    /// The mail does not go back to the queue: a restore does not run the
    /// work of a mail again, so no tool side effect runs a second time.
    ///
    /// - Parameter ids: The ids of the lost mail, in the order of the
    ///   transcript.
    func reportLostMail(_ ids: [MailID]) async {
        for id in ids {
            OriginContext.$current.withValue(.mail([id])) {
                emitSessionScopedEvent(.lost(id))
            }
        }
        await flushMailRecords()
    }

    /// The records of the terminal event `event` for each mail id of
    /// `ended`.
    ///
    /// - Parameters:
    ///   - event: An event that the output of the session sent.
    ///   - ended: The ids that the event ended
    ///     (``SessionOutputHub/emit(_:failure:audience:)``).
    /// - Returns: One record for each mail id of `ended`, in order.
    static func terminalRecords(of event: SessionEvent, ending ended: [SessionOutputHub.TerminalKey]) -> [MailRecord] {
        ended.compactMap { key in
            guard case .mail(let id) = key else { return nil }
            return MailRecord(terminal: event, of: id)
        }
    }

    /// Writes one ``TranscriptEvent/Kind/mail`` event that holds `records`.
    ///
    /// The write leaves the open merged progress row as it is
    /// (``appendToRecorder(_:)``): a mail record is not rendered, so its
    /// place beside the progress events of a run does not matter, and the
    /// row keeps the progress events of its run together.
    ///
    /// - Parameter records: The records, in order.
    private func appendMailRecords(_ records: [MailRecord]) async {
        await recordSessionMetaIfNeeded()
        await appendToRecorder(
            makePartialEvent(
                kind: .mail, grammar: grammar, text: records.map(\.summary).joined(separator: "\n"),
                entry: MailRecordSegment.eventPayload(of: records)))
    }
}
