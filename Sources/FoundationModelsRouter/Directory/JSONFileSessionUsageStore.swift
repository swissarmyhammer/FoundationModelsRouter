import Foundation
import Logging
import Synchronization

/// A ``SessionUsageStore`` that keeps the usages in one JSON file
/// (ROUTER-3).
///
/// The file is a versioned JSON object:
/// `{"version":1,"sessions":{"<ulid>":{"pinnedAt":…,"lastUsedAt":…,"recordingRoot":…}}}`.
/// Each date is ISO 8601 text in UTC with milliseconds (``SessionUsage``).
///
/// The store reads the file one time, at the first call. A missing file
/// gives an empty store. A file that does not read or does not decode also
/// gives an empty store, with a warning, and the next write replaces it. A
/// write makes the parent folder when it is necessary, and writes the whole
/// file atomically (`Data.write(options: .atomic)`), so a reader never sees a
/// partial file.
///
/// The store keeps all the pinned usages, and at most
/// ``maximumRecentCount`` usages that are not pinned. A write removes the
/// usages that are not pinned and have the oldest last use first. A usage
/// with no last use counts from the time of its session id. A usage that
/// holds only a recording root stays (``setRecordingRoot(_:of:)``), also
/// after an unpin. A usage with no pin, no last use and no recording root
/// is removed: a write removes it, and a read of the file removes it too.
///
/// A `Mutex` holds the usages, so each call is safe from each thread. A write
/// changes the usages in memory only after the file write succeeds.
public final class JSONFileSessionUsageStore: SessionUsageStore {
    /// The default maximum number of the usages that are not pinned.
    public static let defaultMaximumRecentCount = 100

    /// The version of the file format that this store reads and writes.
    static let fileVersion = 1

    /// The message of the `warning` record of a file that does not read or
    /// does not decode.
    private static let unreadableFileMessage: Logger.Message =
        "a session usage file cannot be read; the store starts empty"

    /// The Cocoa codes that mean the file is not there: the open of a missing
    /// file gives the first, a read of one gives the second.
    private static let missingFileCodes: Set<CocoaError.Code> = [.fileNoSuchFile, .fileReadNoSuchFile]

    /// The file of the store.
    public let fileURL: URL

    /// The maximum number of the usages that are not pinned.
    public let maximumRecentCount: Int

    /// The usages, before and after the first read of the file.
    private let contents = Mutex<Contents>(.unread)

    /// The state of the usages in memory.
    private enum Contents {
        /// The store did not read the file yet.
        case unread

        /// The usages, by session id.
        case read([ULID: SessionUsage])
    }

    /// The JSON object of the file.
    private struct StoreFile: Codable {
        /// The version of the file format.
        let version: Int

        /// The usages, by the text of the session id.
        let sessions: [String: SessionUsage]
    }

    /// Makes the store of a file. The init does not read the file: the first
    /// call reads it. The file and its folder need not exist.
    ///
    /// - Parameters:
    ///   - fileURL: The file of the store.
    ///   - maximumRecentCount: The maximum number of the usages that are not
    ///     pinned. It must not be negative.
    public init(fileURL: URL, maximumRecentCount: Int = defaultMaximumRecentCount) {
        precondition(maximumRecentCount >= 0, "the maximum recent count must not be negative")
        self.fileURL = fileURL
        self.maximumRecentCount = maximumRecentCount
    }

    /// The usage of each session that the store keeps. The first call reads
    /// the file.
    ///
    /// - Returns: The usages, by session id.
    public func usages() -> [ULID: SessionUsage] {
        contents.withLock { loadedUsages(&$0) }
    }

    /// The usage of one session. The first call reads the file.
    ///
    /// - Parameter id: The id of the session.
    /// - Returns: The usage, or `nil` when the store keeps no usage for `id`.
    public func usage(of id: ULID) -> SessionUsage? {
        usages()[id]
    }

