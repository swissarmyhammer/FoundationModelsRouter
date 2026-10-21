import Foundation
import FoundationModelsExtras
import Testing

@testable import FoundationModelsRouter

/// A vended session writes its first `facts.json` from its
/// ``SessionConfiguration``, holds its facts where synchronous code reads
/// them, and rewrites them through `updateFacts` (ROUTER-1). The write-once
/// `session.json` gets no new key and never changes after creation.
@Suite struct SessionFactsRecordingTests {
    /// The keys of ``SessionFacts`` that must never reach `session.json`.
    private static let factKeys: Set<String> = [
        "agentID", "agentName", "tags", "title", "startedBy", "origin", "archivedAt",
    ]

    /// The configuration of a vended root that carries every fact field.
    private static func configuration(startedBy: ULID) -> SessionConfiguration {
        SessionConfiguration(
            agentID: "folder:/Users/dev/example/agents/reviewer",
            agentName: "Reviewer",
            tags: ["kanban", "review"],
            title: "Review the login change",
            startedBy: startedBy,
            origin: FoundationModelsExtras.SessionDirectoryOrigin.tool)
    }

    /// The facts ``configuration(startedBy:)`` gives a new session.
    private static func expectedFacts(startedBy: ULID) -> SessionFacts {
        SessionFacts(
            agentID: "folder:/Users/dev/example/agents/reviewer",
            agentName: "Reviewer",
            tags: ["kanban", "review"],
            title: "Review the login change",
            startedBy: startedBy,
            origin: .tool)
    }

    /// Vends one root session with the fact configuration under a durable
    /// recording root, runs `body` with it, and closes it.
    private static func withVendedSession(
        _ body: (RoutedSessionActor, ULID) async throws -> Void
    ) async throws {
        let directory = RouterTestFixtures.makeTempDir(prefix: "SessionFactsRecordingTests")
        defer { try? FileManager.default.removeItem(at: directory) }
        let (router, profile) = try await RouterTestFixtures.resolveStandardProfile(
            over: BasicLLMContainer(), cacheDir: directory.appendingPathComponent("cache"),
            recordingsDir: directory.appendingPathComponent("recordings"))
        let startedBy = ULID.generate()
        let session = profile.standard.makeSession(configuration: configuration(startedBy: startedBy))
        let actor = try #require(session as? RoutedSessionActor)
        do {
            try await body(actor, startedBy)
        } catch {
            await session.close()
            throw error
        }
        await session.close()
        withExtendedLifetime(router) {}
    }

    /// The JSON object of a file.
    private static func jsonObject(at file: URL) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any] ?? [:]
    }

    /// A new session's `facts.json` holds the facts of its configuration.
    @Test func aVendedSessionWritesTheFactsOfItsConfiguration() async throws {
        try await Self.withVendedSession { session, startedBy in
            let written = try SessionFacts.read(from: session.recordingDirectory)

            #expect(written == Self.expectedFacts(startedBy: startedBy))
        }
    }

    /// The sidecar of a session with facts holds none of the fact keys, at
    /// its top level or in its configuration envelope.
    @Test func theSidecarGetsNoFactKey() async throws {
        try await Self.withVendedSession { session, _ in
            let sidecar = try Self.jsonObject(
                at: RouterTestFixtures.sidecarURL(inSessionDirectory: session.recordingDirectory))
            let configuration = sidecar["configuration"] as? [String: Any] ?? [:]

            #expect(Set(sidecar.keys).isDisjoint(with: Self.factKeys))
            #expect(!configuration.isEmpty)
            #expect(Set(configuration.keys).isDisjoint(with: Self.factKeys))
        }
    }

    /// `facts` reads with no `await` and equals the file.
    @Test func factsIsReadableSynchronouslyAndEqualsTheFile() async throws {
        try await Self.withVendedSession { session, startedBy in
            let facts = Self.readFactsSynchronously(of: session)
            let onDisk = try SessionFacts.read(from: session.recordingDirectory)

            #expect(facts == Self.expectedFacts(startedBy: startedBy))
            #expect(onDisk == facts)
        }
    }

    /// Reads `facts` from a synchronous function, so the read compiles only
    /// when it needs no `await`.
    private static func readFactsSynchronously(of session: any RoutedSession) -> SessionFacts {
        session.facts
    }

    /// `updateFacts` rewrites `facts.json`, updates `facts`, returns the new
    /// value, and leaves `session.json` byte for byte unchanged.
    @Test func updateFactsRewritesTheFileAndTheValue() async throws {
        try await Self.withVendedSession { session, _ in
            let sidecarURL = RouterTestFixtures.sidecarURL(inSessionDirectory: session.recordingDirectory)
            let sidecarBefore = try Data(contentsOf: sidecarURL)

            let updated = try session.updateFacts { facts in
                facts.tags.insert("urgent")
                facts.title = "Renamed"
            }
            let onDisk = try SessionFacts.read(from: session.recordingDirectory)
            let sidecarAfter = try Data(contentsOf: sidecarURL)

            #expect(updated.tags == ["kanban", "review", "urgent"])
            #expect(updated.title == "Renamed")
            #expect(session.facts == updated)
            #expect(onDisk == updated)
            #expect(sidecarAfter == sidecarBefore)
        }
    }

    /// A session vended with no fact field writes empty facts.
    @Test func aSessionWithNoFactFieldWritesEmptyFacts() async throws {
        let directory = RouterTestFixtures.makeTempDir(prefix: "SessionFactsRecordingTests")
        defer { try? FileManager.default.removeItem(at: directory) }
        let (router, profile) = try await RouterTestFixtures.resolveStandardProfile(
            over: BasicLLMContainer(), cacheDir: directory.appendingPathComponent("cache"),
            recordingsDir: directory.appendingPathComponent("recordings"))
        let session = profile.standard.makeSession(configuration: SessionConfiguration())

        let written = try SessionFacts.read(from: session.recordingDirectory)

        #expect(written == SessionFacts())
        #expect(session.facts == SessionFacts())
        await session.close()
        withExtendedLifetime(router) {}
    }
}
