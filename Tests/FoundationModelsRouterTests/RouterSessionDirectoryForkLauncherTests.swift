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
}
