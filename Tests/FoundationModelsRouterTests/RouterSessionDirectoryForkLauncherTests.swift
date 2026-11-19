import Foundation
import FoundationModels
import FoundationModelsExtras
import Testing

@testable import FoundationModelsRouter

/// ``RouterSessionDirectory/fork(_:)`` through the launcher of the host
/// (D205): the host builds the fork with its own surface
/// (``SessionLauncher/forkSession(_:)``) before the directory registers the
/// fork and mails its first prompt.
@Suite struct RouterSessionDirectoryForkLauncherTests {
    /// The fixture of this suite: stub backends.
    private typealias Fixture = ForkFixture<ForkTestContainer>

    /// The prompts of a source with two turns.
    private static let twoTurns = ["first", "second"]

    /// The history position of the cut of a fork at a position: the end of
    /// the first turn (one prompt and one response).
    private static let cutPosition = 2

    /// The first prompt of a fork.
    private static let forkPrompt = "fork only"

    /// The UI client of each fork of the tests of the task of the fork call.
    private static let client = "fork-launcher-client"

    /// The mark that the first caller sets around its fork call.
    private static let firstCallerMark = "first caller"

    /// The names of the folders that a host adds to a working folder.
    private static let addedFolderNames = ["added-docs", "added-assets"]

    /// The folders that a host adds, in the cache folder of `fixture`.
    ///
    /// - Parameter fixture: The fixture of the test.
    /// - Returns: The added folders, in the order that the host gives them.
    private static func addedFolders(in fixture: Fixture) -> [URL] {
        addedFolderNames.map { fixture.directories.cacheDir.appendingPathComponent($0, isDirectory: true) }
    }

    /// Gives `launcher` to the directory of `fixture`, and makes a source
    /// with two turns and one ``SourceSurfaceTool``.
    ///
    /// - Parameters:
    ///   - fixture: The fixture of the test.
    ///   - launcher: The launcher of the host.
    /// - Returns: The source.
    /// - Throws: What an answer of the source throws.
    private static func makeSource(
        in fixture: Fixture, launcher: some SessionLauncher
    ) async throws -> any RoutedSession {
        await fixture.directory.use(launcher: launcher)
        return try await fixture.makeSource(answering: twoTurns, tools: [SourceSurfaceTool()])
    }

    /// Forks `source` at ``cutPosition`` with `firstPrompt`.
    ///
    /// - Parameters:
    ///   - source: The source.
    ///   - fixture: The fixture of the test.
    ///   - firstPrompt: The first prompt of the fork, or `nil`.
    /// - Returns: The summary of the fork.
    /// - Throws: The error of the fork.
    private static func fork(
        _ source: any RoutedSession, in fixture: Fixture, firstPrompt: String? = nil
    ) async throws -> SessionSummary {
        try await fixture.directory.fork(
            SessionForkRequest(
                sourceID: source.id, cut: .historyPosition(cutPosition), firstPrompt: firstPrompt,
                forker: Fixture.user))
    }

    /// Forks `source` through `launcher`, and gives the request that the
    /// launcher kept after the fork call ended. The fork call can throw: the
    /// test reads only the kept request.
    ///
    /// - Parameters:
    ///   - source: The source.
    ///   - launcher: The launcher of the directory of `fixture`.
    ///   - fixture: The fixture of the test.
    /// - Returns: The request that the launcher kept.
    /// - Throws: When the launcher kept no request.
    private static func keptRequest(
        afterForking source: any RoutedSession, through launcher: ForkLaunchingLauncher, in fixture: Fixture
    ) async throws -> SessionLaunchForkRequest {
        _ = try? await fork(source, in: fixture)
        return try #require(launcher.requests.first)
    }

    /// Forks `source` at ``cutPosition`` for ``client``.
    ///
    /// - Parameters:
    ///   - source: The source.
    ///   - fixture: The fixture of the test.
    /// - Returns: The summary of the fork.
    /// - Throws: The error of the fork.
    private static func forkForClient(
        _ source: any RoutedSession, in fixture: Fixture
    ) async throws -> SessionSummary {
        try await fixture.directory.fork(
            SessionForkRequest(
                sourceID: source.id, cut: .historyPosition(cutPosition), requestedByClient: client,
                forker: Fixture.user))
    }

