import Foundation
import FoundationModelsRouterTestSupport
import Synchronization
import TelemetryTestSupport
import Testing

@testable import FoundationModelsRouter

/// Exercises the recording durability policy: ``JSONLRecorder`` appends each
/// event as one line through the Extras `JSONLFile`, which flushes that line
/// before it returns; an append only grows the file and starts its own line
/// after a torn tail; and both readers — ``TranscriptTree`` and
/// ``MergedTranscript`` — drop a torn final line and skip a line that does
/// not decode, each with a warning, and never throw for either.
@Suite("Recording durability: one flushed line for each event, and torn-line tolerance")
struct RecordingDurabilityTests {
    // MARK: - Fixtures

    /// The newline byte that terminates every JSONL line.
    private static let newline: UInt8 = 0x0A

    /// The working-context token count the fixture record holds.
    private static let contextTokens = 4096

    /// The event kinds the fixture records: the opening `session` line, then
    /// two full answers, each closed by a `.response`-kind event.
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

    /// Writes one complete session under `root`: an `index.md` and a
    /// `transcript.jsonl` holding ``fixtureKinds``' events in order, recorded
    /// through the real ``JSONLRecorder`` so the bytes on disk are exactly
    /// what production writes.
    private static func writeSessionFixture(under root: URL) async throws -> SessionFixture {
        let sessionId = ULID()
        let routerId = ULID()
        let directory = root.appendingPathComponent(sessionId.description, isDirectory: true)
        try SessionRecordFixtures.write(
            SessionRecord(
                sessionId: sessionId,
                workingDirectory: directory,
                updatedAt: Date(),
                slot: .standard,
                model: "org/model",
                context: contextTokens,
                recordingLevel: .full,
                routerId: routerId
            ),
            to: directory
        )
        let recorder = JSONLRecorder(directory: directory)
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

    /// Replaces the fixture's first submission-close `.response` line — a line that
    /// is not the file's last — with bytes that do not decode.
    private static func corruptFirstSubmissionClose(of transcriptURL: URL) throws {
        var lines = try TextFileLines.read(from: transcriptURL)
        let firstSubmissionCloseIndex = try #require(lines.firstIndex { $0.contains("response") })
        lines[firstSubmissionCloseIndex] = "{\"seq\": torn mid-file bytes"
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: transcriptURL)
    }

    // MARK: - Torn final line

