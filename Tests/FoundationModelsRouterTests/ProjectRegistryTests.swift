import Foundation
import Logging
import TelemetryTestSupport
import Testing

@testable import FoundationModelsRouter

/// The cross-project registry `projects.jsonl` in the user layer: one appended
/// record per new working directory, `lastSeen` updates on a revisit, and a
/// stale entry is skipped on read. Every test builds its own throwaway user
/// directory and project directories under a temp directory.
///
/// Copied from the ACPAgent `ProjectRegistryTests` (ROUTER-3): Router owns the
/// record of past sessions now (D72). The compatibility tests at the end pin
/// the bytes the ACPAgent code wrote, so the files on a user's disk stay
/// valid.
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

    /// A revisit updates `lastSeen`, keeps `firstSeen`, and appends no
    /// second line for the same working directory.
    @Test func revisitUpdatesLastSeenWithoutASecondLine() throws {
        let fixture = Fixture()
        let project = try fixture.makeProjectDirectory(named: "alpha")
        try fixture.registry.recordSessionStart(workingDirectory: project, at: Self.firstVisit)

        try fixture.registry.recordSessionStart(workingDirectory: project, at: Self.secondVisit)

        let records = try fixture.registry.projects()
        #expect(records.map(\.firstSeen) == [Self.firstVisit])
        #expect(records.map(\.lastSeen) == [Self.secondVisit])
        let lines = try fixture.registryText().split(separator: "\n")
        #expect(lines.count == 1)
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

    /// A line that does not decode writes one `warning` record. The path of
    /// the registry file is in the metadata of the record, and no record
    /// holds the text of the line.
    @Test func anUndecodableLineWritesOneWarningWithTheRegistryPathInMetadata() async throws {
        let fixture = Fixture()
        let registryFile = fixture.userDirectory.appendingPathComponent(
            ProjectRegistry.registryFileName)
        try Self.undecodableLineText.write(to: registryFile, atomically: true, encoding: .utf8)

        let records = try await TelemetryCapture.run(forbidding: [Self.undecodableLineText]) {
            context in
            _ = try fixture.registry.projects()
            return context.logRecords
        }

        let pathKey = RouterTelemetry.LogMetadataKey.filePath
        let pathRecords = records.filter { $0.metadata[pathKey] != nil }
        #expect(pathRecords.count == 1)
        let record = try #require(pathRecords.first)
        #expect(record.level == .warning)
        #expect(record.metadata[pathKey] == .string(registryFile.path))
    }

    /// The label of the logger of the project registry.
    private static let projectRegistryLoggerLabel = "FoundationModelsRouter.ProjectRegistry"

    /// The logger of the project registry has the module label and the
    /// category of the project registry.
    @Test func projectRegistryLoggerHasTheModuleLabel() {
        #expect(RouterTelemetry.makeLogger(.projectRegistry).label == Self.projectRegistryLoggerLabel)
    }

    // MARK: - ACPAgent compatibility

    /// One line of `projects.jsonl` byte for byte as the ACPAgent
    /// `ProjectRegistry` wrote it: sorted keys, unescaped slashes, RFC 3339
    /// dates, one newline after the record.
    ///
    /// - Parameters:
    ///   - project: The project directory the line names.
    ///   - lastSeen: The RFC 3339 text of `lastSeen`; `firstSeen` is always
    ///     ``firstVisitText``.
    /// - Returns: The line, with its newline.
    private static func acpAgentLine(for project: URL, lastSeen: String) -> String {
        "{\"firstSeen\":\"\(firstVisitText)\",\"lastSeen\":\"\(lastSeen)\",\"path\":\"\(project.path)\"}\n"
    }

    /// ``firstVisit`` as the ACPAgent code serialized it.
    private static let firstVisitText = "2025-08-24T01:46:40Z"

    /// ``secondVisit`` as the ACPAgent code serialized it.
    private static let secondVisitText = "2025-08-25T05:33:20Z"

    /// A file the ACPAgent code wrote reads back to the same records, in file
    /// order.
    @Test func anACPAgentRegistryFileReadsToTheSameRecords() throws {
        let fixture = Fixture()
        let first = try fixture.makeProjectDirectory(named: "alpha")
        let second = try fixture.makeProjectDirectory(named: "beta")
        try fixture.writeRegistryText(
            Self.acpAgentLine(for: first, lastSeen: Self.secondVisitText)
                + Self.acpAgentLine(for: second, lastSeen: Self.firstVisitText))

        let records = try fixture.registry.projects()

        #expect(
            records == [
                ProjectRegistryRecord(path: first.path, firstSeen: Self.firstVisit, lastSeen: Self.secondVisit),
                ProjectRegistryRecord(path: second.path, firstSeen: Self.firstVisit, lastSeen: Self.firstVisit),
            ])
    }

    /// A revisit of a project in a file the ACPAgent code wrote updates
    /// `lastSeen` in place: the file holds the one line, in the ACPAgent
    /// bytes, with no second line.
    @Test func aRevisitOfAnACPAgentRegistryFileUpdatesLastSeenInPlace() throws {
        let fixture = Fixture()
        let project = try fixture.makeProjectDirectory(named: "alpha")
        try fixture.writeRegistryText(Self.acpAgentLine(for: project, lastSeen: Self.firstVisitText))

        try fixture.registry.recordSessionStart(workingDirectory: project, at: Self.secondVisit)

        #expect(try fixture.registryText() == Self.acpAgentLine(for: project, lastSeen: Self.secondVisitText))
    }

    /// A session start in a new working directory writes the same bytes the
    /// ACPAgent code wrote for it.
    @Test func recordSessionStartWritesTheACPAgentBytes() throws {
        let fixture = Fixture()
        let project = try fixture.makeProjectDirectory(named: "alpha")

        try fixture.registry.recordSessionStart(workingDirectory: project, at: Self.firstVisit)

        #expect(try fixture.registryText() == Self.acpAgentLine(for: project, lastSeen: Self.firstVisitText))
    }
}
