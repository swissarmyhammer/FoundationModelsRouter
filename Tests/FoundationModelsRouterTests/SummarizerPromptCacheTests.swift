import Foundation
import FoundationModels
import MLXFoundationModels
import Testing

@testable import FoundationModelsRouter

/// Task ^ptev9yy: each summarizer call of a compaction binds the `.uncached`
/// prompt-cache scope, so a compaction adds no key to the prompt cache of the
/// fork (`generation-queue.md`, section 3).
///
/// Each session runs over the production backend and a real
/// `LanguageModelSession` over a ``PromptCacheScopeRecordingModel``, so each
/// pass records the `MLXLanguageModel.promptCacheScope` that the executor of
/// the fork would see, with no GPU. The flash slot and the standard slot of
/// the profile resolve to the same model, so the log holds the passes of
/// both summarizer tiers. The own-model test gives the flash slot a stub
/// that fails, so that its requested compaction falls back to the own model.
///
/// Every compaction path (the caller compaction, the proactive compaction,
/// the compaction after a tool-result yield, a ceiling stop or an overflow)
/// makes each summarizer call through one seam, the blank backend of
/// `BackendCompactionSummarizer`. The two tests cover the two tiers and the
/// two entry points of that seam.
@Suite("A summarizer call keeps no prompt cache (task ^ptev9yy)")
struct SummarizerPromptCacheTests {
    /// The suite's temp-directory prefix, handed to
    /// ``RouterTestFixtures/makeTempDir(prefix:)``.
    private static let tempDirPrefix = "SummarizerPromptCacheTests"

    /// The first prompt of each session. It fills the context over the target
    /// of ``budget``, so the compaction applies a summary.
    private static let fillingPrompt = String(repeating: "x", count: fillingPromptLength)

    /// The length of ``fillingPrompt``, in characters (one token each).
    private static let fillingPromptLength = 600

    /// The prompt of the answer after the compaction.
    private static let afterCompactionPrompt = "after the compaction"

    /// The caller prompts of each session. A pass that serves none of them is
    /// a summarizer call.
    private static let callerPrompts: Set<String> = [fillingPrompt, afterCompactionPrompt]

    /// The budget of each compaction: its target is far under
    /// ``fillingPrompt``, so the compaction applies.
    private static let budget = TokenBudget(limit: 400, trigger: 0.8, target: 0.5)

    /// The input count each pass of the automatic-compaction model reports:
    /// over the trigger of ``budget`` and under its limit, so the pump
    /// compacts before the next submission.
    private static let reportedInputTokens = 360

    /// A router over one ``PromptCacheScopeRecordingModel``, and the log of
    /// that model.
    private struct Fixture {
        /// The log of the model.
        let log: PromptCacheScopeLog

        /// The resolved profile. Its standard slot runs over the model, and
        /// its flash slot too, unless the fixture gave it a stub that fails.
        let profile: LanguageModelProfile

        /// The directory of the router, which the test removes.
        let directory: URL
    }

    /// Makes a router over a new ``PromptCacheScopeRecordingModel``.
    ///
    /// - Parameters:
    ///   - reportedInputTokens: The input count each pass reports, or zero
    ///     for no usage report.
    ///   - failingFlash: Whether the flash slot resolves to a stub whose each
    ///     call fails, so that a compaction falls back to the own model. With
    ///     `false` (the default), the flash slot resolves to the recording
    ///     model too.
    /// - Returns: The fixture.
    /// - Throws: What the resolution of the profile throws. Before it throws,
    ///   it removes the directory.
    private static func makeFixture(reportedInputTokens: Int = 0, failingFlash: Bool = false) async throws -> Fixture {
        let directory = RouterTestFixtures.makeTempDir(prefix: tempDirPrefix)
        let log = PromptCacheScopeLog()
        let container = LiveBackendContainer(
            model: PromptCacheScopeRecordingModel(log: log, reportedInputTokens: reportedInputTokens))
        return try await RouterTestFixtures.removingDirectoryOnThrow(directory) {
            guard failingFlash else {
                let resolved = try await RouterTestFixtures.resolveStandardProfile(over: container, cacheDir: directory)
                return Fixture(log: log, profile: resolved.profile, directory: directory)
            }
            let router = RouterTestFixtures.makeRouter(
                cacheDir: directory,
                loader: PerSlotModelLoader(
                    standard: container,
                    flash: ConfiguredLLMContainer(responseText: "unused flash answer", shouldThrow: true),
                    dimension: RouterTestFixtures.stubDimension))
            let profile = try await router.resolve(profile: RouterTestFixtures.profile(), reporting: ResolutionProgress())
            return Fixture(log: log, profile: profile, directory: directory)
        }
    }

    /// The production change that makes this test fail: an own-model
    /// summarizer backend that binds no scope, or binds `Optional.none` in
    /// place of `.uncached`. Its pass then sees `nil`, and the fork keys it
    /// by its first transcript entry, which adds a key.
    ///
    /// A requested compaction offers the flash slot first. The flash slot of
    /// this fixture fails, so the compaction falls back to the own model,
    /// and the log holds the pass of the own-model summarizer call only.
    @Test("the own-model summarizer call of a caller compaction binds the uncached scope and adds no key")
    func ownModelSummarizerOfACallerCompactionAddsNoKey() async throws {
        let fixture = try await Self.makeFixture(failingFlash: true)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let session = fixture.profile.standard.makeSession()
        defer { await session.close() }
        _ = try await session.respond(to: Self.fillingPrompt)
        let keysBefore = fixture.log.storeKeys

        let result = try await session.compactAndAwait(budget: Self.budget)

        #expect(result.stagesApplied == [Summarization.stageName])
        #expect(result.summarizerTier == .ownModel)
        #expect(fixture.log.scopes(notServingPrompts: Self.callerPrompts) == [.uncached])
        #expect(keysBefore == [session.id.description])
        #expect(fixture.log.storeKeys == keysBefore)
    }

    /// The production change that makes this test fail: a flash summarizer
    /// backend that binds no scope, or binds `Optional.none` in place of
    /// `.uncached`. Its pass then sees `nil`, and the fork keys it by its
    /// first transcript entry, which adds a key.
    @Test("the flash summarizer call of an automatic compaction binds the uncached scope and adds no key")
    func flashSummarizerOfAnAutomaticCompactionAddsNoKey() async throws {
        let fixture = try await Self.makeFixture(reportedInputTokens: Self.reportedInputTokens)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let session = fixture.profile.standard.makeSession(budget: Self.budget)
        defer { await session.close() }
        _ = try await session.respond(to: Self.fillingPrompt)
        let keysBefore = fixture.log.storeKeys

        let events = try await collect(session.streamEvents(to: Self.afterCompactionPrompt, maxTokens: nil))

        let compaction = try #require(events.compactionResults.first)
        #expect(events.compactionResults.count == 1)
        #expect(compaction.summarizerTier == .flash)
        #expect(fixture.log.scopes(notServingPrompts: Self.callerPrompts) == [.uncached])
        #expect(keysBefore == [session.id.description])
        #expect(fixture.log.storeKeys == keysBefore)
    }
}
