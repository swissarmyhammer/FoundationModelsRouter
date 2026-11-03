import Foundation

/// The restore of the user messages that a crash left in flight.
///
/// The session records one ``TranscriptEvent/Kind/promptStarted`` marker when
/// the pump takes the user-type mail of a submission, before the model runs.
/// The `.prompt` entry of the submission follows at the end of the
/// submission, and it holds one ``MailRecord/mailDelivered(_:)`` record for
/// each mail it delivered. A restore reads the markers in this way:
///
/// - A mail that a later `.prompt` entry delivers is covered. The entry is
///   the record of the message, so the restore does not use the mail of the
///   marker.
/// - A mail that a later terminal record ends is covered too:
///   ``MailRecord/cancelled(_:)`` and ``MailRecord/answerEnded(_:)``. The
///   mail left the submission with no `.prompt` entry, so no message is in
///   flight. The record ``MailRecord/lost(_:)`` does not cover. A restore
///   writes it for the mail that the crash cut off, and the message must
///   stay in the transcript after a second restore.
/// - A mail that no later record covers is open. The process ended before
///   the submission wrote its entries. The restore turns the open mail of a
///   marker into one `.prompt` entry at the place of the marker, with the
///   texts of the open mail. The transcript then ends with the user message
///   that waits for its answer. The open tool calls that follow the marker
///   come after it (``OpenToolCalls``).
///
/// A marker with no open mail is dropped.
enum OpenPrompts {
    /// The prefix of the entry id of a ``TranscriptEvent/Kind/promptStarted``
    /// marker. The id of the first mail follows it. The entry id of the
    /// marker is not the id of any entry of the transcript.
    private static let markerEntryIDPrefix = "prompt-started-"

    /// The prefix of the id of the `.prompt` entry that a restore makes. The
    /// id ends with the id of the first open mail, so it is the same at each
    /// restore of the same recording.
    private static let openEntryIDPrefix = "open-prompt-"

    /// The suffix of the id of the text segment of the `.prompt` entry that a
    /// restore makes.
    private static let textSegmentSuffix = "-text"

    /// The text and the payload of the marker of the mail `mails`.
    ///
    /// The text is the text of the user messages, joined as the `.prompt`
    /// entry of their submission joins them
    /// (``ContextRenderer/blockSeparator``). The payload holds one
    /// ``MailRecord/mailDelivered(_:)`` record for each mail, so the id and
    /// the content of each mail are on disk.
    ///
    /// - Parameter mails: The user-type mail that the pump took, in take
    ///   order. A mail with no prompt text adds a record and no text.
    /// - Returns: The text and the payload of the marker.
    static func marker(of mails: [Mail]) -> (text: String, entry: TranscriptEntryPayload) {
        let text = mails.compactMap(\.promptText).joined(separator: ContextRenderer.blockSeparator)
        let records = mails.map {
            TranscriptEntryMapper.segmentPayload(MailRecordSegment(content: .mailDelivered($0)))
        }
        let firstID = mails.first.map { "\($0.id)" } ?? ""
        return (text, TranscriptEntryPayload(entryId: markerEntryIDPrefix + firstID, segments: records))
    }

    /// `events`, with each covered marker dropped and each marker with open
    /// mail turned into a `.prompt` entry.
    ///
    /// - Parameter events: The events of one session, in `seq` order.
    /// - Returns: The events with no prompt marker.
    static func folding(_ events: [TranscriptEvent]) -> [TranscriptEvent] {
        let coveredAt = lastCoveringIndex(in: events)
        return events.enumerated().compactMap { index, event in
            guard event.kind == .promptStarted else { return event }
            return openPrompt(of: event, at: index, coveredAt: coveredAt)
        }
    }

    /// The index of the last event that covers each mail id: a `.prompt`
    /// event that delivers the mail, or a `.mail` event that ends it.
    ///
    /// - Parameter events: The events of one session.
    /// - Returns: The index of the newest covering event, by mail id.
    private static func lastCoveringIndex(in events: [TranscriptEvent]) -> [MailID: Int] {
        var coveredAt: [MailID: Int] = [:]
        for (index, event) in events.enumerated() where event.kind == .prompt || event.kind == .mail {
            for record in event.mailRecords where covers(record) {
                coveredAt[record.mailID] = index
            }
        }
        return coveredAt
    }

    /// Whether `record` covers the open marker of its mail.
    ///
    /// - Parameter record: A mail record of a `.prompt` or `.mail` event.
    /// - Returns: `true` for a delivery, a cancel and the end of the answer.
    private static func covers(_ record: MailRecord) -> Bool {
        switch record {
        case .mailDelivered, .cancelled, .answerEnded:
            return true
        case .mailQueued, .replaced, .lost:
            return false
        }
    }

    /// The `.prompt` event that replaces `marker`, or `nil` when no mail of
    /// the marker is open.
    ///
    /// - Parameters:
    ///   - marker: A ``TranscriptEvent/Kind/promptStarted`` event.
    ///   - index: The position of the marker among the events.
    ///   - coveredAt: The index of the last covering event, by mail id.
    /// - Returns: The event, with the provenance, the `seq` and the time of
    ///   the marker.
    private static func openPrompt(
        of marker: TranscriptEvent, at index: Int, coveredAt: [MailID: Int]
    ) -> TranscriptEvent? {
        let open = marker.takenMail.filter { (coveredAt[$0.id] ?? -1) < index }
        let texts = open.compactMap(\.promptText)
        guard let first = open.first, !texts.isEmpty else { return nil }
        let entryID = openEntryIDPrefix + "\(first.id)"
        let text = texts.joined(separator: ContextRenderer.blockSeparator)
        return OpenToolCalls.rekinded(
            marker, as: .prompt, text: text,
            entry: TranscriptEntryPayload(
                entryId: entryID, segments: [.text(id: entryID + textSegmentSuffix, content: text)]))
    }
}
