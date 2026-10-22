import Foundation
import Testing

import FoundationModelsRouter

/// Holds ``SessionFacts`` to the access level a consumer outside this package
/// needs (ROUTER-1). A host makes the facts of a session and sets and reads
/// each field. The facts are a plain value: the `index.md` of the session
/// holds them on disk.
///
/// The import is plain, with no `@testable`, so a member that loses `public`
/// stops this file from compiling before a single test runs.
@Suite("SessionFacts over a plain import")
struct SessionFactsPublicSurfaceTests {
    /// The instant the consumer archives the session at, in seconds since
    /// 1970.
    private static let archivedSecondSince1970: TimeInterval = 1_756_000_000

    /// A consumer makes the facts of a session, sets each field, and reads
    /// each field back.
    @Test("a consumer makes the facts of a session and sets and reads each field")
    func aConsumerSetsAndReadsTheFacts() {
        let starter = ULID.generate()
        let archivedAt = Date(timeIntervalSince1970: Self.archivedSecondSince1970)
        var facts = SessionFacts(agentID: "default", tags: ["triage"], origin: .client)
        facts.agentName = "Default"
        facts.title = "Triage"
        facts.startedBy = starter
        facts.archivedAt = archivedAt

        #expect(facts.agentID == "default")
        #expect(facts.agentName == "Default")
        #expect(facts.tags == ["triage"])
        #expect(facts.title == "Triage")
        #expect(facts.startedBy == starter)
        #expect(facts.origin == .client)
        #expect(facts.archivedAt == archivedAt)
        #expect(facts != SessionFacts())
    }
}
