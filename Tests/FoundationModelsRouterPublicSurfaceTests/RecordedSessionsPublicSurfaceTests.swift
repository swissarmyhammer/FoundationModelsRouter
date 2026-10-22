import Foundation
import FoundationModelsExtras
import Testing

import FoundationModelsRouter

/// Holds ``RouterSessionDirectory/recordedSessions(in:)``,
/// ``SessionRecord`` and ``RouterSessionDirectory/setAdditionalDirectories(to:for:)``
/// to the access level a host outside this package needs (ROUTER-3). A host
/// lists the sessions of a recording root from the `index.md` of each
/// session folder, reads the listing data of each record, and sets the
/// added folders of a session.
///
/// The import is plain, with no `@testable`, so a member that loses `public`
/// stops this file from compiling before a single test runs.
@Suite("Recorded sessions over a plain import")
struct RecordedSessionsPublicSurfaceTests {
    /// The title of the session that had a prompt.
    private static let title = "Triage"

    /// The working folder of each recorded session, as the frontmatter holds
    /// it.
    private static let workingDirectoryPath = "/fixture-work/"

    /// The folder the host added to the session that had a prompt.
    private static let addedDirectoryPath = "/fixture-added/"

    /// The last activity of the session that had a prompt, as ISO 8601 text
    /// in UTC with milliseconds.
    private static let promptedUpdatedAtText = "2026-09-25T18:22:10.101Z"

    /// The first submission of the session that had a prompt.
    private static let firstActivityAtText = "2026-09-25T18:20:01.250Z"

    /// The creation of the session that never had a prompt.
    private static let quietUpdatedAtText = "2026-09-24T09:00:00.000Z"

    /// The tool call of the spawning session.
    private static let parentToolCallId = "call-1"

    /// A fresh recording root under the temp directory.
    ///
    /// - Returns: The root URL; the folder itself is not made.
    private static func makeRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("RecordedSessionsPublicSurfaceTests-\(UUID().uuidString)", isDirectory: true)
    }

    /// The date of ISO 8601 text in UTC with milliseconds.
    ///
    /// - Parameter text: The text.
    /// - Returns: The date, or `nil` when the text is not that form.
    private static func date(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text)
    }

    /// A host lists the records of a recording root, newest first, and reads
    /// the listing data of each record.
    @Test("a host lists the records of a recording root and reads their listing data")
    func aHostListsTheRecordsOfARoot() throws {
        let root = Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let ids = [ULID.generate(), ULID.generate()].sorted(by: >)
        let prompted = ids[0]
        let quiet = ids[1]
        let parent = ULID.generate()
        try HandWrittenSessionIndex.write(
            id: prompted, under: root, workingDirectory: Self.workingDirectoryPath,
            updatedAt: Self.promptedUpdatedAtText, title: Self.title,
            optionalLines: [
                "firstActivityAt: \(Self.firstActivityAtText)",
                "additionalDirectories:",
                "  - \(Self.addedDirectoryPath)",
                "agentSpawn:",
                "  parentSessionId: \(parent)",
                "  parentToolCallId: \(Self.parentToolCallId)",
            ])
        try HandWrittenSessionIndex.write(
            id: quiet, under: root, workingDirectory: Self.workingDirectoryPath,
            updatedAt: Self.quietUpdatedAtText, title: nil)

        let records = try RouterSessionDirectory.recordedSessions(in: root)

        #expect(records.map(\.sessionId) == [prompted, quiet])
        let first = try #require(records.first)
        #expect(first.workingDirectory == URL(filePath: Self.workingDirectoryPath, directoryHint: .isDirectory))
        #expect(first.updatedAt == Self.date(Self.promptedUpdatedAtText))
        #expect(first.firstActivityAt == Self.date(Self.firstActivityAtText))
        #expect(first.additionalDirectories == [URL(filePath: Self.addedDirectoryPath, directoryHint: .isDirectory)])
        #expect(first.facts.title == Self.title)
        #expect(first.forkParentId == nil)
        #expect(first.agentSpawn == SessionRecord.AgentSpawn(parentSessionId: parent, parentToolCallId: Self.parentToolCallId))
        let last = try #require(records.last)
        #expect(last.firstActivityAt == nil)
        #expect(last.facts.title == nil)
        #expect(last.agentSpawn == nil)
    }

    /// A host reaches ``RouterSessionDirectory/setAdditionalDirectories(to:for:)``
    /// through the directory of a router, and an id no session has throws
    /// `unknownSession`.
    @Test("a host sets the added folders of a session through the router's directory")
    func aHostSetsTheAddedFolders() async throws {
        let directory = Router(pool: ModelPool()).sessionDirectory
        let unknown = ULID.generate()

        await #expect(throws: SessionDirectoryError.unknownSession(unknown)) {
            try await directory.setAdditionalDirectories(
                to: [URL(filePath: Self.addedDirectoryPath, directoryHint: .isDirectory)], for: unknown)
        }
    }
}
