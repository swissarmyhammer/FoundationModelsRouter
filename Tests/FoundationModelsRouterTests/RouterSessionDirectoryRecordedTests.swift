import Foundation
import FoundationModelsExtras
import Testing

@testable import FoundationModelsRouter

/// The recorded sessions of ``RouterSessionDirectory`` (ROUTER-3): a query
/// with `includesRecorded` gives the root sessions on disk that are not live,
/// listed from the session folders of the recording roots, through
/// `session.json` and `facts.json`. No index file is read or written.
///
/// Router A records the sessions; router B is a new router over the same
/// recordings folder, standing in for a new process, and finds them through
/// the roots the host gives with `useRecordingRoots(_:)`.
@Suite struct RouterSessionDirectoryRecordedTests {
    /// The two routers of one test over one recordings folder.
    struct Fixture {
        /// The cache and recordings folders of the test.
        let directories: TestDirectories

        /// The router that records the sessions.
        let recordingRouter: Router

        /// The resolved profile of ``recordingRouter``.
        let recordingProfile: LanguageModelProfile

        /// The router of the "new process": a second router over the same
        /// recordings folder.
        let readingRouter: Router

        /// The directory of ``readingRouter``.
        var directory: RouterSessionDirectory { readingRouter.sessionDirectory }

        /// Vends a root session of ``recordingRouter`` and closes it, so it is
        /// on disk and live nowhere.
        ///
        /// - Parameter configuration: The configuration of the session.
        /// - Returns: The id and the recording directory of the session.
        func recordClosedRoot(
            _ configuration: SessionConfiguration = SessionConfiguration()
        ) async -> (id: ULID, recordingDirectory: URL) {
            let session = recordingProfile.standard.makeSession(configuration: configuration)
            await session.close()
            return (session.id, session.recordingDirectory)
        }

        /// Gives the directory of ``readingRouter`` the recording root of
        /// `recordingDirectory`: the folder that holds it.
        ///
        /// - Parameter recordingDirectory: The recording directory of a root.
        func useRoot(of recordingDirectory: URL) async {
            let root = recordingDirectory.deletingLastPathComponent()
            await directory.useRecordingRoots { [root] }
        }

        /// Removes the folders of the test.
        func remove() {
            directories.remove()
        }
    }

    /// Makes the two routers over one new recordings folder.
    private static func makeFixture() async throws -> Fixture {
        let directories = TestDirectories(prefix: "RouterSessionDirectoryRecordedTests")
        let (recordingRouter, recordingProfile) = try await RouterTestFixtures.resolveStandardProfile(
            over: BasicLLMContainer(), cacheDir: directories.cacheDir, recordingsDir: directories.recordingsDir)
        let (readingRouter, _) = try await RouterTestFixtures.resolveStandardProfile(
            over: BasicLLMContainer(), cacheDir: directories.cacheDir, recordingsDir: directories.recordingsDir)
        return Fixture(
            directories: directories, recordingRouter: recordingRouter, recordingProfile: recordingProfile,
            readingRouter: readingRouter)
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

    /// The name of the index file that the record of past sessions no longer
    /// writes.
    private static let removedIndexFileName = "sessions.jsonl"

    /// The name of a folder in a recording root that is not named by a ULID.
    private static let notASessionFolderName = "not-a-ulid"

    /// The name of a plain file in a recording root.
    private static let plainFileName = "notes.txt"

    /// A durable root writes no `sessions.jsonl` beside its recording
    /// directory.
    @Test func aDurableRootWritesNoIndexFile() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.remove() }
        let recorded = await fixture.recordClosedRoot()

        let root = recorded.recordingDirectory.deletingLastPathComponent()
        let names = try FileManager.default.contentsOfDirectory(atPath: root.path)

