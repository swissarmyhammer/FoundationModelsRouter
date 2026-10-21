import Foundation
import FoundationModelsExtras
import TelemetryTestSupport
import Testing

@testable import FoundationModelsRouter

/// The facts of a session survive a restore, a session recorded before
/// `facts.json` existed restores with empty facts, and a fork writes its own
/// facts (ROUTER-1).
@Suite struct SessionFactsRestoreTests {
    /// The message fragment of the one warning a restore logs for a session
    /// with no `facts.json`.
    private static let missingFactsWarning = "no facts.json"

    /// Runs `body` with a resolved profile over a durable recording root.
    private static func withProfile(
        _ body: (LanguageModelProfile) async throws -> Void
    ) async throws {
        try await SessionFactsFixtures.withRecordingProfile(prefix: "SessionFactsRestoreTests", body)
    }

    /// Vends a root of `profile` with the facts of
    /// ``SessionFactsFixtures/configuration(startedBy:)``.
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

    /// A recording with no `facts.json` restores with empty facts, logs one
    /// warning, and gets no file written for it.
    @Test func aRecordingWithNoFactsFileRestoresWithEmptyFactsAndOneWarning() async throws {
        try await Self.withProfile { profile in
            let recorded = Self.makeRecordedSession(in: profile)
            await recorded.close()
            let factsFile = recorded.recordingDirectory.appendingPathComponent(SessionFacts.fileName)
            try FileManager.default.removeItem(at: factsFile)

            let (restoredFacts, warnings) = try await TelemetryCapture.run(forbidding: []) { context in
                let restored = try await profile.standard.restoreSession(id: recorded.id)
                let facts = restored.session.facts
                await restored.session.close()
                let warnings = context.logRecords.filter {
                    $0.level == .warning && "\($0.message)".contains(Self.missingFactsWarning)
                }
                return (facts, warnings)
            }

            #expect(restoredFacts == SessionFacts())
            #expect(warnings.count == 1)
            #expect(!FileManager.default.fileExists(atPath: factsFile.path))
        }
    }

    /// A fork writes its own `facts.json`: the agent id, the agent name and
    /// the tags of its source, origin `fork`, and no title and no
    /// `startedBy`.
    @Test func aForkWritesItsOwnFacts() async throws {
        try await Self.withProfile { profile in
            let source = Self.makeRecordedSession(in: profile)
            let fork = try await source.fork(workingDirectory: nil)
            let written = try SessionFacts.read(from: fork.recordingDirectory)
            let held = fork.facts
            await fork.close()
            await source.close()

            let expected = SessionFacts(
                agentID: SessionFactsFixtures.agentID,
                agentName: SessionFactsFixtures.agentName,
                tags: SessionFactsFixtures.tags,
                origin: .fork)
            #expect(written == expected)
            #expect(held == expected)
        }
    }

    /// A restored recorded fork, a node of its source's restored tree, reads
    /// its own facts back.
    @Test func aRestoredForkReadsItsFactsBack() async throws {
        try await Self.withProfile { profile in
            let source = Self.makeRecordedSession(in: profile)
            let fork = try await source.fork(workingDirectory: nil)
            let written = fork.facts
            await fork.close()
            await source.close()

            let tree = try await profile.standard.restoreSessionTree(root: source.id)
            let restoredFork = try #require(tree.session(fork.id))
            let restoredFacts = restoredFork.facts
            await restoredFork.close()
            await tree.root.close()

            #expect(restoredFacts == written)
            #expect(restoredFacts.origin == .fork)
        }
    }
}