    /// Forks `source` for ``client`` while the first fork call of
    /// `launcher` waits at its gate, and then releases that call, also when
    /// this fork throws.
    ///
    /// - Parameters:
    ///   - source: The source.
    ///   - fixture: The fixture of the test.
    ///   - launcher: The launcher whose first fork call waits.
    /// - Returns: The summary of the fork.
    /// - Throws: The error of the fork.
    private static func secondFork(
        of source: any RoutedSession, in fixture: Fixture, releasingTheFirstCallOf launcher: CallerMarkLauncher
    ) async throws -> SessionSummary {
        defer { launcher.releaseFirstCall.signal() }
        return try await forkForClient(source, in: fixture)
    }

    /// The added folders in the record of the live session `id`, or `nil`
    /// when no live Router session has the id.
    ///
    /// - Parameters:
    ///   - id: The id of the session.
    ///   - fixture: The fixture of the test.
    /// - Returns: The added folders of the record.
    private static func liveAdditionalDirectories(of id: ULID, in fixture: Fixture) -> [URL]? {
        (fixture.directory.session(id: id) as? RoutedSessionActor)?.record.additionalDirectories
    }

    /// The original tool names of `session`, or `nil` for a session that is
    /// not a Router session.
    ///
    /// - Parameter session: A session.
    /// - Returns: The names of the tools that the session was made with.
    private static func toolNames(of session: (any RoutedSession)?) -> [String]? {
        (session as? RoutedSessionActor)?.originalTools.map(\.name)
    }

    // MARK: - A launcher that builds the fork

    @Test func theLauncherGetsOneCallWithTheSourceTheCutAndTheForkID() async throws {
        let fixture = try await Fixture.make()
        let launcher = ForkLaunchingLauncher()
        let source = try await Self.makeSource(in: fixture, launcher: launcher)

        let summary = try await Self.fork(source, in: fixture)

        let expected = ForkLaunch(sourceID: source.id, forkedAtHistoryOrdinal: Self.cutPosition, forkID: summary.id)
        #expect(launcher.launches == [expected])
        await launcher.closeSessions()
        await fixture.end([source])
    }

    @Test func theForkIsTheSessionThatTheLauncherGave() async throws {
        let fixture = try await Fixture.make()
        let launcher = ForkLaunchingLauncher()
        let source = try await Self.makeSource(in: fixture, launcher: launcher)

        let summary = try await Self.fork(source, in: fixture)

        let launched = try #require(launcher.sessions.first)
        #expect(fixture.directory.session(id: summary.id) === launched)
        await launcher.closeSessions()
        await fixture.end([source])
    }

    @Test func theForkHasTheToolsThatTheLauncherGave() async throws {
        let fixture = try await Fixture.make()
        let launcher = ForkLaunchingLauncher()
        let source = try await Self.makeSource(in: fixture, launcher: launcher)

        let summary = try await Self.fork(source, in: fixture)

        #expect(Self.toolNames(of: fixture.directory.session(id: summary.id)) == [HostSurfaceTool.toolName])
        await launcher.closeSessions()
        await fixture.end([source])
    }

    @Test func theForkRecordsTheCutThatTheLauncherGot() async throws {
        let fixture = try await Fixture.make()
        let launcher = ForkLaunchingLauncher()
        let source = try await Self.makeSource(in: fixture, launcher: launcher)

        let summary = try await Self.fork(source, in: fixture)

        let fork = try #require(fixture.directory.session(id: summary.id) as? RoutedSessionActor)
        #expect(fork.record.forkedAtHistoryOrdinal == launcher.launches.first?.forkedAtHistoryOrdinal)
        await launcher.closeSessions()
        await fixture.end([source])
    }

