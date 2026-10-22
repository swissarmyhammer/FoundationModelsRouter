import Foundation
import FoundationModelsExtras
import Logging

/// The record of the messages that ``RouterSessionDirectory`` delivered to
/// one session (ROUTER-4): each ``SessionMessage`` with the sender, the
/// `inReplyTo`, the chain depth and the read flag.
///
/// `Mail` has only an id, a sender and a body, and ``MailSender/user`` holds
/// no client id, so the ledger, not the mail, keeps what the message adds. The
/// sender of a message holds the client id of a UI sender
/// (``SessionMessageSender/user(clientID:)``).
///
/// A durable session keeps its ledger in `messages.jsonl` in its recording
/// directory, so its inbox outlives a restore. The file is append-only and
/// goes through the Extras `JSONLFile` (``JSONLAppend``): one line for each
/// delivered message, and one later line for each read mark. A write is best
/// effort, as each JSONL sink of the module is
/// (``JSONLAppend/appendDroppingFailure(_:to:through:logger:failureMessage:failureMetadata:)``):
/// a failure is logged and the line dropped. A memory-only session writes
/// nothing to disk, so its ledger has no directory and lives in memory.
struct SessionMessageLedger: Sendable {
    /// The name of the ledger file in the recording directory of a session.
    static let fileName = "messages.jsonl"

    /// One line of `messages.jsonl`.
    enum Line: Codable, Equatable {
        /// The directory delivered a message to the session.
        case delivered(message: SessionMessage)

        /// The session read the message with this id.
        case read(id: MailID)
    }

    /// `date` at the precision a line of the ledger keeps: the ISO 8601 date
    /// of a `JSONLFile` line holds milliseconds, the text of the Extras
    /// `DateTime`. A message stamped with this instant reads back from the
    /// file equal to the message in memory.
    ///
    /// - Parameter date: An instant.
    /// - Returns: The instant rounded to the nearest millisecond, as the line
    ///   writes it.
    static func recordedInstant(of date: Date) -> Date {
        MillisecondDate.rounded(date)
    }

    /// The messages to the session, in the order of their delivery, each with
    /// its read flag.
    private var messages: [SessionMessage]

    /// The recording directory that holds `messages.jsonl`, or `nil` for a
    /// memory-only ledger.
    private let directory: URL?

    /// Makes a ledger.
    ///
    /// - Parameters:
    ///   - messages: The messages, in the order of their delivery.
    ///   - directory: The recording directory of the file, or `nil` for a
    ///     memory-only ledger.
    private init(messages: [SessionMessage], directory: URL?) {
        self.messages = messages
        self.directory = directory
    }

    /// Reads the ledger of a session.
    ///
    /// The read goes through the Extras `JSONLFile`: a torn final line is
    /// dropped with a warning, and a whole line that does not decode is
    /// skipped with a warning. Neither throws.
    ///
    /// - Parameter directory: The recording directory of a durable session,
    ///   or `nil` for a memory-only session.
    /// - Returns: The messages of `messages.jsonl` in `directory` with their
    ///   read marks applied, an empty ledger when the file is absent, or an
    ///   empty memory-only ledger when `directory` is `nil`.
    /// - Throws: `JSONLFileError.readFailed(description:)` when the file
    ///   exists and does not read.
    static func load(from directory: URL?) throws -> SessionMessageLedger {
        var ledger = SessionMessageLedger(messages: [], directory: directory)
        guard let file = ledger.file else { return ledger }
        for line in try JSONLFile(url: file).records(as: Line.self) {
            ledger.apply(line)
        }
        return ledger
    }

    /// The messages that are not read, in the order of their delivery.
    var unread: [SessionMessage] {
        messages.filter { !$0.isRead }
    }

    /// The message with an id, read or not read.
    ///
    /// - Parameter id: The id of the message.
    /// - Returns: The message, or `nil` when the ledger holds no message with
    ///   the id.
    func message(_ id: MailID) -> SessionMessage? {
        messages.first { $0.id == id }
    }

    /// Records a delivered message, and appends its line to the file.
    ///
    /// - Parameter message: The delivered message.
    mutating func record(_ message: SessionMessage) {
        write(.delivered(message: message))
    }

    /// Marks messages read, and appends one line to the file for each.
    ///
    /// - Parameter ids: The ids of the messages. An id the ledger does not
    ///   hold, and the id of a message that is read already, change nothing
    ///   and write no line.
    mutating func markRead(_ ids: [MailID]) {
        for id in ids where message(id)?.isRead == false {
            write(.read(id: id))
        }
    }

    /// Applies `line` to the messages, and appends it to the file of a
    /// durable ledger.
    ///
    /// - Parameter line: The line.
    private mutating func write(_ line: Line) {
        apply(line)
        guard let file else { return }
        JSONLAppend.appendDroppingFailure(
            line,
            to: file,
            logger: RouterTelemetry.makeLogger(.sessionDirectory),
            failureMessage: "dropping a line of a message ledger",
            failureMetadata: [RouterTelemetry.LogMetadataKey.filePath: "\(file.path)"])
    }

    /// Applies `line` to the messages: a delivery adds its message, and a
    /// read mark sets the read flag of its message.
    ///
    /// - Parameter line: A line of the ledger.
    private mutating func apply(_ line: Line) {
        switch line {
        case .delivered(let message):
            messages.append(message)
        case .read(let id):
            guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
            messages[index].isRead = true
        }
    }

    /// The file of a durable ledger, or `nil` for a memory-only ledger.
    private var file: URL? {
        directory?.appendingPathComponent(Self.fileName, isDirectory: false)
    }
}
