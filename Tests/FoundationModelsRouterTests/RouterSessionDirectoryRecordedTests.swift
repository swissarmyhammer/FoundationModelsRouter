import Foundation
import FoundationModelsExtras
import Testing

@testable import FoundationModelsRouter

/// The recorded sessions of ``RouterSessionDirectory`` (ROUTER-3): a query
/// with `includesRecorded` gives the root sessions on disk that are not live,
/// listed from the session folders of the recording roots, through the
/// `index.md` of each folder. No listing file beside the folders is read or
/// written.
///
/// Router A records the sessions; router B is a new router over the same
/// recordings folder, standing in for a new process, and finds them through
/// the roots the host gives with `useRecordingRoots(_:)`.
@Suite struct RouterSessionDirectoryRecordedTests {
    /// Makes the two routers over one new recordings folder.
    private static func makeFixture() async throws -> SessionDirectoryRouterPair {
        try await SessionDirectoryRouterPair.make(prefix: "RouterSessionDirectoryRecordedTests")
    }

    // MARK: - A new process

    /// A second router finds the two root sessions that the first recorded,
    /// as not live, only when the query includes the recorded sessions.
    @Test func aSecondRouterFindsTheRecordedRootsOnlyWithIncludesRecorded() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.remove() }
        let first = await fixture.recordClosedRoot()
        let second = await fixture.recordClosedRoot()
        await fixture.useRoot(of: first.recordingDirectory)

        let recorded = try await fixture.directory.sessions(matching: SessionQuery(includesRecorded: true))
        let live = try await fixture.directory.sessions(matching: SessionQuery())

        #expect(recorded.map(\.id) == [second.id, first.id])
        #expect(recorded.allSatisfy { !$0.isLive })
        #expect(live.isEmpty)
    }

    // MARK: - Listed by folder

    /// The name of the listing file that the record of past sessions no
    /// longer writes beside the session folders.
    private static let removedListingFileName = "sessions.jsonl"

    /// The name of a folder in a recording root that is not named by a ULID.
    private static let notASessionFolderName = "not-a-ulid"

    /// The name of a plain file in a recording root.
    private static let plainFileName = "notes.txt"

    /// A durable root writes no listing file beside its session folders:
    /// each session folder holds its own `index.md`.
    @Test func aDurableRootWritesNoListingFile() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.remove() }
        let recorded = await fixture.recordClosedRoot()

        let root = recorded.recordingDirectory.deletingLastPathComponent()
        let names = try FileManager.default.contentsOfDirectory(atPath: root.path)

        #expect(!names.contains(Self.removedListingFileName))
        #expect(FileManager.default.fileExists(atPath: SessionIndexFile.url(in: recorded.recordingDirectory).path))
    }

    /// A recorded root is listed from the `index.md` of its folder under the
    /// recording root.
    @Test func aRecordedRootIsListedFromItsFolder() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.remove() }
        let recorded = await fixture.recordClosedRoot()
        await fixture.useRoot(of: recorded.recordingDirectory)

        let found = try await fixture.directory.sessions(matching: SessionQuery(includesRecorded: true))

        #expect(found.map(\.id) == [recorded.id])
    }

    /// An entry of a recording root that is not a folder named by a ULID is
    /// not listed: a folder with another name and a plain file are passed
    /// over.
    @Test func anEntryThatIsNotASessionFolderIsNotListed() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.remove() }
        let recorded = await fixture.recordClosedRoot()
        let root = recorded.recordingDirectory.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(Self.notASessionFolderName, isDirectory: true),
            withIntermediateDirectories: true)
        try Data().write(to: root.appendingPathComponent(Self.plainFileName))
        await fixture.useRoot(of: recorded.recordingDirectory)

        let found = try await fixture.directory.sessions(matching: SessionQuery(includesRecorded: true))

        #expect(found.map(\.id) == [recorded.id])
    }

    /// A folder named by a ULID that holds no `index.md` is not a session,
    /// so it is not listed.
    @Test func aULIDFolderWithNoIndexIsNotListed() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.remove() }
        let kept = await fixture.recordClosedRoot()
        let stripped = await fixture.recordClosedRoot()
        try FileManager.default.removeItem(at: SessionIndexFile.url(in: stripped.recordingDirectory))
        await fixture.useRoot(of: kept.recordingDirectory)

        let found = try await fixture.directory.sessions(matching: SessionQuery(includesRecorded: true))

        #expect(found.map(\.id) == [kept.id])
    }

    // MARK: - The records of a recording root

    /// `recordedSessions(in:)` gives one record for each recorded root
    /// session folder, newest first: the id is the folder name, and the
    /// record holds the working folder, the facts and no first activity for
    /// a session that never had a prompt. A folder with no `index.md` is
    /// passed over.
    @Test func recordedSessionsGivesOneRecordPerRootSessionFolderNewestFirst() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.remove() }
        let folder = fixture.directories.cacheDir
        let starter = ULID.generate()
        var configuration = SessionFactsFixtures.configuration(startedBy: starter)
        configuration.workingDirectory = folder
        let first = await fixture.recordClosedRoot(configuration)
        let second = await fixture.recordClosedRoot(configuration)
        let root = second.recordingDirectory.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(ULID.generate().description, isDirectory: true),
            withIntermediateDirectories: true)

        let records = try RouterSessionDirectory.recordedSessions(in: root)

        #expect(records.map(\.sessionId) == [second.id, first.id])
        #expect(records.map(\.sessionId.description) == [
            second.recordingDirectory.lastPathComponent, first.recordingDirectory.lastPathComponent,
        ])
        #expect(records.allSatisfy { $0.workingDirectory == folder })
        #expect(records.allSatisfy { $0.facts == SessionFactsFixtures.expectedFacts(startedBy: starter) })
        #expect(records.allSatisfy { $0.firstActivityAt == nil })
    }

    // MARK: - Live and recorded

    /// A session that is live and recorded answers once, as live.
    @Test func aLiveRecordedSessionAnswersOnceAsLive() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.remove() }
        let session = fixture.recordingProfile.standard.makeSession(configuration: SessionConfiguration())
        let directory = fixture.recordingRouter.sessionDirectory
        let root = session.recordingDirectory.deletingLastPathComponent()
        await directory.useRecordingRoots { [root] }

        let found = try await directory.sessions(matching: SessionQuery(includesRecorded: true))

        #expect(found.map(\.id) == [session.id])
        #expect(found.first?.isLive == true)
        await session.close()
    }

    /// `summary(of:)` gives the recorded summary, read from the session
    /// folder, of a session that is not live.
    @Test func theSummaryOfARecordedSessionFallsBackToTheSessionFolder() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.remove() }
        let recorded = await fixture.recordClosedRoot()
        await fixture.useRoot(of: recorded.recordingDirectory)

        let summary = try await fixture.directory.summary(of: recorded.id)

        #expect(summary?.id == recorded.id)
        #expect(summary?.isLive == false)
    }

    // MARK: - The additional folders

    /// An event no session sends, which a test sends to mark the end of what
    /// it reads.
    private static let marker = SessionDirectoryEvent.archived(id: ULID.generate())

    /// The name of the first folder a host adds to a working folder.
    private static let firstAddedFolderName = "added-a"

    /// The name of the second folder a host adds to a working folder.
    private static let secondAddedFolderName = "added-b"

    /// The folders a host adds to a working folder, under `base`.
    ///
    /// - Parameter base: The folder the added folders sit in.
    /// - Returns: The added folders, in the order the host gives them.
    private static func addedFolders(under base: URL) -> [URL] {
        [firstAddedFolderName, secondAddedFolderName].map {
            base.appendingPathComponent($0, isDirectory: true)
        }
    }

    /// `setAdditionalDirectories(to:for:)` on a live session returns its
    /// summary, holds the folders in the record of the session and in the
    /// `index.md` on disk, and sends one `factsChanged` for the session.
    @Test func setAdditionalDirectoriesOnALiveSessionChangesItsRecord() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.remove() }
        let directory = fixture.recordingRouter.sessionDirectory
        let session = fixture.recordingProfile.standard.makeSession(configuration: SessionConfiguration())
        let actor = try #require(session as? RoutedSessionActor)
        let folders = Self.addedFolders(under: fixture.directories.cacheDir)
        var events = directory.events().makeAsyncIterator()

        let summary = try await directory.setAdditionalDirectories(to: folders, for: session.id)
        directory.emit(Self.marker)
        let received = await events.next(through: Self.marker)

        #expect(summary.id == session.id)
        #expect(summary.isLive)
        #expect(actor.record.additionalDirectories == folders)
        let onDisk = try #require(try SessionIndexFile.read(in: session.recordingDirectory))
        #expect(onDisk.additionalDirectories == folders)
        #expect(received == [.factsChanged(summary), Self.marker])
        await session.close()
    }

    /// `setAdditionalDirectories(to:for:)` on a recorded session that is not
    /// live rewrites the `index.md` of its folder and sends one
    /// `factsChanged` with its recorded summary.
    @Test func setAdditionalDirectoriesOnARecordedSessionRewritesItsIndex() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.remove() }
        let recorded = await fixture.recordClosedRoot()
        await fixture.useRoot(of: recorded.recordingDirectory)
        let folders = Self.addedFolders(under: fixture.directories.cacheDir)
        var events = fixture.directory.events().makeAsyncIterator()

        let summary = try await fixture.directory.setAdditionalDirectories(to: folders, for: recorded.id)
        fixture.directory.emit(Self.marker)
        let received = await events.next(through: Self.marker)

        #expect(summary.id == recorded.id)
        #expect(!summary.isLive)
        let onDisk = try #require(try SessionIndexFile.read(in: recorded.recordingDirectory))
        #expect(onDisk.additionalDirectories == folders)
        #expect(received == [.factsChanged(summary), Self.marker])
    }

    /// `setAdditionalDirectories(to:for:)` with an id that no live or
    /// recorded session has throws `unknownSession` with that id.
    @Test func setAdditionalDirectoriesWithAnUnknownIdThrowsUnknownSession() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.remove() }
        let recorded = await fixture.recordClosedRoot()
        await fixture.useRoot(of: recorded.recordingDirectory)
        let unknown = ULID.generate()

        await #expect(throws: SessionDirectoryError.unknownSession(unknown)) {
            try await fixture.directory.setAdditionalDirectories(
                to: Self.addedFolders(under: fixture.directories.cacheDir), for: unknown)
        }
    }

    // MARK: - The rules of a recorded summary

    /// A frontmatter `updatedAt` after every file of a test, in whole
    /// milliseconds: 2100-01-01.
    private static let futureSecondSince1970: TimeInterval = 4_102_444_800

    /// A recorded summary carries the working folder and the facts of the
    /// record, and a root kind.
    @Test func aRecordedSummaryCarriesTheRecordFolderAndTheFacts() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.remove() }
        let folder = fixture.directories.cacheDir
        let starter = ULID.generate()
        var configuration = SessionFactsFixtures.configuration(startedBy: starter)
        configuration.workingDirectory = folder
        let recorded = await fixture.recordClosedRoot(configuration)
        await fixture.useRoot(of: recorded.recordingDirectory)

        let summary = try await SessionDirectorySummaries.summary(
            of: recorded.id, in: fixture.directory, matching: SessionQuery(includesRecorded: true))

        #expect(summary.workingDirectory == folder)
        #expect(summary.agentID == SessionFactsFixtures.agentID)
        #expect(summary.agentName == SessionFactsFixtures.agentName)
        #expect(summary.tags == SessionFactsFixtures.tags)
        #expect(summary.title == SessionFactsFixtures.title)
        #expect(summary.startedBy == starter)
        #expect(summary.origin == .tool)
        #expect(summary.kind == .root)
        #expect(summary.state == .idle)
        #expect(summary.createdAt == recorded.id.timestamp)
    }

    /// A record with no fact fields gives the default agent id and origin,
    /// no tags, no title, and an idle state.
    @Test func aRecordWithNoFactFieldsGivesTheDefaultAgentAndOrigin() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.remove() }
        let starter = ULID.generate()
        let recorded = await fixture.recordClosedRoot(SessionFactsFixtures.configuration(startedBy: starter))
        try RouterTestFixtures.rewriteIndex(in: recorded.recordingDirectory) { $0.facts = SessionFacts() }
        await fixture.useRoot(of: recorded.recordingDirectory)

        let summary = try await SessionDirectorySummaries.summary(
            of: recorded.id, in: fixture.directory, matching: SessionQuery(includesRecorded: true))

        #expect(summary.agentID == RouterSessionDirectory.defaultAgentID)
        #expect(summary.origin == RouterSessionDirectory.defaultOrigin)
        #expect(summary.tags.isEmpty)
        #expect(summary.title == nil)
        #expect(summary.state == .idle)
    }

    /// A recorded session with `archivedAt` in its facts is archived.
    @Test func aRecordedSessionWithArchivedAtIsArchived() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.remove() }
        let recorded = await fixture.recordClosedRoot()
        try RouterTestFixtures.rewriteIndex(in: recorded.recordingDirectory) { $0.facts.archivedAt = Date() }
        await fixture.useRoot(of: recorded.recordingDirectory)

        let archived = try await fixture.directory.sessions(
            matching: SessionQuery(state: .archived, includesRecorded: true))

        #expect(archived.map(\.id) == [recorded.id])
    }

    /// A recorded root whose record has a spawn is a subagent of the
    /// spawning session.
    @Test func aRecordedRootWithASpawnIsASubagent() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.remove() }
        let parent = ULID.generate()
        let recorded = await fixture.recordClosedRoot(
            SessionConfiguration(
                agentSpawn: SessionRecord.AgentSpawn(parentSessionId: parent, parentToolCallId: "call-1")))
        await fixture.useRoot(of: recorded.recordingDirectory)

        let summary = try await SessionDirectorySummaries.summary(
            of: recorded.id, in: fixture.directory, matching: SessionQuery(includesRecorded: true))

        #expect(summary.kind == .subagent)
        #expect(summary.parentID == parent)
    }

    /// The title of the facts of the record is the title of the summary.
    @Test func theFactsTitleIsTheTitle() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.remove() }
        let recorded = await fixture.recordClosedRoot()
        try RouterTestFixtures.rewriteIndex(in: recorded.recordingDirectory) {
            $0.facts.title = SessionFactsFixtures.title
        }
        await fixture.useRoot(of: recorded.recordingDirectory)

        let summary = try await SessionDirectorySummaries.summary(
            of: recorded.id, in: fixture.directory, matching: SessionQuery(includesRecorded: true))

        #expect(summary.title == SessionFactsFixtures.title)
    }

    /// An empty title in the facts of the record counts as no title.
    @Test func anEmptyFactsTitleGivesNoTitle() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.remove() }
        let recorded = await fixture.recordClosedRoot()
        try RouterTestFixtures.rewriteIndex(in: recorded.recordingDirectory) { $0.facts.title = "" }
        await fixture.useRoot(of: recorded.recordingDirectory)

        let summary = try await SessionDirectorySummaries.summary(
            of: recorded.id, in: fixture.directory, matching: SessionQuery(includesRecorded: true))

        #expect(summary.title == nil)
    }

    /// The `updatedAt` of a recorded summary is the `updatedAt` of the
    /// frontmatter of its `index.md`.
    @Test func theUpdatedAtOfARecordedSummaryIsTheFrontmatterUpdatedAt() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.remove() }
        let recorded = await fixture.recordClosedRoot()
        let later = Date(timeIntervalSince1970: Self.futureSecondSince1970)
        try RouterTestFixtures.rewriteIndex(in: recorded.recordingDirectory) { $0.updatedAt = later }
        await fixture.useRoot(of: recorded.recordingDirectory)

        let summary = try await SessionDirectorySummaries.summary(
            of: recorded.id, in: fixture.directory, matching: SessionQuery(includesRecorded: true))

        #expect(summary.updatedAt == later)
    }
}
