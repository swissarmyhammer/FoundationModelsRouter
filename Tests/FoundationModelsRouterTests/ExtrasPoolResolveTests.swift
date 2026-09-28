import Foundation
import FoundationModelsRouterTestSupport
import Synchronization
import Testing

@testable import FoundationModelsExtras
@testable import FoundationModelsRouter

/// Pins how ``Router/resolve(profile:reporting:)`` uses the Extras
/// ``ModelPool``: a whole resolve (the measurement, the joint fit and each
/// acquire) is one admission job, so a caller that is not the router (the
/// registry, the multitool) shares the models of the router and cannot load
/// between the measurement and the acquire of the router. No network, no GPU.
@Suite("Router resolve in the Extras model pool")
struct ExtrasPoolResolveTests {
    // MARK: - Fixed values

    /// The weights of the model that a direct caller loads. The pool only
    /// counts them.
    private static let directFootprintBytes: Int64 = 1_000

    /// A host budget that fits every profile of this suite many times.
    private static let ampleBudget: Int64 = RouterTestFixtures.stubProbe.recommendedMaxWorkingSetSize

    // MARK: - Stubs

    /// The loads of the router and of a direct caller, in the order they start.
    private final class LoadLog: Sendable {
        /// One load: which loader ran it, the model, and the keys that were
        /// resident when it started.
        struct Entry: Sendable {
            /// The loader that ran the load: the router's, or the direct caller's.
            let byRouter: Bool

            /// The model of the load.
            let ref: ModelRef

            /// The keys that were resident in the pool when the load started.
            let residentKeys: Set<ModelPoolKey>
        }

        /// The entries, under one lock.
        private let entries = Mutex<[Entry]>([])

        /// The entries in the order the loads started.
        var loads: [Entry] { entries.withLock { $0 } }

        /// Keeps one load.
        ///
        /// - Parameter entry: The load.
        func record(_ entry: Entry) { entries.withLock { $0.append(entry) } }
    }

    /// The router's loader: it writes each load into a ``LoadLog`` with the
    /// keys resident in `pool` at that time. The load of `gatedRef` signals
    /// `entrySignal` and then waits for `releaseGate`.
    private struct LoggingModelLoader: ModelLoader {
        /// The log of every load.
        let log: LoadLog

        /// The pool the router resolves into.
        let pool: ModelPool

        /// The model whose load waits for `releaseGate`.
        let gatedRef: ModelRef

        /// Signalled when the load of `gatedRef` starts.
        let entrySignal: AsyncSemaphore

        /// Awaited before the load of `gatedRef` returns.
        let releaseGate: AsyncSemaphore

        func loadLLM(
            ref: ModelRef, slot: ModelSlot, context: Int,
            reporting: @escaping @Sendable (DownloadProgress) -> Void
        ) async throws -> any LoadedLLMContainer {
            await record(ref)
            return CannedLLMContainer(ref: ref)
        }

        func loadEmbedder(
            ref: ModelRef, slot: ModelSlot,
            reporting: @escaping @Sendable (DownloadProgress) -> Void
        ) async throws -> any LoadedEmbeddingContainer {
            await record(ref)
            return StubEmbeddingContainer(dimension: RouterTestFixtures.stubDimension)
        }

        func preload(container: any LoadedModelContainer) async throws {}

        /// Writes the load of `ref` into the log, and holds the load of
        /// ``gatedRef`` until the test opens the gate.
        ///
        /// - Parameter ref: The model of the load.
        private func record(_ ref: ModelRef) async {
            log.record(.init(byRouter: true, ref: ref, residentKeys: Set(pool.footprint.resident.keys)))
            guard ref == gatedRef else { return }
            entrySignal.signal()
            await releaseGate.wait()
        }
    }

    /// A loader that is not the router's, as the registry or the multitool
    /// gives one. It counts its loads and writes each one into `log`.
    private final class DirectLoader: PooledModelLoader {
        /// The log of every load, or `nil` when the test reads only the count.
        private let log: LoadLog?

