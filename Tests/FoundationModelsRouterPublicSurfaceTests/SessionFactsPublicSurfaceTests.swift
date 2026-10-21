import Foundation
import Testing

import FoundationModelsRouter

/// Holds ``SessionFacts`` to the access level a consumer outside this package
/// needs (ROUTER-1). A host makes the facts of a session, sets each field,
/// writes them into the session's directory and reads them back.
///
/// The import is plain, with no `@testable`, so a member that loses `public`
/// stops this file from compiling before a single test runs.
@Suite("SessionFacts over a plain import")
struct SessionFactsPublicSurfaceTests {
    /// The instant the consumer archives the session at, in seconds since
    /// 1970.
    private static let archivedSecondSince1970: TimeInterval = 1_756_000_000

    @Test("a consumer makes, writes and reads the facts of a session")
    func aConsumerWritesAndReadsTheFacts() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SessionFactsPublicSurfaceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var facts = SessionFacts(agentID: "default", tags: ["triage"], origin: .client)
        facts.agentName = "Default"
        facts.title = "Triage"
        facts.startedBy = ULID.generate()
        facts.archivedAt = Date(timeIntervalSince1970: Self.archivedSecondSince1970)

        try facts.write(to: directory)

        #expect(try SessionFacts.read(from: directory) == facts)
        #expect(facts.schemaVersion == SessionFacts.currentSchemaVersion)
        #expect(SessionFacts.fileName == "facts.json")
    }
}
