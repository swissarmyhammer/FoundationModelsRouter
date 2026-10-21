import Foundation
import Testing

import FoundationModelsRouter

/// Holds the record of past sessions to the access level a consumer outside
/// this package needs (ROUTER-3, D72): ``SessionIndex`` with
/// ``SessionIndexRecord``, ``SessionIndexReadResult``, ``SessionIndexWarning``
/// and ``SessionIndexError``, and ``ProjectRegistry`` with
/// ``ProjectRegistryRecord``. The ACP agent reads them to answer
/// `session/list` and to browse the projects of a user.
///
/// The import is plain, with no `@testable`, so a member or a case that loses
/// `public` stops this file from compiling before a single test runs.
@Suite("SessionIndex and ProjectRegistry over a plain import")
struct SessionRecordPublicSurfaceTests {
    /// A whole second, so the RFC 3339 round trip of a record is exact.
    private static let wholeSecond = Date(timeIntervalSince1970: 1_756_000_000)

    /// A fresh directory under the temp directory. The OS reclaims it.
    ///
    /// - Parameter name: The prefix of the directory's name.
    /// - Returns: The directory URL; the directory itself is not created.
    private static func makeScratchDirectory(named name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
    }

    @Test("a consumer appends, reads, removes and rebuilds index records")
    func aConsumerDrivesTheSessionIndex() throws {
        let root = Self.makeScratchDirectory(named: "SessionRecordPublicSurface")
        let index = SessionIndex(root: root)
        var record = SessionIndexRecord(
            sessionId: "01K3E2Z6Q8R4M7N5P3T1V9W2X4",
            cwd: "/Users/dev/example",
            title: "Fix the flaky login test",
            updatedAt: Self.wholeSecond,
            additionalDirectories: ["/Users/dev/shared"])
        record.title = "Fix the login test"

        try index.append(record)
        let result: SessionIndexReadResult = try index.read()
        #expect(result.records == [record])
        #expect(result.warnings.isEmpty)

        try index.removeRecords(sessionId: record.sessionId)
        #expect(try index.read().records.isEmpty)
        #expect(try index.rebuild(cwd: URL(fileURLWithPath: record.cwd)).isEmpty)
        #expect(index.root == root)
        #expect(SessionIndex.indexFileName == "sessions.jsonl")
        #expect(SessionIndex.gitattributesFileName == ".gitattributes")
    }

    @Test("a consumer reads the last activity date of a session directory")
    func aConsumerReadsTheLastActivityDate() {
        let directory = Self.makeScratchDirectory(named: "last-activity")
        let date = SessionIndex.lastActivityDate(inSessionDirectory: directory)
        #expect(date.timeIntervalSince1970.rounded(.down) == date.timeIntervalSince1970)
    }

    @Test("a consumer names the index warning and the index error")
    func aConsumerNamesTheWarningAndTheError() {
        let warning: SessionIndexWarning = .tornFinalLine
        let error: SessionIndexError = .corruptLine(number: 2)

        #expect(warning.description.contains(SessionIndex.indexFileName))
        #expect(error.description.contains("line 2"))
    }

    @Test("a consumer records a session start and reads the live projects")
    func aConsumerDrivesTheProjectRegistry() throws {
        let project = Self.makeScratchDirectory(named: "SessionRecordPublicSurfaceProject")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let userDirectory = Self.makeScratchDirectory(named: "SessionRecordPublicSurfaceUser")
        let registry = ProjectRegistry(directory: userDirectory)

        try registry.recordSessionStart(workingDirectory: project, at: Self.wholeSecond)

        let expected = ProjectRegistryRecord(path: project.path, firstSeen: Self.wholeSecond, lastSeen: Self.wholeSecond)
        #expect(try registry.projects() == [expected])
        #expect(registry.directory == userDirectory)
        #expect(ProjectRegistry.registryFileName == "projects.jsonl")
    }
}
