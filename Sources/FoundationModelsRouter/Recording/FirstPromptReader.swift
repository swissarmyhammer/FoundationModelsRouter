import Foundation
import FoundationModelsExtras

/// Reads the first prompt of a recorded session without a restore.
///
/// The read opens the `transcript.jsonl` of the session and reads it in
/// chunks. It decodes line by line and stops at the first
/// ``TranscriptEvent/Kind/prompt`` event, so it loads no later line, no other
/// session and no tree. A fork has no prompt of its own before its cut, so
/// the read goes up the folders of its parents, up to the cut of each fork,
/// as ``TranscriptTree/effectiveEntryEvents(forSession:alongWith:)`` does.
enum FirstPromptReader {
    /// The number of bytes in one kibibyte.
    private static let bytesPerKibibyte = 1024

    /// The number of kibibytes of one read of the transcript.
    private static let chunkKibibytes = 64

    /// The number of bytes of one read of the transcript.
    private static let chunkByteCount = chunkKibibytes * bytesPerKibibyte

    /// The byte that ends each line of a JSONL file.
    private static let lineEnd = UInt8(ascii: "\n")

    /// The Cocoa codes that mean the file is not there: the open of a missing
    /// file gives the first, a read of one gives the second.
    private static let missingFileCodes: Set<CocoaError.Code> = [.fileNoSuchFile, .fileReadNoSuchFile]

    /// What a scan of the effective events of one session found.
    private enum Scan {
        /// The first prompt event, with its body.
        case found(String?)

        /// No prompt event in the events that the scan was allowed to read.
        /// Holds the count of entry-kind events that the scan counted.
        case exhausted(entries: Int)
    }

    /// The first prompt of the session in `folder`.
    ///
    /// - Parameter folder: The recording folder of the session.
    /// - Returns: The body of the first prompt, or `nil`.
    /// - Throws: See ``firstPrompt(ofSessionIn:record:)``, and
    ///   ``TranscriptTreeError/indexMissing(directory:)`` or
    ///   ``TranscriptTreeError/indexUnreadable(directory:)`` for the
    ///   `index.md` of the folder.
    static func firstPrompt(ofSessionIn folder: URL) throws -> String? {
        try firstPrompt(ofSessionIn: folder, record: try requiredRecord(in: folder))
    }

    /// The first prompt of the session in `folder`, whose record is known.
    ///
    /// - Parameters:
    ///   - folder: The recording folder of the session.
    ///   - record: The record of the session.
    /// - Returns: The body of the first prompt, or `nil`.
    /// - Throws: The errors of the `index.md` of a parent folder (as above),
    ///   ``RecordingSchemaVersionError`` for a record of a newer router, and
    ///   `JSONLFileError.readFailed(description:)` for a transcript that
    ///   exists and does not read.
    static func firstPrompt(ofSessionIn folder: URL, record: SessionRecord) throws -> String? {
        guard case .found(let body) = try scan(folder, record: record, entryLimit: nil) else { return nil }
        return body
    }

    /// Scans the effective events of one session in order: the events of its
    /// parent up to its fork cut, then its own events.
    ///
    /// - Parameters:
    ///   - folder: The recording folder of the session.
    ///   - record: The record of the session.
    ///   - entryLimit: The most entry-kind events that the scan may count, or
    ///     `nil` for no limit.
    /// - Returns: The first prompt, or the count of the entry-kind events.
    private static func scan(_ folder: URL, record: SessionRecord, entryLimit: Int?) throws -> Scan {
        var entries = 0
        if let cut = record.effectiveForkCut {
            let parentFolder = folder.deletingLastPathComponent()
            let parentRecord = try requiredRecord(in: parentFolder)
            switch try scan(parentFolder, record: parentRecord, entryLimit: min(cut, entryLimit ?? cut)) {
            case .found(let body):
                return .found(body)
            case .exhausted(let parentEntries):
                entries = parentEntries
            }
        }
        var body: String??
        try forEachEvent(in: folder.appendingPathComponent(transcriptFileName, isDirectory: false)) { event in
            if event.kind.isEntryKind {
                if let entryLimit, entries >= entryLimit { return false }
                entries += 1
            }
            guard event.kind == .prompt else { return true }
            body = .some(event.promptBody)
            return false
        }
        return body.map(Scan.found) ?? .exhausted(entries: entries)
    }

    /// The record of the session in `folder`.
    ///
    /// - Parameter folder: The recording folder of the session.
    /// - Returns: The record.
    /// - Throws: ``TranscriptTreeError/indexMissing(directory:)``,
    ///   ``TranscriptTreeError/indexUnreadable(directory:)``, or
    ///   ``RecordingSchemaVersionError`` for a record of a newer router,
    ///   which is no damage and stays typed apart from it.
    private static func requiredRecord(in folder: URL) throws -> SessionRecord {
        let record: SessionRecord?
        do {
            record = try SessionIndexFile.read(in: folder)
        } catch let error as RecordingSchemaVersionError {
            throw error
        } catch {
            throw TranscriptTreeError.indexUnreadable(directory: folder)
        }
        guard let record else { throw TranscriptTreeError.indexMissing(directory: folder) }
        return record
    }

    /// Gives the events of the JSONL file at `file` to `body`, one by one in
    /// the order of the lines, until `body` answers `false`. The file is read
    /// in chunks, so a stop leaves the rest of the file unread.
    ///
    /// A line that does not decode is skipped, and the bytes after the last
    /// line end, a torn final line, are dropped, as the Extras `JSONLFile`
    /// reads them. A file that does not exist has no events.
    ///
    /// - Parameters:
    ///   - file: The JSONL file.
    ///   - body: Takes one event and answers whether to go on.
    /// - Throws: `JSONLFileError.readFailed(description:)` when the file
    ///   exists and does not read.
    private static func forEachEvent(in file: URL, _ body: (TranscriptEvent) -> Bool) throws {
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: file)
        } catch let error as CocoaError where missingFileCodes.contains(error.code) {
            return
        } catch {
            throw JSONLFileError.readFailed(description: String(describing: error))
        }
        defer { try? handle.close() }
        let decoder = makeDecoder()
        var pending = Data()
        do {
            while let chunk = try handle.read(upToCount: chunkByteCount), !chunk.isEmpty {
                pending.append(chunk)
                while let end = pending.firstIndex(of: lineEnd) {
                    let line = pending.subdata(in: pending.startIndex..<end)
                    pending.removeSubrange(pending.startIndex...end)
                    if let event = try? decoder.decode(TranscriptEvent.self, from: line), !body(event) { return }
                }
            }
        } catch {
            throw JSONLFileError.readFailed(description: String(describing: error))
        }
    }

    /// A decoder for the lines of a `transcript.jsonl`: each date is ISO 8601
    /// text in UTC with milliseconds (``MillisecondDate``), the text that the
    /// recorder writes.
    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            return try MillisecondDate.requiredDate(fromText: text, codingPath: decoder.codingPath)
        }
        return decoder
    }
}
