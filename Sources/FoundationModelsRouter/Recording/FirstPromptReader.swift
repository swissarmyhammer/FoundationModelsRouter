import Foundation
import FoundationModelsExtras

/// Reads the first prompt of a recorded session without a restore.
///
/// The read opens the `transcript.jsonl` of the session and reads it in
/// chunks. It decodes line by line, so it loads no other session and no tree.
/// It stops at the first ``TranscriptEvent/Kind/prompt`` event that no
/// pending marker precedes. The session writes a
/// ``TranscriptEvent/Kind/promptStarted`` marker when the pump takes the
/// message, and the `.prompt` entry only at the end of the submission, so a
/// session that a crash cut in its first submission has the marker and no
/// entry. A marker and the entry of the same message have the same body.
///
/// A marker holds the place of the first prompt only while its mail is open.
/// The read applies the rule of ``OpenPrompts``: a later `.prompt` entry that
/// delivers the mail, or a later `.mail` record that ends it, covers the
/// marker, and the marker is then no prompt of the transcript. So the read
/// goes on after a marker until a record covers it, or until the end of the
/// events that it may read. A fork has no prompt of its own before its cut, so
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

    /// The first prompt of a session.
    private struct FirstPrompt {
        /// The body of the prompt, or `nil` for a prompt event with no prompt
        /// text of its own.
        let body: String?
    }

    /// What a scan of the effective events of one session found.
    private enum Scan {
        /// The first prompt event or prompt marker, with its body.
        case found(String?)

        /// No prompt event in the events that the scan was allowed to read.
        /// Holds the count of entry-kind events that the scan counted.
        case exhausted(entries: Int)
    }

    /// The search for the first prompt in the events of one folder, in order.
    ///
    /// It holds the markers that may still be open, and it ends them by the
    /// cover rule of ``OpenPrompts``.
    private struct PromptSearch {
        /// A marker that no record has covered yet, with the mail that later
        /// records covered.
        private struct PendingMarker {
            /// The ``TranscriptEvent/Kind/promptStarted`` event.
            let marker: TranscriptEvent

            /// The ids of the mail of the marker that a later record covered.
            var covered: Set<MailID> = []
        }

        /// The markers that have open mail, in event order.
        private var pending: [PendingMarker] = []

        /// The first `.prompt` event that a pending marker preceded. It is
        /// the first prompt when each such marker is covered. `nil` when
        /// there is no such event yet.
        private var firstEntry: FirstPrompt?

        /// Takes the next event of the folder.
        ///
        /// - Parameter event: The event.
        /// - Returns: The first prompt when this event settles it, or `nil`
        ///   when the search goes on.
        mutating func read(_ event: TranscriptEvent) -> FirstPrompt? {
            if event.kind == .promptStarted {
                if OpenPrompts.open(in: event, isCovered: { _ in false }) != nil {
                    pending.append(PendingMarker(marker: event))
                }
                return nil
            }
            cover(by: event)
            let entry = event.kind == .prompt ? FirstPrompt(body: event.promptBody) : nil
            guard pending.isEmpty else {
                firstEntry = firstEntry ?? entry
                return nil
            }
            return firstEntry ?? entry
        }

        /// Applies the records of `event` to the pending markers: a marker
        /// with no open mail left leaves the search.
        ///
        /// - Parameter event: An event of the folder.
        mutating func cover(by event: TranscriptEvent) {
            let ids = OpenPrompts.coveredMailIDs(by: event)
            guard !ids.isEmpty else { return }
            for index in pending.indices {
                pending[index].covered.formUnion(ids)
            }
            pending.removeAll { OpenPrompts.open(in: $0.marker, isCovered: $0.covered.contains) == nil }
        }

        /// The first prompt when the events of the folder end.
        ///
        /// - Parameter keepingOpenMarkers: Whether the pending markers still
        ///   count as prompts. They do not when the events end at the cut of
        ///   a fork that keeps no marker.
        /// - Returns: The first prompt, or `nil` when the events hold none.
        func finish(keepingOpenMarkers: Bool) -> FirstPrompt? {
            guard keepingOpenMarkers, let first = pending.first,
                let open = OpenPrompts.open(in: first.marker, isCovered: first.covered.contains)
            else { return firstEntry }
            return FirstPrompt(body: open.text)
        }
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
        var search = PromptSearch()
        var found: FirstPrompt?
        try forEachEvent(in: folder.appendingPathComponent(transcriptFileName, isDirectory: false)) { event in
            // The first entry-kind event after the cut ends the events that
            // the fork inherits. A submission that its entry delivers can
            // still cover a marker before the cut, so the stop covers first
            // (``TranscriptTree/forkPrefix(of:entryCount:)``).
            if let limit = entryLimit, entries >= limit, event.kind.isEntryKind {
                search.cover(by: event)
                return false
            }
            if event.kind.isEntryKind {
                entries += 1
            }
            found = search.read(event)
            return found == nil
        }
        // The cut of a fork counts the entries that it keeps and the open
        // markers that it keeps. A marker that waits at the end of the
        // events before the cut is in the cut only when the cut counts more
        // than the entries of this folder.
        let keepsOpenMarkers = entryLimit.map { entries < $0 } ?? true
        guard let body = found ?? search.finish(keepingOpenMarkers: keepsOpenMarkers) else {
            return .exhausted(entries: entries)
        }
        return .found(body.body)
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
