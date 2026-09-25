import Foundation
import FoundationModelsRouterRealModelSupport
import FoundationModelsRouterTestSupport
import HuggingFace
import MLXHuggingFace
import MLXLMCommon
import Synchronization
import Testing
import Tokenizers

@testable import FoundationModelsRouter

/// The working context of ``twoModelProfile``, in tokens: 4k. It is the short
/// context of the spill measurements of fork task ^mre55m3.
private let twoModelContextTokens = 4096

/// The profile of this suite: two small generation models with attention
/// layers only, and the real embedder of the gated suites. All three are
/// resident at one time.
///
/// Qwen3 has no recurrent layers, so each of its turns leaves one prompt-cache
/// entry that the fork can write to disk and read again.
private let twoModelProfile = ProfileDefinition(
    name: "prompt-cache-two-models",
    description: "Two small Qwen3 generation models and the gated embedder.",
    standard: ["mlx-community/Qwen3-4B-4bit"],
    flash: ["mlx-community/Qwen3-1.7B-4bit"],
    embedding: [RealModels.embedding],
    context: twoModelContextTokens
)

/// The prompt each session of this suite answers.
private let promptCachePrompt = "Say hello in one short sentence."

/// The instructions each session of this suite is made with.
private let promptCacheInstructions = "You are a terse assistant."

/// The room the second resolve leaves for the prompt cache above the resident
/// footprint: 1 MiB. One turn of either model leaves a larger entry, so each
/// entry must go to disk.
private let promptCacheRoomBytes: Int64 = 1 << 20

/// A ``MachineProbe`` whose recommended working set the test sets. It starts
/// at the working set of the host.
private final class AdjustableWorkingSetProbe: MachineProbe {
    /// The live probe that gives the chip and the physical RAM.
    private let live = SystemMachineProbe()

    /// The working set this probe reports.
    private let workingSet: Mutex<Int64>

    /// Makes a probe that reports the working set of the host.
    init() {
        workingSet = Mutex(live.recommendedMaxWorkingSetSize)
    }

    var chip: String { live.chip }

    var totalRAM: Int64 { live.totalRAM }

    var recommendedMaxWorkingSetSize: Int64 { workingSet.withLock { $0 } }

    /// Sets the working set the next reads report.
    ///
    /// - Parameter bytes: The working set, in bytes.
    func setWorkingSet(_ bytes: Int64) {
        workingSet.withLock { $0 = bytes }
    }
}

/// Gated real-model coverage for `generation-queue.md` section 3: the pool
/// sizes the prompt-cache memory budget of the fork, with two generation
/// models resident.
///
/// ## What it proves
///
/// The first resolve measures the footprint of the profile. The second resolve
/// runs on a probe whose working set is that footprint plus
/// ``promptCacheRoomBytes``, so the pool sends a budget of at most that room.
/// A turn on each model then leaves an entry that is larger than the room, so
/// the fork writes each entry to disk. When the writes end, the weights plus
/// the resident prompt cache (in memory plus spilling) fit in the working set,
/// and the files on disk hold the entries. The fork default (one quarter of
/// the free working set) would keep both entries in memory, so a budget that
/// did not reach the fork fails the test.
///
/// ## Why the coverage is gated
///
/// `Tests/FoundationModelsRouterTests/PromptCacheBudgetTests.swift` proves the
/// budget arithmetic and when the pool sends it, over a recording loader. Only
/// ``LiveModelLoader`` over real models proves that the budget reaches the
/// process-wide store of the fork, and that the store obeys it.
@Suite(
    "Gated real-model coverage: two resident models keep weights plus prompt caches in the pool budget",
    .serialized,
    .exclusiveRealModel
)
struct PromptCacheBudgetIntegrationTests {
    @Test("two resident models: the weights plus the prompt caches stay in the pool budget")
    func weightsPlusPromptCachesStayInThePoolBudget() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PromptCacheBudgetIntegrationTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let probe = AdjustableWorkingSetProbe()
        let pool = ModelPool()
        let loader = LiveModelLoader(
            downloader: #hubDownloader(), tokenizerLoader: #huggingFaceTokenizerLoader())
        let router = Router(
            cacheDir: root.appendingPathComponent("cache", isDirectory: true),
            probe: probe,
            loader: loader,
            samplingMode: .greedy,
            pool: pool
        )

        let footprint = try await residentFootprint(of: router, on: pool)
        let workingSet = footprint + promptCacheRoomBytes
        probe.setWorkingSet(workingSet)

        var profile: LanguageModelProfile? = try await router.resolve(
            profile: twoModelProfile, reporting: ResolutionProgress())
        #expect(await pool.residentFootprintBytes == footprint)
        try await answerOnce(on: try #require(profile).standard)
        try await answerOnce(on: try #require(profile).flash)

        let usage = try await promptCacheUsageOnceWritten(by: loader)
        #expect(usage.diskBytes > 0)
        #expect(Int64(usage.memoryBytes) <= promptCacheRoomBytes)
        #expect(await pool.residentFootprintBytes + Int64(usage.residentBytes) <= workingSet)

        profile = nil
        #expect(try await residentModelCountOnceEvicted(pool) == 0)
    }

    /// Resolves ``twoModelProfile`` one time on the host working set, reads
    /// the resident footprint, and gives the profile back.
    ///
    /// - Parameters:
    ///   - router: The router to resolve on.
    ///   - pool: The pool of `router`, empty before the call.
    /// - Returns: The resident footprint of the profile, in bytes.
    /// - Throws: Whatever the resolve throws, or `CancellationError`.
    private func residentFootprint(of router: Router, on pool: ModelPool) async throws -> Int64 {
        var profile: LanguageModelProfile? = try await router.resolve(
            profile: twoModelProfile, reporting: ResolutionProgress())
        #expect(profile != nil)
        let footprint = await pool.residentFootprintBytes
        profile = nil
        #expect(try await residentModelCountOnceEvicted(pool) == 0)
        return footprint
    }

    /// Makes one session on `model` and answers ``promptCachePrompt`` one time,
    /// which leaves one prompt-cache entry.
    ///
    /// Every turn states ``GatedRealModelBudget/responseTokenCeiling`` as its
    /// reply ceiling, so a `<think>` block that does not stop cannot make the
    /// turn run without end.
    ///
    /// - Parameter model: The resident generation model.
    /// - Throws: Whatever the turn throws.
    private func answerOnce(on model: RoutedLLM) async throws {
        let session = model.makeSession(instructions: promptCacheInstructions)
        _ = try await session.respond(
            to: promptCachePrompt, maxTokens: GatedRealModelBudget.responseTokenCeiling)
    }

    /// The prompt-cache usage of `loader` once no entry is being written to
    /// disk, or the usage at the end of a bounded wait.
    ///
    /// - Parameter loader: The loader whose prompt cache to read.
    /// - Returns: The usage.
    /// - Throws: `CancellationError` when the test is cancelled.
    private func promptCacheUsageOnceWritten(by loader: LiveModelLoader) async throws -> PromptCacheUsage {
        try await SettledValuePoll.value(of: { await loader.promptCacheUsage }) { $0.spillingBytes == 0 }
    }

    /// The resident model count of `pool` once the drains that dropped
    /// profiles started have run, or the count at the end of a bounded wait.
    ///
    /// - Parameter pool: The pool to read.
    /// - Returns: The resident model count.
    /// - Throws: `CancellationError` when the test is cancelled.
    private func residentModelCountOnceEvicted(_ pool: ModelPool) async throws -> Int {
        try await SettledValuePoll.value(of: { await pool.residentModelCount }) { $0 == 0 }
    }
}
