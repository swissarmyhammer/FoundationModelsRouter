import Foundation
import FoundationModelsRouterTestSupport
import Testing

@testable import FoundationModelsRouter

/// Holds ``RecordingRedactionScan`` to its contract: the scan that decides
/// whether a recorded conversation is safe to commit (task `^4bb3mjv`).
///
/// The scan replaced the prose redaction table in
/// `Fixtures/CompactionRecording/README.md`. These tests pin the two facts
/// that table could only describe: the JSON `\/` escape must not hide a path,
/// and the one synthetic path the fixture is allowed to carry must not
/// trigger a finding.
@Suite("RecordingRedactionScan finds operator traces in recorded bytes (task ^4bb3mjv)")
struct RecordingRedactionScanTests {

    // MARK: - The JSON escape trap

    @Test("a JSON-escaped /Users/ path is found, because the scan unescapes \\/ first")
    func aJSONEscapedOperatorPathIsFound() {
        // The router's sidecar encoder escapes each `/` as `\/`, so a leaked
        // path is stored as `\/Users\/...`. A literal search for `/Users/`
        // finds nothing in those bytes; the scan must normalize first.
        let leakedSidecar = #"{"workingDirectory":"file:\/\/\/Users\/operator\/recordings\/"}"#
        let findings = RecordingRedactionScan.findings(
            in: leakedSidecar,
            file: "session.json",
            patterns: RecordingRedactionScan.operatorPatterns
        )
        #expect(findings.contains(RecordingRedactionScan.Finding(file: "session.json", pattern: "/Users/", line: 1)))
    }

    @Test("the synthetic working directory the fixture carries produces no finding")
    func theSyntheticWorkingDirectoryProducesNoFinding() {
        // The one path a clean recording carries: the machine-independent
        // value the recording tool sets before recording.
        let cleanSidecar = #"{"workingDirectory":"file:\/\/\/recordings\/station-archive\/"}"#
        let findings = RecordingRedactionScan.findings(
            in: cleanSidecar,
            file: "session.json",
            patterns: RecordingRedactionScan.operatorPatterns
        )
        #expect(findings.isEmpty, "expected no finding, got \(findings)")
    }

    // MARK: - Matching

    @Test("matching ignores case")
    func matchingIgnoresCase() {
        let findings = RecordingRedactionScan.findings(
            in: "authorization: bearer abc123",
            file: "transcript.jsonl",
            patterns: RecordingRedactionScan.operatorPatterns
        )
        #expect(findings.contains { $0.pattern == "Bearer " })
    }

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

    @Test("a sidecar that carries the recordingRoot override is found")
    func theRecordingRootKeyIsFound() {
        // The `^pfdrppj` leak: a session vended with a per-session
        // `recordingRoot:` stamps that absolute path into `session.json`. A
        // clean recording never carries the key at all.
        let leakedSidecar = #"{"configuration":{"recordingRoot":"file:\/\/\/private\/tmp\/rec2\/"}}"#
        let findings = RecordingRedactionScan.findings(
            in: leakedSidecar,
            file: "session.json",
            patterns: RecordingRedactionScan.operatorPatterns
        )
        #expect(findings.contains { $0.pattern == "recordingRoot" })
    }

    // MARK: - The one benign hit the README documents

    @Test("the router's own default compaction prompt produces no finding")
    func theDefaultCompactionPromptTextIsClean() {
        // Every recorded sidecar carries this product text, including the
        // word "secret" in its "secret handling" line. The pattern list must
        // not read product text as a credential.
        let findings = RecordingRedactionScan.findings(
            in: CompactionPrompt.default.text,
            file: "session.json",
            patterns: RecordingRedactionScan.operatorPatterns
        )
        #expect(findings.isEmpty, "the default compaction prompt tripped the scan: \(findings)")
    }

    // MARK: - Machine-derived patterns

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
