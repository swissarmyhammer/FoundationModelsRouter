import Foundation
import os

/// The logger best-effort sinks report dropped events to.
private let recordingLogger = Logger(
    subsystem: moduleName,
    category: "Recording"
)

/// A ``TranscriptRecorder`` that appends each event as one JSON object per line
/// to a `transcript.jsonl`, routing each event to a per-session directory while
/// keeping one globally monotonic `seq`.
///
/// As an actor it serializes appends, so the single `seq` it stamps and the order
/// lines land in agree across *every* directory it writes: concurrent sessions
/// and forks appending into their own lineage-nested files still share one total
/// order. Each event is written to its `directory`'s `transcript.jsonl` (or the
/// recorder's own ``directory`` when the caller passes `nil`); the open handle
/// per directory is created lazily and reused. Writing is best-effort: any I/O
/// failure is logged and the event dropped — ``append(_:to:)`` never throws.
public actor JSONLRecorder: TranscriptRecorder {
    /// The default directory `transcript.jsonl` is written into when an append
    /// carries no explicit session directory.
    private let directory: URL
    /// The clock used to stamp each event's `ts`.
    private let now: @Sendable () -> Date
    /// Encodes each event to a single compact JSON line (no embedded newlines).
    private let encoder = JSONEncoder()
    /// The next sequence number to stamp — global across all directories, so the
    /// whole recorder is one monotonic log.
    private var seq = 0
    /// The append handles, one per directory, opened lazily and reused across
    /// appends and keyed by the directory's standardized path.
    private var handles: [String: FileHandle] = [:]

    /// Creates a JSONL recorder whose default directory is `directory`.
    ///
    /// - Parameters:
    ///   - directory: The directory to write `transcript.jsonl` into for appends
    ///     that carry no explicit session directory; created on demand at first
    ///     append. Per-session appends are written under their own directory.
    ///   - now: The clock used to stamp each event's `ts`.
    public init(directory: URL, now: @escaping @Sendable () -> Date = { Date() }) {
        self.directory = directory
        self.now = now
    }

    /// Stamps and appends an event as one JSON line into `directory`'s
    /// `transcript.jsonl` (or the recorder's default directory when `nil`); logs
    /// and drops it on any I/O failure.
    public func append(_ partial: TranscriptEvent.Partial, to directory: URL?) async {
        let event = partial.stamped(seq: seq, ts: now())
        seq += 1
        let target = directory ?? self.directory
        do {
            let handle = try handleForAppending(in: target)
            var line = try encoder.encode(event)
            line.append(0x0A)
            try handle.write(contentsOf: line)
        } catch {
            recordingLogger.error(
                "dropping transcript event seq \(event.seq, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    /// Returns the reusable append handle for a directory, creating the directory
    /// and its `transcript.jsonl` and seeking to the end on first use.
    ///
    /// - Parameter directory: The directory whose `transcript.jsonl` to append to.
    /// - Returns: A handle positioned at the end of that file.
    /// - Throws: If the directory or file cannot be created or opened.
    private func handleForAppending(in directory: URL) throws -> FileHandle {
        let key = directory.standardizedFileURL.path
        if let handle = handles[key] { return handle }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("transcript.jsonl", isDirectory: false)
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: fileURL)
        try handle.seekToEnd()
        handles[key] = handle
        return handle
    }
}

/// A ``TranscriptRecorder`` that collects events in memory.
///
/// As an actor it serializes appends, so ``events`` is the stamped log in `seq`
/// order — contiguous from `0` — regardless of how many tasks append
/// concurrently. Intended for tests and in-process introspection.
public actor InMemoryRecorder: TranscriptRecorder {
    /// The stamped events in append (and therefore `seq`) order.
    public private(set) var events: [TranscriptEvent] = []
    /// The next sequence number to stamp.
    private var seq = 0
    /// The clock used to stamp each event's `ts`.
    private let now: @Sendable () -> Date

    /// Creates an in-memory recorder.
    ///
    /// - Parameter now: The clock used to stamp each event's `ts`.
    public init(now: @escaping @Sendable () -> Date = { Date() }) {
        self.now = now
    }

    /// Stamps and stores an event; the session directory is ignored since this
    /// sink keeps a single in-memory log rather than an on-disk layout.
    public func append(_ partial: TranscriptEvent.Partial, to directory: URL?) async {
        events.append(partial.stamped(seq: seq, ts: now()))
        seq += 1
    }
}

/// The no-op ``TranscriptRecorder`` — recording turned "off" as a sink rather
/// than a `nil` recorder.
///
/// It stores nothing and shares the identical ``append(_:)`` call path, so a
/// session born with `.none` behaves exactly like one born with a real sink,
/// only without any record.
public struct NoneRecorder: TranscriptRecorder {
    /// Creates the no-op sink.
    public init() {}

    /// Accepts and discards an event, ignoring the session directory.
    public func append(_ partial: TranscriptEvent.Partial, to directory: URL?) async {}
}
