import Foundation
import FoundationModelsExtras
import Testing

@testable import FoundationModelsRouter

/// The default name of a new session (D199 (b)): ``RouterSessionDirectory``
/// gives each new root session with no title the name
/// `SessionName.default(agentName:usedNames:)`, from the name of its agent
/// and the names of the sessions in its folder that are not archived. A
/// recorded session with no title gets the default name when the directory
/// reads it. Only a rename changes the name.
///
/// Router A records the sessions. Router B is a new router over the same
/// recordings folder, as a new process, which reads the recorded sessions
/// through the roots that the host gives with `useRecordingRoots(_:)`.
@Suite struct RouterSessionDirectoryDefaultNameTests {
    /// The two routers of one test, and the working folders of the test.
    struct Fixture {
        /// The two routers over one recordings folder.
        let pair: SessionDirectoryRouterPair

        /// The directory of the recording router, which holds its live
        /// sessions.
        var liveDirectory: RouterSessionDirectory { pair.recordingRouter.sessionDirectory }

        /// The directory of the reading router, which reads the sessions that
        /// the recording router recorded.
        var readingDirectory: RouterSessionDirectory { pair.directory }

        /// A working folder of the test. The folder is in the cache folder of
        /// the test, thus ``remove()`` removes it.
        ///
        /// - Parameter name: The name of the folder.
        /// - Returns: The folder.
        func folder(_ name: String) -> URL {
            pair.directories.cacheDir.appendingPathComponent(name, isDirectory: true)
        }

        /// Vends a live root session of the agent ``agentName`` in `folder`.
        ///
        /// - Parameters:
        ///   - folder: The working folder of the session.
        ///   - title: The title of the configuration. The default is none.
        /// - Returns: The session.
        func vend(in folder: URL, title: String? = nil) -> any RoutedSession {
            pair.recordingProfile.standard.makeSession(configuration: configuration(in: folder, title: title))
        }

        /// Records a closed root session of the agent ``agentName`` in
        /// `folder`, live nowhere, and gives ``readingDirectory`` its
        /// recording root.
        ///
        /// - Parameter folder: The working folder of the session.
        /// - Returns: The id and the recording directory of the session.
        func recordClosed(in folder: URL) async -> (id: ULID, recordingDirectory: URL) {
            let recorded = await pair.recordClosedRoot(configuration(in: folder, title: nil))
            await pair.useRoot(of: recorded.recordingDirectory)
            return recorded
        }

        /// Uses a launcher over the profile of the recording router in
        /// ``liveDirectory``.
        ///
        /// - Returns: The launcher.
        func useLauncher() async -> FakeSessionLauncher {
            let launcher = FakeSessionLauncher(profile: pair.recordingProfile)
            await liveDirectory.use(launcher: launcher)
            return launcher
        }

        /// Removes the folders of the test.
        func remove() {
            pair.remove()
        }

        /// The configuration of a session of the agent ``agentName``.
        ///
        /// - Parameters:
        ///   - folder: The working folder of the session.
        ///   - title: The title, or `nil`.
        /// - Returns: The configuration.
        private func configuration(in folder: URL, title: String?) -> SessionConfiguration {
            SessionConfiguration(
                workingDirectory: folder, agentID: RouterSessionDirectoryDefaultNameTests.agentID,
                agentName: RouterSessionDirectoryDefaultNameTests.agentName, title: title)
        }
    }

    /// Makes the two routers over one new recordings folder.
    private static func makeFixture() async throws -> Fixture {
        Fixture(pair: try await SessionDirectoryRouterPair.make(prefix: "RouterSessionDirectoryDefaultNameTests"))
    }

    /// The live title of `session` in the live directory of `fixture`.
    ///
    /// - Parameters:
    ///   - session: A live session.
    ///   - fixture: The fixture.
    /// - Returns: The title of the summary.
    private static func liveTitle(of session: any RoutedSession, in fixture: Fixture) async throws -> String? {
        try await SessionDirectorySummaries.summary(of: session.id, in: fixture.liveDirectory).title
    }

    /// The title that the reading directory reads for the recorded session
    /// `id`.
    ///
    /// - Parameters:
    ///   - id: The session id.
    ///   - fixture: The fixture.
    /// - Returns: The title of the recorded summary.
    private static func recordedTitle(of id: ULID, in fixture: Fixture) async throws -> String? {
        try await SessionDirectorySummaries.summary(
            of: id, in: fixture.readingDirectory, matching: SessionQuery(includesRecorded: true)
        ).title
    }

