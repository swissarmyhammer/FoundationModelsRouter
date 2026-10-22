import Foundation
import FoundationModelsExtras
import Testing

@testable import FoundationModelsRouter

/// The mutable `facts.json` of one recorded session (ROUTER-1): the facts
/// that change after the session starts, beside the write-once
/// `session.json`. Every test writes into its own throwaway session
/// directory under the temp directory.
@Suite struct SessionFactsTests {
    /// The instant every made value is archived at, in milliseconds since
    /// 1970. It falls inside a second, so a file that keeps whole seconds
    /// does not read it back.
    private static let archivedMillisecondsSince1970: Int64 = 1_756_000_000_123

    /// The instant every made value is archived at.
    private static var archivedAt: Date {
        DateTime(millisecondsSince1970: archivedMillisecondsSince1970).date
    }

    /// The bytes of the write-once sidecar the overwrite tests put beside
    /// `facts.json`.
    private static let sidecarBytes = Data("{\"slot\":\"standard\"}\n".utf8)

    /// A throwaway session directory. The OS reclaims the temp directory.
    private static func makeSessionDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SessionFactsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// Facts with every field filled, with a folder agent id (D71).
    private static func makeFacts() -> SessionFacts {
        SessionFacts(
            agentID: "folder:/Users/dev/example/agents/reviewer",
            agentName: "Reviewer",
            tags: ["kanban", "review"],
            title: "Review the login change",
            startedBy: ULID.generate(),
            origin: .tool,
            archivedAt: archivedAt)
    }

    /// A write followed by a read gives an equal value, the folder agent id,
    /// the set of tags and the archive date included.
    @Test func writeThenReadRoundTrips() throws {
        let directory = try Self.makeSessionDirectory()
        let facts = Self.makeFacts()

        try facts.write(to: directory)
        let read = try SessionFacts.read(from: directory)

        #expect(read == facts)
        #expect(read?.agentID == "folder:/Users/dev/example/agents/reviewer")
        #expect(read?.tags == ["kanban", "review"])
    }

    /// Facts with no field set round-trip as well.
    @Test func emptyFactsRoundTrip() throws {
        let directory = try Self.makeSessionDirectory()

        try SessionFacts().write(to: directory)

        #expect(try SessionFacts.read(from: directory) == SessionFacts())
    }

    /// A directory with no `facts.json` reads as `nil`, not an error.
    @Test func aDirectoryWithNoFactsFileReadsAsNil() throws {
        let directory = try Self.makeSessionDirectory()

        #expect(try SessionFacts.read(from: directory) == nil)
    }

    /// The file is named `facts.json`.
    @Test func theFileIsNamedFactsJSON() throws {
        let directory = try Self.makeSessionDirectory()

        try Self.makeFacts().write(to: directory)

        let file = directory.appendingPathComponent("facts.json")
        #expect(SessionFacts.fileName == "facts.json")
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    /// A second write replaces the first, leaves no temporary file, and does
    /// not touch the write-once `session.json` beside it.
    @Test func aSecondWriteOverwritesAndLeavesTheSidecarAlone() throws {
        let directory = try Self.makeSessionDirectory()
        let sidecar = directory.appendingPathComponent(sessionSidecarFileName)
        try Self.sidecarBytes.write(to: sidecar)
        var facts = Self.makeFacts()
        try facts.write(to: directory)

        facts.tags.insert("urgent")
        facts.title = "Renamed"
        try facts.write(to: directory)

        #expect(try SessionFacts.read(from: directory) == facts)
        #expect(try Data(contentsOf: sidecar) == Self.sidecarBytes)
        let entries = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(Set(entries) == [SessionFacts.fileName, sessionSidecarFileName])
    }

    /// A file with a key this reader does not know still decodes: the schema
    /// is additive.
    @Test func anUnknownExtraKeyDecodes() throws {
        let directory = try Self.makeSessionDirectory()
        let text = """
            {"agentID":"default","tags":["a"],"schemaVersion":1,"addedByALaterRouter":true}
            """
        try Data(text.utf8).write(to: directory.appendingPathComponent(SessionFacts.fileName))

        let read = try #require(try SessionFacts.read(from: directory))

        #expect(read.agentID == "default")
        #expect(read.tags == ["a"])
        #expect(read.origin == nil)
    }

    /// A file with no `schemaVersion` key and no `tags` key decodes with the
    /// documented absent values.
    @Test func absentKeysDecodeAsTheirAbsentValues() throws {
        let directory = try Self.makeSessionDirectory()
        try Data("{}".utf8).write(to: directory.appendingPathComponent(SessionFacts.fileName))

        let read = try #require(try SessionFacts.read(from: directory))

        #expect(read == SessionFacts())
        #expect(read.schemaVersion == SessionFacts.currentSchemaVersion)
    }

    /// A file stamped with a schema version newer than this reader knows is
    /// refused, not misread.
    @Test func aNewerSchemaVersionIsRefused() throws {
        let directory = try Self.makeSessionDirectory()
        let newer = SessionFacts.currentSchemaVersion + 1
        let text = "{\"schemaVersion\":\(newer)}"
        try Data(text.utf8).write(to: directory.appendingPathComponent(SessionFacts.fileName))

        #expect(
            throws: RecordingSchemaVersionError.recordingFromNewerRouter(
                directory: directory, version: newer, supported: SessionFacts.currentSchemaVersion)
        ) {
            try SessionFacts.read(from: directory)
        }
    }

    /// The file holds the facts in the record encoding the other Recording
    /// files share: one line, sorted keys, RFC 3339 dates in UTC with
    /// milliseconds and unescaped slashes.
    ///
    /// The production change that makes this test fail: a `facts.json` date
    /// written with whole seconds, as the JSONL lines no longer are.
    @Test func theFileIsWrittenInTheSharedRecordEncoding() throws {
        let directory = try Self.makeSessionDirectory()
        let facts = SessionFacts(
            agentID: "folder:/agents/reviewer", tags: ["review"], archivedAt: Self.archivedAt)

        try facts.write(to: directory)

        let text = try String(
            contentsOf: directory.appendingPathComponent(SessionFacts.fileName), encoding: .utf8)
        #expect(
            text == """
                {"agentID":"folder:/agents/reviewer","archivedAt":"2025-08-24T01:46:40.123Z",\
                "schemaVersion":1,"tags":["review"]}
                """)
    }

    /// A date with whole seconds only is not the text the file writes, so the
    /// read refuses it rather than reading a different instant.
    ///
    /// The production change that makes this test fail: a `facts.json`
    /// reader that still takes whole-second dates.
    @Test func aWholeSecondDateIsRefused() throws {
        let directory = try Self.makeSessionDirectory()
        let text = "{\"archivedAt\":\"2025-08-24T01:46:40Z\"}"
        try Data(text.utf8).write(to: directory.appendingPathComponent(SessionFacts.fileName))

        #expect(throws: DecodingError.self) {
            try SessionFacts.read(from: directory)
        }
    }

    /// The origin is the Extras `SessionDirectoryOrigin`, by its raw value.
    @Test func theOriginIsWrittenByItsRawValue() throws {
        let directory = try Self.makeSessionDirectory()

        try SessionFacts(origin: FoundationModelsExtras.SessionDirectoryOrigin.trigger).write(to: directory)

        let data = try Data(contentsOf: directory.appendingPathComponent(SessionFacts.fileName))
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        #expect(object["origin"] as? String == "trigger")
    }
}