        /// The count of the loads of this loader.
        let loadCount = Atomic<Int>(0)

        /// Makes a loader that writes each load into `log`.
        ///
        /// - Parameter log: The log, or `nil` when the test reads only the count.
        init(log: LoadLog?) {
            self.log = log
        }

        func load(_ key: ModelPoolKey) async throws -> any Sendable {
            loadCount.add(1, ordering: .sequentiallyConsistent)
            log?.record(.init(byRouter: false, ref: key.ref, residentKeys: []))
            return StubEmbeddingContainer(dimension: RouterTestFixtures.stubDimension)
        }

        func evict(_ container: any Sendable) async {}
    }

    // MARK: - Fixtures

    /// A trio of refs that no other test names, so a test can use the pool
    /// of the process without a clash with another suite.
    ///
    /// - Parameter name: The name of the profile.
    /// - Returns: The profile.
    private static func uniqueTrio(named name: String) -> ProfileDefinition {
        let prefix = "org/\(name)-\(ULID.generate())"
        return ProfileDefinition(
            name: name, description: "refs that no other test names",
            standard: [ModelRef("\(prefix)-std")], flash: [ModelRef("\(prefix)-flash")],
            embedding: [ModelRef("\(prefix)-emb")]
        )
    }

    /// Every pool key of `profile`, one for each slot.
    ///
    /// - Parameter profile: The profile.
    /// - Returns: The keys.
    private static func keys(of profile: ProfileDefinition) -> Set<ModelPoolKey> {
        let generation = (profile.standard + profile.flash).map { ModelPoolKey(ref: $0, role: .llm) }
        return Set(generation + profile.embedding.map { ModelPoolKey(ref: $0, role: .embedding) })
    }

    // MARK: - The pool of the process

    @Test("two routers on the pool of the process that resolve the same models load each model one time")
    @MainActor
    func twoRoutersOnTheSharedPoolLoadOnce() async throws {
        let dir = RouterTestFixtures.makeTempDir(prefix: "ExtrasPoolResolveTests")
        defer { try? FileManager.default.removeItem(at: dir) }
        let trio = Self.uniqueTrio(named: "shared-pool")
        let firstSpy = LoadSpy()
        let secondSpy = LoadSpy()
        let first = ResidencyFixtures.makeRouter(
            spy: firstSpy, recommendedMaxWorkingSetSize: Self.ampleBudget, cacheDir: dir, pool: .shared)
        let second = ResidencyFixtures.makeRouter(
            spy: secondSpy, recommendedMaxWorkingSetSize: Self.ampleBudget, cacheDir: dir, pool: .shared)

        var fromFirst: LanguageModelProfile? = try await first.resolve(profile: trio, reporting: ResolutionProgress())
        var fromSecond: LanguageModelProfile? = try await second.resolve(profile: trio, reporting: ResolutionProgress())

        #expect(await firstSpy.llmLoads.count == ResidencyFixtures.modelsPerTrio - 1)
        #expect(await firstSpy.embedderLoads.count == 1)
        #expect(await secondSpy.llmLoads.isEmpty)
        #expect(await secondSpy.embedderLoads.isEmpty)
        #expect(try #require(fromFirst).standard.chosen == trio.standard.first)

        // Give the models back, so that the pool of the process keeps nothing
        // of this test.
        fromFirst.dropReference()
        fromSecond.dropReference()
        let keys = Self.keys(of: trio)
        #expect(try await ModelPool.shared.admittedFootprint.resident.keys.allSatisfy { !keys.contains($0) })
        #expect(await firstSpy.evictions == ResidencyFixtures.modelsPerTrio)
    }

    // MARK: - A caller that is not the router