        #expect(!names.contains(Self.removedIndexFileName))
    }

    /// A recorded root is listed from its folder under the recording root,
    /// with no index file beside it.
    @Test func aRecordedRootIsListedFromItsFolder() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.remove() }
        let recorded = await fixture.recordClosedRoot()
        let root = recorded.recordingDirectory.deletingLastPathComponent()
        try? FileManager.default.removeItem(at: root.appendingPathComponent(Self.removedIndexFileName))
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

    /// A fork lives in the folder of its root, so the recording root lists
    /// only the root.
    @Test func aForkIsNotListedAsARecordedRoot() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.remove() }
        let root = fixture.recordingProfile.standard.makeSession(configuration: SessionConfiguration())
        let fork = try await root.fork(workingDirectory: nil)
        await fork.close()
        await root.close()
        await fixture.useRoot(of: root.recordingDirectory)

        let found = try await fixture.directory.sessions(matching: SessionQuery(includesRecorded: true))

        #expect(found.map(\.id) == [root.id])
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

    // MARK: - The rules of a recorded summary

    /// A modification instant after every file of a test: 2100-01-01.
    private static let futureSecondSince1970: TimeInterval = 4_102_444_800

    /// A modification instant before every file of a test: 2001-01-01.
    private static let pastSecondSince1970: TimeInterval = 978_307_200

    /// Rewrites the `facts.json` in `directory` with `change` applied.
    private static func rewriteFacts(
        in directory: URL, _ change: (inout SessionFacts) -> Void
    ) throws {
        var facts = try #require(try SessionFacts.read(from: directory))
        change(&facts)
        try facts.write(to: directory)
    }

    /// Removes the `facts.json` in `directory`, so the session folder holds
    /// no facts.
    private static func removeFacts(in directory: URL) throws {
        try FileManager.default.removeItem(at: directory.appendingPathComponent(SessionFacts.fileName))
    }

    /// Sets the modification date of the file named `fileName` in
    /// `directory`.
    private static func setModificationDate(_ date: Date, ofFileNamed fileName: String, in directory: URL) throws {
        try FileManager.default.setAttributes(
            [.modificationDate: date], ofItemAtPath: directory.appendingPathComponent(fileName).path)
    }

    /// A recorded summary carries the working folder of `session.json` and
    /// the facts of `facts.json`, and a root kind.
    @Test func aRecordedSummaryCarriesTheSidecarFolderAndTheFacts() async throws {
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

    /// A session folder with no `facts.json` gives empty facts: the default
    /// agent id and origin, no tags, no title, and an idle state.
    @Test func aSessionFolderWithNoFactsGivesEmptyFacts() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.remove() }
        let recorded = await fixture.recordClosedRoot()
        try Self.removeFacts(in: recorded.recordingDirectory)
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
        try Self.rewriteFacts(in: recorded.recordingDirectory) { $0.archivedAt = Date() }
        await fixture.useRoot(of: recorded.recordingDirectory)

        let archived = try await fixture.directory.sessions(
            matching: SessionQuery(state: .archived, includesRecorded: true))

        #expect(archived.map(\.id) == [recorded.id])
    }

    /// A recorded root whose `session.json` has a spawn is a subagent of
    /// the spawning session.
    @Test func aRecordedRootWithASpawnIsASubagent() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.remove() }
        let parent = ULID.generate()
        let recorded = await fixture.recordClosedRoot(
            SessionConfiguration(
                agentSpawn: SessionSidecar.AgentSpawn(parentSessionId: parent, parentToolCallId: "call-1")))
        await fixture.useRoot(of: recorded.recordingDirectory)

        let summary = try await SessionDirectorySummaries.summary(
            of: recorded.id, in: fixture.directory, matching: SessionQuery(includesRecorded: true))

        #expect(summary.kind == .subagent)
        #expect(summary.parentID == parent)
    }

    /// The title of `facts.json` is the title of the summary.
    @Test func theFactsTitleIsTheTitle() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.remove() }
        let recorded = await fixture.recordClosedRoot()
        try Self.rewriteFacts(in: recorded.recordingDirectory) { $0.title = SessionFactsFixtures.title }
        await fixture.useRoot(of: recorded.recordingDirectory)

        let summary = try await SessionDirectorySummaries.summary(
            of: recorded.id, in: fixture.directory, matching: SessionQuery(includesRecorded: true))

        #expect(summary.title == SessionFactsFixtures.title)
    }

    /// An empty title in `facts.json` counts as no title.
    @Test func anEmptyFactsTitleGivesNoTitle() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.remove() }
        let recorded = await fixture.recordClosedRoot()
        try Self.rewriteFacts(in: recorded.recordingDirectory) { $0.title = "" }
        await fixture.useRoot(of: recorded.recordingDirectory)

        let summary = try await SessionDirectorySummaries.summary(
            of: recorded.id, in: fixture.directory, matching: SessionQuery(includesRecorded: true))

        #expect(summary.title == nil)
    }

    /// A `facts.json` modified after the other files of the session folder
    /// makes `updatedAt` its modification date.
    @Test func aLaterFactsFileGivesTheUpdatedAt() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.remove() }
        let recorded = await fixture.recordClosedRoot()
        let later = Date(timeIntervalSince1970: Self.futureSecondSince1970)
        try Self.setModificationDate(later, ofFileNamed: SessionFacts.fileName, in: recorded.recordingDirectory)
        await fixture.useRoot(of: recorded.recordingDirectory)

        let summary = try await SessionDirectorySummaries.summary(
            of: recorded.id, in: fixture.directory, matching: SessionQuery(includesRecorded: true))

        #expect(summary.updatedAt == later)
    }

    /// A `transcript.jsonl` modified after the other files of the session
    /// folder makes `updatedAt` its modification date.
    @Test func aLaterTranscriptGivesTheUpdatedAt() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.remove() }
        let recorded = await fixture.recordClosedRoot()
        try Self.setModificationDate(
            Date(timeIntervalSince1970: Self.pastSecondSince1970), ofFileNamed: SessionFacts.fileName,
            in: recorded.recordingDirectory)
        let transcript = recorded.recordingDirectory.appendingPathComponent(transcriptFileName)
        if !FileManager.default.fileExists(atPath: transcript.path) {
            try Data().write(to: transcript)
        }
        let later = Date(timeIntervalSince1970: Self.futureSecondSince1970)
        try Self.setModificationDate(later, ofFileNamed: transcriptFileName, in: recorded.recordingDirectory)
        await fixture.useRoot(of: recorded.recordingDirectory)

        let summary = try await SessionDirectorySummaries.summary(
            of: recorded.id, in: fixture.directory, matching: SessionQuery(includesRecorded: true))

        #expect(summary.updatedAt == later)
    }
}
