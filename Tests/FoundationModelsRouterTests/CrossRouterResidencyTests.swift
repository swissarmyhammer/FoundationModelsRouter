import Foundation
import FoundationModels
import Testing

@testable import FoundationModelsRouter

/// Pins the cross-router rules of `model-pool.md` §2.7 and §3: two routers
/// over one ``ModelPool`` share, price, and evict together, and two routers
/// over two pools do not.
///
/// Each test builds two routers. Each router has its own ``LoadSpy``, so a
/// test can tell which router's loader ran. Both routers take the same probe
/// and `headroomReserve: 0`, because `hostBudget()` stays per router and a
/// budget pin across two routers holds only when both price against one
/// machine. Everything runs against stubs: no network, no GPU.
@Suite("Cross-router residency")
struct CrossRouterResidencyTests {
    // MARK: - Fixtures

    /// Two routers built over the same simulated machine, each with its own spy.
    private struct RouterPair {
        /// The router that resolves first, and so loads every shared key.
        let first: Router

        /// The spy behind `first`'s loader.
        let firstSpy: LoadSpy

        /// The router that resolves second.
        let second: Router

        /// The spy behind `second`'s loader.
        let secondSpy: LoadSpy
    }

    /// The fork ceiling of the router that loads the key in the fork-ceiling
    /// test. The one ceiling the second router's forks must admit at.
    private static let loadingRouterForkCeiling = 1

    /// The fork ceiling of the router that reuses the key in the fork-ceiling
    /// test. Larger than ``loadingRouterForkCeiling``, so a fork admitted
    /// past the first router's ceiling would show.
    private static let reusingRouterForkCeiling = 4

    /// How many times one ref loads when two routers on two pools each load it.
    private static let loadsWithoutSharing = 2

    /// A host budget that fits one trio and a second profile's reuse charge:
    /// the second router shares the resident containers, but each of its two
    /// generation slots still pays for its own session KV cache.
    private static let oneTrioPlusReuseBudget: Int64 =
        ResidencyFixtures.oneTrioFootprint + ResidencyFixtures.reusedTrioCharge + ResidencyFixtures.headroomBufferBytes

    /// A host budget that fits exactly one trio and nothing else.
    private static let oneTrioBudget: Int64 =
        ResidencyFixtures.oneTrioFootprint + ResidencyFixtures.headroomBufferBytes

    /// The standard model of ``sharedTrio``, the one a session answers from.
    private static let sharedStandardRef: ModelRef = "org/x-std"

    /// The trio every sharing test resolves from both routers.
    private static let sharedTrio = ProfileDefinition(
        name: "shared", description: "both routers want the identical models",
        standard: [sharedStandardRef], flash: ["org/x-flash"], embedding: ["org/x-emb"]
    )

    /// Every ref ``sharedTrio`` names, one for each slot.
    private static let sharedRefs: [ModelRef] = sharedTrio.standard + sharedTrio.flash + sharedTrio.embedding

    /// A trio disjoint from ``sharedTrio``, which cannot fit beside it under
    /// ``oneTrioBudget``.
    private static let disjointTrio = ProfileDefinition(
        name: "disjoint", description: "cannot fit beside the shared trio",
        standard: ["org/x-other-std"], flash: ["org/x-other-flash"], embedding: ["org/x-other-emb"]
    )

    private static func makeTempDir() -> URL {
        RouterTestFixtures.makeTempDir(prefix: "CrossRouterResidencyTests")
    }

    /// Builds two routers over one simulated machine, each with its own spy.
    ///
    /// - Parameters:
    ///   - recommendedMaxWorkingSetSize: The host budget both routers price against.
    ///   - cacheDir: The cache directory both routers share.
    ///   - firstPool: The first router's pool.
    ///   - secondPool: The second router's pool. Defaults to `firstPool`, so
    ///     the two routers share residents unless a test passes a second pool.
    ///   - firstForkCeiling: The first router's `maxConcurrentForks`.
    ///   - secondForkCeiling: The second router's `maxConcurrentForks`.
    /// - Returns: The pair.
    private static func makePair(
        recommendedMaxWorkingSetSize: Int64,
        cacheDir: URL,
        firstPool: ModelPool,
        secondPool: ModelPool? = nil,
        firstForkCeiling: Int = defaultMaxConcurrentForks,
        secondForkCeiling: Int = defaultMaxConcurrentForks
    ) -> RouterPair {
        let firstSpy = LoadSpy()
        let secondSpy = LoadSpy()
        return RouterPair(
            first: ResidencyFixtures.makeRouter(
                spy: firstSpy,
                recommendedMaxWorkingSetSize: recommendedMaxWorkingSetSize,
                cacheDir: cacheDir,
                pool: firstPool,
                maxConcurrentForks: firstForkCeiling
            ),
            firstSpy: firstSpy,
            second: ResidencyFixtures.makeRouter(
                spy: secondSpy,
                recommendedMaxWorkingSetSize: recommendedMaxWorkingSetSize,
                cacheDir: cacheDir,
                pool: secondPool ?? firstPool,
                maxConcurrentForks: secondForkCeiling
            ),
            secondSpy: secondSpy
        )
    }

