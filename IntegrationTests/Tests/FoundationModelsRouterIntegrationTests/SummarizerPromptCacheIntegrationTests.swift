import Foundation
import FoundationModels
import FoundationModelsRouterTestSupport
import Testing

@testable import FoundationModelsRouter
@testable import FoundationModelsRouterRealModelSupport
@testable import MLXFoundationModels

/// The real model of this suite: `Qwen2.5-3B-Instruct-4bit`, 1.6 GB on disk,
/// the model of ``CompactionRoundTripIntegrationTests``. Its layers are all
/// attention layers, so its caches can rewind to the seam where a render
/// parts from the cached tokens, and a pass after a compaction can reuse the
/// shared prefix.
private let summarizerPromptCacheModel: ModelRef = "mlx-community/Qwen2.5-3B-Instruct-4bit"

/// The instructions of each session of this suite. The compacted transcript
/// keeps them word for word, so the pass after a compaction shares them with
/// the pass before it.
private let summarizerPromptCacheInstructions = CompactionRoundTripFixture.instructions

/// The count of the facts in ``fillingPrompt``.
private let fillingFactCount = 60

/// The first prompt of each session: about 900 tokens of numbered facts. It
/// takes the live context over the target of
/// ``CompactionRoundTripFixture/compactionBudget``, so the caller compaction
/// makes its one summarizer call and applies the summary.
private let fillingPrompt =
    (1...fillingFactCount).map { "Fact \($0): the code word of item \($0) is ALPHA-\($0)." }.joined(separator: " ")
    + " Reply with just \"OK\"."

/// The prompt of the answer after the compaction.
private let afterCompactionPrompt = "Reply with just \"OK\"."

/// The key count and the byte totals of the prompt cache of the fork, read
/// together.
private struct PromptCacheState: Equatable {
    /// How many sessions hold an entry in memory.
    let keyCount: Int

    /// The bytes in memory, the bytes whose write to disk has not ended, and
    /// the bytes on disk.
    let usage: PromptCacheUsage
}

/// Gated real-model coverage for task ^ptev9yy (`generation-queue.md`,
/// section 3): the summarizer call of a compaction keeps no prompt cache.
///
/// ## What it proves
///
/// - A caller compaction leaves the key count and the byte totals of the
///   prompt cache of the fork as they were. Only the real executor of the fork
///   reads the `.uncached` scope, so only this suite proves that the scope
///   reaches it and that it adds no key.
/// - The next pass of the compacted session still reuses its own cache: the
///   summarizer call did not take the entry of the session.
///
/// `SummarizerPromptCacheTests` in the unit target proves the scope that each
/// summarizer pass binds, over a recording model, with no GPU.
///
/// The key count is `ExecutorPromptCacheStore.retainedSessionCount`, an
/// internal member of the fork that exists for tests; the fork publishes the
/// byte totals only.
@Suite(
    "Gated real-model coverage: a compaction adds no key to the prompt cache (task ^ptev9yy)",
    .serialized,
    .exclusiveRealModel
)
struct SummarizerPromptCacheIntegrationTests {
    /// Argmax decoding, so each run feeds the same tokens.
    private static let samplingMode: GenerationOptions.SamplingMode = .greedy

    /// A session over the real model, with the model to evict and the
    /// directory to remove.
    private struct Fixture {
        /// The loaded model.
        let loaded: RealModelContainer

        /// The session of the test, as the actor, so the test can read its
        /// backend and its token counter.
        let session: RoutedSessionActor

        /// The directory of the cache and the recordings of the router, which
        /// the test removes.
        let directory: URL
    }

