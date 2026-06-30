import Foundation
import os

/// The logger best-effort sinks report dropped events to.
private let recordingLogger = Logger(
    subsystem: "FoundationModelsRouter",
    category: "Recording"
)

/// A ``TranscriptRecorder`` that appends each event as one JSON object per line
/// to `transcript.jsonl` under a directory.
///
/// As an actor it serializes appends, so the `seq` it stamps and the order it
/// writes lines in agree. Writing is best-effort: the directory and file are
/// created lazily on first append, the open handle is reused, and any I/O
/// failure is logged and the event dropped — ``append(_:)`` never throws.
public actor JSONLRecorder: TranscriptRecorder {
    /// The directory `transcript.jsonl` is written into.
    private let directory: URL
    /// The full path of the transcript file within ``directory``.
    private let fileURL: URL
    /// The clock used to stamp each event's `ts`.
    private let now: @Sendable () -> Date
    /// Encodes each event to a single compact JSON line (no embedded newlines).
    private let encoder = JSONEncoder()
    /// The next sequence number to stamp.
    private var seq = 0
    /// The append handle, opened lazily and reused across appends.
    private var handle: FileHandle?

    /// Creates a JSONL recorder writing under `directory`.
    ///
    /// - Parameters:
    ///   - directory: The directory to write `transcript.jsonl` into; created on
    ///     demand at first append.
    ///   - now: The clock used to stamp each event's `ts`.
    public init(directory: URL, now: @escaping @Sendable () -> Date = { Date() }) {
        self.directory = directory
        self.fileURL = directory.appendingPathComponent("transcript.jsonl", isDirectory: false)
        self.now = now
    }

    /// Stamps and appends an event as one JSON line; logs and drops it on any
    /// I/O failure.
    public func append(_ partial: TranscriptEvent.Partial) async {
        let event = partial.stamped(seq: seq, ts: now())
        seq += 1
        do {
            let handle = try handleForAppending()
            var line = try encoder.encode(event)
            line.append(0x0A)
            try handle.write(contentsOf: line)
        } catch {
            recordingLogger.error(
                "dropping transcript event seq \(event.seq, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    /// Returns the reusable append handle, creating the directory and file and
    /// seeking to the end on first use.
    ///
    /// - Returns: A handle positioned at the end of `transcript.jsonl`.
    /// - Throws: If the directory or file cannot be created or opened.
    private func handleForAppending() throws -> FileHandle {
        if let handle { return handle }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: fileURL)
        try handle.seekToEnd()
        self.handle = handle
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

    /// Stamps and stores an event.
    public func append(_ partial: TranscriptEvent.Partial) async {
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

    /// Accepts and discards an event.
    public func append(_ partial: TranscriptEvent.Partial) async {}
}
