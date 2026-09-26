import Foundation
import FoundationModels
import FoundationModelsRouterTestSupport
import MLXFoundationModels
import Testing

@testable import FoundationModelsRouter

/// Task ^cc2tezn: the prompt cache of the fork is keyed by the Router session
/// id, and a session releases its key when it closes (`generation-queue.md`,
/// sections 2 and 3).
///
/// Each session runs over the production backend and a real
/// `LanguageModelSession` over a ``PromptCacheScopeRecordingModel``, so each
/// pass records the `MLXLanguageModel.promptCacheScope` that the executor of
/// the fork would see, and each release reaches the model, with no GPU.
@Suite("The prompt cache is keyed by the Router session id, and released on close (task ^cc2tezn)")
struct SessionPromptCacheKeyTests {
    /// The suite's temp-directory prefix, handed to
    /// ``RouterTestFixtures/makeTempDir(prefix:)``.
    private static let tempDirPrefix = "SessionPromptCacheKeyTests"

    /// The first prompt of the parent session.
    private static let parentPrompt = "parent first"

    /// The prompt of the parent after its fork.
    private static let parentAfterForkPrompt = "parent after the fork"

    /// The prompt of the fork.
    private static let forkPrompt = "fork first"

    /// The prompt of the answer after the compaction.
    private static let afterCompactionPrompt = "after the compaction"

    /// The length of the prompt that fills the context before the
    /// compaction, in characters (one token each).
    private static let fillingPromptLength = 600

    /// The budget of the caller compaction: its target is far under the
    /// filling prompt, so the compaction applies.
    private static let compactionBudget = TokenBudget(limit: 400, trigger: 0.8, target: 0.5)

    /// A router over one ``PromptCacheScopeRecordingModel``, and the log of
    /// that model.
    private struct Fixture {
        /// The log of the model.
        let log: PromptCacheScopeLog

        /// The resolved profile whose standard slot runs over the model.
        let profile: LanguageModelProfile

        /// The directory of the router, which the test removes.
        let directory: URL
    }

    /// Makes a router over a new ``PromptCacheScopeRecordingModel``.
    ///
    /// - Returns: The fixture.
    /// - Throws: What the resolution of the profile throws.
    private static func makeFixture() async throws -> Fixture {
        let directory = RouterTestFixtures.makeTempDir(prefix: tempDirPrefix)
        let log = PromptCacheScopeLog()
        let container = LiveBackendContainer(model: PromptCacheScopeRecordingModel(log: log))
        let resolved = try await RouterTestFixtures.resolveStandardProfile(over: container, cacheDir: directory)
        return Fixture(log: log, profile: resolved.profile, directory: directory)
    }

    /// The scope of the passes of `session`.
    ///
    /// - Parameter session: The session.
    /// - Returns: The `.session` scope named by the id of `session`.
    private static func scope(of session: any RoutedSession) -> MLXLanguageModel.PromptCacheScope {
        .session(session.id.description)
    }

    /// The production change that makes this test fail: a wrapper that binds
    /// no scope (each pass then sees `nil`), or a fork that runs with the id
    /// of its parent.
    @Test("a fork and its parent put their passes under two different keys")
    func aForkAndItsParentUseTwoKeys() async throws {
        let fixture = try await Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let parent = fixture.profile.standard.makeSession()

        _ = try await parent.respond(to: Self.parentPrompt)
        let fork = try await parent.fork(workingDirectory: nil)
        _ = try await fork.respond(to: Self.forkPrompt)
        _ = try await parent.respond(to: Self.parentAfterForkPrompt)

        #expect(parent.id != fork.id)
        #expect(fixture.log.scopes(servingPrompt: Self.parentPrompt) == [Self.scope(of: parent)])
        #expect(fixture.log.scopes(servingPrompt: Self.parentAfterForkPrompt) == [Self.scope(of: parent)])
        #expect(fixture.log.scopes(servingPrompt: Self.forkPrompt) == [Self.scope(of: fork)])
    }

    /// The production change that makes this test fail: a `close()` that
    /// releases no key, or releases a key other than the session id.
    @Test("a closed session releases its key on the model it used")
    func aClosedSessionReleasesItsKey() async throws {
        let fixture = try await Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let session = fixture.profile.standard.makeSession()
        _ = try await session.respond(to: Self.parentPrompt)

        await session.close()

        #expect(fixture.log.releasedSessionIDs == [session.id.description])
    }

    /// The production change that makes this test fail: a fork whose close
    /// releases the key of its parent (for example a fork that keeps the id
    /// of its parent).
    @Test("the close of a fork releases the key of the fork and not the key of its open parent")
    func closingAForkDoesNotReleaseItsParentsKey() async throws {
        let fixture = try await Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let parent = fixture.profile.standard.makeSession()
        _ = try await parent.respond(to: Self.parentPrompt)
        let fork = try await parent.fork(workingDirectory: nil)
        _ = try await fork.respond(to: Self.forkPrompt)

        await fork.close()

        #expect(fixture.log.releasedSessionIDs == [fork.id.description])
    }

    /// The production change that makes this test fail: a release that
    /// comes after the early return for a close with no terminal events of
    /// the mailbox.
    @Test("a session closed with no mailbox events still releases its key")
    func aSessionClosedWithNoMailboxEventsReleasesItsKey() async throws {
        let fixture = try await Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let session = fixture.profile.standard.makeSession()

        await session.close()

        #expect(fixture.log.releasedSessionIDs == [session.id.description])
    }

    /// The production change that makes this test fail: a backend that a
    /// compaction replaces and that does not get the id of its session (its
    /// passes then see `nil`), or a new key for each backend.
    @Test("a compaction that drops the first entry keeps the key of the session")
    func aCompactionKeepsTheKeyOfTheSession() async throws {
        let fixture = try await Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let session = fixture.profile.standard.makeSession()
        let fillingPrompt = String(repeating: "x", count: Self.fillingPromptLength)
        _ = try await session.respond(to: fillingPrompt)
        let firstEntryBefore = try #require(Array(await session.transcript).first).id

        let result = try await session.compact(budget: Self.compactionBudget)
        let firstEntryAfter = try #require(Array(await session.transcript).first).id
        _ = try await session.respond(to: Self.afterCompactionPrompt)

        #expect(result.stagesApplied == [Summarization.stageName])
        #expect(firstEntryAfter != firstEntryBefore)
        #expect(fixture.log.scopes(servingPrompt: fillingPrompt) == [Self.scope(of: session)])
        #expect(fixture.log.scopes(servingPrompt: Self.afterCompactionPrompt) == [Self.scope(of: session)])
        #expect(fixture.log.sessionKeys == [session.id.description])
    }
}
