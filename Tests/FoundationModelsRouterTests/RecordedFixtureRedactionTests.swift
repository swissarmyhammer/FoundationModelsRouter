import Foundation
import FoundationModelsRouterRealModelSupport
import FoundationModelsRouterTestSupport
import Testing

/// The redaction review of the checked-in compaction recording, as a test
/// rather than as prose (task `^4bb3mjv`).
///
/// `^pfdrppj` cleared the fixture's bytes by hand and wrote WHAT it searched
/// for into `Fixtures/CompactionRecording/README.md`. That table could only
/// describe one review of one recording; this suite runs the same search, on
/// every plain `swift test` run, over whatever recording is checked in. A
/// re-recorded fixture that carries an operator path, a credential shape, or
/// the `recordingRoot` leak goes red here before it ships. The suite loads no
/// model, so it lives in this hermetic target and reads the recording through
/// ``CompactionRecordingFixture`` — the same accessor the gated compaction suite
/// reads (task ^cvsh3m9).
///
/// The scan covers the RECORDED files alone — the session's `index.md` and
/// its `transcript.jsonl` — and deliberately not the fixture's own
/// `README.md`, which names the forbidden patterns in order to document them.
///
/// Only ``RecordingRedactionScan/operatorPatterns`` runs here. The
/// machine-derived patterns belong to the RECORDING machine, and this test
/// runs on a different one, where a short user name could collide with the
/// synthetic prose. The `RecordCompactionFixture` tool is what runs both
/// pattern sets, at record time.
///
/// No `.exclusiveRealModel` trait: the suite loads no model, so it needs no
/// place in the residency serial order.
@Suite(
    "The checked-in compaction recording carries no operator trace (task ^4bb3mjv)"
)
struct RecordedFixtureRedactionTests {

    /// The name of the record of a session folder: YAML frontmatter over an
    /// open body.
    private static let indexFileName = "index.md"

    /// The file extension of the append-only event stream.
    private static let eventStreamExtension = "jsonl"

    /// How many recorded files the fixture's single session holds: one
    /// `index.md` and one event stream.
    private static let recordedFileCount = 2

    /// Whether `file` is a recorded file the scan must cover: the `index.md`
    /// of a session folder, or an event stream. The fixture's own
    /// `README.md` is not one.
    ///
    /// - Parameter file: A file under the fixture directory.
    /// - Returns: `true` for a recorded file.
    private static func isRecorded(_ file: URL) -> Bool {
        file.lastPathComponent == indexFileName || file.pathExtension == eventStreamExtension
    }

    /// Every recorded file under the bundled fixture directory, at any depth.
    ///
    /// - Returns: The recorded files, sorted by path for a stable failure
    ///   message.
    /// - Throws: An expectation failure when the bundle vends no resource
    ///   directory or the fixture directory cannot be enumerated.
    private static func recordedFiles() throws -> [URL] {
        let fixtureRoot = try #require(
            CompactionRecordingFixture.directory,
            "the support target's bundle vends no resource directory, so the recording fixture is unreachable"
        )
        let enumerator = try #require(
            FileManager.default.enumerator(at: fixtureRoot, includingPropertiesForKeys: nil),
            "the fixture directory at \(fixtureRoot.path) cannot be enumerated"
        )
        return enumerator
            .compactMap { $0 as? URL }
            .filter(isRecorded)
            .sorted { $0.path < $1.path }
    }

    /// Every recorded file of the fixture is free of the operator patterns,
    /// and the scan sees exactly one `index.md` and one event stream.
    @Test("every recorded byte is free of the forbidden patterns")
    func everyRecordedByteIsFreeOfTheForbiddenPatterns() throws {
        let files = try Self.recordedFiles()

        // The recording format writes exactly one index.md and one event
        // stream for the fixture's single session. Fewer files means the
        // scan is looking at nothing, which must fail loudly rather than
        // pass as clean.
        #expect(
            files.count == Self.recordedFileCount,
            "expected one index.md and one event stream, found \(files.map(\.lastPathComponent))"
        )
        #expect(files.contains { $0.lastPathComponent == Self.indexFileName })

        for fileURL in files {
            let text = try String(contentsOf: fileURL, encoding: .utf8)
            let findings = RecordingRedactionScan.findings(
                in: text,
                file: fileURL.lastPathComponent,
                patterns: RecordingRedactionScan.operatorPatterns
            )
            #expect(
                findings.isEmpty,
                "the checked-in recording carries forbidden text: \(findings)"
            )
        }
    }
}
