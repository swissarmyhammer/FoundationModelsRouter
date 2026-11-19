import Foundation
import FoundationModels
import FoundationModelsExtras
import Testing

@testable import FoundationModelsRouter

/// ``RouterSessionDirectory/fork(_:)`` (D205): a live fork of kind `fork`
/// with the history of its source up to the cut, its record, its name, its
/// first prompt and its lifetime.
@Suite struct RouterSessionDirectoryForkTests {
    /// The fixture of this suite: stub backends that can hold one turn.
    private typealias Fixture = ForkFixture<ForkTestContainer>

    /// The prompt of the first turn of each source.
    private static let firstPrompt = "first"

    /// The prompt of the second turn of each source.
    private static let secondPrompt = "second"

    /// The prompts of a source with two turns.
    private static let twoTurns = [firstPrompt, secondPrompt]

    /// The prompt of a turn that runs while the test forks.
    private static let heldPrompt = "held"

    /// The prompt that only the fork gets.
    private static let forkPrompt = "fork only"

    /// The prompt that only the source gets after the fork.
    private static let sourcePrompt = "source only"

    /// The title of a named source.
    private static let sourceTitle = "Review the login"

    /// The text of a message that the directory delivers to a source.
    private static let mailText = "mail turn"

    /// The history position of the second prompt of a source with two
    /// turns: the stub backend records a prompt and a response for each
    /// turn, and no instructions.
    private static let secondTurnPosition = 2

    /// A turn index that no source of this suite has.
    private static let missingTurn = 5

    // MARK: - The last completed turn

    @Test func aForkAtTheLastCompletedTurnHasBothTurns() async throws {
        let fixture = try await Fixture.make()
        let source = try await fixture.makeSource(answering: Self.twoTurns)

        let fork = try await fixture.fork(source, at: .lastCompletedTurn)

        #expect(await fork.transcript.promptTexts == Self.twoTurns)
        await fixture.end([source, fork])
    }

    @Test func aPromptToTheForkDoesNotChangeTheSource() async throws {
        let fixture = try await Fixture.make()
        let source = try await fixture.makeSource(answering: Self.twoTurns)
        let fork = try await fixture.fork(source, at: .lastCompletedTurn)

        _ = try await fork.respond(to: Self.forkPrompt)

        #expect(await source.transcript.promptTexts == Self.twoTurns)
        await fixture.end([source, fork])
    }

    @Test func aPromptToTheSourceDoesNotChangeTheFork() async throws {
        let fixture = try await Fixture.make()
        let source = try await fixture.makeSource(answering: Self.twoTurns)
        let fork = try await fixture.fork(source, at: .lastCompletedTurn)

        _ = try await source.respond(to: Self.sourcePrompt)

        #expect(await fork.transcript.promptTexts == Self.twoTurns)
        await fixture.end([source, fork])
    }

    @Test func aForkWhileATurnRunsHasNoRunningTurn() async throws {
        let fixture = try await Fixture.make(heldPrompt: Self.heldPrompt)
        let source = try await fixture.makeSource(answering: Self.twoTurns)
        let backend = try #require(fixture.container.lastHoldingBackend)
        let running = Task { try await source.respond(to: Self.heldPrompt) }
        try await backend.entered.wait()

        let fork = try await fixture.fork(source, at: .lastCompletedTurn)
        backend.release.signal()
        _ = try await running.value

        #expect(await fork.transcript.promptTexts == Self.twoTurns)
        await fixture.end([source, fork])
    }

    @Test func theRunningTurnEndsNormallyInTheSource() async throws {
        let fixture = try await Fixture.make(heldPrompt: Self.heldPrompt)
        let source = try await fixture.makeSource(answering: Self.twoTurns)
        let backend = try #require(fixture.container.lastHoldingBackend)
        let running = Task { try await source.respond(to: Self.heldPrompt) }
        try await backend.entered.wait()

        let fork = try await fixture.fork(source, at: .lastCompletedTurn)
        backend.release.signal()
        _ = try await running.value

        #expect(await source.transcript.promptTexts == Self.twoTurns + [Self.heldPrompt])
        await fixture.end([source, fork])
    }

    // MARK: - Turn cuts

    @Test func aForkBeforeTheSecondTurnHasTheFirstTurn() async throws {
        let fixture = try await Fixture.make()
        let source = try await fixture.makeSource(answering: Self.twoTurns)

        let fork = try await fixture.fork(source, at: .beforeTurn(1))

        #expect(await fork.transcript.promptTexts == [Self.firstPrompt])
        await fixture.end([source, fork])
    }

