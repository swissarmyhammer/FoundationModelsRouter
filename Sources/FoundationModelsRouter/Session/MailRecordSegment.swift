import Foundation
import FoundationModels

/// One fact about one mail, as the recorded transcript keeps it
/// (`mailbox.md`, section 5, problems 10 and 14).
///
/// The session writes a record when a mail enters the queue, when the pump
/// delivers it, when a signal changes it, and when it gets its terminal
/// event. ``ContextRenderer`` renders only ``mailDelivered(_:)``: the other
/// records are for audit, for a restore and for tests.
enum MailRecord: Codable, Equatable, Sendable {
    /// ``RoutedSession/mail(_:)`` put the mail in the queue. Not rendered.
    case mailQueued(Mail)

    /// The pump took the mail for a submission. The record is a segment of
    /// the recorded `.prompt` entry of that submission, in take order, and
    /// the text of that entry is the render of these records
    /// (``ContextRenderer/promptText(delivering:followedBy:)``).
    case mailDelivered(Mail)

    /// The signal ``RoutedSession/replace(_:with:)`` changed the body of the
    /// queued mail. Not rendered.
    case replaced(MailID, body: MailBody)

    /// The terminal event ``SessionEvent/cancelled(_:)`` of the mail. Not
    /// rendered.
    case cancelled(MailID)

    /// The terminal event ``SessionEvent/answered(_:)`` or
    /// ``SessionEvent/answerFailed(_:)`` of the answer that delivered the
    /// mail. Not rendered.
    case answerEnded(MailID)

    /// The terminal event ``SessionEvent/lost(_:)`` that a restore sent for
    /// the mail. Not rendered.
    case lost(MailID)

    /// The id of the mail that the record is about.
    var mailID: MailID {
        switch self {
        case .mailQueued(let mail), .mailDelivered(let mail):
            return mail.id
        case .replaced(let id, _), .cancelled(let id), .answerEnded(let id), .lost(let id):
            return id
        }
    }

    /// Whether the record is the terminal event of its mail. After a
    /// terminal record, the mail is not open: a restore does not report it
    /// lost.
    var isTerminal: Bool {
        switch self {
        case .mailQueued, .mailDelivered, .replaced:
            return false
        case .cancelled, .answerEnded, .lost:
            return true
        }
    }

    /// The record of the terminal event `event` for the mail `id`, or `nil`
    /// when `event` is not the terminal event of a mail.
    ///
    /// - Parameters:
    ///   - event: An event that the output of the session sent.
    ///   - id: The id of a mail that `event` ends.
    init?(terminal event: SessionEvent, of id: MailID) {
        switch event {
        case .answered, .answerFailed:
            self = .answerEnded(id)
        case .cancelled:
            self = .cancelled(id)
        case .lost:
            self = .lost(id)
        default:
            return nil
        }
    }

    /// A short text for the record, with the id and the kind of the mail
    /// and no content of the mail. The text of a
    /// ``TranscriptEvent/Kind/mail`` event is the summary of each of its
    /// records, one line for each.
    var summary: String {
        switch self {
        case .mailQueued(let mail):
            return "mail \(mail.id) queued (\(mail.body.kind.rawValue))"
        case .mailDelivered(let mail):
            return "mail \(mail.id) delivered (\(mail.body.kind.rawValue))"
        case .replaced(let id, let body):
            return "mail \(id) replaced (\(body.kind.rawValue))"
        case .cancelled(let id):
            return "mail \(id) cancelled"
        case .answerEnded(let id):
            return "mail \(id) answer ended"
        case .lost(let id):
            return "mail \(id) lost"
        }
    }
}

/// A ``PersistableStructuredSegment`` that records one ``MailRecord``.
///
/// A ``MailRecord/mailDelivered(_:)`` record is a segment of the recorded
/// `.prompt` entry of the submission that delivered the mail. Each other
/// record is a segment of a ``TranscriptEvent/Kind/mail`` event, which
/// mirrors no transcript entry. The segment travels under the schema name
/// `FoundationModelsRouter.MailRecordSegment`.
struct MailRecordSegment: PersistableStructuredSegment, Equatable, Sendable {
    /// The stable name that identifies this segment on disk.
    static let schemaName = "FoundationModelsRouter.MailRecordSegment"

    /// The unique identifier of this segment.
    let id: String

    /// The record this segment carries.
    let content: MailRecord

    /// Creates a segment that wraps `content`.
    ///
    /// - Parameters:
    ///   - id: The segment's id. Defaults to a fresh UUID.
    ///   - content: The record.
    init(id: String = UUID().uuidString, content: MailRecord) {
        self.id = id
        self.content = content
    }

    /// The payload of one ``TranscriptEvent/Kind/mail`` event that records
    /// `records`, one segment for each record, in order. The payload's entry
    /// id is a new ULID, because the event mirrors no transcript entry.
    ///
    /// - Parameter records: The records of the event.
    /// - Returns: The payload.
    static func eventPayload(of records: [MailRecord]) -> TranscriptEntryPayload {
        TranscriptEntryPayload(
            entryId: ULID.generate().description,
            segments: records.map { TranscriptEntryMapper.segmentPayload(MailRecordSegment(content: $0)) })
    }

    /// `entry` with no ``MailRecordSegment`` in it, when it is a `.prompt`
    /// entry. The text of a `.prompt` entry is already the render of its
    /// delivered mail, so the model reads the mail once. Every other entry,
    /// and every other segment, stays as it is.
    ///
    /// - Parameter entry: An entry of a transcript that goes to a backend.
    /// - Returns: The entry, with the mail records removed.
    static func removingRecords(from entry: Transcript.Entry) -> Transcript.Entry {
        guard case .prompt(let prompt) = entry else { return entry }
        let kept = prompt.segments.filter { segment in
            guard case .structure(let structure) = segment else { return true }
            return structure.schemaName != schemaName
        }
        guard kept.count != prompt.segments.count else { return entry }
        return .prompt(
            Transcript.Prompt(id: prompt.id, segments: kept, options: prompt.options, responseFormat: prompt.responseFormat))
    }
}

extension TranscriptEvent {
    /// Every ``MailRecord`` this event's entry carries, in segment order: the
    /// records of a ``Kind/mail`` event, and the
    /// ``MailRecord/mailDelivered(_:)`` records of a `.prompt` event.
    ///
    /// The read is total. A segment under another schema name, and a segment
    /// whose body does not decode, are each passed over.
    var mailRecords: [MailRecord] {
        structureContents(named: MailRecordSegment.schemaName, as: MailRecord.self)
    }

    /// The decoded body of each persisted structure segment of this event's
    /// entry under `schemaName`, in segment order.
    ///
    /// The read is total. A segment of another case, a segment under another
    /// schema name, and a segment whose body does not decode are each passed
    /// over, so one unreadable segment never costs the caller the rest of the
    /// entry.
    ///
    /// - Parameters:
    ///   - schemaName: The schema name of the segments to read.
    ///   - type: The type of the body of those segments.
    /// - Returns: The decoded bodies.
    func structureContents<Content: Decodable>(named schemaName: String, as type: Content.Type) -> [Content] {
        (entry?.segments ?? []).compactMap { segment in
            guard let structure = segment.persistedStructure, structure.schemaName == schemaName else { return nil }
            return try? JSONDecoder().decode(type, from: Data(structure.contentJSON.utf8))
        }
    }
}
