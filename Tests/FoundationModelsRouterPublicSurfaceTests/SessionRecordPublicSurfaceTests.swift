import Foundation
import Testing

import FoundationModelsRouter

/// Holds the registry of past projects to the access level a consumer
/// outside this package needs (ROUTER-3, D72): ``ProjectRegistry`` with
/// ``ProjectRegistryRecord``. The ACP agent reads them to browse the projects
/// of a user.
///
/// The import is plain, with no `@testable`, so a member or a case that loses
/// `public` stops this file from compiling before a single test runs.
@Suite("ProjectRegistry and ProjectRegistryRecord over a plain import")
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
