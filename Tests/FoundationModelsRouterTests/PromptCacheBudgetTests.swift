import Foundation
import Testing

@testable import FoundationModelsRouter

/// A ``ModelLoader`` that records each prompt-cache memory budget it gets and
/// each load, in one list in call order, and reports a fixed prompt-cache
/// usage.
///
/// It gives each load to the shared ``StubModelLoader``, which loads one
/// ``CannedLLMContainer`` for each generation slot and a
/// ``StubEmbeddingContainer`` for each embedder. It does no download and uses
/// no GPU.
private actor PromptCacheRecordingLoader: ModelLoader {
    /// One call that the loader received.
    enum Call: Equatable {
        /// A memory budget of the prompt cache.
        case budget(Int)

        /// A load of a model.
        case load(ModelRef)
    }

    /// The reference of the canned generation container that each load gives.
    private static let cannedRef: ModelRef = "org/prompt-cache"

    /// Each call, in the order it arrived.
    private(set) var calls: [Call] = []

    /// Each memory budget the router sent, in the order it was sent.
    var memoryBudgets: [Int] {
        calls.compactMap { call in
            guard case .budget(let budget) = call else { return nil }
            return budget
        }
    }

    /// The usage this loader reports for each read.
    private let usage: PromptCacheUsage

    /// Whether each load throws ``DeliberateLoadFailure``.
    private let failsEachLoad: Bool

    /// The shared stub that does each load.
    private let stub = StubModelLoader(
        container: CannedLLMContainer(ref: cannedRef), dimension: RouterTestFixtures.stubDimension)

    /// Makes a loader that reports `usage`.
    ///
    /// - Parameters:
    ///   - usage: The prompt-cache usage to report.
    ///   - failsEachLoad: Whether each load throws ``DeliberateLoadFailure``.
    init(usage: PromptCacheUsage = .zero, failsEachLoad: Bool = false) {
        self.usage = usage
        self.failsEachLoad = failsEachLoad
    }

    func loadLLM(
        ref: ModelRef,
        slot: ModelSlot,
        context: Int,
        reporting: @escaping @Sendable (DownloadProgress) -> Void
    ) async throws -> any LoadedLLMContainer {
        try recordLoad(of: ref)
        return try await stub.loadLLM(ref: ref, slot: slot, context: context, reporting: reporting)
    }

    func loadEmbedder(
        ref: ModelRef,
        slot: ModelSlot,
        reporting: @escaping @Sendable (DownloadProgress) -> Void
    ) async throws -> any LoadedEmbeddingContainer {
        try recordLoad(of: ref)
        return try await stub.loadEmbedder(ref: ref, slot: slot, reporting: reporting)
    }

    func preload(container: any LoadedModelContainer) async throws {
        try await stub.preload(container: container)
    }

    func configurePromptCache(memoryBudgetBytes: Int) async {
        calls.append(.budget(memoryBudgetBytes))
    }

    var promptCacheUsage: PromptCacheUsage { usage }

    /// Records the load of `ref`, and fails it when ``failsEachLoad`` is set.
    ///
    /// - Parameter ref: The model of the load.
    /// - Throws: ``DeliberateLoadFailure`` when ``failsEachLoad`` is set.
    private func recordLoad(of ref: ModelRef) throws {
        calls.append(.load(ref))
        if failsEachLoad {
            throw DeliberateLoadFailure()
        }
    }
}

/// The failure a load of ``PromptCacheBudgetTests`` throws on purpose.
private struct DeliberateLoadFailure: Error {}

/// Unit coverage of the prompt-cache memory budget (`generation-queue.md`
/// section 3): the working set less the footprint of each resident model and
/// less the bytes that are being written to disk. Inside its admission job, a
/// resolve sends the budget to its loader before each acquire, and again after
/// a failed load.
struct PromptCacheBudgetTests {
    /// The recommended working set of each test: 48 GiB.
    static let workingSet: Int64 = 48 << 30

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

    /// The recommended working set of the probe of each test router.
    static let hostWorkingSet = RouterTestFixtures.stubProbe.recommendedMaxWorkingSetSize

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

    // MARK: - A resolve sends the budget

