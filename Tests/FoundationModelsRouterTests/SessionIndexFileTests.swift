import Foundation
import FoundationModelsExtras
import Testing

@testable import FoundationModelsRouter

/// The `index.md` of one recorded session: a YAML frontmatter that holds the
/// ``SessionRecord`` (the facts, the listing data and the restore data), and
/// an open body that Router never reads and keeps on every rewrite. Every
/// test writes into its own throwaway session folder under the temp
/// directory.
@Suite struct SessionIndexFileTests {
    /// An instant inside a second, in milliseconds since 1970, so a file that
    /// keeps whole seconds does not read it back.
    private static let millisecondsSince1970: Int64 = 1_756_000_000_123

    /// The instant every made record is updated at.
    private static var updatedAt: Date {
        DateTime(millisecondsSince1970: millisecondsSince1970).date
    }

    /// The text of ``updatedAt`` in the frontmatter.
    private static let updatedAtText = "2025-08-24T01:46:40.123Z"

    /// The milliseconds that ``firstActivityAt`` comes before ``updatedAt``.
    private static let firstActivityLeadMilliseconds: Int64 = 60_000

    /// The instant the first submission of every made record started.
    private static var firstActivityAt: Date {
        DateTime(millisecondsSince1970: millisecondsSince1970 - firstActivityLeadMilliseconds).date
    }

    /// The working context of every made record, in tokens.
    private static let context = 8_192

    /// The fork cut of a made fork record, in backend entries.
    private static let forkedAtEntryCount = 7

    /// The fork cut of a made fork record, in recorded history.
    private static let forkedAtHistoryOrdinal = 9

    /// The compactions of a made record.
    private static let compactionCount = 2

    /// A body a host writes below the frontmatter, with a line that is a
    /// fence, so a reader that split the text again would lose part of it.
    private static let hostBody = "# Notes\n\nThe host keeps its notes here.\n---\nAfter a rule.\n"

