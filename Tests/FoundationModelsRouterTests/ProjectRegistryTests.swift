import Foundation
import Logging
import TelemetryTestSupport
import Testing

@testable import FoundationModelsRouter

/// The cross-project registry `projects.jsonl` in the user layer: each
/// session start appends one line, the newest line of a path wins on read,
/// and a stale entry is skipped on read. Every test builds its own throwaway
/// user directory and project directories under a temp directory.
@Suite struct ProjectRegistryTests {
    /// A throwaway user layer root plus real project directories, so the
    /// stale-skip check can delete one.
    struct Fixture {
        /// The temp root that holds every other directory.
        let root: URL

        /// The injected user layer root the registry file lives in.
        let userDirectory: URL

        /// The registry under test.
        let registry: ProjectRegistry

        init() {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "ProjectRegistryTests-\(UUID().uuidString)", isDirectory: true)
            userDirectory = root.appendingPathComponent("user", isDirectory: true)
            registry = ProjectRegistry(directory: userDirectory)
            try! FileManager.default.createDirectory(
                at: userDirectory, withIntermediateDirectories: true)
        }

        /// Makes a real project directory named `name` and returns its URL.
        func makeProjectDirectory(named name: String) throws -> URL {
            let directory = root.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            return directory
        }

        /// The raw text of the registry file.
        func registryText() throws -> String {
            try String(
                contentsOf: userDirectory.appendingPathComponent(ProjectRegistry.registryFileName),
                encoding: .utf8)
        }

