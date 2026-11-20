import Foundation
import FoundationModelsExtras
import Testing

@testable import FoundationModelsRouter

/// The summary of a recorded session made from its record alone (D207):
/// `SessionSummary(record:)` gives the same summary as the recorded summary
/// of ``RouterSessionDirectory``, and
/// ``RouterSessionDirectory/recordedSummary(inSessionFolder:)`` reads the
/// `index.md` of one session folder and no other folder.
///
/// Each test writes its records by hand under a new recording root. The
/// directory of a new router reads that root through `useRecordingRoots(_:)`.
@Suite struct SessionSummaryRecordTests {
    /// The title of each recorded session that has a title.
    private static let title = "Review the login change"

    /// The last summary in the facts of the session with a recap.
    private static let lastSummary = "The login change is reviewed."

    /// The recap in the facts of the session with a recap.
    private static let recap = "You reviewed the login change and found one bug."

    /// The provenance of an imported session (D209 (h)).
    private static let provenance = SessionImportProvenance(
        agent: "codex", sourceID: "source-7", sourcePath: "/Users/dev/.codex/sessions/source-7.jsonl",
        importedAt: Date(timeIntervalSince1970: 0))

    /// The number of characters of the short id of a session.
    private static let shortIDLength = 7

    /// The POSIX permissions of a folder that the owner can search but not
    /// list.
    private static let searchOnlyPermissions = 0o100

    /// The POSIX permissions of a file that no one can read.
    private static let noPermissions = 0

    /// The POSIX permissions that let the owner remove a folder.
    private static let ownerFolderPermissions = 0o700

    /// The POSIX permissions that let the owner remove a file.
    private static let ownerFilePermissions = 0o600

    /// A new recording root, and the directory of a new router that reads it.
    struct Fixture {
        /// The recording root of the test.
        let root: URL

        /// The directory that reads ``root``.
        let directory: RouterSessionDirectory

        /// Makes the root and the directory.
        ///
        /// - Returns: The fixture.
        static func make() async -> Fixture {
            let root = RouterTestFixtures.makeTempDir(prefix: "SessionSummaryRecordTests")
            let directory = Router(pool: ModelPool()).sessionDirectory
            await directory.useRecordingRoots { [root] }
            return Fixture(root: root, directory: directory)
        }

        /// Writes a record to a new session folder and reads it back.
        ///
        /// - Parameters:
        ///   - parent: The folder that holds the new session folder. The
        ///     default is ``root``.
        ///   - change: Changes the placeholder record before the write.
        /// - Returns: The record as the `index.md` holds it.
        /// - Throws: The error of the write or of the read.
        func writeSession(
            under parent: URL? = nil, _ change: (inout SessionRecord) -> Void = { _ in }
        ) throws -> SessionRecord {
            let folder = (parent ?? root).appendingPathComponent(ULID.generate().description, isDirectory: true)
            var record = SessionRecordFixtures.record(in: folder)
            change(&record)
            try SessionRecordFixtures.write(record, to: folder)
            return try SessionRecordFixtures.recordOnDisk(in: folder)
        }

        /// The session folder of a record written under ``root``.
        ///
        /// - Parameter record: A record that ``writeSession(under:_:)`` wrote
        ///   directly under ``root``.
        /// - Returns: The session folder.
        func folder(of record: SessionRecord) -> URL {
            root.appendingPathComponent(record.sessionId.description, isDirectory: true)
        }

        /// The recorded summary that the directory gives for `record`.
        ///
        /// - Parameter record: A record on disk under ``root``.
        /// - Returns: The summary of the directory.
        /// - Throws: The error of the read, or the `#require` failure when
        ///   the directory has no summary for the session.
        func directorySummary(of record: SessionRecord) async throws -> SessionSummary {
            try #require(try await directory.summary(of: record.sessionId))
        }

        /// Removes the root and all that it holds.
        func remove() {
            try? FileManager.default.removeItem(at: root)
        }
    }

    // MARK: - SessionSummary(record:)

    /// A root session gives the summary of the directory.
    @Test func aRootSessionGivesTheSummaryOfTheDirectory() async throws {
        let fixture = await Fixture.make()
        defer { fixture.remove() }
        let record = try fixture.writeSession { $0.facts.title = Self.title }

        let expected = try await fixture.directorySummary(of: record)

        #expect(SessionSummary(record: record) == expected)
    }

    /// A fork gives the summary of the directory: the kind and the parent
    /// that the record holds.
    @Test func aForkGivesTheSummaryOfTheDirectory() async throws {
        let fixture = await Fixture.make()
        defer { fixture.remove() }
        let source = try fixture.writeSession { $0.facts.title = Self.title }
        let fork = try fixture.writeSession(under: fixture.folder(of: source)) { record in
            record.forkParentId = source.sessionId
            record.facts.title = Self.title
        }

        let expected = try await fixture.directorySummary(of: fork)

        #expect(SessionSummary(record: fork) == expected)
    }

    /// A fork has the kind `fork` and the parent that the record holds.
    @Test func aForkHasTheKindAndTheParentOfTheRecord() {
        let source = ULID.generate()
        var record = SessionRecordFixtures.record(in: URL(fileURLWithPath: "/unused", isDirectory: true))
        record.forkParentId = source

        let summary = SessionSummary(record: record)

        #expect(summary.kind == .fork && summary.parentID == source)
    }