    @Test(
        "a torn final line is dropped and the tree loads with the state from before that answer",
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

    /// The message of the warning that the Extras `JSONLFile` reader logs for
    /// a whole line that does not decode.
    private static let skippedLineWarning = "skipped a line of a JSONL file that does not decode"

    /// The fixture kinds without the first submission-close `.response`,
    /// the line ``corruptFirstSubmissionClose(of:)`` damages.
    private static var fixtureKindsWithoutFirstSubmissionClose: [TranscriptEvent.Kind] {
        var kinds = fixtureKinds
        kinds.remove(at: kinds.firstIndex(of: .response) ?? kinds.endIndex)
        return kinds
    }

    /// Runs `read` and counts the warnings of skipped lines it logged.
    ///
    /// - Parameter read: The read of the damaged transcript.
    /// - Returns: The kinds of the events `read` gave, and the count of
    ///   skipped-line warnings.
    private static func kindsAndSkipWarnings(
        of read: @escaping @Sendable () throws -> [TranscriptEvent]
    ) async throws -> (kinds: [TranscriptEvent.Kind], warnings: Int) {
        try await TelemetryCapture.run(forbidding: []) { context in
            let kinds = try read().map(\.kind)
            let warnings = context.logRecords.filter {
                $0.level == .warning && "\($0.message)" == Self.skippedLineWarning
            }
            return (kinds, warnings.count)
        }
    }

    @Test("a corrupt line that is not the last one is skipped with a warning, and the tree loads the rest")
    func midFileCorruptionIsSkippedOnLoad() async throws {
        let root = Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try await Self.writeSessionFixture(under: root)
        try Self.corruptFirstSubmissionClose(of: fixture.transcriptURL)

        let tree = try TranscriptTree.load(under: root)

        let (kinds, warnings) = try await Self.kindsAndSkipWarnings {
            try tree.events(forSession: fixture.sessionId)
        }

        #expect(kinds == Self.fixtureKindsWithoutFirstSubmissionClose)
        #expect(warnings == 1)
    }

    @Test("a corrupt line that is not the last one is skipped with a warning in the merged stream")
    func midFileCorruptionIsSkippedFromMergedStream() async throws {
        let root = Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try await Self.writeSessionFixture(under: root)
        try Self.corruptFirstSubmissionClose(of: fixture.transcriptURL)

        let (kinds, warnings) = try await Self.kindsAndSkipWarnings {
            try MergedTranscript.merged(under: root)
        }

        #expect(kinds == Self.fixtureKindsWithoutFirstSubmissionClose)
        #expect(warnings == 1)
    }

    // MARK: - Append only

    /// How far after the fixture a later recorder stamps its events, so the
    /// merged stream, which orders by time first, puts them last.
    private static let laterRecorderOffset: TimeInterval = 3600

    @Test("an append after a torn final line keeps every earlier byte and starts a line of its own")
    func anAppendAfterATornFinalLineStartsALineOfItsOwn() async throws {
        let root = Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try await Self.writeSessionFixture(under: root)
        try Self.tearFinalLine(of: fixture.transcriptURL, keeping: Self.tornTailKeptByteCounts[1])
        let tornBytes = try Data(contentsOf: fixture.transcriptURL)
        let directory = fixture.transcriptURL.deletingLastPathComponent()
        let later = Date().addingTimeInterval(Self.laterRecorderOffset)

        await JSONLRecorder(directory: directory, now: { later }).append(
            TranscriptEvent.Partial(routerId: ULID(), sessionId: fixture.sessionId, kind: .prompt), to: nil)

        let grown = try Data(contentsOf: fixture.transcriptURL)
        #expect(grown.prefix(tornBytes.count) == tornBytes)
        let merged = try MergedTranscript.merged(under: root)
        #expect(merged.map(\.kind) == Array(Self.fixtureKinds.dropLast()) + [.prompt])
    }

    @Test("an append only grows the transcript: every earlier byte stays as it was")
    func anAppendOnlyGrowsTheTranscript() async throws {
        let root = Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try await Self.writeSessionFixture(under: root)
        let before = try Data(contentsOf: fixture.transcriptURL)
        let directory = fixture.transcriptURL.deletingLastPathComponent()

        await JSONLRecorder(directory: directory).append(
            TranscriptEvent.Partial(routerId: ULID(), sessionId: fixture.sessionId, kind: .prompt), to: nil)

        let after = try Data(contentsOf: fixture.transcriptURL)
        #expect(after.count > before.count)
        #expect(after.prefix(before.count) == before)
    }

    // MARK: - One flushed line for each event

    /// A line append that records each event and file it is given instead
    /// of touching disk, so a test sees exactly what the recorder appends.
    private final class SpyLineAppend: Sendable {
        /// The kind and the file of each append, in order, under a lock: the
        /// recorder actor and the test both touch this spy.
        private let appends = Mutex<[(kind: TranscriptEvent.Kind, file: URL)]>([])

        /// The kinds of the appended events, in order.
        var kinds: [TranscriptEvent.Kind] {
            appends.withLock { $0.map(\.kind) }
        }

        /// The files of the appends, in order.
        var files: [URL] {
            appends.withLock { $0.map(\.file) }
        }

        /// Records one append of `record` to `file`.
        ///
        /// - Parameters:
        ///   - record: The appended record, a ``TranscriptEvent``.
        ///   - file: The file of the append.
        func append(_ record: any Encodable, to file: URL) {
            let kind = (record as? TranscriptEvent)?.kind
            appends.withLock { $0.append((kind ?? .session, file)) }
            #expect(kind != nil, "the recorder appended a record that is not a transcript event")
        }
    }

    @Test("every event is one line append of its own, not only the close of a submission")
    func everyEventIsOneFlushedLineAppend() async {
        let directory = Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let spy = SpyLineAppend()
        let recorder = JSONLRecorder(directory: directory, appendLine: { record, file in spy.append(record, to: file) })

        for kind in Self.fixtureKinds {
            await recorder.append(TranscriptEvent.Partial(routerId: ULID(), sessionId: ULID(), kind: kind), to: nil)
        }

        #expect(spy.kinds == Self.fixtureKinds)
        let transcript = directory.appendingPathComponent("transcript.jsonl", isDirectory: false)
        #expect(spy.files == Array(repeating: transcript, count: Self.fixtureKinds.count))
    }
}
