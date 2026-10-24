import Foundation
import FoundationModelsExtras
import Testing

@testable import FoundationModelsRouter

/// The facts of a session survive a restore, and a restored session rewrites
/// its `index.md` with the body a host wrote kept (ROUTER-1).
@Suite struct SessionFactsRestoreTests {
    /// The text a host writes below the frontmatter of an `index.md`.
    private static let hostBody = "\n# Notes\nhost text\n"

    /// The title a restored session changes its facts to.
    private static let restoredTitle = "Renamed after restore"

    /// Runs `body` with a resolved profile over a durable recording root.
    ///
    /// - Parameter body: The work to run with the resolved profile.
    private static func withProfile(
        _ body: (LanguageModelProfile) async throws -> Void
    ) async throws {
        try await SessionFactsFixtures.withRecordingProfile(prefix: "SessionFactsRestoreTests", body)
    }

    /// Vends a root of `profile` with the facts of
    /// ``SessionFactsFixtures/configuration(startedBy:)``.
    ///
    /// - Parameter profile: The profile to vend from.
    /// - Returns: The session.
    private static func makeRecordedSession(in profile: LanguageModelProfile) -> any RoutedSession {
        profile.standard.makeSession(configuration: SessionFactsFixtures.configuration(startedBy: ULID.generate()))
    }

    /// A restore gives the facts the session wrote, the folder agent id
    /// included.
    @Test func aRestoreReadsTheWrittenFactsBack() async throws {
        try await Self.withProfile { profile in
            let recorded = Self.makeRecordedSession(in: profile)
            let written = recorded.facts
            await recorded.close()

            let restored = try await profile.standard.restoreSession(id: recorded.id)
            let restoredFacts = restored.session.facts
            await restored.session.close()

            #expect(restoredFacts == written)
            #expect(restoredFacts.agentID == SessionFactsFixtures.agentID)
        }
    }

    /// A restored session's `updateFacts` rewrites the frontmatter of its
    /// `index.md` and keeps the body a host wrote byte for byte.
    @Test func aRestoredSessionsUpdateFactsRewritesItsIndexAndKeepsTheBody() async throws {
        try await Self.withProfile { profile in
            let recorded = Self.makeRecordedSession(in: profile)
            await recorded.close()
            let file = SessionIndexFile.url(in: recorded.recordingDirectory)
            let withBody = try String(contentsOf: file, encoding: .utf8) + Self.hostBody
            try withBody.write(to: file, atomically: true, encoding: .utf8)
            let bodyBefore = FrontmatterDocument.split(text: withBody).body

            let restored = try await profile.standard.restoreSession(id: recorded.id)
            let actor = try #require(restored.session as? RoutedSessionActor)
            let updated = actor.updateFacts { facts in facts.title = Self.restoredTitle }
            await restored.session.close()

            let onDisk = try #require(try SessionIndexFile.read(in: actor.recordingDirectory)).facts
            let bodyAfter = FrontmatterDocument.split(text: try String(contentsOf: file, encoding: .utf8)).body

            // The restore names the folder by its canonical path (`/private/var`
            // for the temporary directory), so compare canonical paths.
            let restoredFolder = try actor.recordingDirectory.resourceValues(forKeys: [.canonicalPathKey]).canonicalPath
            let recordedFolder = try recorded.recordingDirectory.resourceValues(forKeys: [.canonicalPathKey])
                .canonicalPath
            #expect(restoredFolder == recordedFolder)
            #expect(updated.title == Self.restoredTitle)
            #expect(onDisk == updated)
            #expect(onDisk.agentID == SessionFactsFixtures.agentID)
            #expect(bodyBefore.hasSuffix(Self.hostBody))
            #expect(bodyAfter == bodyBefore)
        }
    }
}
