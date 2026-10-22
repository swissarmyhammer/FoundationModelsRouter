import Foundation
import FoundationModelsExtras
import Testing

import FoundationModelsRouter

/// Holds ``RouterSessionDirectory/useRecordingRoots(_:)`` to the access level
/// a host outside this package needs (ROUTER-3). The host gives the recording
/// roots of its projects, and a query that includes the recorded sessions
/// reads them.
///
/// The import is plain, with no `@testable`, so a member that loses `public`
/// stops this file from compiling before a single test runs.
@Suite("Recording roots over a plain import")
struct RecordingRootsPublicSurfaceTests {
    /// The title of the recorded session.
    private static let title = "Triage"

    @Test("a host's recording root gives its recorded sessions to the router's directory")
    func aHostRecordingRootGivesItsRecordedSessions() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RecordingRootsPublicSurfaceTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let id = ULID.generate()
        let sessionDirectory = root.appendingPathComponent(id.description, isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
        try SessionFacts(title: Self.title).write(to: sessionDirectory)
        let directory = Router(pool: ModelPool()).sessionDirectory

        await directory.useRecordingRoots { [root] }
        let found = try await directory.sessions(matching: SessionQuery(includesRecorded: true))

        #expect(found.map(\.id) == [id])
        #expect(found.first?.title == Self.title)
        #expect(found.first?.isLive == false)
    }
}
