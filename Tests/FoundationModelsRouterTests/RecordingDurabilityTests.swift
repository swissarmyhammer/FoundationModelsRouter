import Foundation
import Testing

@testable import FoundationModelsRouter

/// Exercises the recording durability policy: ``JSONLRecorder`` synchronizes
/// its append handle at each turn close (a `.response`-kind event), and both
/// readers — ``TranscriptTree`` and ``MergedTranscript`` — tolerate the crash
/// artifact that policy expects — a torn final line in a `transcript.jsonl` —
/// while failing loudly, with a typed error naming the file, on corruption
/// anywhere before it.
@Suite("Recording durability: turn-close sync and torn-tail tolerance")
struct RecordingDurabilityTests {
    // MARK: - Fixtures

    /// The newline byte that terminates every JSONL line.
    private static let newline: UInt8 = 0x0A

    /// The working-context token count the fixture sidecar records.
    private static let contextTokens = 4096

    /// The event kinds the fixture records: the opening `session` line, then
    /// two full turns, each closed by a `.response`-kind event.
    private static let fixtureKinds: [TranscriptEvent.Kind] = [
        .session, .prompt, .response, .prompt, .response,
    ]

    /// How many bytes of the torn final line each truncation case keeps —
    /// a single opening byte, an early tear, and a tear near the line's end.
    private static let tornTailKeptByteCounts = [1, 24, 60]

    /// One recorded session on disk: its id and transcript file.
    private struct SessionFixture {
        let sessionId: ULID
        let transcriptURL: URL
    }

    /// A fresh temporary directory to use as a router recording root.
    private static func makeTempDirectory() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("RecordingDurabilityTests-\(ULID().description)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Writes one complete session under `root`: a sidecar and a
    /// `transcript.jsonl` holding ``fixtureKinds``' events in order, recorded
    /// through the real ``JSONLRecorder`` so the bytes on disk are exactly
    /// what production writes.
    private static func writeSessionFixture(under root: URL) async throws -> SessionFixture {
        let sessionId = ULID()
        let directory = root.appendingPathComponent(sessionId.description, isDirectory: true)
        try SessionSidecar.write(
            SessionSidecar(
                slot: .standard,
                model: "org/model",
                context: contextTokens,
                instructions: nil,
                grammar: nil,
                recordingLevel: .full,
                forkedAtEntryCount: nil,
                profile: nil,
                workingDirectory: directory
            ),
            to: directory
        )
        let recorder = JSONLRecorder(directory: directory)
        let routerId = ULID()
        for kind in fixtureKinds {
            await recorder.append(
                TranscriptEvent.Partial(
                    routerId: routerId,
                    sessionId: sessionId,
                    kind: kind,
                    text: "a body long enough that the final line can be torn at every tested offset"
                ),
                to: nil
            )
        }
        return SessionFixture(
            sessionId: sessionId,
            transcriptURL: directory.appendingPathComponent("transcript.jsonl", isDirectory: false)
        )
    }

    /// The byte offset where the file's final non-empty line starts, ignoring
    /// the trailing newline that terminates it.
    private static func finalLineStart(of data: Data) -> Int {
        let withoutTrailingNewline = data.last == newline ? data.dropLast() : data[...]
        guard let previousNewline = withoutTrailingNewline.lastIndex(of: newline) else { return 0 }
        return previousNewline + 1
    }

    /// Truncates the file's final line to its first `keptBytes` bytes — the
    /// torn tail a crash mid-append leaves.
    private static func tearFinalLine(of transcriptURL: URL, keeping keptBytes: Int) throws {
        let data = try Data(contentsOf: transcriptURL)
        let lastLineStart = finalLineStart(of: data)
        #expect(keptBytes < data.count - lastLineStart)
        try data.prefix(lastLineStart + keptBytes).write(to: transcriptURL)
    }

    /// Replaces the fixture's first turn-close `.response` line — a line that
    /// is not the file's last — with bytes that do not decode.
    private static func corruptFirstTurnClose(of transcriptURL: URL) throws {
        let text = try String(contentsOf: transcriptURL, encoding: .utf8)
        var lines = text.split(separator: "\n").map(String.init)
        let firstTurnCloseIndex = try #require(lines.firstIndex { $0.contains("response") })
        lines[firstTurnCloseIndex] = "{\"seq\": torn mid-file bytes"
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: transcriptURL)
    }

