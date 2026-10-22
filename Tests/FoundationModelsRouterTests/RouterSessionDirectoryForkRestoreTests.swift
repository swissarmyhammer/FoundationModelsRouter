import Foundation
import FoundationModelsExtras
import Testing

@testable import FoundationModelsRouter

/// The other vend points of a session register in its router's directory
/// too (ROUTER-3): a fork, a restored root and each restored fork. A closed
/// session leaves the live list while a host still holds it.
///
/// Each test records under a durable root of its own, so a restore reads
/// back a recording the same test made.
@Suite struct RouterSessionDirectoryForkRestoreTests {
    /// Runs `body` with a resolved profile over a durable recording root, and
    /// the session directory of the router that resolved it.
    ///
    /// - Parameter body: The work to run with the profile and its directory.
    private static func withRecordingProfile(
        _ body: (LanguageModelProfile, RouterSessionDirectory) async throws -> Void
    ) async throws {
        try await SessionFactsFixtures.withRecordingProfile(prefix: "RouterSessionDirectoryForkRestoreTests") {
            profile in
            let directory = try #require(profile.standard.sessionDirectory)
            try await body(profile, directory)
        }
    }

    /// Closes each session in `sessions`.
    private static func close(_ sessions: [any RoutedSession]) async {
        for session in sessions {
            await session.close()
        }
    }

    // MARK: - Fork

    /// A fork is in the directory with the kind `fork` and its source as
    /// parent, right after `fork(workingDirectory:)` returns.
    @Test func aForkIsInTheDirectoryAsAForkOfItsSource() async throws {
        try await Self.withRecordingProfile { profile, directory in
            let source = profile.standard.makeSession(configuration: SessionConfiguration())
            let fork = try await source.fork(workingDirectory: nil)

            let summary = try await SessionDirectorySummaries.summary(of: fork.id, in: directory)

            #expect(summary.kind == .fork)
            #expect(summary.parentID == source.id)
            await Self.close([fork, source])
        }
    }

    // MARK: - Restore

    /// `restoreSession(id:)` gives a root that is in the directory, as a root.
    @Test func aRestoredRootIsInTheDirectory() async throws {
        try await Self.withRecordingProfile { profile, directory in
            let recorded = profile.standard.makeSession(configuration: SessionConfiguration())
            await recorded.close()

            let restored = try await profile.standard.restoreSession(id: recorded.id)
            let summary = try await SessionDirectorySummaries.summary(of: restored.session.id, in: directory)

            #expect(summary.kind == .root)
            #expect(summary.parentID == nil)
            await Self.close([restored.session])
        }
    }

    /// A restored root whose sidecar records an agent spawn is a subagent of
    /// the spawning session.
    @Test func aRestoredRootWithARecordedSpawnIsASubagent() async throws {
        try await Self.withRecordingProfile { profile, directory in
            let spawningSessionId = ULID.generate()
            let spawn = SessionSidecar.AgentSpawn(
                parentSessionId: spawningSessionId, parentToolCallId: "agents-tool-call-1")
            let recorded = profile.standard.makeSession(configuration: SessionConfiguration(agentSpawn: spawn))
            await recorded.close()

            let restored = try await profile.standard.restoreSession(id: recorded.id)
            let summary = try await SessionDirectorySummaries.summary(of: restored.session.id, in: directory)

            #expect(summary.kind == .subagent)
            #expect(summary.parentID == spawningSessionId)
            await Self.close([restored.session])
        }
    }

    /// Each recorded fork of a restored root is in the directory, with the
    /// kind `fork` and its source as parent, while the tree holds it.
    @Test func aRestoredForkIsInTheDirectoryAsAForkOfItsSource() async throws {
        try await Self.withRecordingProfile { profile, directory in
            let source = profile.standard.makeSession(configuration: SessionConfiguration())
            let fork = try await source.fork(workingDirectory: nil)
            await Self.close([fork, source])

            let tree = try await profile.standard.restoreSessionTree(root: source.id)
            let restoredFork = try #require(tree.session(fork.id))
            let summary = try await SessionDirectorySummaries.summary(of: restoredFork.id, in: directory)

            #expect(summary.kind == .fork)
            #expect(summary.parentID == source.id)
            await Self.close([restoredFork, tree.root])
        }
    }

    /// A restored session's summary carries the facts that the restore read
    /// back from its `facts.json`.
    @Test func aRestoredSummaryCarriesTheRecordedFacts() async throws {
        try await Self.withRecordingProfile { profile, directory in
            let startedBy = ULID.generate()
            let recorded = profile.standard.makeSession(
                configuration: SessionFactsFixtures.configuration(startedBy: startedBy))
            await recorded.close()

            let restored = try await profile.standard.restoreSession(id: recorded.id)
            let summary = try await SessionDirectorySummaries.summary(of: restored.session.id, in: directory)

            #expect(summary.agentID == SessionFactsFixtures.agentID)
            #expect(summary.agentName == SessionFactsFixtures.agentName)
            #expect(summary.tags == SessionFactsFixtures.tags)
            #expect(summary.title == SessionFactsFixtures.title)
            #expect(summary.startedBy == startedBy)
            #expect(summary.origin == .tool)
            await Self.close([restored.session])
        }
    }

    // MARK: - Close

    /// A session that is in the live query before `close()` is gone from it
    /// after, while the test still holds it.
    @Test func aClosedSessionLeavesTheLiveList() async throws {
        try await Self.withRecordingProfile { profile, directory in
            let session = profile.standard.makeSession(configuration: SessionConfiguration())
            let beforeClose = try await directory.sessions(matching: SessionQuery())

            await session.close()
            let afterClose = try await directory.sessions(matching: SessionQuery())

            #expect(beforeClose.map(\.id) == [session.id])
            #expect(afterClose.isEmpty)
            withExtendedLifetime(session) {}
        }
    }
}