    @Test func theFirstPromptRunsOnTheSessionThatTheLauncherGave() async throws {
        let fixture = try await Fixture.make()
        let launcher = ForkLaunchingLauncher()
        let source = try await Self.makeSource(in: fixture, launcher: launcher)

        _ = try await Self.fork(source, in: fixture, firstPrompt: Self.forkPrompt)

        let launched = try #require(launcher.sessions.first)
        #expect(await launched.awaitIdle())
        #expect(await launched.transcript.promptTexts == [Self.twoTurns[0], Self.forkPrompt])
        await launcher.closeSessions()
        await fixture.end([source])
    }

    @Test func theFirstPromptWaitsUntilTheLauncherReturns() async throws {
        let fixture = try await Fixture.make()
        let launcher = ForkLaunchingLauncher()
        let source = try await Self.makeSource(in: fixture, launcher: launcher)

        _ = try await Self.fork(source, in: fixture, firstPrompt: Self.forkPrompt)

        #expect(launcher.statesAtReturn == [ForkStateAtReturn(promptTexts: [Self.twoTurns[0]], waitingMessages: 0)])
        await launcher.closeSessions()
        await fixture.end([source])
    }

    // MARK: - The added folders of the fork

    @Test func theForkRecordHasTheFoldersThatTheLauncherGave() async throws {
        let fixture = try await Fixture.make()
        let folders = Self.addedFolders(in: fixture)
        let launcher = ForkLaunchingLauncher(additionalDirectories: folders)
        let source = try await Self.makeSource(in: fixture, launcher: launcher)

        let summary = try await Self.fork(source, in: fixture)

        #expect(Self.liveAdditionalDirectories(of: summary.id, in: fixture) == folders)
        await launcher.closeSessions()
        await fixture.end([source])
    }

    @Test func theForkRecordHasTheFoldersThatTheLauncherGaveAfterARestart() async throws {
        let fixture = try await Fixture.make()
        let folders = Self.addedFolders(in: fixture)
        let launcher = ForkLaunchingLauncher(additionalDirectories: folders)
        let source = try await Self.makeSource(in: fixture, launcher: launcher)
        let summary = try await Self.fork(source, in: fixture)
        await launcher.closeSessions()
        await source.close()
        let restarted = try await fixture.restarted()

        let restored = try await restarted.profile.standard.restoreSession(id: summary.id).session

        #expect((restored as? RoutedSessionActor)?.record.additionalDirectories == folders)
        await restarted.end([restored])
    }

    @Test func aForkWithOnlyToolsHasNoFoldersOfTheSource() async throws {
        let fixture = try await Fixture.make()
        let launcher = ForkLaunchingLauncher()
        let source = try await Self.makeSource(in: fixture, launcher: launcher)
        try await fixture.directory.setAdditionalDirectories(to: Self.addedFolders(in: fixture), for: source.id)

        let summary = try await Self.fork(source, in: fixture)

        #expect(Self.liveAdditionalDirectories(of: summary.id, in: fixture) == [])
        await launcher.closeSessions()
        await fixture.end([source])
    }

    @Test func aForkWithTheSurfaceOfTheSourceHasTheFoldersOfTheSource() async throws {
        let fixture = try await Fixture.make()
        let folders = Self.addedFolders(in: fixture)
        let launcher = FakeSessionLauncher(profile: fixture.profile)
        let source = try await Self.makeSource(in: fixture, launcher: launcher)
        try await fixture.directory.setAdditionalDirectories(to: folders, for: source.id)

        let summary = try await Self.fork(source, in: fixture)

        #expect(Self.liveAdditionalDirectories(of: summary.id, in: fixture) == folders)
        let fork = try #require(fixture.directory.session(id: summary.id))
        await fixture.end([source, fork])
    }

    // MARK: - The task of the fork call