    @Test("a resolve shrinks the budget before the load of each new model")
    func resolveShrinksTheBudgetBeforeEachLoad() async throws {
        let loader = PromptCacheRecordingLoader()
        let (profile, _) = try await Self.resolve(with: loader, on: ModelPool())
        let generation = ResidencyFixtures.generationModelFootprint
        let embedding = ResidencyFixtures.embeddingModelFootprint

        #expect(
            await loader.calls == [
                .budget(Int(Self.hostWorkingSet - generation)),
                .load(profile.standard.chosen),
                .budget(Int(Self.hostWorkingSet - 2 * generation)),
                .load(profile.flash.chosen),
                .budget(Int(Self.hostWorkingSet - 2 * generation - embedding)),
                .load(profile.embedding.chosen),
            ])
    }

    @Test("a load that fails gives the budget back")
    func failedLoadGivesTheBudgetBack() async throws {
        let loader = PromptCacheRecordingLoader(failsEachLoad: true)
        let pool = ModelPool()

        await #expect(throws: DeliberateLoadFailure.self) {
            _ = try await Self.resolve(with: loader, on: pool)
        }
        #expect(
            await loader.memoryBudgets == [
                Int(Self.hostWorkingSet - ResidencyFixtures.generationModelFootprint), Int(Self.hostWorkingSet),
            ])
        #expect(pool.residentModelCount == 0)
    }

    @Test("a resolve that reuses resident models sends the budget with the session of each new hold")
    func reuseSendsTheBudgetWithEachNewHold() async throws {
        let loader = PromptCacheRecordingLoader()
        let pool = ModelPool()
        let (first, _) = try await Self.resolve(with: loader, on: pool)
        let residentBeforeReuse = pool.footprint.totalBytes
        let loadsBeforeReuse = await loader.calls.count

        let (second, _) = try await Self.resolve(with: loader, on: pool)

        // No load, and one budget for each slot. The two generation holds
        // each add one session KV cache; the embedding hold adds nothing.
        let sessions = ResidencyFixtures.sessionKVBytes
        let reuseCalls = await Array(loader.calls.dropFirst(loadsBeforeReuse))
        #expect(
            reuseCalls == [
                .budget(Int(Self.hostWorkingSet - residentBeforeReuse - sessions)),
                .budget(Int(Self.hostWorkingSet - residentBeforeReuse - 2 * sessions)),
                .budget(Int(Self.hostWorkingSet - residentBeforeReuse - 2 * sessions)),
            ])
        withExtendedLifetime((first, second)) {}
    }

    @Test("a resolve holds the spilling bytes out of the budget it sends")
    func resolveHoldsOutTheSpillingBytes() async throws {
        let usage = PromptCacheUsage(
            memoryBytes: Self.memoryBytes, spillingBytes: Self.spillingBytes, diskBytes: Self.diskBytes)
        let loader = PromptCacheRecordingLoader(usage: usage)
        let pool = ModelPool()

        let (profile, _) = try await Self.resolve(with: loader, on: pool)

        let expected = Int(Self.hostWorkingSet - pool.footprint.totalBytes) - Self.spillingBytes
        #expect(await loader.memoryBudgets.last == expected)
        withExtendedLifetime(profile) {}
    }

    @Test("the last budget of a resolve is the working set less the resident footprint")
    func lastBudgetIsTheWorkingSetLessTheResidentFootprint() async throws {
        let loader = PromptCacheRecordingLoader()
        let pool = ModelPool()

        let (profile, _) = try await Self.resolve(with: loader, on: pool)

        #expect(pool.footprint.totalBytes > 0)
        #expect(await loader.memoryBudgets.last == Int(Self.hostWorkingSet - pool.footprint.totalBytes))
        withExtendedLifetime(profile) {}
    }

    // MARK: - Helpers

    /// Resolves the standard test profile through a router over `loader` and
    /// `pool`.
    ///
    /// - Parameters:
    ///   - loader: The loader of the router.
    ///   - pool: The pool of the router.
    /// - Returns: The profile, beside the router that resolved it.
    /// - Throws: What the resolve throws.
    private static func resolve(
        with loader: PromptCacheRecordingLoader, on pool: ModelPool
    ) async throws -> (LanguageModelProfile, Router) {
        let cacheDir = RouterTestFixtures.makeTempDir(prefix: "PromptCacheBudgetTests")
        defer { try? FileManager.default.removeItem(at: cacheDir) }
        let router = RouterTestFixtures.makeRouter(cacheDir: cacheDir, loader: loader, pool: pool)
        let profile = try await router.resolve(profile: RouterTestFixtures.profile(), reporting: ResolutionProgress())
        return (profile, router)
    }
}
