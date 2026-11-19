import Foundation
import FoundationModels
import FoundationModelsExtras
import TelemetryTestSupport
import Testing

@testable import FoundationModelsRouter

/// D205 (f), part 1: a fork starts with a copy of the prompt cache of its
/// source.
///
/// Each session runs over the production backend and a real
/// `LanguageModelSession` over a ``PromptCacheScopeRecordingModel``, which
/// records each pass, each release and each copy of the cache of a session,
/// with no GPU. The model gives the copy outcome that the test chooses.
@Suite struct ForkPromptCacheCopyTests {
    /// The fixture of the fork suites over the recording model.
    private typealias Forks = ForkFixture<LiveBackendContainer<PromptCacheScopeRecordingModel>>

    /// A fork fixture, the log of its model and the loader of its router.
    private struct Fixture {
        /// The router, the profile and the directory of the forks.
        let forks: Forks

        /// The log of the model.
        let log: PromptCacheScopeLog

        /// The loader of the router, which records each budget.
        let loader: PromptCacheLogLoader
    }

    /// The prompts of the turns of each source.
    private static let sourcePrompts = ["first", "second"]

    /// The first prompt of a fork.
    private static let forkPrompt = "fork only"

    /// A model reference that the source does not run on.
    private static let otherModel = ModelRef(repo: "test/another-model")

    /// The spilling bytes that the usage of the model reports after a copy.
    private static let spillingBytesAfterCopy = 4096

    /// Makes a fork fixture over a new recording model.
    ///
    /// - Parameters:
    ///   - copyOutcome: The outcome of each copy of the model.
    ///   - usageAfterCopy: The usage that the model reports after a copy.
    /// - Returns: The fixture.
    /// - Throws: What the resolve of the profile throws.
    private static func makeFixture(
        copyOutcome: PromptCacheCopyOutcome = .copied, usageAfterCopy: PromptCacheUsage = .zero
    ) async throws -> Fixture {
        let log = PromptCacheScopeLog(usageAfterCopy: usageAfterCopy)
        let container = LiveBackendContainer(model: PromptCacheScopeRecordingModel(log: log, copyOutcome: copyOutcome))
        let loader = PromptCacheLogLoader(container: container, log: log)
        let forks = try await Forks.make(over: container, loader: loader)
        return Fixture(forks: forks, log: log, loader: loader)
    }

    /// Makes a source with the turns of ``sourcePrompts``.
    ///
    /// - Parameter fixture: The fixture of the test.
    /// - Returns: The source.
    /// - Throws: What an answer of the source throws, or the `#require`
    ///   failure for a source that is not a Router session.
    private static func makeSource(in fixture: Fixture) async throws -> RoutedSessionActor {
        try #require(try await fixture.forks.makeSource(answering: sourcePrompts) as? RoutedSessionActor)
    }

    /// The copy of the cache of `source` to `fork` before any pass of the
    /// fork.
    ///
    /// - Parameters:
    ///   - source: The source.
    ///   - fork: The fork.
    /// - Returns: The copy call.
    private static func copyBeforeTheFirstPass(
        of source: any RoutedSession, to fork: any RoutedSession
    ) -> PromptCacheCopyCall {
        PromptCacheCopyCall(
            sourceSessionID: source.id.description, targetSessionID: fork.id.description, targetPassesBefore: 0)
    }

    /// Makes a fork of `source` through `handle`, not through the
    /// directory, and lets it take the copy of the cache of `source`.
    ///
    /// - Parameters:
    ///   - source: The source.
    ///   - handle: The handle that makes the fork.
    /// - Returns: The fork, not registered.
    private static func forkDirectly(_ source: RoutedSessionActor, through handle: RoutedLLM) async
        -> RoutedSessionActor
    {
        let fork = handle.makeFork(
            of: source, id: .generate(), seed: ForkSeed(entries: [], historyOrdinal: 0, usageState: .none),
            tools: nil)
        await fork.takePromptCacheCopy(of: source, through: handle)
        return fork
    }

    // MARK: - The copy at the fork

    /// The production change that makes this test fail: a fork that copies
    /// no cache, copies another key, or copies after its first prompt.
    @Test func aForkCopiesTheCacheOfItsSourceBeforeItsFirstPrompt() async throws {
        let fixture = try await Self.makeFixture()
        let source = try await Self.makeSource(in: fixture)

        let fork = try await fixture.forks.fork(source, at: .lastCompletedTurn, firstPrompt: Self.forkPrompt)
        #expect(await fork.awaitIdle())

        #expect(fixture.log.recordedCopies == [Self.copyBeforeTheFirstPass(of: source, to: fork)])
        #expect(fixture.log.scopes(servingPrompt: Self.forkPrompt) == [.session(fork.id.description)])
        await fixture.forks.end([source, fork])
    }

    /// The production change that makes this test fail: a copy on the
    /// default build path only, and not in the build of a host launcher.
    @Test func aForkThroughTheLauncherCopiesTheCacheOfItsSource() async throws {
        let fixture = try await Self.makeFixture()
        await fixture.forks.directory.use(launcher: ForkLaunchingLauncher())
        let source = try await Self.makeSource(in: fixture)

        let fork = try await fixture.forks.fork(source, at: .lastCompletedTurn, firstPrompt: Self.forkPrompt)
        #expect(await fork.awaitIdle())

        #expect(fixture.log.recordedCopies == [Self.copyBeforeTheFirstPass(of: source, to: fork)])
        await fixture.forks.end([source, fork])
    }