    /// An archived session gives the summary of the directory.
    @Test func anArchivedSessionGivesTheSummaryOfTheDirectory() async throws {
        let fixture = await Fixture.make()
        defer { fixture.remove() }
        let record = try fixture.writeSession { record in
            record.facts.title = Self.title
            record.facts.archivedAt = record.updatedAt
        }

        let expected = try await fixture.directorySummary(of: record)

        #expect(SessionSummary(record: record) == expected)
    }

    /// A session with a recap gives the summary of the directory.
    @Test func aSessionWithARecapGivesTheSummaryOfTheDirectory() async throws {
        let fixture = await Fixture.make()
        defer { fixture.remove() }
        let record = try fixture.writeSession { record in
            record.facts.title = Self.title
            record.facts.lastSummary = Self.lastSummary
            record.facts.recap = Self.recap
            record.facts.recapAt = record.updatedAt
        }

        let expected = try await fixture.directorySummary(of: record)

        #expect(SessionSummary(record: record) == expected)
    }

    /// A fork with no title gives the summary of the directory. The
    /// directory gives no default name to a fork that it reads, so the
    /// summary of the directory also has no title.
    @Test func aSessionWithNoTitleGivesTheSummaryOfTheDirectory() async throws {
        let fixture = await Fixture.make()
        defer { fixture.remove() }
        let source = try fixture.writeSession { $0.facts.title = Self.title }
        let fork = try fixture.writeSession(under: fixture.folder(of: source)) { record in
            record.forkParentId = source.sessionId
        }

        let expected = try await fixture.directorySummary(of: fork)

        #expect(SessionSummary(record: fork) == expected)
    }

    /// The production change that makes this test fail: a summary that
    /// does not give the provenance of the facts (D209 (h)).
    @Test func anImportedSessionGivesItsProvenance() {
        var record = SessionRecordFixtures.record(in: URL(fileURLWithPath: "/unused", isDirectory: true))
        record.facts.importedFrom = Self.provenance

        let summary = SessionSummary(record: record)

        #expect(summary.importedFrom == Self.provenance)
    }

    /// The production change that makes this test fail: facts that keep
    /// the provenance dates that are not rounded, while the `index.md` holds
    /// them rounded to the millisecond.
    @Test func theFactsRoundTheProvenanceDatesToTheMillisecond() {
        var facts = SessionFacts()
        facts.importedFrom = RouterTestFixtures.provenance(Self.provenance)

        #expect(facts.importedFrom == Self.provenance)
    }

    /// A session with no title has the 7-character short id as its slug.
    @Test func aSessionWithNoTitleHasTheShortIDAsItsSlug() {
        let record = SessionRecordFixtures.record(in: URL(fileURLWithPath: "/unused", isDirectory: true))

        let summary = SessionSummary(record: record)

        #expect(summary.slug == String(record.sessionId.ulidString.suffix(Self.shortIDLength)).lowercased())
    }

    // MARK: - recordedSummary(inSessionFolder:)

    /// A session folder gives the summary of its record.
    @Test func aSessionFolderGivesTheSummaryOfItsRecord() async throws {
        let fixture = await Fixture.make()
        defer { fixture.remove() }
        let record = try fixture.writeSession { $0.facts.title = Self.title }

        let summary = try RouterSessionDirectory.recordedSummary(inSessionFolder: fixture.folder(of: record))

        #expect(summary == SessionSummary(record: record))
    }

    /// A folder with no `index.md` gives no summary.
    @Test func aFolderWithNoIndexGivesNoSummary() async throws {
        let fixture = await Fixture.make()
        defer { fixture.remove() }
        let folder = fixture.root.appendingPathComponent(ULID.generate().description, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let summary = try RouterSessionDirectory.recordedSummary(inSessionFolder: folder)

        #expect(summary == nil)
    }

    /// An `index.md` with no frontmatter throws the read error of the file.
    @Test func aDamagedIndexThrows() async throws {
        let fixture = await Fixture.make()
        defer { fixture.remove() }
        let folder = fixture.root.appendingPathComponent(ULID.generate().description, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = SessionIndexFile.url(in: folder)
        try "no frontmatter here".write(to: file, atomically: true, encoding: .utf8)

        #expect(throws: SessionIndexFileError.missingFrontmatter(file: file)) {
            try RouterSessionDirectory.recordedSummary(inSessionFolder: folder)
        }
    }

    /// A sibling session folder that the process cannot read does not make
    /// the read of a session folder fail: the read touches no other folder.
    /// The sibling folder can be searched but not listed, and its `index.md`
    /// cannot be read, so a read of the whole root fails on it.
    @Test func aSiblingFolderThatDoesNotReadDoesNotStopTheRead() async throws {
        let fixture = await Fixture.make()
        let record = try fixture.writeSession { $0.facts.title = Self.title }
        let sibling = try fixture.writeSession()
        let siblingFolder = fixture.folder(of: sibling)
        let siblingIndex = SessionIndexFile.url(in: siblingFolder)
        try FileManager.default.setAttributes([.posixPermissions: Self.noPermissions], ofItemAtPath: siblingIndex.path)
        try FileManager.default.setAttributes([.posixPermissions: Self.searchOnlyPermissions], ofItemAtPath: siblingFolder.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: Self.ownerFolderPermissions], ofItemAtPath: siblingFolder.path)
            try? FileManager.default.setAttributes([.posixPermissions: Self.ownerFilePermissions], ofItemAtPath: siblingIndex.path)
            fixture.remove()
        }

        let summary = try RouterSessionDirectory.recordedSummary(inSessionFolder: fixture.folder(of: record))

        #expect(summary == SessionSummary(record: record))
    }
}
