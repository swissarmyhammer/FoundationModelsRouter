import Foundation

/// Scans recorded conversation files for text that must not be committed —
/// operator paths, machine identity, and credential shapes (task `^4bb3mjv`).
///
/// This scan is the code form of the prose redaction table that
/// `Fixtures/CompactionRecording/README.md` used to carry. Three callers run
/// it:
///
/// - The `RecordCompactionFixture` tool runs it over a fresh recording,
///   with ``operatorPatterns`` plus ``machinePatterns(userName:homeDirectory:temporaryDirectory:currentDirectory:)``
///   for the recording machine, and refuses to hand over a recording with a
///   finding.
/// - `RecordedFixtureRedactionTests` in the integration target runs
///   ``operatorPatterns`` over the checked-in fixture bytes on every
///   integration run, so the committed recording stays proven clean.
/// - `RecordingRedactionScanTests` in the unit target holds the scan itself
///   to its contract.
///
/// The scan reads TEXT, one line at a time, case-insensitively. Before it
/// matches, it rewrites the JSON escape `\/` to `/`, because the router's
/// sidecar encoder stores `/Users/...` as `\/Users\/...` and a literal search
/// would find nothing in those bytes. For the same reason `://` cannot be a
/// pattern: after the rewrite, the synthetic
/// `file:///recordings/station-archive/` working directory carries it, so
/// `http` and `@` stand in for the URL and address checks.
public enum RecordingRedactionScan {

    /// One pattern hit in one scanned file.
    public struct Finding: Equatable, Sendable, CustomStringConvertible {
        /// The name of the scanned file, as the caller gave it.
        public let file: String

        /// The pattern that matched.
        public let pattern: String

        /// The 1-based line the pattern matched on.
        public let line: Int

        /// Creates a finding.
        ///
        /// - Parameters:
        ///   - file: The name of the scanned file, as the caller gives it.
        ///   - pattern: The pattern that matched.
        ///   - line: The 1-based line the pattern matched on.
        public init(file: String, pattern: String, line: Int) {
            self.file = file
            self.pattern = pattern
            self.line = line
        }

        /// The finding as one readable line: `file:line: pattern`.
        public var description: String {
            "\(file):\(line): forbidden pattern \"\(pattern)\""
        }
    }

    /// The machine-independent forbidden patterns.
    ///
    /// Each entry is a substring that no clean recording carries, matched
    /// case-insensitively after the `\/` rewrite. The groups mirror the
    /// review that cleared the first checked-in recording (`^pfdrppj`):
    /// operator paths, this repository's own tooling, the model cache,
    /// credential shapes, remote addresses, and the sidecar key of the
    /// `recordingRoot:` leak. The word `secret` is deliberately absent: the
    /// router's default compaction prompt is product text that carries it,
    /// and every recorded sidecar embeds that prompt.
    public static let operatorPatterns: [String] = [
        // Machine paths. A path from the recording box, in any of the
        // places macOS and Linux put one.
        "/Users/", "/private/", "/var/folders", "/tmp", "/home/",
        // This repository and its tooling. Any of these names in a
        // recording points back at the operator's checkout or agent.
        "swissarmyhammer", "scratchpad", ".build", "Xcode", "claude",
        // The model cache. A weights path or a Hub token prefix.
        "huggingface", ".cache", "hf_",
        // Credential shapes.
        "sk-", "pk_", "AKIA", "Bearer ", "PRIVATE KEY", "api_key",
        "password", "passwd", "credential", "ssh-",
        // Remote addresses. `http` covers each URL scheme, and `@` covers
        // mail addresses and user-at-host targets.
        "http", "@",
        // The `^pfdrppj` leak: a per-session `recordingRoot:` override is
        // stamped into `session.json` as an absolute machine path. A clean
        // recording never carries the key at all.
        "recordingRoot",
    ]

    /// The shortest machine-derived value the scan accepts as a pattern.
    ///
    /// A one- or two-character value — a short user name, a root path —
    /// matches ordinary prose on nearly every line, which makes the scan
    /// unusable rather than safe. Shorter values are dropped; the fixed
    /// ``operatorPatterns`` still cover the path shapes such a value would
    /// sit inside.
    public static let minimumMachinePatternLength = 3

    /// The forbidden patterns derived from the machine the scan runs on.
    ///
    /// The recording tool passes the defaults, so the scan knows the
    /// operator's user name and directories without prose telling anybody to
    /// remember them. Tests pass explicit values. The checked-in fixture is
    /// NOT scanned with these: it was recorded on a different machine, and a
    /// test machine's own short names could collide with synthetic prose.
    ///
    /// - Parameters:
    ///   - userName: The operator's user name.
    ///   - homeDirectory: The operator's home directory path.
    ///   - temporaryDirectory: The machine's temporary directory path.
    ///   - currentDirectory: The working directory the tool runs in, which
    ///     is normally the repository checkout.
    /// - Returns: The values long enough to be selective, in the order
    ///   given.
    public static func machinePatterns(
        userName: String = NSUserName(),
        homeDirectory: String = NSHomeDirectory(),
        temporaryDirectory: String = FileManager.default.temporaryDirectory.path,
        currentDirectory: String = FileManager.default.currentDirectoryPath
    ) -> [String] {
        [userName, homeDirectory, temporaryDirectory, currentDirectory]
            .filter { $0.count >= minimumMachinePatternLength }
    }

    /// Scans one file's text for the given patterns.
    ///
    /// - Parameters:
    ///   - text: The file's whole text.
    ///   - file: The file's name, carried onto each finding.
    ///   - patterns: The forbidden substrings, matched case-insensitively
    ///     after the `\/` escape is rewritten to `/`.
    /// - Returns: One finding for each pattern that matches a line, in line
    ///   order. A line that matches several patterns yields one finding for
    ///   each pattern.
    public static func findings(in text: String, file: String, patterns: [String]) -> [Finding] {
        let normalized = text.replacingOccurrences(of: "\\/", with: "/")
        var found: [Finding] = []
        let lines = normalized.split(separator: "\n", omittingEmptySubsequences: false)
        for (index, line) in lines.enumerated() {
            for pattern in patterns where line.range(of: pattern, options: .caseInsensitive) != nil {
                found.append(Finding(file: file, pattern: pattern, line: index + 1))
            }
        }
        return found
    }
}
