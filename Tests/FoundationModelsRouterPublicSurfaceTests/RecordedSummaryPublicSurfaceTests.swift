import Foundation
import FoundationModelsExtras
import Testing

import FoundationModelsRouter

/// Holds `SessionSummary(record:)` and
/// ``RouterSessionDirectory/recordedSummary(inSessionFolder:)`` to the access
/// level a host outside this package needs (D207). A host makes the summary
/// of a recorded session from its record, or from the `index.md` of its
/// folder, with no directory and with no read of another folder.
///
/// The import is plain, with no `@testable`, so a member that loses `public`
/// stops this file from compiling before a single test runs.
@Suite("Recorded summaries over a plain import")
struct RecordedSummaryPublicSurfaceTests {
    /// The working folder of the recorded session, as the frontmatter holds
    /// it.
    private static let workingDirectoryPath = "/fixture-work/"

    /// The last activity of the recorded session, as ISO 8601 text in UTC
    /// with milliseconds.
    private static let updatedAtText = "2026-11-19T09:00:00.000Z"

    /// A fresh recording root under the temp directory.
    ///
    /// - Returns: The root URL; the folder itself is not made.
    private static func makeRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("RecordedSummaryPublicSurfaceTests-\(UUID().uuidString)", isDirectory: true)
    }

    /// A host reads the summary of one session folder, and it is the summary
    /// of the record of that folder.
    @Test("a host reads the summary of one session folder and of its record")
    func aHostReadsTheSummaryOfOneFolder() throws {
        let root = Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = try HandWrittenSessionIndex.write(
            id: ULID.generate(), under: root, workingDirectory: Self.workingDirectoryPath,
            updatedAt: Self.updatedAtText, title: nil)
        let record = try #require(try RouterSessionDirectory.recordedSessions(in: root).first)

        let summary = try RouterSessionDirectory.recordedSummary(inSessionFolder: folder)

        #expect(summary == SessionSummary(record: record))
    }
}
