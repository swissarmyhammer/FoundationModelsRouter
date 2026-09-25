import Foundation
import Testing

@testable import FoundationModelsRouter

/// A ``ModelLoader`` that records each prompt-cache memory budget it gets, and
/// reports a fixed prompt-cache usage.
///
/// It gives each load to the shared ``StubModelLoader``, which loads one
/// ``CannedLLMContainer`` for each generation slot and a
/// ``StubEmbeddingContainer`` for each embedder. It does no download and uses
/// no GPU.
private actor PromptCacheRecordingLoader: ModelLoader {
    /// The reference of the canned generation container that each load gives.
    private static let cannedRef: ModelRef = "org/prompt-cache"

    /// Each memory budget the pool sent, in the order it was sent.
    private(set) var memoryBudgets: [Int] = []

    /// The usage this loader reports for each read.
    private let usage: PromptCacheUsage

    /// The shared stub that does each load.
    private let stub = StubModelLoader(
        container: CannedLLMContainer(ref: cannedRef), dimension: RouterTestFixtures.stubDimension)

    /// Makes a loader that reports `usage`.
    ///
    /// - Parameter usage: The prompt-cache usage to report.
    init(usage: PromptCacheUsage = .zero) {
        self.usage = usage
    }

    func loadLLM(
        ref: ModelRef,
        slot: ModelSlot,
        context: Int,
        reporting: @escaping @Sendable (DownloadProgress) -> Void
    ) async throws -> any LoadedLLMContainer {
        try await stub.loadLLM(ref: ref, slot: slot, context: context, reporting: reporting)
    }

    func loadEmbedder(
        ref: ModelRef,
        slot: ModelSlot,
        reporting: @escaping @Sendable (DownloadProgress) -> Void
    ) async throws -> any LoadedEmbeddingContainer {
        try await stub.loadEmbedder(ref: ref, slot: slot, reporting: reporting)
    }

    func preload(container: any LoadedModelContainer) async throws {
        try await stub.preload(container: container)
    }

    func configurePromptCache(memoryBudgetBytes: Int) async {
        memoryBudgets.append(memoryBudgetBytes)
    }

    var promptCacheUsage: PromptCacheUsage { usage }
}

/// The failure a load of ``PromptCacheBudgetTests`` throws on purpose.
private struct DeliberateLoadFailure: Error {}

/// Unit coverage of the prompt-cache memory budget (`generation-queue.md`
/// section 3): the working set less the footprint of each resident model and
/// less the bytes that are being written to disk, sent to the loader each time
/// the resident footprint changes.
struct PromptCacheBudgetTests {
    /// The recommended working set of each test: 48 GiB.
    static let workingSet: Int64 = 48 << 30

    /// The recommended working set that a later resolve measures: 32 GiB. It
    /// is different from ``workingSet``, so a test can see which working set a
    /// budget used.
    static let laterWorkingSet: Int64 = 32 << 30

    /// The footprint of the first resident model: 6 GiB.
    static let firstFootprint: Int64 = 6 << 30

    /// The footprint of the second resident model: 3 GiB.
    static let secondFootprint: Int64 = 3 << 30

    /// The prompt-cache bytes in memory that a usage double reports: 2 GiB.
    static let memoryBytes = 2 << 30

    /// The prompt-cache bytes that a usage double reports as being written to
    /// disk: 1 GiB.
    static let spillingBytes = 1 << 30

    /// The prompt-cache bytes on disk that a usage double reports: 5 GiB.
    static let diskBytes = 5 << 30

    /// The pool key of the first model.
    static let firstKey = ResidencyKey(ref: "org/first", role: .llm)

    /// The pool key of the second model.
    static let secondKey = ResidencyKey(ref: "org/second", role: .llm)

    // MARK: - The budget computation

    @Test("with no resident model, the budget is the whole working set")
    func budgetWithNoResidentModelIsTheWorkingSet() {
        let budget = PromptCacheBudget.memoryBudgetBytes(
            workingSetBytes: Self.workingSet, residentFootprints: [], usage: .zero)
        #expect(budget == Int(Self.workingSet))
    }

    @Test("with one resident model, the budget is the working set less its footprint")
    func budgetWithOneResidentModel() {
        let budget = PromptCacheBudget.memoryBudgetBytes(
            workingSetBytes: Self.workingSet, residentFootprints: [Self.firstFootprint], usage: .zero)
        #expect(budget == Int(Self.workingSet - Self.firstFootprint))
    }

