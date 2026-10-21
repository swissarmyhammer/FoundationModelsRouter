import Foundation
import FoundationModelsExtras

@testable import FoundationModelsRouter

/// The session facts that the facts suites (`SessionFactsRecordingTests`,
/// `SessionFactsRestoreTests`) record, and the durable recording profile
/// they record them under (ROUTER-1).
enum SessionFactsFixtures {
    /// The folder agent id (D71) of the recorded session.
    static let agentID = "folder:/Users/dev/example/agents/reviewer"

    /// The agent name of the recorded session.
    static let agentName = "Reviewer"

    /// The tags of the recorded session.
    static let tags: Set<String> = ["kanban", "review"]

    /// The title of the recorded session.
    static let title = "Review the login change"

    /// The configuration of a vended root that carries every fact field.
    ///
    /// - Parameter startedBy: The session that started the root.
    /// - Returns: The configuration.
    static func configuration(startedBy: ULID) -> SessionConfiguration {
        SessionConfiguration(
            agentID: agentID,
            agentName: agentName,
            tags: tags,
            title: title,
            startedBy: startedBy,
            origin: FoundationModelsExtras.SessionDirectoryOrigin.tool)
    }

    /// The facts ``configuration(startedBy:)`` gives a new session.
    ///
    /// - Parameter startedBy: The session that started the root.
    /// - Returns: The facts.
    static func expectedFacts(startedBy: ULID) -> SessionFacts {
        SessionFacts(
            agentID: agentID,
            agentName: agentName,
            tags: tags,
            title: title,
            startedBy: startedBy,
            origin: .tool)
    }

    /// Resolves the standard profile over a durable recording root in a new
    /// temporary directory and runs `body` with it; the directory goes after.
    ///
    /// - Parameters:
    ///   - prefix: The name prefix of the temporary directory.
    ///   - body: The work to run with the resolved profile.
    static func withRecordingProfile(
        prefix: String,
        _ body: (LanguageModelProfile) async throws -> Void
    ) async throws {
        let directory = RouterTestFixtures.makeTempDir(prefix: prefix)
        defer { try? FileManager.default.removeItem(at: directory) }
        let (router, profile) = try await RouterTestFixtures.resolveStandardProfile(
            over: BasicLLMContainer(), cacheDir: directory.appendingPathComponent("cache"),
            recordingsDir: directory.appendingPathComponent("recordings"))
        try await body(profile)
        withExtendedLifetime(router) {}
    }
}
