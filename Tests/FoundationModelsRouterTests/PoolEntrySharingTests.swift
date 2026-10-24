import Foundation
import FoundationModelsRouterTestSupport
import Synchronization
import Testing

@testable import FoundationModelsExtras
@testable import FoundationModelsRouter

/// Pins that all users of one model share ONE load of the entry of the model
/// in the Extras ``ModelPool``, and that the router puts no queue around a
/// call (task ^qhgfajc). The generations of all users of one model take the
/// FIFO lock of that model one at a time, as the lock of an MLX model does,
/// and each embed call of a ``RoutedEmbedder`` goes to the embedding model
/// directly.
///
/// Each test waits on real signals (a latch, a semaphore, a pass that waits
/// for the lock of the model), never on the clock, inside the limit of a
/// ``BoundedWait``. No network, no GPU.
@Suite("The entry of a model in the pool: one load, and no queue of the router")
struct PoolEntrySharingTests {
    // MARK: - Fixed values

    /// A host budget that fits every profile of this suite many times.
    private static let ampleBudget: Int64 = RouterTestFixtures.stubProbe.recommendedMaxWorkingSetSize

    /// The prompts of the three model calls, in the order they are submitted.
    private static let prompts = ["first", "second", "third"]

    /// The texts of each embed call.
    private static let texts = ["one text"]

    /// The value of each element of the vectors of the gated embedding model.
    private static let vectorElement: Float = 0.25

    // MARK: - Stubs

    /// A loader for a key that is resident already. The pool never calls it,
    /// so a call is a test failure.
    private struct ResidentKeyLoader: PooledModelLoader {
        /// Records a failure: the key of the acquire must be resident.
        ///
        /// - Parameter key: The key that the pool asked to load.
        /// - Returns: Never returns.
        /// - Throws: `CancellationError`, always.
        func load(_ key: ModelPoolKey) async throws -> any Sendable {
            Issue.record("the pool loaded \(key.ref.stringValue), which must be resident")
            throw CancellationError()
        }

        /// Evicts nothing: this loader loads nothing.
        ///
        /// - Parameter container: The container to evict.
        func evict(_ container: any Sendable) async {}
    }

    /// An embedding model whose each call signals `entered` and then waits for
    /// one signal of `gate`. It counts the calls that are inside it now, and
    /// the most that were inside it at one time.
    private final class GatedEmbedding: PooledEmbedding {
        /// Signalled when a call enters the model.
        let entered = AsyncSemaphore(value: 0)

        /// Each call waits for one signal of this semaphore before it returns.
        let gate = AsyncSemaphore(value: 0)

        /// The calls inside the model now, and the most at one time.
        private let calls = Mutex((active: 0, peak: 0))

        /// The length of each vector.
        let dimension = RouterTestFixtures.stubDimension

        /// The most calls that were inside the model at one time.
        var peakActiveCalls: Int { calls.withLock { $0.peak } }

        /// Gives one constant vector for each text, after one signal of ``gate``.
        ///
        /// - Parameter texts: The texts.
        /// - Returns: One vector for each text.
        func embed(texts: [String]) async throws -> [[Float]] {
            calls.withLock { calls in
                calls.active += 1
                calls.peak = max(calls.peak, calls.active)
            }
            entered.signal()
            await gate.wait()
            calls.withLock { $0.active -= 1 }
            return texts.map { _ in [Float](repeating: PoolEntrySharingTests.vectorElement, count: dimension) }
        }
    }

    /// A loader that is not the router's: it gives one ``GatedEmbedding`` and
    /// counts its loads.
    private final class DirectEmbeddingLoader: PooledModelLoader {
        /// The model this loader gives.
        let embedding = GatedEmbedding()

        /// The count of the loads of this loader.
        let loadCount = Atomic<Int>(0)

        /// Gives ``embedding``.
        ///
        /// - Parameter key: The key of the load.
        /// - Returns: ``embedding``.
        func load(_ key: ModelPoolKey) async throws -> any Sendable {
            loadCount.add(1, ordering: .sequentiallyConsistent)
            return embedding
        }

        /// Evicts nothing: the model holds no memory.
        ///
        /// - Parameter container: The container to evict.
        func evict(_ container: any Sendable) async {}
    }

    // MARK: - Fixtures

    /// A trio of refs that no other test names.
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

    /// Takes a hold of a key that is resident in `pool`, as a caller that is
    /// not the router does.
    ///
    /// - Parameters:
    ///   - key: The resident key.
    ///   - pool: The pool.
    /// - Returns: The hold.
    /// - Throws: What the acquire throws.
    private static func residentHold(of key: ModelPoolKey, in pool: ModelPool) async throws -> ModelHold {
        try await pool.acquire(key, footprintBytes: 0, sessionBytes: 0, loader: ResidentKeyLoader())
    }

    // MARK: - Generation