    @Test("with two resident models, the budget is the working set less both footprints")
    func budgetWithTwoResidentModels() {
        let budget = PromptCacheBudget.memoryBudgetBytes(
            workingSetBytes: Self.workingSet,
            residentFootprints: [Self.firstFootprint, Self.secondFootprint],
            usage: .zero
        )
        #expect(budget == Int(Self.workingSet - Self.firstFootprint - Self.secondFootprint))
    }

    @Test("the spilling bytes come off the budget, and the bytes in memory and on disk do not")
    func budgetHoldsOutTheSpillingBytes() {
        let usage = PromptCacheUsage(
            memoryBytes: Self.memoryBytes, spillingBytes: Self.spillingBytes, diskBytes: Self.diskBytes)
        let budget = PromptCacheBudget.memoryBudgetBytes(
            workingSetBytes: Self.workingSet, residentFootprints: [Self.firstFootprint], usage: usage)
        #expect(budget == Int(Self.workingSet - Self.firstFootprint) - Self.spillingBytes)
    }

    @Test("resident prompt-cache memory is the bytes in memory plus the spilling bytes")
    func residentBytesCountTheSpillingBytes() {
        let usage = PromptCacheUsage(
            memoryBytes: Self.memoryBytes, spillingBytes: Self.spillingBytes, diskBytes: Self.diskBytes)
        #expect(usage.residentBytes == Self.memoryBytes + Self.spillingBytes)
    }

    @Test("footprints past the working set give a budget of zero, never a negative one")
    func budgetNeverGoesBelowZero() {
        let budget = PromptCacheBudget.memoryBudgetBytes(
            workingSetBytes: Self.firstFootprint,
            residentFootprints: [Self.firstFootprint, Self.secondFootprint],
            usage: .zero
        )
        #expect(budget == 0)
    }

    // MARK: - The pool sends the budget

    @Test("the pool sends the budget again after each load and after each unload")
    func poolSendsTheBudgetAfterEachLoadAndUnload() async throws {
        let loader = PromptCacheRecordingLoader()
        let pool = ModelPool()
        let sizing = PromptCacheSizing(loader: loader, workingSetBytes: Self.workingSet)

        try await acquire(Self.firstKey, footprint: Self.firstFootprint, sizing: sizing, on: pool)
        #expect(await loader.memoryBudgets.last == Int(Self.workingSet - Self.firstFootprint))

        try await acquire(Self.secondKey, footprint: Self.secondFootprint, sizing: sizing, on: pool)
        let bothResident = Int(Self.workingSet - Self.firstFootprint - Self.secondFootprint)
        #expect(await loader.memoryBudgets.last == bothResident)

        let sentBeforeUnload = await loader.memoryBudgets.count
        await release(Self.secondKey, on: pool)
        #expect(await loader.memoryBudgets.count > sentBeforeUnload)
        #expect(await loader.memoryBudgets.last == Int(Self.workingSet - Self.firstFootprint))

        await release(Self.firstKey, on: pool)
        #expect(await loader.memoryBudgets.last == Int(Self.workingSet))
        #expect(await pool.residentModelCount == 0)
    }

    @Test("a release sizes the budget against the working set of the latest acquisition")
    func releaseUsesTheWorkingSetOfTheLatestAcquisition() async throws {
        let loader = PromptCacheRecordingLoader()
        let pool = ModelPool()
        let firstSizing = PromptCacheSizing(loader: loader, workingSetBytes: Self.workingSet)
        let laterSizing = PromptCacheSizing(loader: loader, workingSetBytes: Self.laterWorkingSet)

        try await acquire(Self.firstKey, footprint: Self.firstFootprint, sizing: firstSizing, on: pool)
        try await acquire(Self.firstKey, footprint: Self.firstFootprint, sizing: laterSizing, on: pool)
        await release(Self.firstKey, on: pool)

        #expect(await pool.residentModelCount == 1)
        #expect(await loader.memoryBudgets.last == Int(Self.laterWorkingSet - Self.firstFootprint))
    }

    @Test("the pool shrinks the budget before it loads the weights of a new model")
    func poolShrinksTheBudgetBeforeTheLoad() async throws {
        let loader = PromptCacheRecordingLoader()
        let pool = ModelPool()
        let sizing = PromptCacheSizing(loader: loader, workingSetBytes: Self.workingSet)
        let expected = Int(Self.workingSet - Self.firstFootprint)

        try await acquire(Self.firstKey, footprint: Self.firstFootprint, sizing: sizing, on: pool) {
            #expect(await loader.memoryBudgets.last == expected)
            return .llm(CannedLLMContainer(ref: Self.firstKey.ref))
        }
    }