        /// Overwrites the registry file with `text`.
        func writeRegistryText(_ text: String) throws {
            try text.write(
                to: userDirectory.appendingPathComponent(ProjectRegistry.registryFileName),
                atomically: true, encoding: .utf8)
        }
    }

    /// The instant of the first visit in each test.
    static let firstVisit = Date(timeIntervalSince1970: 1_756_000_000)

    /// A later instant, for the revisit tests.
    static let secondVisit = Date(timeIntervalSince1970: 1_756_100_000)

    /// A session start in a new working directory appends one record with
    /// equal `firstSeen` and `lastSeen`.
    @Test func newWorkingDirectoryAppendsOneRecord() throws {
        let fixture = Fixture()
        let project = try fixture.makeProjectDirectory(named: "alpha")

        try fixture.registry.recordSessionStart(workingDirectory: project, at: Self.firstVisit)

        let records = try fixture.registry.projects()
        #expect(records.map(\.path) == [project.path])
        #expect(records.map(\.firstSeen) == [Self.firstVisit])
        #expect(records.map(\.lastSeen) == [Self.firstVisit])
    }

    /// A revisit appends a newer line for the working directory, which keeps
    /// `firstSeen` and updates `lastSeen`; the earlier line stays byte for
    /// byte, and the newest line wins on read.
    @Test func revisitAppendsANewerLineThatWins() throws {
        let fixture = Fixture()
        let project = try fixture.makeProjectDirectory(named: "alpha")
        try fixture.registry.recordSessionStart(workingDirectory: project, at: Self.firstVisit)
        let firstText = try fixture.registryText()

        try fixture.registry.recordSessionStart(workingDirectory: project, at: Self.secondVisit)

        let records = try fixture.registry.projects()
        #expect(records.map(\.firstSeen) == [Self.firstVisit])
        #expect(records.map(\.lastSeen) == [Self.secondVisit])
        let text = try fixture.registryText()
        #expect(text.hasPrefix(firstText))
        #expect(text.split(separator: "\n").count == 2)
    }

    /// Two different working directories give two records, in visit order.
    @Test func secondWorkingDirectoryAppendsASecondRecord() throws {
        let fixture = Fixture()
        let first = try fixture.makeProjectDirectory(named: "alpha")
        let second = try fixture.makeProjectDirectory(named: "beta")

        try fixture.registry.recordSessionStart(workingDirectory: first, at: Self.firstVisit)
        try fixture.registry.recordSessionStart(workingDirectory: second, at: Self.secondVisit)

        let records = try fixture.registry.projects()
        #expect(records.map(\.path) == [first.path, second.path])
    }

    /// A record whose directory no longer exists is stale: the read skips
    /// it and keeps the live ones.
    @Test func staleEntryIsSkippedOnRead() throws {
        let fixture = Fixture()
        let kept = try fixture.makeProjectDirectory(named: "alpha")
        let removed = try fixture.makeProjectDirectory(named: "beta")
        try fixture.registry.recordSessionStart(workingDirectory: kept, at: Self.firstVisit)
        try fixture.registry.recordSessionStart(workingDirectory: removed, at: Self.secondVisit)
        try FileManager.default.removeItem(at: removed)

        let records = try fixture.registry.projects()

        #expect(records.map(\.path) == [kept.path])
    }

    /// A missing registry file reads as an empty list, not an error.
    @Test func missingRegistryFileReadsAsEmpty() throws {
        let fixture = Fixture()

        let records = try fixture.registry.projects()

        #expect(records.isEmpty)
    }

    /// The text of the line of the log case that does not decode. A line
    /// holds a project path, so no log record may hold it.
    private static let undecodableLineText = "{\"path\":\"undecodable-line-of-the-log-case\"}"

    /// The message of the `warning` record the JSONL reader writes when it
    /// skips a line that does not decode.
    private static let skippedLineWarning = "skipped a line of a JSONL file that does not decode"

    /// A line that does not decode is skipped: the read gives no records and
    /// writes exactly one `warning` record with the skip message, and no
    /// record holds the text of the line.
    @Test func anUndecodableLineIsSkippedWithOneWarning() async throws {
        let fixture = Fixture()
        try fixture.writeRegistryText(Self.undecodableLineText + "\n")

        let (projects, warnings) = try await TelemetryCapture.run(forbidding: [Self.undecodableLineText]) {
            context in
            let projects = try fixture.registry.projects()
            let warnings = context.logRecords.filter {
                $0.level == .warning && "\($0.message)" == Self.skippedLineWarning
            }
            return (projects, warnings.count)
        }

        #expect(projects.isEmpty)
        #expect(warnings == 1)
    }

    // MARK: - The line format

    /// One line of `projects.jsonl` byte for byte: sorted keys, unescaped
    /// slashes, RFC 3339 dates in UTC with milliseconds, one newline after
    /// the record.
    ///
    /// - Parameters:
    ///   - project: The project directory the line names.
    ///   - lastSeen: The RFC 3339 text of `lastSeen`; `firstSeen` is always
    ///     ``firstVisitText``.
    /// - Returns: The line, with its newline.
    private static func registryLine(for project: URL, lastSeen: String) -> String {
        "{\"firstSeen\":\"\(firstVisitText)\",\"lastSeen\":\"\(lastSeen)\",\"path\":\"\(project.path)\"}\n"
    }

    /// ``firstVisit`` as a line of the registry writes it.
    private static let firstVisitText = "2025-08-24T01:46:40.000Z"

    /// ``secondVisit`` as a line of the registry writes it.
    private static let secondVisitText = "2025-08-25T05:33:20.000Z"

    /// A file of hand-written lines reads back to the same records, in file
    /// order.
    @Test func aRegistryFileReadsToTheSameRecords() throws {
        let fixture = Fixture()
        let first = try fixture.makeProjectDirectory(named: "alpha")
        let second = try fixture.makeProjectDirectory(named: "beta")
        try fixture.writeRegistryText(
            Self.registryLine(for: first, lastSeen: Self.secondVisitText)
                + Self.registryLine(for: second, lastSeen: Self.firstVisitText))

        let records = try fixture.registry.projects()

        #expect(
            records == [
                ProjectRegistryRecord(path: first.path, firstSeen: Self.firstVisit, lastSeen: Self.secondVisit),
                ProjectRegistryRecord(path: second.path, firstSeen: Self.firstVisit, lastSeen: Self.firstVisit),
            ])
    }

    /// A session start in a new working directory writes one line in the
    /// line format.
    @Test func recordSessionStartWritesTheRegistryLine() throws {
        let fixture = Fixture()
        let project = try fixture.makeProjectDirectory(named: "alpha")

        try fixture.registry.recordSessionStart(workingDirectory: project, at: Self.firstVisit)

        #expect(try fixture.registryText() == Self.registryLine(for: project, lastSeen: Self.firstVisitText))
    }
}