    /// A throwaway session folder. The OS reclaims the temp directory.
    private static func makeSessionDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SessionIndexFileTests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent(ULID.generate().description, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// The facts of a made record, each field filled.
    private static func makeFacts() -> SessionFacts {
        SessionFacts(
            agentID: "folder:/Users/dev/example/agents/reviewer",
            agentName: "Reviewer",
            tags: ["kanban", "review"],
            title: "Review the login change",
            startedBy: ULID.generate(),
            origin: .tool,
            archivedAt: updatedAt)
    }

    /// A record with every field filled: a fork with a spawn, a profile and
    /// a configuration.
    ///
    /// - Parameter directory: The session folder, whose name is the id.
    /// - Returns: The record.
    private static func makeFullRecord(in directory: URL) throws -> SessionRecord {
        SessionRecord(
            sessionId: try #require(ULID(directory.lastPathComponent)),
            workingDirectory: URL(fileURLWithPath: "/tmp/sample working directory", isDirectory: true),
            updatedAt: updatedAt,
            slot: .flash,
            model: "org/model-a",
            context: context,
            recordingLevel: .full,
            routerId: ULID.generate(),
            facts: makeFacts(),
            firstActivityAt: firstActivityAt,
            additionalDirectories: [
                URL(fileURLWithPath: "/tmp/extra-one", isDirectory: true),
                URL(fileURLWithPath: "/tmp/extra-two", isDirectory: true),
            ],
            forkParentId: ULID.generate(),
            forkedAtEntryCount: forkedAtEntryCount,
            forkedAtHistoryOrdinal: forkedAtHistoryOrdinal,
            instructions: "You are terse.\nAnswer in one line.",
            grammar: #"{"type":"object"}"#,
            profile: SessionRecord.ResolvedProfile(
                definitionName: "coding", standard: "org/std-a", flash: "org/flash-a", embedding: "org/emb-a",
                context: context),
            agentSpawn: SessionRecord.AgentSpawn(parentSessionId: ULID.generate(), parentToolCallId: "call-42"),
            configuration: SessionConfiguration(
                instructions: "You are terse.", workingDirectory: URL(fileURLWithPath: "/tmp/sample"),
                tools: []
            ).persistable,
            compactionCount: compactionCount)
    }

    /// A root record with only the required fields.
    ///
    /// - Parameter directory: The session folder, whose name is the id.
    /// - Returns: The record.
    private static func makeRootRecord(in directory: URL) throws -> SessionRecord {
        SessionRecord(
            sessionId: try #require(ULID(directory.lastPathComponent)),
            workingDirectory: directory,
            updatedAt: updatedAt,
            slot: .standard,
            model: "org/model-a",
            context: context,
            recordingLevel: .full,
            routerId: ULID.generate())
    }

    /// The text of the `index.md` in `directory`.
    private static func indexText(in directory: URL) throws -> String {
        try String(contentsOf: SessionIndexFile.url(in: directory), encoding: .utf8)
    }

    // MARK: - Round trip

    /// A save followed by a read gives an equal record, each field included.
    @Test func everyFieldSurvivesASaveAndARead() throws {
        let directory = try Self.makeSessionDirectory()
        let record = try Self.makeFullRecord(in: directory)

        try SessionIndexFile.save(record, in: directory)

        #expect(try SessionIndexFile.read(in: directory) == record)
    }

    /// A root record reads back with no fork cut, no spawn, no first
    /// activity, no tags and no additional folders.
    @Test func aRootRecordReadsBackWithItsAbsentFieldsAbsent() throws {
        let directory = try Self.makeSessionDirectory()
        let record = try Self.makeRootRecord(in: directory)

        try SessionIndexFile.save(record, in: directory)
        let read = try #require(try SessionIndexFile.read(in: directory))

        #expect(read == record)
        #expect(read.forkParentId == nil)
        #expect(read.forkedAtEntryCount == nil)
        #expect(read.agentSpawn == nil)
        #expect(read.firstActivityAt == nil)
        #expect(read.additionalDirectories.isEmpty)
        #expect(read.facts == SessionFacts())
    }

    /// The file is `index.md` in the session folder.
    @Test func theFileIsNamedIndexMarkdown() throws {
        let directory = try Self.makeSessionDirectory()

        try SessionIndexFile.save(try Self.makeRootRecord(in: directory), in: directory)

        #expect(SessionIndexFile.fileName == "index.md")
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("index.md").path))
    }

    /// The frontmatter holds the facts at its top level, the working folder
    /// as the path `cwd`, the folder name as `sessionId`, and each date as
    /// ISO 8601 text with milliseconds.
    @Test func theFrontmatterHoldsFlatFactsThePathAndMillisecondDates() throws {
        let directory = try Self.makeSessionDirectory()
        let record = try Self.makeFullRecord(in: directory)

        try SessionIndexFile.save(record, in: directory)
        let text = try Self.indexText(in: directory)

        #expect(text.hasPrefix("---\n"))
        #expect(text.contains("sessionId: \(directory.lastPathComponent)"))
        #expect(text.contains("cwd: /tmp/sample working directory"))
        #expect(text.contains("title: Review the login change"))
        #expect(text.contains("agentName: Reviewer"))
        #expect(text.contains(Self.updatedAtText))
        #expect(!text.contains("facts:"))
    }

    /// A date with whole seconds only is not the text Router writes, so the
    /// read refuses it rather than reading another instant.
    @Test func aWholeSecondDateIsRefused() throws {
        let directory = try Self.makeSessionDirectory()
        try SessionIndexFile.save(try Self.makeRootRecord(in: directory), in: directory)
        let text = try Self.indexText(in: directory)
        let wholeSecond = text.replacingOccurrences(of: Self.updatedAtText, with: "2025-08-24T01:46:40Z")
        try wholeSecond.write(to: SessionIndexFile.url(in: directory), atomically: true, encoding: .utf8)

        #expect(throws: SessionIndexFileError.self) { try SessionIndexFile.read(in: directory) }
    }

    // MARK: - Absent, damaged and newer files

    /// A folder with no `index.md` reads as `nil`.
    @Test func aFolderWithNoIndexReadsAsNil() throws {
        let directory = try Self.makeSessionDirectory()

        #expect(try SessionIndexFile.read(in: directory) == nil)
    }

    /// An `index.md` with no frontmatter is not a session record.
    @Test func anIndexWithNoFrontmatterThrows() throws {
        let directory = try Self.makeSessionDirectory()
        try Self.hostBody.write(to: SessionIndexFile.url(in: directory), atomically: true, encoding: .utf8)

        #expect(throws: SessionIndexFileError.missingFrontmatter(file: SessionIndexFile.url(in: directory))) {
            try SessionIndexFile.read(in: directory)
        }
    }

    /// An `index.md` whose frontmatter lacks a required key throws.
    @Test func anIndexWithAnUndecodableFrontmatterThrows() throws {
        let directory = try Self.makeSessionDirectory()
        try "---\ntitle: only a title\n---\n".write(
            to: SessionIndexFile.url(in: directory), atomically: true, encoding: .utf8)

        #expect(throws: SessionIndexFileError.self) { try SessionIndexFile.read(in: directory) }
    }

    /// A record stamped with a newer schema version than this reader knows is
    /// refused with the typed error.
    @Test func aNewerSchemaVersionIsRefused() throws {
        let directory = try Self.makeSessionDirectory()
        var record = try Self.makeRootRecord(in: directory)
        let newer = RecordingSchemaVersion.current + 1
        record.schemaVersion = newer
        try SessionIndexFile.save(record, in: directory)

        #expect(
            throws: RecordingSchemaVersionError.recordingFromNewerRouter(
                directory: directory, version: newer, supported: RecordingSchemaVersion.current)
        ) { try SessionIndexFile.read(in: directory) }
    }

    // MARK: - The open body

    /// A rewrite replaces the frontmatter and keeps the body that a host
    /// wrote below it, byte for byte.
    @Test func aRewriteKeepsTheBody() throws {
        let directory = try Self.makeSessionDirectory()
        var record = try Self.makeRootRecord(in: directory)
        try SessionIndexFile.save(record, in: directory)
        let withBody = try Self.indexText(in: directory) + Self.hostBody
        try withBody.write(to: SessionIndexFile.url(in: directory), atomically: true, encoding: .utf8)

        record.facts.title = "Renamed"
        try SessionIndexFile.save(record, in: directory)
        let text = try Self.indexText(in: directory)

        #expect(text.hasSuffix("---\n" + Self.hostBody))
        #expect(try SessionIndexFile.read(in: directory)?.facts.title == "Renamed")
    }

    /// A first save writes an empty body.
    @Test func aFirstSaveWritesAnEmptyBody() throws {
        let directory = try Self.makeSessionDirectory()

        try SessionIndexFile.save(try Self.makeRootRecord(in: directory), in: directory)

        #expect(FrontmatterDocument.split(text: try Self.indexText(in: directory)).body.isEmpty)
    }

    /// A save into a folder that is not there throws the save error and
    /// makes no folder.
    @Test func aSaveIntoAMissingFolderThrows() throws {
        let directory = try Self.makeSessionDirectory()
        let missing = directory.appendingPathComponent(ULID.generate().description, isDirectory: true)
        let record = try Self.makeRootRecord(in: missing)

        #expect(throws: FrontmatterDocumentSaveError.temporaryFileFailed(errno: ENOENT)) {
            try SessionIndexFile.save(record, in: missing)
        }
        #expect(!FileManager.default.fileExists(atPath: missing.path))
    }
}
