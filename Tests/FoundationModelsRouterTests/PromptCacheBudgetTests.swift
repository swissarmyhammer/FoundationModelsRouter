import Foundation
import FoundationModelsExtras
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
        for (id, waiter) in budgetWaiters where waiter.budget == memoryBudgetBytes {
            resumeWaiter(id)
        }
    }

    var promptCacheUsage: PromptCacheUsage { usage }

    /// One caller of ``waitUntilLatestBudget(is:)`` that waits for its budget.
    private struct BudgetWaiter {
        /// The budget the caller waits for.
        let budget: Int

        /// Resumes the caller.
        let continuation: CheckedContinuation<Void, Never>
    }

    /// The callers that wait for a budget, by the number of their wait.
    private var budgetWaiters: [Int: BudgetWaiter] = [:]

    /// The number of the last wait.
    private var lastWaiterID = 0

    /// Returns when the latest budget this loader got is `budget`: at once
    /// when it is already the latest, else when the router sends it. A
    /// cancelled caller returns at once, so the time limit of a test stops
    /// the wait.
    ///
    /// - Parameter budget: The budget to wait for.
    func waitUntilLatestBudget(is budget: Int) async {
        if memoryBudgets.last == budget { return }
        lastWaiterID += 1
        let id = lastWaiterID
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume()
                } else {
                    budgetWaiters[id] = BudgetWaiter(budget: budget, continuation: continuation)
                }
            }
        } onCancel: {
            Task { await self.resumeWaiter(id) }
        }
    }

    /// Resumes the wait `id`, when it still waits.
    ///
    /// - Parameter id: The number of the wait.
    private func resumeWaiter(_ id: Int) {
        budgetWaiters.removeValue(forKey: id)?.continuation.resume()
    }

    /// The last budget this loader got before the load of `ref`.
    ///
    /// - Parameter ref: The model of the load.
    /// - Returns: The budget, or `nil` when no load of `ref` or no budget
    ///   before it was recorded.
    func budgetBeforeLoad(of ref: ModelRef) -> Int? {
        guard let loadIndex = calls.firstIndex(of: .load(ref)) else { return nil }
        return calls[..<loadIndex].reversed().lazy.compactMap { call -> Int? in
            guard case .budget(let budget) = call else { return nil }
            return budget
        }.first
    }

    /// Each budget after the first `skippedCount` budgets, with a budget that
    /// repeats the one before it left out.
    ///
    /// - Parameter skippedCount: The count of the first budgets to leave out.
    /// - Returns: The budgets, in the order they were sent.
    func distinctBudgets(after skippedCount: Int = 0) -> [Int] {
        memoryBudgets.dropFirst(skippedCount).reduce(into: []) { distinct, budget in
            if distinct.last != budget { distinct.append(budget) }
        }
    }

    /// The model of each load, in the order the loads started.
    var loadedRefs: [ModelRef] {
        calls.compactMap { call in
            guard case .load(let ref) = call else { return nil }
            return ref
        }
    }

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
/// each acquire. The footprints task of each router sends the budget for each
/// change of the pool that another caller makes: a load, a release, an
/// eviction.
///
/// Each wait of this suite is on a real signal: a budget that the loader gets,
/// or a load that starts. The time limit only stops a test that hangs.
@Suite(.timeLimit(.minutes(1)))
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

    @Test("a resolve sends the budget of each new model before the loader's load of that model")
    func resolveShrinksTheBudgetBeforeEachLoad() async throws {
        let loader = PromptCacheRecordingLoader()
        let (profile, _) = try await Self.resolve(with: loader, on: ModelPool())
        let generation = ResidencyFixtures.generationModelFootprint
        let embedding = ResidencyFixtures.embeddingModelFootprint

        #expect(
            await loader.budgetBeforeLoad(of: profile.standard.chosen) == Int(Self.hostWorkingSet - generation))
        #expect(
            await loader.budgetBeforeLoad(of: profile.flash.chosen) == Int(Self.hostWorkingSet - 2 * generation))
        #expect(
            await loader.budgetBeforeLoad(of: profile.embedding.chosen)
                == Int(Self.hostWorkingSet - 2 * generation - embedding))
    }

    @Test("a load that fails gives the budget back")
    func failedLoadGivesTheBudgetBack() async throws {
        let loader = PromptCacheRecordingLoader(failsEachLoad: true)
        let pool = ModelPool()

        await #expect(throws: DeliberateLoadFailure.self) {
            _ = try await Self.resolve(with: loader, on: pool)
        }
        let loadBudget = Int(Self.hostWorkingSet - ResidencyFixtures.generationModelFootprint)
        #expect(await loader.distinctBudgets().suffix(2) == [loadBudget, Int(Self.hostWorkingSet)])
        #expect(pool.residentModelCount == 0)
    }

    @Test("a resolve that reuses resident models sends the budget with the session of each new hold")
    func reuseSendsTheBudgetWithEachNewHold() async throws {
        let loader = PromptCacheRecordingLoader()
        let pool = ModelPool()
        let (first, _) = try await Self.resolve(with: loader, on: pool)
        let residentBeforeReuse = pool.footprint.totalBytes
        let budgetsBeforeReuse = await loader.memoryBudgets.count
        let loadsBeforeReuse = await loader.loadedRefs

        let (second, _) = try await Self.resolve(with: loader, on: pool)

        // No load, and one new budget for each generation hold: each adds one
        // session KV cache. The embedding hold adds nothing. A budget of the
        // footprint before the reuse can come first, from the footprints
        // stream of the first resolve.
        let sessions = ResidencyFixtures.sessionKVBytes
        let budgetBeforeReuse = Int(Self.hostWorkingSet - residentBeforeReuse)
        let reuseBudgets = await loader.distinctBudgets(after: budgetsBeforeReuse).drop { $0 == budgetBeforeReuse }
        #expect(
            Array(reuseBudgets) == [
                Int(Self.hostWorkingSet - residentBeforeReuse - sessions),
                Int(Self.hostWorkingSet - residentBeforeReuse - 2 * sessions),
            ])
        #expect(await loader.loadedRefs == loadsBeforeReuse)
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

    // MARK: - The footprints stream sends the budget

    @Test("a load that a different caller starts resizes the prompt cache of the router while it loads")
    func loadByAnotherCallerResizesTheRouter() async throws {
        let loader = PromptCacheRecordingLoader()
        let pool = ModelPool()
        let cacheDir = RouterTestFixtures.makeTempDir(prefix: "PromptCacheBudgetTests")
        defer { try? FileManager.default.removeItem(at: cacheDir) }
        let router = RouterTestFixtures.makeRouter(cacheDir: cacheDir, loader: loader, pool: pool)
        let directLoader = GatedPooledLoader()
        let releaseHold = AsyncSemaphore(value: 0)

        // The task keeps the hold of the direct caller until the test opens
        // `releaseHold`. Then the hold goes, and the model is evicted.
        let direct = Task {
            let hold = try await pool.acquire(
                Self.directKey, footprintBytes: Self.directFootprintBytes, sessionBytes: 0, loader: directLoader)
            await releaseHold.wait()
            return hold.key
        }
        // The load of the direct caller runs now, and waits for the gate.
        await directLoader.loadStarted.wait()
        await loader.waitUntilLatestBudget(is: Int(Self.hostWorkingSet - Self.directFootprintBytes))
        #expect(pool.footprint.loadingBytes == Self.directFootprintBytes)

        directLoader.loadGate.signal()
        releaseHold.signal()
        #expect(try await direct.value == Self.directKey)

        // The release, and then the eviction, send the whole working set again.
        await loader.waitUntilLatestBudget(is: Int(Self.hostWorkingSet))
        #expect(await loader.loadedRefs.isEmpty)
        withExtendedLifetime(router) {}
    }

    @Test("two routers on one pool each resize the prompt cache of their own loader")
    func twoRoutersEachResizeTheirOwnLoader() async throws {
        let pool = ModelPool()
        let resolvingLoader = PromptCacheRecordingLoader()
        let watchingLoader = PromptCacheRecordingLoader()
        let cacheDir = RouterTestFixtures.makeTempDir(prefix: "PromptCacheBudgetTests")
        defer { try? FileManager.default.removeItem(at: cacheDir) }
        let watchingRouter = RouterTestFixtures.makeRouter(cacheDir: cacheDir, loader: watchingLoader, pool: pool)

        let (profile, _) = try await Self.resolve(with: resolvingLoader, on: pool)

        let residentBudget = Int(Self.hostWorkingSet - pool.footprint.totalBytes)
        await watchingLoader.waitUntilLatestBudget(is: residentBudget)
        await resolvingLoader.waitUntilLatestBudget(is: residentBudget)
        #expect(await watchingLoader.loadedRefs.isEmpty)
        #expect(await resolvingLoader.loadedRefs.count == ResidencyFixtures.modelsPerTrio)
        withExtendedLifetime((profile, watchingRouter)) {}
    }

    @Test("the footprints task of a router ends when the router is released")
    func footprintsTaskEndsWithTheRouter() async throws {
        let loader = PromptCacheRecordingLoader()
        let cacheDir = RouterTestFixtures.makeTempDir(prefix: "PromptCacheBudgetTests")
        defer { try? FileManager.default.removeItem(at: cacheDir) }
        var router: Router? = RouterTestFixtures.makeRouter(cacheDir: cacheDir, loader: loader, pool: ModelPool())
        let footprintsTask = try #require(router).promptCacheSizing.footprintsTask
        // The first value of the stream is the empty pool.
        await loader.waitUntilLatestBudget(is: Int(Self.hostWorkingSet))

        router = nil

        await footprintsTask.value
        #expect(footprintsTask.isCancelled)
    }

    // MARK: - Helpers

    /// The key that a direct caller loads.
    private static let directKey = ModelPoolKey(ref: "org/prompt-cache-direct", role: .embedding)

    /// The weights of the model that a direct caller loads: 4 GiB.
    private static let directFootprintBytes: Int64 = 4 << 30

    /// A loader that is not the router's, as the registry or the multitool
    /// gives one. Its load signals ``loadStarted`` and then waits for
    /// ``loadGate``.
    private final class GatedPooledLoader: PooledModelLoader {
        /// Signalled when a load starts.
        let loadStarted = AsyncSemaphore(value: 0)

        /// Awaited before a load returns.
        let loadGate = AsyncSemaphore(value: 0)

        func load(_ key: ModelPoolKey) async throws -> any Sendable {
            loadStarted.signal()
            await loadGate.wait()
            return StubEmbeddingContainer(dimension: RouterTestFixtures.stubDimension)
        }

        func evict(_ container: any Sendable) async {}
    }

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