    @Test func aForkAfterTheFirstTurnHasTheFirstTurn() async throws {
        let fixture = try await Fixture.make()
        let source = try await fixture.makeSource(answering: Self.twoTurns)

        let fork = try await fixture.fork(source, at: .afterTurn(0))

        #expect(await fork.transcript.promptTexts == [Self.firstPrompt])
        await fixture.end([source, fork])
    }

    @Test func aDeliveredMessageStartsATurn() async throws {
        let fixture = try await Fixture.make()
        let source = try await fixture.makeSource(answering: [Self.firstPrompt])
        _ = try await fixture.directory.send(Self.mailText, to: source.id, from: Fixture.user, awaitingDelivery: true)
        #expect(await source.awaitIdle())
        _ = try await source.respond(to: Self.secondPrompt)

        let fork = try await fixture.fork(source, at: .beforeTurn(2))

        #expect(await fork.transcript.promptTexts == [Self.firstPrompt, Self.mailText])
        await fixture.end([source, fork])
    }

    @Test func aTurnThatDoesNotExistIsOutOfRange() async throws {
        let fixture = try await Fixture.make()
        let source = try await fixture.makeSource(answering: Self.twoTurns)

        let error = await fixture.forkError(of: source.id, at: .afterTurn(Self.missingTurn))

        #expect(error == .forkCutOutOfRange(.afterTurn(Self.missingTurn)))
        await fixture.end([source])
    }

    // MARK: - History positions

    @Test func aForkAtAHistoryPositionRecordsThePosition() async throws {
        let fixture = try await Fixture.make()
        let source = try await fixture.makeSource(answering: Self.twoTurns)

        let fork = try await fixture.fork(source, at: .historyPosition(Self.secondTurnPosition))

        let record = try #require(try SessionIndexFile.read(in: fork.recordingDirectory))
        #expect(record.forkedAtHistoryOrdinal == Self.secondTurnPosition)
        await fixture.end([source, fork])
    }

    @Test func aHistoryPositionAfterTheEndIsOutOfRange() async throws {
        let fixture = try await Fixture.make()
        let source = try await fixture.makeSource(answering: Self.twoTurns)
        let cut = SessionForkCut.historyPosition(Self.missingTurn)

        let error = await fixture.forkError(of: source.id, at: cut)

        #expect(error == .forkCutOutOfRange(cut))
        await fixture.end([source])
    }

    // MARK: - The fork

    @Test func theForkIsAForkOfItsSourceInTheFolderOfItsSource() async throws {
        let fixture = try await Fixture.make()
        let source = try await fixture.makeSource(answering: Self.twoTurns)

        let fork = try await fixture.fork(source, at: .lastCompletedTurn)

        let summary = try #require(try await fixture.directory.summary(of: fork.id))
        #expect(summary.kind == .fork)
        #expect(summary.parentID == source.id)
        #expect(summary.origin == .fork)
        #expect(summary.workingDirectory == source.workingDirectory)
        await fixture.end([source, fork])
    }

    @Test func theForkRecordsInTheFolderOfItsSource() async throws {
        let fixture = try await Fixture.make()
        let source = try await fixture.makeSource(answering: Self.twoTurns)

        let fork = try await fixture.fork(source, at: .lastCompletedTurn)

        #expect(fork.recordingDirectory.deletingLastPathComponent() == source.recordingDirectory)
        await fixture.end([source, fork])
    }

    @Test func theForkNamesFollowTheSourceName() async throws {
        let fixture = try await Fixture.make()
        let source = try await fixture.makeSource(answering: Self.twoTurns, title: Self.sourceTitle)

        let first = try await fixture.fork(source, at: .lastCompletedTurn)
        let second = try await fixture.fork(source, at: .lastCompletedTurn)

        #expect(first.facts.title == "review-the-login-fork")
        #expect(second.facts.title == "review-the-login-fork-2")
        await fixture.end([source, first, second])
    }

    @Test func theFirstPromptStartsTheFirstTurnOfTheFork() async throws {
        let fixture = try await Fixture.make()
        let source = try await fixture.makeSource(answering: Self.twoTurns)

        let fork = try await fixture.fork(source, at: .lastCompletedTurn, firstPrompt: Self.forkPrompt)
        #expect(await fork.awaitIdle())

        #expect(await fork.transcript.promptTexts == Self.twoTurns + [Self.forkPrompt])
        await fixture.end([source, fork])
    }