    /// Pins or unpins a session, and writes the file.
    ///
    /// A pin of a pinned session keeps the time of the first pin. An unpin
    /// clears the pin. An unpin of a session that has no last use and no
    /// recording root removes its usage.
    ///
    /// - Parameters:
    ///   - pinned: `true` to pin the session, `false` to unpin it.
    ///   - id: The id of the session.
    ///   - recordingRoot: The recording root of the session, or `nil` to keep
    ///     the recording root that the store holds.
    ///   - time: The time of the pin.
    /// - Returns: The usage of the session after the change.
    /// - Throws: The error of the folder or of the write. The file and the
    ///   store then stay as they were.
    @discardableResult
    public func setPinned(_ pinned: Bool, of id: ULID, recordingRoot: URL?, at time: Date) throws -> SessionUsage {
        try change(id, recordingRoot: recordingRoot) { usage in
            usage.pinnedAt = pinned ? (usage.pinnedAt ?? MillisecondDate.rounded(time)) : nil
        }
    }

    /// Records a use of a session, and writes the file.
    ///
    /// - Parameters:
    ///   - id: The id of the session.
    ///   - recordingRoot: The recording root of the session, or `nil` to keep
    ///     the recording root that the store holds.
    ///   - time: The time of the use.
    /// - Returns: The usage of the session after the change.
    /// - Throws: The error of the folder or of the write. The file and the
    ///   store then stay as they were.
    @discardableResult
    public func markUsed(_ id: ULID, recordingRoot: URL?, at time: Date) throws -> SessionUsage {
        try change(id, recordingRoot: recordingRoot) { usage in
            usage.lastUsedAt = MillisecondDate.rounded(time)
        }
    }

    /// Records the recording root of a session, keeps its pin and its last
    /// use, and writes the file. This call records no use.
    ///
    /// - Parameters:
    ///   - recordingRoot: The recording root of the session.
    ///   - id: The id of the session.
    /// - Returns: The usage of the session after the change.
    /// - Throws: The error of the folder or of the write. The file and the
    ///   store then stay as they were.
    @discardableResult
    public func setRecordingRoot(_ recordingRoot: URL, of id: ULID) throws -> SessionUsage {
        try change(id, recordingRoot: recordingRoot) { _ in }
    }

    // MARK: - Changes

    /// Changes the usage of one session, removes the usages above the limit,
    /// and writes the file. The usages in memory change only when the write
    /// succeeds.
    ///
    /// - Parameters:
    ///   - id: The id of the session.
    ///   - recordingRoot: The recording root of the session, or `nil` to keep
    ///     the stored recording root.
    ///   - body: The change of the usage.
    /// - Returns: The usage of the session after the change.
    /// - Throws: The error of the write.
    private func change(
        _ id: ULID, recordingRoot: URL?, _ body: (inout SessionUsage) -> Void
    ) throws -> SessionUsage {
        try contents.withLock { contents in
            var usages = loadedUsages(&contents)
            var usage = usages[id] ?? SessionUsage()
            body(&usage)
            usage.recordingRoot = recordingRoot ?? usage.recordingRoot
            usages[id] = usage.holdsAnything ? usage : nil
            let kept = trimmed(usages)
            try write(kept)
            contents = .read(kept)
            return usage
        }
    }

    /// The usages without the usages above the limit: all the pinned usages,
    /// and the ``maximumRecentCount`` usages that are not pinned and have the
    /// newest last use.
    ///
    /// - Parameter usages: The usages, by session id.
    /// - Returns: The usages that the store keeps.
    private func trimmed(_ usages: [ULID: SessionUsage]) -> [ULID: SessionUsage] {
        let removed = Set(
            usages.filter { !$0.value.isPinned }
                .sorted(by: Self.isMoreRecent)
                .dropFirst(maximumRecentCount)
                .map(\.key))
        return usages.filter { !removed.contains($0.key) }
    }