    /// The production change that makes this test fail: a copy with no
    /// check of the model reference.
    @Test func aForkOnAnotherModelTakesNoCopy() async throws {
        let fixture = try await Self.makeFixture()
        let source = try await Self.makeSource(in: fixture)
        let other = HandBuiltProfileFixtures.makeProfile(
            definitionName: "other-model", chosen: Self.otherModel, container: fixture.forks.container,
            router: fixture.forks.router)

        let fork = await Self.forkDirectly(source, through: other.standard)

        #expect(fixture.log.recordedCopies.isEmpty)
        await fixture.forks.end([source, fork])
    }

    /// The production change that makes this test fail: a copy with no
    /// check of the slot.
    @Test func aForkOnAnotherSlotTakesNoCopy() async throws {
        let fixture = try await Self.makeFixture()
        let source = try await Self.makeSource(in: fixture)
        let other = HandBuiltProfileFixtures.makeProfile(
            definitionName: "same-model", chosen: source.model, container: fixture.forks.container,
            router: fixture.forks.router)

        let fork = await Self.forkDirectly(source, through: other.flash)

        #expect(fixture.log.recordedCopies.isEmpty)
        await fixture.forks.end([source, fork])
    }

    /// The production change that makes this test fail: a backend that
    /// reports an outcome for a model that keeps no copyable cache.
    @Test func aBackendOverAModelThatDoesNotCopyGivesNoOutcome() async throws {
        let container = LiveBackendContainer(model: StaleWaitLanguageModel(log: RejectingModelLog()))
        let backend = try #require(container.makeSession(instructions: nil) as? MLXFoundationModelsSessionBackend)

        let outcome = await backend.copyPromptCache(
            fromSession: ULID.generate().description, toSession: ULID.generate().description)

        #expect(outcome == nil)
    }

    // MARK: - A copy that does not copy

    /// The production change that makes this test fail: a fork that fails
    /// or stops when its source has no cache.
    @Test func aForkWhoseSourceHasNoCacheAnswers() async throws {
        let fixture = try await Self.makeFixture(copyOutcome: .sourceNotFound)
        let source = try await Self.makeSource(in: fixture)
        let fork = try await fixture.forks.fork(source, at: .lastCompletedTurn)

        let answer = try await fork.respond(to: Self.forkPrompt)

        #expect(answer == PromptCacheScopeRecordingModel.answer)
        await fixture.forks.end([source, fork])
    }

    /// The production change that makes this test fail: a fork that fails
    /// or stops when a pass of its source holds the cache.
    @Test func aForkWhoseSourceCacheIsInUseAnswers() async throws {
        let fixture = try await Self.makeFixture(copyOutcome: .sourceInUse)
        let source = try await Self.makeSource(in: fixture)
        let fork = try await fixture.forks.fork(source, at: .lastCompletedTurn)

        let answer = try await fork.respond(to: Self.forkPrompt)

        #expect(answer == PromptCacheScopeRecordingModel.answer)
        await fixture.forks.end([source, fork])
    }

    // MARK: - The budget

    /// The production change that makes this test fail: a copy that sends
    /// no budget, so the next budget does not count the bytes of the copy.
    @Test func theBudgetIsSentAgainAfterACopy() async throws {
        let fixture = try await Self.makeFixture(
            usageAfterCopy: PromptCacheUsage(memoryBytes: 0, spillingBytes: Self.spillingBytesAfterCopy, diskBytes: 0))
        let source = try await Self.makeSource(in: fixture)
        let budgetBefore = try #require(fixture.loader.memoryBudgets.last)

        let fork = try await fixture.forks.fork(source, at: .lastCompletedTurn)

        #expect(fixture.loader.memoryBudgets.last == budgetBefore - Self.spillingBytesAfterCopy)
        await fixture.forks.end([source, fork])
    }

    // MARK: - The release

    /// The production change that makes this test fail: a close of the fork
    /// that releases the key of its source, or no key.
    @Test func aClosedForkReleasesOnlyItsOwnKey() async throws {
        let fixture = try await Self.makeFixture()
        let source = try await Self.makeSource(in: fixture)
        let fork = try await fixture.forks.fork(source, at: .lastCompletedTurn)

        await fork.close()

        #expect(fixture.log.releasedSessionIDs == [fork.id.description])
        await fixture.forks.end([source])
    }

    /// The production change that makes this test fail: a close of the
    /// source that also releases the copy of its fork.
    @Test func aClosedSourceDoesNotReleaseTheKeyOfTheFork() async throws {
        let fixture = try await Self.makeFixture()
        let source = try await Self.makeSource(in: fixture)
        let fork = try await fixture.forks.fork(source, at: .lastCompletedTurn)

        await source.close()

        #expect(fixture.log.releasedSessionIDs == [source.id.description])
        await fixture.forks.end([fork])
    }

    // MARK: - The log

    /// The production change that makes this test fail: a copy whose
    /// outcome goes to no log record with the id of the fork.
    @Test func theOutcomeOfTheCopyIsLoggedWithTheForkID() async throws {
        try await TelemetryCapture.run(forbidding: []) { context in
            let fixture = try await Self.makeFixture(copyOutcome: .sourceInUse)
            let source = try await Self.makeSource(in: fixture)
            await source.useCaptureLogger(for: context.logger)

            let fork = try await fixture.forks.fork(source, at: .lastCompletedTurn)

            context.expectLogged(
                containing: "prompt cache",
                metadata: [
                    RouterTelemetry.LogMetadataKey.forkSessionId: fork.id.description,
                    RouterTelemetry.LogMetadataKey.forkPromptCacheCopy: PromptCacheCopyOutcome.sourceInUse.rawValue,
                ])
            await fixture.forks.end([source, fork])
        }
    }
}