    // MARK: - New sessions

    /// The production change that makes this test fail: a registration that
    /// leaves the title of a new session `nil`.
    @Test func aNewSessionOfAnAgentHasTheSlugOfTheAgentName() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.remove() }
        let session = fixture.vend(in: fixture.folder(Self.projectFolder))

        #expect(try await Self.liveTitle(of: session, in: fixture) == Self.baseName)
        await session.close()
    }

    /// The production change that makes this test fail: used names that
    /// leave out the live sessions of the folder.
    @Test func aSecondSessionInTheSameFolderHasTheNextNumber() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.remove() }
        let folder = fixture.folder(Self.projectFolder)
        let first = fixture.vend(in: folder)
        let second = fixture.vend(in: folder)

        #expect(try await Self.liveTitle(of: second, in: fixture) == Self.secondName)
        await SessionFixtureLifecycle.close([first, second])
    }

    /// The production change that makes this test fail: used names that
    /// take the sessions of each folder.
    @Test func aSessionInAnotherFolderHasTheBaseName() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.remove() }
        let first = fixture.vend(in: fixture.folder(Self.projectFolder))
        let other = fixture.vend(in: fixture.folder(Self.otherFolder))

        #expect(try await Self.liveTitle(of: other, in: fixture) == Self.baseName)
        await SessionFixtureLifecycle.close([first, other])
    }

    /// The production change that makes this test fail: used names that
    /// take the archived sessions of the folder.
    @Test func anArchivedSessionDoesNotBlockItsName() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.remove() }
        let folder = fixture.folder(Self.projectFolder)
        let archived = fixture.vend(in: folder)
        _ = try await fixture.liveDirectory.archive(archived.id, by: Self.user)
        let next = fixture.vend(in: folder)

        #expect(try await Self.liveTitle(of: next, in: fixture) == Self.baseName)
        await SessionFixtureLifecycle.close([archived, next])
    }

    /// The production change that makes this test fail: a default name that
    /// replaces the title of the configuration.
    @Test func aSessionWithATitleKeepsItsTitle() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.remove() }
        let session = fixture.vend(in: fixture.folder(Self.projectFolder), title: Self.renamedTitle)

        #expect(try await Self.liveTitle(of: session, in: fixture) == Self.renamedTitle)
        await session.close()
    }

    /// The production change that makes this test fail: a default name that
    /// is not written to the `index.md` of the new session.
    @Test func theDefaultNameIsInTheIndexOfTheNewSession() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.remove() }
        let session = fixture.vend(in: fixture.folder(Self.projectFolder))

        #expect(try SessionIndexFile.read(in: session.recordingDirectory)?.facts.title == Self.baseName)
        await session.close()
    }

    // MARK: - Rename

    /// The production change that makes this test fail: a read that gives a
    /// renamed session its default name again.
    @Test func aRenameReplacesTheDefaultNameAndStaysAfterTheNextRead() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.remove() }
        let session = fixture.vend(in: fixture.folder(Self.projectFolder))
        _ = try await fixture.liveDirectory.setTitle(Self.renamedTitle, of: session.id)
        await session.close()
        await fixture.pair.useRoot(of: session.recordingDirectory)

        #expect(try await Self.recordedTitle(of: session.id, in: fixture) == Self.renamedTitle)
    }

    // MARK: - Recorded sessions

    /// The production change that makes this test fail: a read of a recorded
    /// session that leaves its title `nil`.
    @Test func aRecordedSessionWithNoTitleReadsWithADefaultName() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.remove() }
        let recorded = await fixture.recordClosed(in: fixture.folder(Self.projectFolder))
        try RouterTestFixtures.rewriteIndex(in: recorded.recordingDirectory) { $0.facts.title = nil }

        #expect(try await Self.recordedTitle(of: recorded.id, in: fixture) == Self.baseName)
    }

    /// The production change that makes this test fail: a read that gives
    /// the default name to the summary only, so a later read can give
    /// another name.
    @Test func theDefaultNameOfARecordedSessionIsWrittenToItsIndex() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.remove() }
        let recorded = await fixture.recordClosed(in: fixture.folder(Self.projectFolder))
        try RouterTestFixtures.rewriteIndex(in: recorded.recordingDirectory) { $0.facts.title = nil }

        _ = try await Self.recordedTitle(of: recorded.id, in: fixture)

        #expect(try SessionIndexFile.read(in: recorded.recordingDirectory)?.facts.title == Self.baseName)
    }

    /// The production change that makes this test fail: a read that names a
    /// recorded session with no look at the other recorded sessions of its
    /// folder.
    @Test func aRecordedSessionWithNoTitleTakesTheNextFreeName() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.remove() }
        let folder = fixture.folder(Self.projectFolder)
        let named = await fixture.recordClosed(in: folder)
        let untitled = await fixture.recordClosed(in: folder)
        try RouterTestFixtures.rewriteIndex(in: untitled.recordingDirectory) { $0.facts.title = nil }

        #expect(try await Self.recordedTitle(of: untitled.id, in: fixture) == Self.secondName)
        #expect(try await Self.recordedTitle(of: named.id, in: fixture) == Self.baseName)
    }

    /// The production change that makes this test fail: a change of the
    /// record of a recorded session, which reads the record, and gives a
    /// summary with no title.
    @Test func aChangeOfARecordedSessionWithNoTitleGivesItsDefaultName() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.remove() }
        let recorded = await fixture.recordClosed(in: fixture.folder(Self.projectFolder))
        try RouterTestFixtures.rewriteIndex(in: recorded.recordingDirectory) { $0.facts.title = nil }

        let summary = try await fixture.readingDirectory.addTags([Self.tag], to: recorded.id)

        #expect(summary.title == Self.baseName)
    }

    // MARK: - Starts

    /// The production change that makes this test fail: a start that keeps
    /// the `nil` title of its request.
    @Test func aStartWithNoTitleGivesTheDefaultName() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.remove() }
        let launcher = await fixture.useLauncher()

        let summary = try await fixture.liveDirectory.start(
            SessionStartRequest(
                agentID: Self.agentID, workingDirectory: fixture.folder(Self.projectFolder),
                firstMessage: Self.firstMessage, origin: .tool))

        #expect(summary.title == Self.baseName)
        await launcher.closeSessions()
    }

    /// The production change that makes this test fail: a start that puts
    /// the empty title of its request in place of the default name.
    @Test func aStartWithAnEmptyTitleGivesTheDefaultName() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.remove() }
        let launcher = await fixture.useLauncher()

        let summary = try await fixture.liveDirectory.start(
            SessionStartRequest(
                agentID: Self.agentID, workingDirectory: fixture.folder(Self.projectFolder),
                firstMessage: Self.firstMessage, title: "", origin: .tool))

        #expect(summary.title == Self.baseName)
        await launcher.closeSessions()
    }

    /// The production change that makes this test fail: `startAgent`, which
    /// starts the session of an agent address, with no default name.
    @Test func anAgentAddressStartsASessionWithTheDefaultName() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.remove() }
        let launcher = await fixture.useLauncher()

        let receipts = try await fixture.liveDirectory.send(
            OutgoingSessionMessage(
                from: Self.user, to: .agent(id: Self.agentID, folder: fixture.folder(Self.projectFolder)),
                text: Self.firstMessage))
        let target = try #require(receipts.first?.target)

        #expect(try await fixture.liveDirectory.summary(of: target)?.title == Self.baseName)
        await launcher.closeSessions()
    }

    // MARK: - Constants

    /// The id of the agent of each session.
    private static let agentID = "claude-code"

    /// The name of the agent of each session.
    private static let agentName = "Claude Code"

    /// The default name of the first session of the agent in a folder.
    private static let baseName = "claude-code"

    /// The default name of the second session of the agent in a folder.
    private static let secondName = "claude-code-2"

    /// The title of a rename, and of a configuration with a title.
    private static let renamedTitle = "Plan the trip"

    /// The name of the first working folder.
    private static let projectFolder = "project"

    /// The name of the second working folder.
    private static let otherFolder = "other-project"

    /// The tag that a change of a record adds.
    private static let tag = "travel"

    /// The first message of a start.
    private static let firstMessage = "Summarize the open tasks."

    /// The user that archives a session and sends a message.
    private static let user = SessionMessageSender.user(clientID: "client-a")
}