    // MARK: - The source

    @Test func aForkOfAForkHasTheHistoryOfItsSourceUpToItsCut() async throws {
        let fixture = try await Fixture.make()
        let source = try await fixture.makeSource(answering: Self.twoTurns)
        let first = try await fixture.fork(source, at: .afterTurn(0))
        _ = try await first.respond(to: Self.forkPrompt)

        let second = try await fixture.fork(first, at: .beforeTurn(1))

        #expect(await second.transcript.promptTexts == [Self.firstPrompt])
        await fixture.end([source, first, second])
    }

    @Test func aRecordedSourceIsRestoredThroughTheLauncher() async throws {
        let fixture = try await Fixture.make()
        let launcher = FakeSessionLauncher(profile: fixture.profile)
        await fixture.directory.use(launcher: launcher)
        let source = try await fixture.makeSource(answering: Self.twoTurns)
        await source.close()

        let fork = try await fixture.fork(source, at: .lastCompletedTurn)

        #expect(launcher.restoredIDs == [source.id])
        await launcher.closeSessions()
        await fixture.end([fork])
    }

    @Test func aForkOfARestoredSourceHasItsTurns() async throws {
        let fixture = try await Fixture.make()
        let launcher = FakeSessionLauncher(profile: fixture.profile)
        await fixture.directory.use(launcher: launcher)
        let source = try await fixture.makeSource(answering: Self.twoTurns)
        await source.close()

        let fork = try await fixture.fork(source, at: .lastCompletedTurn)

        #expect(await fork.transcript.promptTexts == Self.twoTurns)
        await launcher.closeSessions()
        await fixture.end([fork])
    }

    @Test func aRecordedSourceWithNoLauncherIsRefused() async throws {
        let fixture = try await Fixture.make()
        let source = try await fixture.makeSource(answering: Self.twoTurns)
        await source.close()

        let error = await fixture.forkError(of: source.id, at: .lastCompletedTurn)

        #expect(error == .noLauncher)
        await fixture.end([])
    }