    @Test("sessions of two routers on one model share one load, and take the lock of the model one generation at a time, in FIFO order")
    @MainActor
    func sessionsOfTwoRoutersShareOneLoadAndTakeTurnsInOrder() async throws {
        let dir = RouterTestFixtures.makeTempDir(prefix: "PoolEntrySharingTests")
        defer { try? FileManager.default.removeItem(at: dir) }
        let pool = ModelPool()
        let fixture = PassObservingFixture()
        let trio = Self.uniqueTrio(named: "generation")
        let firstSpy = LoadSpy()
        let secondSpy = LoadSpy()
        let first = ResidencyFixtures.makeRouter(
            spy: firstSpy, recommendedMaxWorkingSetSize: Self.ampleBudget, cacheDir: dir, pool: pool,
            llmContainer: { _ in fixture.makeContainer() })
        let second = ResidencyFixtures.makeRouter(
            spy: secondSpy, recommendedMaxWorkingSetSize: Self.ampleBudget, cacheDir: dir, pool: pool,
            llmContainer: { _ in fixture.makeContainer() })
        let fromFirst = try await first.resolve(profile: trio, reporting: ResolutionProgress())
        let fromSecond = try await second.resolve(profile: trio, reporting: ResolutionProgress())

        // One load of the standard model for both routers.
        let standard = try #require(trio.standard.first)
        let firstLoads = await firstSpy.llmLoads
        let secondLoads = await secondSpy.llmLoads
        let standardLoads = (firstLoads + secondLoads).filter { $0 == standard }
        #expect(standardLoads.count == 1)

        // The first call holds the lock of the model. The next two wait for
        // that lock, in the order they came. Each wait also ends when its
        // answer ended (rule T1): the latch holds the first answer in the
        // model and the next passes in the lock, so in a test that passes no
        // answer ends first.
        let sessions = [fromFirst, fromSecond, fromFirst].map { $0.standard.makeSession() }
        // The latch opens before the closes, also when the test throws (rule
        // T1): a close waits for the held pass.
        defer { await SessionFixtureLifecycle.close(sessions, opening: [fixture.latch]) }
        var answers: [Task<String, any Error>] = []
        for (index, session) in sessions.enumerated() {
            let prompt = Self.prompts[index]
            let answer = Task { try await session.respond(to: prompt) }
            answers.append(answer)
            if index == 0 {
                try await BoundedWait.run {
                    try await RecordedWaitResult.wait(
                        for: { try await fixture.observer.waitUntil { $0.entered == 1 } }, endingOnEndOf: answer)
                }
            } else {
                try await BoundedWait.run { try await fixture.lock.waitForWaiters(index) }
            }
            #expect(await fixture.observer.enteredCount == 1)
            #expect(await fixture.lock.waitingCount == index)
        }
        #expect(await fixture.observer.maximumActive == 1)

        await fixture.latch.open()
        for (index, answer) in answers.enumerated() {
            #expect(try await BoundedWait.value(of: answer) == PassObservingModel.answer(to: Self.prompts[index]))
        }
        #expect(fixture.passes.recorded.map(\.prompt) == Self.prompts)
        #expect(await fixture.observer.maximumActive == 1)
        withExtendedLifetime((first, second, fromFirst, fromSecond)) {}
    }

    // MARK: - Embedding

    @Test("a router embed call and a direct Extras embedder of one key share one load, and the router adds no queue")
    @MainActor
    func routerEmbedAndDirectEmbedderShareOneLoad() async throws {
        let dir = RouterTestFixtures.makeTempDir(prefix: "PoolEntrySharingTests")
        defer { try? FileManager.default.removeItem(at: dir) }
        let pool = ModelPool()
        let spy = LoadSpy()
        let router = ResidencyFixtures.makeRouter(
            spy: spy, recommendedMaxWorkingSetSize: Self.ampleBudget, cacheDir: dir, pool: pool)
        let trio = Self.uniqueTrio(named: "embedding")
        let embeddingKey = ModelPoolKey(ref: try #require(trio.embedding.first), role: .embedding)
        let directLoader = DirectEmbeddingLoader()

        // The direct caller loads the model first; the router takes a hold of
        // that container. One load in all.
        let directHold = try await pool.acquire(
            embeddingKey, footprintBytes: ResidencyFixtures.embeddingModelFootprint, sessionBytes: 0,
            loader: directLoader)
        let profile = try await router.resolve(profile: trio, reporting: ResolutionProgress())
        #expect(directLoader.loadCount.load(ordering: .sequentiallyConsistent) == 1)
        #expect(await spy.embedderLoads.isEmpty)

        // The direct call is in the model. The router call goes to the model
        // directly: the router puts no queue around it, and the model
        // serializes its own calls. Each wait also ends when its call ended
        // (rule T1): the gate holds each call in the model, so in a test that
        // passes no call ends first.
        let directEmbedder = try PooledEmbedder(hold: directHold)
        let directCall = Task { try await directEmbedder.embed(texts: Self.texts) }
        let entered = directLoader.embedding.entered
        try await BoundedWait.run { try await RecordedWaitResult.wait(forPermitOf: entered, endingOnEndOf: directCall) }
        let routerCall = Task { try await profile.embedding.embed(texts: Self.texts) }
        try await BoundedWait.run { try await RecordedWaitResult.wait(forPermitOf: entered, endingOnEndOf: routerCall) }

        directLoader.embedding.gate.signal()
        directLoader.embedding.gate.signal()
        let expected = [[Float](repeating: Self.vectorElement, count: RouterTestFixtures.stubDimension)]
        #expect(try await BoundedWait.value(of: directCall) == expected)
        #expect(try await BoundedWait.value(of: routerCall) == expected)
        #expect(directLoader.embedding.peakActiveCalls == 2)
        withExtendedLifetime((router, profile, directHold)) {}
    }
}