    @Test("a load that fails gives the budget back")
    func failedLoadGivesTheBudgetBack() async throws {
        let loader = PromptCacheRecordingLoader()
        let pool = ModelPool()
        let sizing = PromptCacheSizing(loader: loader, workingSetBytes: Self.workingSet)

        await #expect(throws: DeliberateLoadFailure.self) {
            try await acquire(Self.firstKey, footprint: Self.firstFootprint, sizing: sizing, on: pool) {
                throw DeliberateLoadFailure()
            }
        }
        #expect(await loader.memoryBudgets.last == Int(Self.workingSet))
        #expect(await pool.residentModelCount == 0)
    }

    @Test("the pool holds the spilling bytes out of the budget it sends")
    func poolHoldsOutTheSpillingBytes() async throws {
        let usage = PromptCacheUsage(
            memoryBytes: Self.memoryBytes, spillingBytes: Self.spillingBytes, diskBytes: Self.diskBytes)
        let loader = PromptCacheRecordingLoader(usage: usage)
        let pool = ModelPool()
        let sizing = PromptCacheSizing(loader: loader, workingSetBytes: Self.workingSet)

        try await acquire(Self.firstKey, footprint: Self.firstFootprint, sizing: sizing, on: pool)
        let expected = Int(Self.workingSet - Self.firstFootprint) - Self.spillingBytes
        #expect(await loader.memoryBudgets.last == expected)
    }

    // MARK: - The router gives its loader and its working set to the pool

    @Test("a resolve sends the working set less the resident footprint, and a drop sends it again")
    func resolveAndDropSendTheBudget() async throws {
        let loader = PromptCacheRecordingLoader()
        let pool = ModelPool()
        let cacheDir = RouterTestFixtures.makeTempDir(prefix: "PromptCacheBudgetTests")
        defer { try? FileManager.default.removeItem(at: cacheDir) }
        let router = RouterTestFixtures.makeRouter(cacheDir: cacheDir, loader: loader, pool: pool)
        let hostWorkingSet = RouterTestFixtures.stubProbe.recommendedMaxWorkingSetSize

        var profile: LanguageModelProfile? = try await router.resolve(
            profile: RouterTestFixtures.profile(), reporting: ResolutionProgress())
        #expect(profile != nil)
        let residentFootprint = await pool.residentFootprintBytes
        #expect(residentFootprint > 0)
        #expect(await loader.memoryBudgets.last == Int(hostWorkingSet - residentFootprint))

        profile.dropReference()
        await pool.settleDroppedResidencies()
        #expect(await loader.memoryBudgets.last == Int(hostWorkingSet))
    }

    // MARK: - Helpers

    /// Acquires `key` on `pool` under the resolve lock, with a charge of no KV
    /// cache.
    ///
    /// - Parameters:
    ///   - key: The pool key to acquire.
    ///   - footprint: The whole footprint of the model.
    ///   - sizing: The prompt-cache target and working set of the acquisition.
    ///   - pool: The pool to acquire on.
    ///   - load: The load of a fresh entry, or `nil` (the default) for a load
    ///     that gives a canned generation container for `key`.
    /// - Throws: Whatever the acquisition throws.
    private func acquire(
        _ key: ResidencyKey,
        footprint: Int64,
        sizing: PromptCacheSizing,
        on pool: ModelPool,
        load: (@Sendable () async throws -> PooledContainer)? = nil
    ) async throws {
        let cannedLoad: @Sendable () async throws -> PooledContainer = {
            .llm(CannedLLMContainer(ref: key.ref))
        }
        try await pool.withResolveLock {
            _ = try await pool.acquire(
                key: key,
                footprintBytes: footprint,
                sessionBytes: 0,
                promptCache: sizing,
                load: load ?? cannedLoad,
                evict: { _ in }
            )
        }
    }

    /// Releases the one charge of `key` on `pool` under the resolve lock.
    ///
    /// - Parameters:
    ///   - key: The pool key to release.
    ///   - pool: The pool to release on.
    private func release(_ key: ResidencyKey, on pool: ModelPool) async {
        await pool.withResolveLock {
            await pool.release(charges: [SlotCharge(key: key, sessionBytes: 0)])
        }
    }
}