    /// Loads the model and makes one session with
    /// ``summarizerPromptCacheInstructions``.
    ///
    /// - Returns: The fixture.
    /// - Throws: What the load throws.
    private static func makeFixture() async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SummarizerPromptCacheIntegrationTests-\(UUID().uuidString)", isDirectory: true)
        let cacheDir = root.appendingPathComponent("cache", isDirectory: true)
        let recordingsDir = root.appendingPathComponent("recordings", isDirectory: true)
        let loaded = try await RealModelContainer.load(
            ref: summarizerPromptCacheModel, context: CompactionRoundTripFixture.context, samplingMode: samplingMode)
        let profile = RealModelHarness.make(
            model: summarizerPromptCacheModel, context: CompactionRoundTripFixture.context,
            container: loaded.container, samplingMode: loaded.samplingMode,
            cacheDir: cacheDir, recordingsDir: recordingsDir)
        let session = try #require(
            profile.standard.makeSession(instructions: summarizerPromptCacheInstructions) as? RoutedSessionActor)
        return Fixture(loaded: loaded, session: session, directory: root)
    }

    /// Answers ``fillingPrompt`` and compacts, and requires that the summary
    /// applied.
    ///
    /// - Parameter session: The session to fill and compact.
    /// - Throws: What the answer or the compaction throws.
    private static func fillAndCompact(_ session: RoutedSessionActor) async throws {
        _ = try await session.respond(to: fillingPrompt, maxTokens: GatedRealModelBudget.responseTokenCeiling)
        let result = try await session.compact(budget: CompactionRoundTripFixture.compactionBudget)
        #expect(
            result.stagesApplied == [Summarization.stageName],
            "expected the summary to apply, got \(result.stagesApplied), shortfall \(String(describing: result.shortfall))"
        )
    }

    /// The key count and the byte totals of the prompt cache, once no entry
    /// is being written to disk, or at the end of a bounded wait.
    ///
    /// - Returns: The state of the prompt cache.
    /// - Throws: `CancellationError` when the test is cancelled.
    private static func settledPromptCacheState() async throws -> PromptCacheState {
        try await SettledValuePoll.value(of: {
            let usage = await MLXLanguageModel.promptCacheUsage
            return PromptCacheState(
                keyCount: await ExecutorPromptCacheStore.current.retainedSessionCount,
                usage: PromptCacheUsage(
                    memoryBytes: usage.memoryBytes, spillingBytes: usage.spillingBytes, diskBytes: usage.diskBytes))
        }) { $0.usage.spillingBytes == 0 }
    }

    /// The production change that makes this test fail: a summarizer backend
    /// that binds no scope, or binds `Optional.none` in place of `.uncached`.
    /// The fork then keys the summarizer pass by its first transcript entry,
    /// and keeps one more entry, with its bytes.
    @Test("a caller compaction leaves the key count and the byte totals of the prompt cache as they were")
    func aCompactionAddsNoKeyToThePromptCache() async throws {
        let fixture = try await Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        _ = try await fixture.session.respond(to: fillingPrompt, maxTokens: GatedRealModelBudget.responseTokenCeiling)
        let before = try await Self.settledPromptCacheState()

        let result = try await fixture.session.compact(budget: CompactionRoundTripFixture.compactionBudget)
        let after = try await Self.settledPromptCacheState()

        #expect(result.stagesApplied == [Summarization.stageName])
        #expect(before.keyCount > 0, "the answer before the compaction must leave the entry of the session")
        #expect(after == before, "the compaction must add no key and no byte: before \(before), after \(after)")

        await fixture.loaded.container.model.evict()
    }

    /// The production change that makes this test fail: a summarizer backend
    /// that binds the key of the session. The summarizer pass then takes the
    /// entry of the session and leaves its own tokens in it, so the next pass
    /// shares only the first tokens of the chat template with that entry, and
    /// not the instructions.
    @Test("the next answer of a compacted session reuses at least its instructions from its own cache")
    func theNextAnswerAfterACompactionReusesItsOwnCache() async throws {
        let fixture = try await Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        try await Self.fillAndCompact(fixture.session)

        _ = try await fixture.session.respond(
            to: afterCompactionPrompt, maxTokens: GatedRealModelBudget.responseTokenCeiling)

        // The compaction replaced the backend, so the usage of the new SDK
        // session is the usage of the answer after the compaction only.
        let backend = try #require(await fixture.session.backend as? MLXFoundationModelsSessionBackend)
        let cachedTokens = backend.session.usage.input.cachedTokenCount
        let instructionTokens = fixture.session.tokenCounter.count(summarizerPromptCacheInstructions)
        #expect(
            cachedTokens >= instructionTokens,
            "the answer after the compaction reused \(cachedTokens) tokens; the instructions alone are \(instructionTokens)"
        )

        await fixture.loaded.container.model.evict()
    }
}
