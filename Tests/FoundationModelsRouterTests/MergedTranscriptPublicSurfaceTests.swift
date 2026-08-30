import Foundation
import Testing

import FoundationModelsRouter

/// Exercises ``TranscriptEvent/merged(under:)`` — the one public entry point a
/// package outside this one reads a router's whole recorded run back through.
///
/// The import is plain, with no `@testable`, so the compiler is the first
/// assertion here: were that entry point to lose `public`, this file would stop
/// compiling before a single test ran. That is the assertion that matters,
/// because the only consumer of this surface lives in another package, where
/// `@testable` is not available to it.
///
/// The fixture is written as raw JSONL rather than built from ``TranscriptEvent``
/// values, because the memberwise initializer is internal — which is exactly
/// what an outside caller sees, so the suite reaches the merge the same way that
/// caller does.
@Suite("TranscriptEvent.merged: read a merged transcript over the public surface")
struct MergedTranscriptPublicSurfaceTests {
    /// The temp-directory prefix every fixture in this suite is built with, so a
    /// leaked directory is attributable to this suite.
    private static let tempDirPrefix = "MergedTranscriptPublicSurfaceTests"

    /// The transcript file name a recorder writes under each session directory,
    /// and the one the merge discovers.
    private static let transcriptFileName = "transcript.jsonl"

    /// The number of sessions the fixture spreads its events over. The events
    /// are dealt round-robin between them, so no session's own file holds a
    /// contiguous run of the merged order.
    private static let sessionCount = 2

    /// The body text of every event the fixture records, in the exact order the
    /// merge must return them. An entry's index in this array IS that event's
    /// `seq`, and its `ts` is derived from that index, so the expected order is
    /// stated once and read back three ways.
    private static let recordedTexts = [
        "first session, first turn",
        "second session, first turn",
        "first session, second turn",
        "second session, second turn",
    ]

    // MARK: - The read

    @Test("the public read merges every session under one router directory into one ordered stream")
    func mergesEverySessionUnderTheRouterDirectory() throws {
        let routerDirectory = RouterTestFixtures.makeTempDir(prefix: Self.tempDirPrefix)
        defer { try? FileManager.default.removeItem(at: routerDirectory) }

        let routerId = ULID.generate()
        let sessionIds = (0..<Self.sessionCount).map { _ in ULID.generate() }
        for (offset, sessionId) in sessionIds.enumerated() {
            try Self.writeSession(
                id: sessionId,
                of: routerId,
                lines: Self.fixtureLines(forSessionAt: offset),
                under: routerDirectory
            )
        }

        let merged = try TranscriptEvent.merged(under: routerDirectory)

        // The order: every body comes back in the recorded order, not in the
        // order any one file holds its own lines.
        #expect(merged.map(\.text) == Self.recordedTexts as [String?])
        #expect(merged.map(\.seq) == Array(Self.recordedTexts.indices))
        // The merge: the stream alternates between the two session files, so
        // the read covered both of them rather than one.
        #expect(
            merged.map(\.sessionId)
                == Self.recordedTexts.indices.map { sessionIds[$0 % Self.sessionCount] }
        )
    }

    // MARK: - Fixtures

    /// One recorded line of a fixture session, in the shape the recorder writes
    /// it to disk.
    private struct FixtureLine {
        /// The recorder-assigned sequence number — the log's total order, and
        /// this line's index in ``MergedTranscriptPublicSurfaceTests/recordedTexts``.
        let seq: Int

        /// The event's body text, which the assertions read back.
        let text: String

        /// The wall-clock stamp, as the seconds-since-reference-date number a
        /// recorder writes. It rises with ``seq``, so `(ts, seq)` and `seq`
        /// agree on the order the merge must produce.
        var ts: Double { Double(seq) }
    }

    /// The lines the session at `offset` records, newest first.
    ///
    /// Two things about the result make the assertions load-bearing: the
    /// round-robin deal leaves each session holding a non-contiguous slice of
    /// the merged order, and the reversal leaves each file's own lines in the
    /// opposite of it. A merge that concatenated its files, in the order it read
    /// their lines, could not pass.
    ///
    /// - Parameter offset: The session's position in the round-robin deal.
    /// - Returns: That session's lines, in the order they are written to disk.
    private static func fixtureLines(forSessionAt offset: Int) -> [FixtureLine] {
        let owned = recordedTexts.enumerated().filter { $0.offset % sessionCount == offset }
        return owned.reversed().map { FixtureLine(seq: $0.offset, text: $0.element) }
    }

    /// Writes one session directory under `routerDirectory`, holding `lines` as
    /// its `transcript.jsonl`.
    ///
    /// - Parameters:
    ///   - sessionId: The session's span id, which also names its directory.
    ///   - routerId: The recording root id every line carries.
    ///   - lines: The lines to write, in the order they are written.
    ///   - routerDirectory: The router's recording root the merge reads under.
    /// - Throws: Whatever creating the directory or writing the file throws.
    private static func writeSession(
        id sessionId: ULID,
        of routerId: ULID,
        lines: [FixtureLine],
        under routerDirectory: URL
    ) throws {
        let sessionDirectory = routerDirectory.appendingPathComponent(
            sessionId.description,
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: sessionDirectory,
            withIntermediateDirectories: true
        )
        let body = lines.map { line in
            """
            {"routerId":"\(routerId)","sessionId":"\(sessionId)","seq":\(line.seq),\
            "ts":\(line.ts),"kind":"prompt","text":"\(line.text)"}
            """
        }
        try body.joined(separator: "\n").appending("\n").write(
            to: sessionDirectory.appendingPathComponent(transcriptFileName, isDirectory: false),
            atomically: true,
            encoding: .utf8
        )
    }
}