    /// How many times `spy`'s loader loaded `ref` in either role.
    ///
    /// - Parameters:
    ///   - spy: The spy to read.
    ///   - ref: The ref to count.
    /// - Returns: The load count.
    private static func loads(on spy: LoadSpy, of ref: ModelRef) async -> Int {
        await spy.llmLoads.filter { $0 == ref }.count + spy.embedderLoads.filter { $0 == ref }.count
    }

    /// How many loads `spy`'s loader ran, in either role.
    ///
    /// - Parameter spy: The spy to read.
    /// - Returns: The load count.
    private static func totalLoads(on spy: LoadSpy) async -> Int {
        await spy.llmLoads.count + spy.embedderLoads.count
    }

    // MARK: - Two routers on one pool load a shared ref one time.

    @Test("two routers on one pool that resolve one profile load each ref one time, through the first router")
    @MainActor
    func twoRoutersOnOnePoolLoadASharedRefOnce() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let pair = Self.makePair(
            recommendedMaxWorkingSetSize: Self.oneTrioPlusReuseBudget, cacheDir: dir, firstPool: ModelPool()
        )

        let fromFirst = try await pair.first.resolve(profile: Self.sharedTrio, reporting: ResolutionProgress())
        let fromSecond = try await pair.second.resolve(profile: Self.sharedTrio, reporting: ResolutionProgress())

        // Every ref loaded one time, and only through the first router.
        for ref in Self.sharedRefs {
            #expect(await Self.loads(on: pair.firstSpy, of: ref) == 1)
        }
        #expect(await Self.totalLoads(on: pair.secondSpy) == 0)

