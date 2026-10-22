import Foundation
import FoundationModelsRouterTestSupport
import Testing

@testable import FoundationModelsRouter

/// Holds ``RecordingRedactionScan`` to its contract: the scan that decides
/// whether a recorded conversation is safe to commit (task `^4bb3mjv`).
///
/// The scan replaced the prose redaction table in
/// `Fixtures/CompactionRecording/README.md`. These tests pin the facts that
/// table could only describe: an operator path in the YAML of an `index.md`
/// is found, the JSON `\/` escape of an event line must not hide a path, and
/// the one synthetic path the fixture is allowed to carry must not trigger a
/// finding.
@Suite("RecordingRedactionScan finds operator traces in recorded bytes (task ^4bb3mjv)")
struct RecordingRedactionScanTests {

    /// The name of the record of a session folder.
    private static let indexFileName = "index.md"

    /// The name of the event stream of a session folder.
    private static let transcriptFileName = "transcript.jsonl"

    // MARK: - A path in the index.md record

    /// The YAML frontmatter of an `index.md` holds the working folder as a
    /// plain path, so an operator path there is found as it stands.
    @Test("an operator path in the cwd line of an index.md is found")
    func anOperatorPathInTheIndexIsFound() {
        let leakedIndex = "---\nsessionId: 01M0BGQR2DV5T0P9XQ1PS05K8V\ncwd: /Users/operator/recordings/\n---\n"
        let findings = RecordingRedactionScan.findings(
            in: leakedIndex,
            file: Self.indexFileName,
            patterns: RecordingRedactionScan.operatorPatterns
        )
        let lineOfTheCwd = 3
        #expect(
            findings.contains(
                RecordingRedactionScan.Finding(file: Self.indexFileName, pattern: "/Users/", line: lineOfTheCwd)))
    }

    // MARK: - The JSON escape trap

    /// A JSON encoder can escape each `/` of an event line as `\/`; the scan
    /// rewrites the escape before it matches.
    @Test("a JSON-escaped /Users/ path is found, because the scan unescapes \\/ first")
    func aJSONEscapedOperatorPathIsFound() {
        // A leaked path in an event line can be stored as `\/Users\/...`. A
        // literal search for `/Users/` finds nothing in those bytes; the scan
        // must normalize first.
        let leakedLine = #"{"kind":"prompt","text":"read \/Users\/operator\/recordings\/notes"}"#
        let findings = RecordingRedactionScan.findings(
            in: leakedLine,
            file: Self.transcriptFileName,
            patterns: RecordingRedactionScan.operatorPatterns
        )
        #expect(
            findings.contains(
                RecordingRedactionScan.Finding(file: Self.transcriptFileName, pattern: "/Users/", line: 1)))
    }

    /// The machine-independent working folder the recording tool sets, as
    /// the `index.md` holds it, trips no pattern.
    @Test("the synthetic working directory the fixture carries produces no finding")
    func theSyntheticWorkingDirectoryProducesNoFinding() {
        // The one path a clean recording carries: the machine-independent
        // value the recording tool sets before recording, as a plain path in
        // the `cwd` key and as a file URL in the configuration.
        let cleanIndex = "cwd: /recordings/station-archive/\n  workingDirectory: file:///recordings/station-archive/\n"
        let findings = RecordingRedactionScan.findings(
            in: cleanIndex,
            file: Self.indexFileName,
            patterns: RecordingRedactionScan.operatorPatterns
        )
        #expect(findings.isEmpty, "expected no finding, got \(findings)")
    }

    // MARK: - Matching

    /// A pattern matches text in any case.
    @Test("matching ignores case")
    func matchingIgnoresCase() {
        let findings = RecordingRedactionScan.findings(
            in: "authorization: bearer abc123",
            file: "transcript.jsonl",
            patterns: RecordingRedactionScan.operatorPatterns
        )
        #expect(findings.contains { $0.pattern == "Bearer " })
    }

    /// A finding carries the 1-based line of its hit.
    @Test("a finding names the line the pattern stands on, counted from 1")
    func theLineNumberNamesTheLineOfTheHit() {
        let text = "clean line\nstill clean\nleak: /var/folders/ab/xyz\n"
        let findings = RecordingRedactionScan.findings(
            in: text,
            file: "transcript.jsonl",
            patterns: RecordingRedactionScan.operatorPatterns
        )
        let lineOfTheHit = 3
        #expect(
            findings.contains(
                RecordingRedactionScan.Finding(
                    file: "transcript.jsonl", pattern: "/var/folders", line: lineOfTheHit)))
    }

    // MARK: - The recordingRoot leak from ^pfdrppj

    /// The configuration key of a per-session recording root is a finding
    /// wherever it stands in an `index.md`.
    @Test("an index.md that carries the recordingRoot override is found")
    func theRecordingRootKeyIsFound() {
        // The `^pfdrppj` leak: a session vended with a per-session
        // `recordingRoot:` stamps that absolute path into its `index.md`. A
        // clean recording never carries the key at all.
        let leakedIndex = "configuration:\n  recordingRoot: file:///private/tmp/rec2/\n"
        let findings = RecordingRedactionScan.findings(
            in: leakedIndex,
            file: Self.indexFileName,
            patterns: RecordingRedactionScan.operatorPatterns
        )
        #expect(findings.contains { $0.pattern == "recordingRoot" })
    }

    // MARK: - The one benign hit the README documents

    /// The default compaction prompt, which every recorded `index.md`
    /// embeds, trips no pattern.
    @Test("the router's own default compaction prompt produces no finding")
    func theDefaultCompactionPromptTextIsClean() {
        // Every recorded index.md carries this product text, including the
        // word "secret" in its "secret handling" line. The pattern list must
        // not read product text as a credential.
        let findings = RecordingRedactionScan.findings(
            in: CompactionPrompt.default.text,
            file: Self.indexFileName,
            patterns: RecordingRedactionScan.operatorPatterns
        )
        #expect(findings.isEmpty, "the default compaction prompt tripped the scan: \(findings)")
    }

    // MARK: - Machine-derived patterns

    /// The machine patterns hold each machine value long enough to select.
    @Test("machinePatterns carries the user name, home, temporary directory and current directory")
    func machinePatternsCarryTheOperatorFacts() {
        let patterns = RecordingRedactionScan.machinePatterns(
            userName: "operatorname",
            homeDirectory: "/Users/operatorname",
            temporaryDirectory: "/var/folders/ab/xyz",
            currentDirectory: "/Users/operatorname/repo"
        )
        for expected in [
            "operatorname", "/Users/operatorname", "/var/folders/ab/xyz", "/Users/operatorname/repo",
        ] {
            #expect(patterns.contains(expected), "missing machine pattern \(expected)")
        }
    }

    /// A machine value shorter than the minimum is no pattern.
    @Test("a machine value too short to be selective is dropped")
    func aShortMachineValueIsDropped() {
        // A two-character user name would match ordinary prose on nearly
        // every line, which makes the scan unusable rather than safe.
        let patterns = RecordingRedactionScan.machinePatterns(
            userName: "ab",
            homeDirectory: "/Users/ab",
            temporaryDirectory: "/var/folders/cd/xyz",
            currentDirectory: "/Users/ab/repo"
        )
        #expect(!patterns.contains("ab"))
        #expect(patterns.contains("/Users/ab"))
    }
}