    // MARK: - Torn final line

    @Test(
        "a torn final line is dropped and the tree loads with the turn-before state",
        arguments: tornTailKeptByteCounts
    )
    func tornFinalLineIsDroppedOnLoad(keptBytes: Int) async throws {
        let root = Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try await Self.writeSessionFixture(under: root)
        try Self.tearFinalLine(of: fixture.transcriptURL, keeping: keptBytes)

        let tree = try TranscriptTree.load(under: root)
        let events = try tree.events(forSession: fixture.sessionId)
        #expect(events.map(\.kind) == Array(Self.fixtureKinds.dropLast()))
    }

    @Test(
        "a torn final line is dropped from the merged stream too",
        arguments: tornTailKeptByteCounts
    )
    func tornFinalLineIsDroppedFromMergedStream(keptBytes: Int) async throws {
        let root = Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try await Self.writeSessionFixture(under: root)
        try Self.tearFinalLine(of: fixture.transcriptURL, keeping: keptBytes)

        let merged = try MergedTranscript.merged(under: root)
        #expect(merged.map(\.kind) == Array(Self.fixtureKinds.dropLast()))
    }

    // MARK: - Mid-file corruption

    @Test("a corrupt line that is not the last one fails loudly, naming the session and file")
    func midFileCorruptionThrowsTypedError() async throws {
        let root = Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try await Self.writeSessionFixture(under: root)
        try Self.corruptFirstTurnClose(of: fixture.transcriptURL)

        do {
            _ = try TranscriptTree.load(under: root)
            Issue.record("loading a tree over mid-file corruption succeeded")
        } catch TranscriptTreeError.transcriptLineCorrupt(let session, let file) {
            #expect(session == fixture.sessionId)
            #expect(file.lastPathComponent == "transcript.jsonl")
            #expect(file.deletingLastPathComponent().lastPathComponent == fixture.sessionId.description)
        }
    }

    @Test("mid-file corruption fails the merged stream loudly, naming the file")
    func midFileCorruptionThrowsTypedErrorFromMergedStream() async throws {
        let root = Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try await Self.writeSessionFixture(under: root)
        try Self.corruptFirstTurnClose(of: fixture.transcriptURL)

        do {
            _ = try MergedTranscript.merged(under: root)
            Issue.record("merging over mid-file corruption succeeded")
        } catch MergedTranscriptError.transcriptLineCorrupt(let file) {
            #expect(file.lastPathComponent == "transcript.jsonl")
            #expect(file.deletingLastPathComponent().lastPathComponent == fixture.sessionId.description)
        }
    }

    // MARK: - Turn-close sync

    /// One recorded call on ``SpyAppendHandle``.
    private enum HandleCall: Equatable {
        case write
        case synchronize
    }

    /// A ``TranscriptAppendHandle`` that records its calls instead of touching
    /// disk, so a test can assert exactly when the recorder synchronizes.
    private final class SpyAppendHandle: TranscriptAppendHandle, @unchecked Sendable {
        /// Guards ``recordedCalls`` — the recorder actor and the test both
        /// touch this spy.
        private let lock = NSLock()
        /// Every call made on this handle, in order.
        private var recordedCalls: [HandleCall] = []

        /// Every call made on this handle so far, in order.
        var calls: [HandleCall] {
            lock.withLock { recordedCalls }
        }

        func write(contentsOf data: Data) throws {
            lock.withLock { recordedCalls.append(.write) }
        }

        func synchronize() throws {
            lock.withLock { recordedCalls.append(.synchronize) }
        }
    }

    @Test("the append handle is synchronized exactly when a turn-close `.response` event lands")
    func synchronizesAtTurnClose() async {
        let directory = Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let spy = SpyAppendHandle()
        let recorder = JSONLRecorder(directory: directory, openHandle: { _ in spy })

        let routerId = ULID()
        let sessionId = ULID()
        for kind in Self.fixtureKinds {
            await recorder.append(
                TranscriptEvent.Partial(routerId: routerId, sessionId: sessionId, kind: kind),
                to: nil
            )
        }

        #expect(
            spy.calls == [
                .write, .write, .write, .synchronize, .write, .write, .synchronize,
            ]
        )
    }
}