        // The second router's handle is over the first router's container.
        let reply = try await fromSecond.standard.makeSession(instructions: nil).respond(to: "hi")
        #expect(reply == CannedLLMContainer.reply(for: Self.sharedStandardRef))
        withExtendedLifetime(fromFirst) {}
    }

    // MARK: - A release from one router keeps the model for the other.

    @Test("a release from the first router keeps the model resident for the second router's session")
    @MainActor
    func releaseFromOneRouterKeepsTheModelForTheOther() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let pair = Self.makePair(
            recommendedMaxWorkingSetSize: Self.oneTrioPlusReuseBudget, cacheDir: dir, firstPool: ModelPool()
        )

        let fromFirst = try await pair.first.resolve(profile: Self.sharedTrio, reporting: ResolutionProgress())
        let fromSecond = try await pair.second.resolve(profile: Self.sharedTrio, reporting: ResolutionProgress())

        await fromFirst.release()

        // Still referenced by the second router: nothing evicted anywhere.
        #expect(await pair.firstSpy.evictions == 0)
        #expect(await pair.secondSpy.evictions == 0)
        let reply = try await fromSecond.standard.makeSession(instructions: nil).respond(to: "still alive")
        #expect(reply == CannedLLMContainer.reply(for: Self.sharedStandardRef))
    }

    // MARK: - The last release evicts through the loading router's loader.

    @Test("the last release evicts every model one time, through the loader of the router that loaded it")
    @MainActor
    func lastReleaseEvictsThroughTheLoadingRoutersLoader() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let pair = Self.makePair(
            recommendedMaxWorkingSetSize: Self.oneTrioPlusReuseBudget, cacheDir: dir, firstPool: ModelPool()
        )

        let fromFirst = try await pair.first.resolve(profile: Self.sharedTrio, reporting: ResolutionProgress())
        let fromSecond = try await pair.second.resolve(profile: Self.sharedTrio, reporting: ResolutionProgress())

        // The loading router releases first, so the last release comes from
        // the router that never loaded anything.
        await fromFirst.release()
        #expect(await pair.firstSpy.evictions == 0)

        await fromSecond.release()

        // Every model evicted one time, and each eviction ran through the
        // first router's loader, never the second's.
        #expect(await pair.firstSpy.evictions == ResidencyFixtures.modelsPerTrio)
        #expect(await pair.secondSpy.evictions == 0)
    }

    // MARK: - The second router prices the first router's residents.

    @Test("a second router's resolve prices the first router's residents against the shared budget")
    @MainActor
    func secondRouterPricesTheFirstRoutersResidents() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let hostBudget = Self.oneTrioBudget
        let pair = Self.makePair(recommendedMaxWorkingSetSize: hostBudget, cacheDir: dir, firstPool: ModelPool())

        let fromFirst = try await pair.first.resolve(profile: Self.sharedTrio, reporting: ResolutionProgress())

        // The disjoint trio cannot fit beside the first router's trio, and
        // the budget the failure reports is the host budget less everything
        // the first router made resident.
        do {
            _ = try await pair.second.resolve(profile: Self.disjointTrio, reporting: ResolutionProgress())
            Issue.record("the disjoint trio must not fit beside the first router's trio")
        } catch let failure as ResolutionFailure {
            #expect(failure.budgetBytes == hostBudget - ResidencyFixtures.oneTrioFootprint)
        }

        // The failed resolve loaded nothing and evicted nothing.
        #expect(await Self.totalLoads(on: pair.secondSpy) == 0)
        #expect(await pair.firstSpy.evictions == 0)
        withExtendedLifetime(fromFirst) {}
    }

    // MARK: - Two routers on two pools do not share.

    @Test("two routers on two different pools load each ref two times")
    @MainActor
    func twoRoutersOnTwoPoolsDoNotShare() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        // Each pool holds its own trio, and each router prices only its own
        // pool, so one trio's budget is enough for both.
        let pair = Self.makePair(
            recommendedMaxWorkingSetSize: Self.oneTrioBudget,
            cacheDir: dir,
            firstPool: ModelPool(),
            secondPool: ModelPool()
        )

        let fromFirst = try await pair.first.resolve(profile: Self.sharedTrio, reporting: ResolutionProgress())
        let fromSecond = try await pair.second.resolve(profile: Self.sharedTrio, reporting: ResolutionProgress())

        // Every ref loaded one time through each router: two loads in all.
        for ref in Self.sharedRefs {
            let firstLoads = await Self.loads(on: pair.firstSpy, of: ref)
            let secondLoads = await Self.loads(on: pair.secondSpy, of: ref)
            #expect(firstLoads == 1)
            #expect(firstLoads + secondLoads == Self.loadsWithoutSharing)
        }
        withExtendedLifetime((fromFirst, fromSecond)) {}
    }

    // MARK: - The fork ceiling comes from the router that loaded the key.

    /// `model-pool.md` §2.7, "Fork ceiling: the first router wins":
    /// ``ResidentModelGates`` is minted at first load from the loading
    /// router's `maxConcurrentForks`, and a second router over the same key
    /// gets that ceiling. The suspending-fork shape is
    /// `ForkConcurrencyTests.forkAdmissionBoundsConcurrentForks`.
    @Test("a second router's forks admit at the ceiling of the router that loaded the key")
    @MainActor
    func forkCeilingComesFromTheRouterThatLoadedTheKey() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let pair = Self.makePair(
            recommendedMaxWorkingSetSize: Self.oneTrioPlusReuseBudget,
            cacheDir: dir,
            firstPool: ModelPool(),
            firstForkCeiling: Self.loadingRouterForkCeiling,
            secondForkCeiling: Self.reusingRouterForkCeiling
        )

        let fromFirst = try await pair.first.resolve(profile: Self.sharedTrio, reporting: ResolutionProgress())
        let fromSecond = try await pair.second.resolve(profile: Self.sharedTrio, reporting: ResolutionProgress())

        // One gate for one container, minted at the first router's ceiling.
        let admissionGate = fromSecond.standard.forkAdmissionGate
        #expect(admissionGate === fromFirst.standard.forkAdmissionGate)
        #expect(admissionGate.availablePermits == Self.loadingRouterForkCeiling)

        // One fork fills the first router's ceiling, well under the second's.
        let root = fromSecond.standard.makeSession()
        var firstFork: RoutedSession? = try await root.fork(workingDirectory: nil)
        #expect(firstFork?.parentId == root.id)
        #expect(admissionGate.availablePermits == 0)

        // A second fork must await a free slot. `async let` keeps the wait
        // structured: the fork is awaited below, after the slot frees.
        async let secondFork = root.fork(workingDirectory: nil)
        #expect(await BoundedWait.conditionReached("the second fork waiting on the admission gate") {
            admissionGate.waiterCount == 1
        })

        // Releasing the first fork frees its slot; the waiter is admitted.
        firstFork = nil
        let admitted = try await secondFork
        #expect(admitted.parentId == root.id)
        withExtendedLifetime((fromFirst, root)) {}
    }
}
