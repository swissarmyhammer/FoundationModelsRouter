import Foundation
import Testing

import FoundationModelsRouter

/// Holds the store of a user's projects to the access level a consumer
/// outside this package needs: ``ProjectStore`` with ``ProjectRecord``. The
/// ACP agent registers a project at each session start, lists the projects
/// to browse them, and gives the store the folder it lives in.
///
/// The import is plain, with no `@testable`, so a member that loses `public`
/// stops this file from compiling before a single test runs.
@Suite("ProjectStore and ProjectRecord over a plain import")
struct ProjectStorePublicSurfaceTests {
    /// A whole second, and so a whole millisecond, the precision of the date
    /// a project file keeps, so the round trip of a record is exact.
    private static let wholeSecond = Date(timeIntervalSince1970: 1_756_000_000)

    /// A fresh directory under the temp directory. The OS reclaims it.
    ///
    /// - Parameter name: The prefix of the directory's name.
    /// - Returns: The directory URL; the directory itself is not created.
    private static func makeScratchDirectory(named name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
    }

    @Test("a consumer registers, lists and removes a project")
    func aConsumerDrivesTheProjectStore() throws {
        let project = Self.makeScratchDirectory(named: "ProjectStorePublicSurfaceProject")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let storeDirectory = Self.makeScratchDirectory(named: "ProjectStorePublicSurfaceStore")
        let store = ProjectStore(directory: storeDirectory)

        try store.register(workingDirectory: project, at: Self.wholeSecond)

        let expected = ProjectRecord(path: project.path, firstSeen: Self.wholeSecond, lastSeen: Self.wholeSecond)
        #expect(try store.projects() == [expected])
        #expect(store.directory == storeDirectory)
        let file = storeDirectory.appendingPathComponent(ProjectStore.fileName(forWorkingDirectory: project))
        #expect(FileManager.default.fileExists(atPath: file.path))

        try store.remove(workingDirectory: project)

        #expect(try store.projects().isEmpty)
    }
}