    @Test("a router and a direct acquire of one key load it one time, and it stays resident until both release it")
    @MainActor
    func routerAndDirectCallerShareOneLoad() async throws {
        let dir = RouterTestFixtures.makeTempDir(prefix: "ExtrasPoolResolveTests")
        defer { try? FileManager.default.removeItem(at: dir) }
        let pool = ModelPool()
        let spy = LoadSpy()
        let router = ResidencyFixtures.makeRouter(
            spy: spy, recommendedMaxWorkingSetSize: Self.ampleBudget, cacheDir: dir, pool: pool)
        let trio = Self.uniqueTrio(named: "direct")
        let embeddingKey = ModelPoolKey(ref: try #require(trio.embedding.first), role: .embedding)
        let directLoader = DirectLoader(log: nil)

        var directHold: ModelHold? = try await pool.acquire(
            embeddingKey, footprintBytes: Self.directFootprintBytes, sessionBytes: 0, loader: directLoader)
        var profile: LanguageModelProfile? = try await router.resolve(profile: trio, reporting: ResolutionProgress())

        // One load of the key in all: the direct caller loaded it first, and
        // the router took a hold of that container.
        #expect(directLoader.loadCount.load(ordering: .sequentiallyConsistent) == 1)
        #expect(await spy.embedderLoads.isEmpty)

        // The router releases first: the direct hold keeps the model.
        profile.dropReference()
        #expect(try await pool.admittedFootprint.resident.count == 1)
        #expect(pool.isResident(embeddingKey))

        // The last release evicts the model.
        directHold = nil
        #expect(try await pool.admittedFootprint.resident.isEmpty)
        #expect(!pool.isResident(embeddingKey))
        #expect(directHold == nil)
    }

    @Test("a direct acquire of a new key during a resolve loads only after the admission job of the router ends")
    @MainActor
    func directLoadWaitsForTheAdmissionJobOfTheRouter() async throws {
        let dir = RouterTestFixtures.makeTempDir(prefix: "ExtrasPoolResolveTests")
        defer { try? FileManager.default.removeItem(at: dir) }
        let pool = ModelPool()
        let log = LoadLog()
        let trio = Self.uniqueTrio(named: "admission")
        let entrySignal = AsyncSemaphore(value: 0)
        let releaseGate = AsyncSemaphore(value: 0)
        let router = RouterTestFixtures.makeRouter(
            cacheDir: dir,
            loader: LoggingModelLoader(
                log: log, pool: pool, gatedRef: try #require(trio.standard.first),
                entrySignal: entrySignal, releaseGate: releaseGate),
            pool: pool
        )
        let directKey = ModelPoolKey(ref: ModelRef("org/direct-\(ULID.generate())"), role: .embedding)
        let directLoader = DirectLoader(log: log)

        let resolve = Task { try await router.resolve(profile: trio, reporting: ResolutionProgress()) }
        // The admission job of the router now runs its first load.
        await entrySignal.wait()
        let direct = Task {
            try await pool.acquire(
                directKey, footprintBytes: Self.directFootprintBytes, sessionBytes: 0, loader: directLoader)
        }
        // The direct acquire waits in the admission queue behind the router.
        #expect(await BoundedWait.conditionReached("the direct acquire waits") {
            await pool.admissions.waitingCount == 1
        })
        releaseGate.signal()
        let profile = try await resolve.value
        let hold = try await direct.value

        // The three loads of the router come first, and no load of the
        // router saw the direct key: the fit of the router measured the pool
        // that its acquires found. The direct load comes last.
        let loads = log.loads
        #expect(loads.map(\.byRouter) == [true, true, true, false])
        #expect(loads.allSatisfy { !$0.residentKeys.contains(directKey) })
        #expect(loads.last?.ref == directKey.ref)
        #expect(pool.footprint.resident.keys.filter { $0 != directKey }.count == ResidencyFixtures.modelsPerTrio)
        withExtendedLifetime((profile, hold)) {}
    }
}