    /// The order of the usages that are not pinned: the newest time first,
    /// then the greater session id, so that the order is stable. The time
    /// of a usage is its last use, or the time of its session id when it
    /// has no last use, so a usage that holds only a recording root is as
    /// recent as its session.
    ///
    /// - Parameters:
    ///   - first: A usage and its session id.
    ///   - second: Another usage and its session id.
    /// - Returns: `true` when `first` comes before `second`.
    private static func isMoreRecent(
        _ first: (key: ULID, value: SessionUsage), _ second: (key: ULID, value: SessionUsage)
    ) -> Bool {
        (first.value.lastUsedAt ?? first.key.timestamp, first.key)
            > (second.value.lastUsedAt ?? second.key.timestamp, second.key)
    }

    // MARK: - File

    /// The usages in memory, after a read of the file at the first call.
    ///
    /// - Parameter contents: The state of the usages. The first call changes
    ///   it to ``Contents/read(_:)``.
    /// - Returns: The usages, by session id.
    private func loadedUsages(_ contents: inout Contents) -> [ULID: SessionUsage] {
        switch contents {
        case .read(let usages):
            return usages
        case .unread:
            let usages = readFile()
            contents = .read(usages)
            return usages
        }
    }

    /// Reads the usages of the file.
    ///
    /// - Returns: The usages, or no usages when the file is missing, or with
    ///   a warning when the file does not read or does not decode.
    private func readFile() -> [ULID: SessionUsage] {
        do {
            return try Self.usages(decoding: Data(contentsOf: fileURL))
        } catch let error as CocoaError where Self.missingFileCodes.contains(error.code) {
            return [:]
        } catch {
            RouterTelemetry.makeLogger(.sessionDirectory).warning(
                Self.unreadableFileMessage,
                metadata: RouterTelemetry.errorMetadata(error).merging([
                    RouterTelemetry.LogMetadataKey.filePath: "\(fileURL.path)"
                ]) { _, new in new })
            return [:]
        }
    }

    /// Decodes the usages of the data of a file.
    ///
    /// - Parameter data: The data of the file.
    /// - Returns: The usages, by session id. An entry with no pin, no last
    ///   use and no recording root is not a usage, so the read removes it, as
    ///   a write does.
    /// - Throws: A decoding error when the data is not the JSON object of a
    ///   file, or ``SessionUsageFileError`` when the version is not
    ///   ``fileVersion`` or a session id is not valid.
    private static func usages(decoding data: Data) throws -> [ULID: SessionUsage] {
        let file = try JSONDecoder().decode(StoreFile.self, from: data)
        guard file.version == fileVersion else {
            throw SessionUsageFileError.unknownVersion(file.version)
        }
        let pairs = try file.sessions.map { text, usage in
            guard let id = ULID(ulidString: text) else { throw SessionUsageFileError.invalidSessionID(text) }
            return (id, usage)
        }
        return try Dictionary(pairs) { _, _ in throw SessionUsageFileError.duplicateSessionID }
            .filter { $0.value.holdsAnything }
    }

    /// Writes the usages to the file atomically, and makes its folder when it
    /// is necessary.
    ///
    /// - Parameter usages: The usages, by session id.
    /// - Throws: The error of the folder or of the write.
    private func write(_ usages: [ULID: SessionUsage]) throws {
        let file = StoreFile(
            version: Self.fileVersion,
            sessions: Dictionary(uniqueKeysWithValues: usages.map { ($0.key.ulidString, $0.value) }))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(file)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
    }
}

/// A session usage file that decodes as JSON and does not hold the usages of
/// this store.
enum SessionUsageFileError: Error, Equatable {
    /// The file has a version that the store does not know.
    case unknownVersion(Int)

    /// A key of `sessions` is not the text of a ULID.
    case invalidSessionID(String)

    /// Two keys of `sessions` give the same ULID.
    case duplicateSessionID
}

extension SessionUsage {
    /// Whether the usage has a pin, a last use or a recording root. A usage
    /// with none of them holds nothing to keep.
    fileprivate var holdsAnything: Bool {
        pinnedAt != nil || lastUsedAt != nil || recordingRoot != nil
    }
}
