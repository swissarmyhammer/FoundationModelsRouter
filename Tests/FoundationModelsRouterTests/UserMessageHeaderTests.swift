import Foundation
import FoundationModelsExtras
import Testing

@testable import FoundationModelsRouter

/// The words of ``UserMessageHeader`` for a source session with no title
/// to show. The directory gives each root session a default name, so a send
/// through the directory cannot make such a source session.
@Suite("UserMessageHeader: the name of a source session with no title")
struct UserMessageHeaderTests {
    /// The working folder of the source session.
    private static let folder = URL(fileURLWithPath: "/tmp/source-folder")

    /// A summary of a live root session in ``folder`` with `title`.
    ///
    /// - Parameter title: The title of the session.
    /// - Returns: The summary.
    private static func summary(title: String?) -> SessionSummary {
        let now = Date()
        return SessionSummary(
            id: ULID(), agentID: "agent", workingDirectory: folder, title: title, tags: [], kind: .root,
            state: .idle, origin: .client, createdAt: now, updatedAt: now, isLive: true)
    }

    /// The production change that makes this test fail: a header that shows
    /// an empty or missing title instead of the short id of the source
    /// session.
    @Test("a source session with an empty or missing title gives its short id", arguments: ["", nil])
    func noTitleGivesTheShortID(title: String?) {
        let summary = Self.summary(title: title)

        let header = UserMessageHeader(source: summary.id, summary: summary)

        #expect(header.line == "From the user, in \(summary.shortID) (\(Self.folder.path))")
    }
}
