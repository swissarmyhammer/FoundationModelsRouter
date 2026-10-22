import Foundation
import FoundationModelsExtras
import TelemetryTestSupport
import Testing

@testable import FoundationModelsRouter

/// The recorded sessions of ``RouterSessionDirectory`` (ROUTER-3): each new
/// durable root appends its line to `sessions.jsonl` when it registers, and
/// a query with `includesRecorded` gives the root sessions on disk that are
/// not live, through `SessionIndex`, `session.json` and `facts.json`.
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

    // MARK: - The index line

    /// The records of the `sessions.jsonl` in the folder that holds
    /// `recordingDirectory`.
    private static func indexRecords(beside recordingDirectory: URL) throws -> [SessionIndexRecord] {
        try SessionIndex(root: recordingDirectory.deletingLastPathComponent()).read().records
    }

    /// A new durable root appends one line at its registration, with its id,
    /// its working folder and its title.
    @Test func aNewDurableRootAppendsOneIndexLine() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.remove() }
        let folder = fixture.directories.cacheDir
        let session = fixture.recordingProfile.standard.makeSession(
            configuration: SessionConfiguration(workingDirectory: folder, title: SessionFactsFixtures.title))

        let records = try Self.indexRecords(beside: session.recordingDirectory)

        #expect(records.map(\.sessionId) == [session.id.description])
        #expect(records.first?.cwd == folder.path)
        #expect(records.first?.title == SessionFactsFixtures.title)
        await session.close()
    }

    /// A fork, a subagent and a restored root append no line: the root's
    /// own line stays the only one.
    @Test func aForkASubagentAndARestoredRootAppendNoIndexLine() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.remove() }
        let standard = fixture.recordingProfile.standard
        let root = standard.makeSession(configuration: SessionConfiguration())
        let fork = try await root.fork(workingDirectory: nil)
        let subagent = standard.makeSession(
            configuration: SessionConfiguration(
                agentSpawn: SessionSidecar.AgentSpawn(parentSessionId: root.id, parentToolCallId: "call-1")))
        for session in [fork, subagent, root] {
            await session.close()
        }
        let restored = try await standard.restoreSession(id: root.id)

        let records = try Self.indexRecords(beside: root.recordingDirectory)

        #expect(records.map(\.sessionId) == [root.id.description])
        await restored.session.close()
    }

    /// A root with no durable recording writes no index.
    @Test func aMemoryOnlyRootAppendsNoIndexLine() async throws {
        let scratch = RouterTestFixtures.makeTempDir(prefix: "RouterSessionDirectoryRecordedTests-memory")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let (router, profile) = try await RouterTestFixtures.resolveStandardProfile(
            over: BasicLLMContainer(), cacheDir: scratch)
        let session = profile.standard.makeSession(configuration: SessionConfiguration())
        let index = session.recordingDirectory.deletingLastPathComponent()
            .appendingPathComponent(SessionIndex.indexFileName)

        #expect(!FileManager.default.fileExists(atPath: index.path))
        await session.close()
        withExtendedLifetime(router) {}
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

    /// `summary(of:)` gives the recorded summary of a session that is not
    /// live.
    @Test func theSummaryOfARecordedSessionFallsBackToTheRecord() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.remove() }
        let recorded = await fixture.recordClosedRoot()
        await fixture.useRoot(of: recorded.recordingDirectory)

        let summary = try await fixture.directory.summary(of: recorded.id)

        #expect(summary?.id == recorded.id)
        #expect(summary?.isLive == false)
    }

    /// The last record of a session id wins: a resume appends a second line
    /// for the same session.
    @Test func theLastRecordOfASessionIdWins() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.remove() }
        let recorded = await fixture.recordClosedRoot()
        try Self.removeFacts(in: recorded.recordingDirectory)
        try Self.appendRecord(of: recorded, title: Self.recordTitle)
        await fixture.useRoot(of: recorded.recordingDirectory)

        let found = try await fixture.directory.sessions(matching: SessionQuery(includesRecorded: true))

        #expect(found.map(\.id) == [recorded.id])
        #expect(found.first?.title == Self.recordTitle)
    }

    // MARK: - The rules of a recorded summary

    /// The title an index record carries in the rule tests.
    private static let recordTitle = "Fix the flaky login test"

    /// A modification instant after every record of a test: 2100-01-01.
    private static let futureSecondSince1970: TimeInterval = 4_102_444_800

    /// A modification instant before every record of a test: 2001-01-01.
    private static let pastSecondSince1970: TimeInterval = 978_307_200

    /// Rewrites the `facts.json` in `directory` with `change` applied.
    private static func rewriteFacts(
        in directory: URL, _ change: (inout SessionFacts) -> Void
    ) throws {
        var facts = try #require(try SessionFacts.read(from: directory))
        change(&facts)
        try facts.write(to: directory)
    }

    /// Removes the `facts.json` in `directory`, as a session recorded before
    /// the file existed has none.
    private static func removeFacts(in directory: URL) throws {
        try FileManager.default.removeItem(at: directory.appendingPathComponent(SessionFacts.fileName))
    }

    /// Sets the modification date of the `facts.json` in `directory`.
    private static func setFactsModificationDate(_ date: Date, in directory: URL) throws {
        try FileManager.default.setAttributes(
            [.modificationDate: date], ofItemAtPath: directory.appendingPathComponent(SessionFacts.fileName).path)
    }

    /// Appends an index record of `recorded` with `title`, as the host did
    /// before the directory wrote the index.
    private static func appendRecord(
        of recorded: (id: ULID, recordingDirectory: URL), title: String
    ) throws {
        try SessionIndex(root: recorded.recordingDirectory.deletingLastPathComponent()).append(
            SessionIndexRecord(
                sessionId: recorded.id.description, cwd: recorded.recordingDirectory.path, title: title,
                updatedAt: Date(), additionalDirectories: []))
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
        try Self.appendRecord(of: recorded, title: Self.recordTitle)
        await fixture.useRoot(of: recorded.recordingDirectory)

        let summary = try await SessionDirectorySummaries.summary(
            of: recorded.id, in: fixture.directory, matching: SessionQuery(includesRecorded: true))

        #expect(summary.kind == .subagent)
        #expect(summary.parentID == parent)
    }

    /// The title of `facts.json` wins over the title of the index record.
    @Test func theFactsTitleWinsOverTheRecordTitle() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.remove() }
        let recorded = await fixture.recordClosedRoot(SessionConfiguration(title: Self.recordTitle))
        try Self.rewriteFacts(in: recorded.recordingDirectory) { $0.title = SessionFactsFixtures.title }
        await fixture.useRoot(of: recorded.recordingDirectory)

        let summary = try await SessionDirectorySummaries.summary(
            of: recorded.id, in: fixture.directory, matching: SessionQuery(includesRecorded: true))

        #expect(summary.title == SessionFactsFixtures.title)
    }

    /// An empty title in `facts.json` falls back to the title of the index
    /// record.
    @Test func anEmptyFactsTitleFallsBackToTheRecordTitle() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.remove() }
        let recorded = await fixture.recordClosedRoot(SessionConfiguration(title: Self.recordTitle))
        try Self.rewriteFacts(in: recorded.recordingDirectory) { $0.title = "" }
        await fixture.useRoot(of: recorded.recordingDirectory)

        let summary = try await SessionDirectorySummaries.summary(
            of: recorded.id, in: fixture.directory, matching: SessionQuery(includesRecorded: true))

        #expect(summary.title == Self.recordTitle)
    }

    /// A `facts.json` changed after the index record makes `updatedAt` its
    /// modification date.
    @Test func aLaterFactsFileGivesTheUpdatedAt() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.remove() }
        let recorded = await fixture.recordClosedRoot()
        let later = Date(timeIntervalSince1970: Self.futureSecondSince1970)
        try Self.setFactsModificationDate(later, in: recorded.recordingDirectory)
        await fixture.useRoot(of: recorded.recordingDirectory)

        let summary = try await SessionDirectorySummaries.summary(
            of: recorded.id, in: fixture.directory, matching: SessionQuery(includesRecorded: true))

        #expect(summary.updatedAt == later)
    }

    /// An index record newer than `facts.json` gives the `updatedAt`.
    @Test func aLaterRecordGivesTheUpdatedAt() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.remove() }
        let recorded = await fixture.recordClosedRoot()
        try Self.setFactsModificationDate(
            Date(timeIntervalSince1970: Self.pastSecondSince1970), in: recorded.recordingDirectory)
        await fixture.useRoot(of: recorded.recordingDirectory)
        let record = try #require(try Self.indexRecords(beside: recorded.recordingDirectory).first)

        let summary = try await SessionDirectorySummaries.summary(
            of: recorded.id, in: fixture.directory, matching: SessionQuery(includesRecorded: true))

        #expect(summary.updatedAt == record.updatedAt)
    }

    /// A `sessions.jsonl` line as the ACPAgent code wrote it, for a session
    /// with no `facts.json`, gives empty facts and the title of the record.
    @Test func anACPAgentIndexLineGivesEmptyFactsAndTheRecordTitle() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.remove() }
        let recorded = await fixture.recordClosedRoot()
        try Self.removeFacts(in: recorded.recordingDirectory)
        let root = recorded.recordingDirectory.deletingLastPathComponent()
        let line = """
            {"additionalDirectories":[],"cwd":"/Users/dev/example","sessionId":"\(recorded.id)",\
            "title":"\(Self.recordTitle)","updatedAt":"2025-08-24T01:46:40Z"}

            """
        try line.write(
            to: root.appendingPathComponent(SessionIndex.indexFileName), atomically: true, encoding: .utf8)
        await fixture.useRoot(of: recorded.recordingDirectory)

        let summary = try await SessionDirectorySummaries.summary(
            of: recorded.id, in: fixture.directory, matching: SessionQuery(includesRecorded: true))

        #expect(summary.title == Self.recordTitle)
        #expect(summary.agentID == RouterSessionDirectory.defaultAgentID)
        #expect(summary.origin == RouterSessionDirectory.defaultOrigin)
        #expect(summary.tags.isEmpty)
        #expect(summary.state == .idle)
    }

    // MARK: - Skipped records

    /// The message fragment of the warning for a record that is skipped.
    private static let skippedRecordWarning = "was skipped"

    /// The query of `fixture` that includes the recorded sessions, and the
    /// warnings of skipped records it logged.
    private static func recordedSessionsAndSkipWarnings(
        in fixture: Fixture
    ) async throws -> (found: [SessionSummary], warnings: Int) {
        try await TelemetryCapture.run(forbidding: []) { context in
            let found = try await fixture.directory.sessions(matching: SessionQuery(includesRecorded: true))
            let warnings = context.logRecords.filter {
                $0.level == .warning && "\($0.message)".contains(Self.skippedRecordWarning)
            }
            return (found, warnings.count)
        }
    }

    /// A record whose session directory is gone is skipped with one
    /// warning.
    @Test func aRecordWithNoSessionDirectoryIsSkippedWithAWarning() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.remove() }
        let recorded = await fixture.recordClosedRoot()
        try FileManager.default.removeItem(at: recorded.recordingDirectory)
        await fixture.useRoot(of: recorded.recordingDirectory)

        let (found, warnings) = try await Self.recordedSessionsAndSkipWarnings(in: fixture)

        #expect(found.isEmpty)
        #expect(warnings == 1)
    }

    /// A record whose session id is not a ULID is skipped with one warning.
    @Test func aRecordWhoseIdIsNotAULIDIsSkippedWithAWarning() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.remove() }
        let recorded = await fixture.recordClosedRoot()
        try SessionIndex(root: recorded.recordingDirectory.deletingLastPathComponent()).append(
            SessionIndexRecord(
                sessionId: "not-a-ulid", cwd: recorded.recordingDirectory.path, title: Self.recordTitle,
                updatedAt: Date(), additionalDirectories: []))
        await fixture.useRoot(of: recorded.recordingDirectory)

        let (found, warnings) = try await Self.recordedSessionsAndSkipWarnings(in: fixture)

        #expect(found.map(\.id) == [recorded.id])
        #expect(warnings == 1)
    }
}