    @Test func aSourceThatRecordsNothingCannotFork() async throws {
        let directories = TestDirectories(prefix: "RouterSessionDirectoryForkTests")
        let (router, profile) = try await RouterTestFixtures.resolveStandardProfile(
            over: ForkTestContainer(heldPrompt: nil), cacheDir: directories.cacheDir)
        let source = profile.standard.makeSession()

        await #expect(throws: SessionDirectoryError.forkUnsupported) {
            try await router.sessionDirectory.fork(
                SessionForkRequest(sourceID: source.id, cut: .lastCompletedTurn, forker: Fixture.user))
        }
        await source.close()
        directories.remove()
    }

    // MARK: - Refusals

    @Test func aForkOfAnArchivedSourceIsRefused() async throws {
        let fixture = try await Fixture.make()
        let source = try await fixture.makeSource(answering: Self.twoTurns)
        _ = try await fixture.directory.archive(source.id, by: Fixture.user)

        let error = await fixture.forkError(of: source.id, at: .lastCompletedTurn)

        #expect(error == .archivedSession(source.id))
        await fixture.end([source])
    }

    @Test func aForkOfAnUnknownSourceIsRefused() async throws {
        let fixture = try await Fixture.make()
        let unknown = ULID.generate()

        let error = await fixture.forkError(of: unknown, at: .lastCompletedTurn)

        #expect(error == .unknownSession(unknown))
        await fixture.end([])
    }

    // MARK: - Lifetime

    @Test func theForkIsNoUnendedChildOfItsSource() async throws {
        let fixture = try await Fixture.make()
        let source = try await fixture.makeSource(answering: Self.twoTurns)

        let fork = try await fixture.fork(source, at: .lastCompletedTurn)

        #expect(try await fixture.directory.unendedChildren(of: source.id).map(\.id).contains(fork.id) == false)
        await fixture.end([source, fork])
    }

    @Test func theForkLivesOnWhenItsSourceEnds() async throws {
        let fixture = try await Fixture.make()
        let source = try await fixture.makeSource(answering: Self.twoTurns)
        let forkID = try await fixture.fork(source, at: .lastCompletedTurn).id

        _ = try await fixture.directory.markEnded(source.id, reason: .finished)
        await source.close()

        let fork = try #require(fixture.directory.session(id: forkID))
        _ = try await fork.respond(to: Self.forkPrompt)
        #expect(await fork.transcript.promptTexts == Self.twoTurns + [Self.forkPrompt])
        await fixture.end([fork])
    }

    @Test func theForkLivesOnWhenItsSourceIsArchived() async throws {
        let fixture = try await Fixture.make()
        let source = try await fixture.makeSource(answering: Self.twoTurns)
        let forkID = try await fixture.fork(source, at: .lastCompletedTurn).id

        _ = try await fixture.directory.archive(source.id, by: Fixture.user)

        let summary = try #require(try await fixture.directory.summary(of: forkID))
        #expect(summary.isLive)
        #expect(summary.state != .archived)
        let fork = try #require(fixture.directory.session(id: forkID))
        await fixture.end([source, fork])
    }

    // MARK: - Restart

    @Test func aRestartRestoresTheForkWithItsPrefix() async throws {
        let fixture = try await Fixture.make()
        let source = try await fixture.makeSource(answering: Self.twoTurns)
        let fork = try await fixture.fork(source, at: .afterTurn(0))
        _ = try await fork.respond(to: Self.forkPrompt)
        await source.close()
        await fork.close()

        let tree = try await fixture.profile.standard.restoreSessionTree(root: source.id)

        let restored = try #require(tree.session(fork.id))
        #expect(await restored.transcript.promptTexts == [Self.firstPrompt, Self.forkPrompt])
        await fixture.end([tree.root] + tree.children(of: source.id))
    }

    @Test func aRestartRestoresTheForkAsAFork() async throws {
        let fixture = try await Fixture.make()
        let source = try await fixture.makeSource(answering: Self.twoTurns)
        let fork = try await fixture.fork(source, at: .afterTurn(0))
        await source.close()
        await fork.close()

        let tree = try await fixture.profile.standard.restoreSessionTree(root: source.id)

        let summary = try #require(try await fixture.directory.summary(of: fork.id))
        #expect(summary.kind == .fork)
        #expect(summary.parentID == source.id)
        await fixture.end([tree.root] + tree.children(of: source.id))
    }

    /// Makes a named source with one fork, closes both, and restarts the
    /// fixture.
    ///
    /// - Parameter fixture: The fixture before the restart.
    /// - Returns: The restarted fixture, the source and the fork. Both are
    ///   closed.
    /// - Throws: What the source, the fork or the restart throws.
    private static func restartAfterAFork(
        of fixture: Fixture
    ) async throws -> (restarted: Fixture, source: any RoutedSession, fork: any RoutedSession) {
        let source = try await fixture.makeSource(answering: Self.twoTurns, title: Self.sourceTitle)
        let fork = try await fixture.fork(source, at: .afterTurn(0))
        await source.close()
        await fork.close()
        return (try await fixture.restarted(), source, fork)
    }

    @Test func aRecordedForkIsFoundByIDAfterARestart() async throws {
        let (restarted, source, fork) = try await Self.restartAfterAFork(of: try await Fixture.make())

        let summary = try #require(try await restarted.directory.summary(of: fork.id))

        #expect(summary.kind == .fork)
        #expect(summary.parentID == source.id)
        restarted.directories.remove()
    }

    @Test func aRecordedForkIsListedAsAForkAfterARestart() async throws {
        let (restarted, source, fork) = try await Self.restartAfterAFork(of: try await Fixture.make())

        let forks = try await restarted.directory.sessions(
            matching: SessionQuery(kind: .fork, parentID: source.id, includesRecorded: true))

        #expect(forks.map(\.id) == [fork.id])
        restarted.directories.remove()
    }

    @Test func aRecordedForkIsRestoredByIDAfterARestart() async throws {
        let (restarted, _, fork) = try await Self.restartAfterAFork(of: try await Fixture.make())

        let restored = try await restarted.profile.standard.restoreSession(id: fork.id).session

        #expect(restored.id == fork.id)
        #expect(await restored.transcript.promptTexts == [Self.firstPrompt])
        await restarted.end([restored])
    }

    @Test func aRecordedForkNameCountsForANewForkAfterARestart() async throws {
        let (restarted, source, _) = try await Self.restartAfterAFork(of: try await Fixture.make())
        let launcher = FakeSessionLauncher(profile: restarted.profile)
        await restarted.directory.use(launcher: launcher)

        let second = try await restarted.fork(source, at: .lastCompletedTurn)

        #expect(second.facts.title == "review-the-login-fork-2")
        await launcher.closeSessions()
        await restarted.end([second])
    }
}