    /// Two forks of one source for one client at the same time: the first
    /// sets ``ForkCallerMark`` around its fork call and waits in the
    /// launcher, the second sets no mark and ends while the first waits.
    @Test func theLauncherCallSeesTheTaskLocalsOfTheForkCallerOnly() async throws {
        let fixture = try await Fixture.make()
        let launcher = CallerMarkLauncher()
        let source = try await Self.makeSource(in: fixture, launcher: launcher)
        let firstCall = Task {
            try await ForkCallerMark.$value.withValue(Self.firstCallerMark) {
                try await Self.forkForClient(source, in: fixture)
            }
        }
        try await launcher.firstCallEntered.wait()
        let second = try await Self.secondFork(of: source, in: fixture, releasingTheFirstCallOf: launcher)
        let first = try await firstCall.value

        #expect(
            launcher.seen == [
                CallerMarkSeen(forkID: second.id, mark: nil),
                CallerMarkSeen(forkID: first.id, mark: Self.firstCallerMark),
            ])
        let forks = [first.id, second.id].compactMap { fixture.directory.session(id: $0) }
        await fixture.end([source] + forks)
    }

    // MARK: - A launcher with no fork operation

    @Test func aLauncherWithNoForkOperationForksWithTheToolsOfTheSource() async throws {
        let fixture = try await Fixture.make()
        let launcher = FakeSessionLauncher(profile: fixture.profile)
        let source = try await Self.makeSource(in: fixture, launcher: launcher)

        let summary = try await Self.fork(source, in: fixture)

        let fork = try #require(fixture.directory.session(id: summary.id))
        #expect(Self.toolNames(of: fork) == [SourceSurfaceTool.toolName])
        await fixture.end([source, fork])
    }

    @Test func aLauncherWithNoForkOperationForksWithTheHistoryUpToTheCut() async throws {
        let fixture = try await Fixture.make()
        let launcher = FakeSessionLauncher(profile: fixture.profile)
        let source = try await Self.makeSource(in: fixture, launcher: launcher)

        let summary = try await Self.fork(source, in: fixture)

        let fork = try #require(fixture.directory.session(id: summary.id))
        #expect(await fork.transcript.promptTexts == [Self.twoTurns[0]])
        await fixture.end([source, fork])
    }

    // MARK: - A launcher that throws

    @Test func aForkThatTheLauncherRefusesIsRefused() async throws {
        let fixture = try await Fixture.make()
        let launcher = ForkLaunchingLauncher(behavior: .buildThenThrow)
        let source = try await Self.makeSource(in: fixture, launcher: launcher)

        await #expect(throws: ForkLaunchingLauncher.Refusal()) {
            try await Self.fork(source, in: fixture, firstPrompt: Self.forkPrompt)
        }
        await launcher.closeSessions()
        await fixture.end([source])
    }

    @Test func aForkThatTheLauncherRefusesIsNotRegistered() async throws {
        let fixture = try await Fixture.make()
        let launcher = ForkLaunchingLauncher(behavior: .buildThenThrow)
        let source = try await Self.makeSource(in: fixture, launcher: launcher)

        _ = try? await Self.fork(source, in: fixture, firstPrompt: Self.forkPrompt)

        let launch = try #require(launcher.launches.first)
        #expect(fixture.directory.session(id: launch.forkID) == nil)
        await launcher.closeSessions()
        await fixture.end([source])
    }

    @Test func aForkThatTheLauncherRefusesLeavesNoRecordingNode() async throws {
        let fixture = try await Fixture.make()
        let launcher = ForkLaunchingLauncher(behavior: .buildThenThrow)
        let source = try await Self.makeSource(in: fixture, launcher: launcher)

        _ = try? await Self.fork(source, in: fixture, firstPrompt: Self.forkPrompt)

        let launch = try #require(launcher.launches.first)
        let node = source.recordingDirectory.appendingPathComponent(launch.forkID.description, isDirectory: true)
        #expect(FileManager.default.fileExists(atPath: node.path) == false)
        await launcher.closeSessions()
        await fixture.end([source])
    }

    // MARK: - A launcher that breaks the contract

    @Test func aSecondBuildOfOneForkIsRefused() async throws {
        let fixture = try await Fixture.make()
        let launcher = ForkLaunchingLauncher(behavior: .buildTwice)
        let source = try await Self.makeSource(in: fixture, launcher: launcher)

        let error = await #expect(throws: SessionLaunchForkError.self) {
            try await Self.fork(source, in: fixture)
        }

        let launch = try #require(launcher.launches.first)
        #expect(error == .forkAlreadyMade(launch.forkID))
        await launcher.closeSessions()
        await fixture.end([source])
    }

    @Test func aLauncherThatGivesAnotherSessionIsRefused() async throws {
        let fixture = try await Fixture.make()
        let other = try await fixture.makeSource(answering: [])
        let launcher = ForkLaunchingLauncher(behavior: .returnOther(other))
        let source = try await Self.makeSource(in: fixture, launcher: launcher)

        let error = await #expect(throws: SessionLaunchForkError.self) {
            try await Self.fork(source, in: fixture)
        }

        let launch = try #require(launcher.launches.first)
        #expect(error == .notTheRequestedFork(launch.forkID))
        await launcher.closeSessions()
        await fixture.end([source, other])
    }

    // MARK: - A request that the launcher keeps after the fork call

    @Test func aRequestKeptAfterARefusalBeforeTheBuildBuildsNoFork() async throws {
        let fixture = try await Fixture.make()
        let launcher = ForkLaunchingLauncher(behavior: .throwBeforeBuild)
        let source = try await Self.makeSource(in: fixture, launcher: launcher)
        let request = try await Self.keptRequest(afterForking: source, through: launcher, in: fixture)

        await #expect(throws: SessionLaunchForkError.requestClosed(request.forkID)) {
            try await request.makeFork(tools: [])
        }
        await launcher.closeSessions()
        await fixture.end([source])
    }

    @Test func aRequestKeptAfterARefusalBeforeTheBuildLeavesNoRecordingNode() async throws {
        let fixture = try await Fixture.make()
        let launcher = ForkLaunchingLauncher(behavior: .throwBeforeBuild)
        let source = try await Self.makeSource(in: fixture, launcher: launcher)
        let request = try await Self.keptRequest(afterForking: source, through: launcher, in: fixture)

        let lateFork = try? await request.makeFork(tools: [])

        let node = source.recordingDirectory.appendingPathComponent(request.forkID.description, isDirectory: true)
        #expect(FileManager.default.fileExists(atPath: node.path) == false)
        await lateFork?.close()
        await launcher.closeSessions()
        await fixture.end([source])
    }

    @Test func aRequestKeptAfterARefusalAfterTheBuildBuildsNoFork() async throws {
        let fixture = try await Fixture.make()
        let launcher = ForkLaunchingLauncher(behavior: .buildThenThrow)
        let source = try await Self.makeSource(in: fixture, launcher: launcher)
        let request = try await Self.keptRequest(afterForking: source, through: launcher, in: fixture)

        await #expect(throws: SessionLaunchForkError.requestClosed(request.forkID)) {
            try await request.makeFork(tools: [])
        }
        await launcher.closeSessions()
        await fixture.end([source])
    }

    @Test func aRequestKeptAfterAnotherSessionBuildsNoFork() async throws {
        let fixture = try await Fixture.make()
        let other = try await fixture.makeSource(answering: [])
        let launcher = ForkLaunchingLauncher(behavior: .returnOther(other))
        let source = try await Self.makeSource(in: fixture, launcher: launcher)
        let request = try await Self.keptRequest(afterForking: source, through: launcher, in: fixture)

        await #expect(throws: SessionLaunchForkError.requestClosed(request.forkID)) {
            try await request.makeFork(tools: [])
        }
        await launcher.closeSessions()
        await fixture.end([source, other])
    }

    @Test func aRequestKeptAfterTheForkBuildsNoSecondFork() async throws {
        let fixture = try await Fixture.make()
        let launcher = ForkLaunchingLauncher()
        let source = try await Self.makeSource(in: fixture, launcher: launcher)
        let request = try await Self.keptRequest(afterForking: source, through: launcher, in: fixture)

        await #expect(throws: SessionLaunchForkError.requestClosed(request.forkID)) {
            try await request.makeFork(tools: [])
        }
        await launcher.closeSessions()
        await fixture.end([source])
    }
}
