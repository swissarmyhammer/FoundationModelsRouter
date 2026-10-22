import FoundationModelsExtras
import Testing

@testable import FoundationModelsRouter

/// The reads of one session's summary out of a ``RouterSessionDirectory``
/// that the directory suites (`RouterSessionDirectoryRegistrationTests`,
/// `RouterSessionDirectoryEventTests`, `RouterSessionDirectoryForkRestoreTests`,
/// `RouterSessionDirectoryRecordedTests`) share (ROUTER-3).
enum SessionDirectorySummaries {
    /// The one summary `directory` gives for `id` among the sessions that
    /// match `query`. The test fails when no such summary is there.
    ///
    /// - Parameters:
    ///   - id: The session id.
    ///   - directory: The directory to read.
    ///   - query: The query to run; the live sessions by default.
    /// - Returns: The summary of the session.
    static func summary(
        of id: ULID, in directory: RouterSessionDirectory, matching query: SessionQuery = SessionQuery()
    ) async throws -> SessionSummary {
        let found = try await directory.sessions(matching: query)
        return try #require(found.first { $0.id == id })
    }
}
