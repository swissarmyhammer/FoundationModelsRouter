import Foundation
import FoundationModelsRouterTestSupport
import Synchronization
import Testing

@testable import FoundationModelsExtras
@testable import FoundationModelsRouter

/// Pins that all users of one model share ONE work queue, and that the entry
/// of the model in the Extras ``ModelPool`` owns it (``ModelHold/queue``). No
/// router type makes a ``GenerationQueue``: each session backend of a routed
/// handle names the queue of the pool entry, and each embed call of a
/// ``RoutedEmbedder`` waits in the queue of the embedding model.
///
/// Each test waits on real signals (a latch, a semaphore, the count of the
/// waiting jobs of the queue), never on the clock. No network, no GPU.
@Suite("The work queue of the pool entry")
struct PoolEntryQueueTests {
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
            return texts.map { _ in [Float](repeating: PoolEntryQueueTests.vectorElement, count: dimension) }
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

    @Test("sessions of two routers on one model use the queue of the pool entry, one call at a time, in FIFO order")
    @MainActor
    func sessionsOfTwoRoutersShareTheEntryQueueInOrder() async throws {
        let dir = RouterTestFixtures.makeTempDir(prefix: "PoolEntryQueueTests")
        defer { try? FileManager.default.removeItem(at: dir) }
        let pool = ModelPool()
        let fixture = PassObservingFixture()
        let trio = Self.uniqueTrio(named: "generation")
        let first = ResidencyFixtures.makeRouter(
            spy: LoadSpy(), recommendedMaxWorkingSetSize: Self.ampleBudget, cacheDir: dir, pool: pool,
            llmContainer: { _ in fixture.makeContainer() })
        let second = ResidencyFixtures.makeRouter(
            spy: LoadSpy(), recommendedMaxWorkingSetSize: Self.ampleBudget, cacheDir: dir, pool: pool,
            llmContainer: { _ in fixture.makeContainer() })
        let fromFirst = try await first.resolve(profile: trio, reporting: ResolutionProgress())
        let fromSecond = try await second.resolve(profile: trio, reporting: ResolutionProgress())

        // The queue of the pool entry of the standard model.
        let standardKey = ModelPoolKey(ref: try #require(trio.standard.first), role: .llm)
        let hold = try await Self.residentHold(of: standardKey, in: pool)
        let queue = hold.queue
        #expect(fromFirst.standard.backendQueue === queue)
        #expect(fromSecond.standard.backendQueue === queue)

        // The first call holds the model. The next two wait in the one queue,
        // in the order they are submitted.
        let sessions = [fromFirst, fromSecond, fromFirst].map { $0.standard.makeSession() }
        var answers: [Task<String, any Error>] = []
        for (index, session) in sessions.enumerated() {
            let prompt = Self.prompts[index]
            answers.append(Task { try await session.respond(to: prompt) })
            #expect(
                await BoundedWait.conditionReached("call \(index) is in the model or waits in the queue") {
                    let entered = await fixture.observer.enteredCount
                    let waiting = await queue.waitingCount
                    return entered == 1 && waiting == index
                })
        }
        #expect(await fixture.observer.maximumActive == 1)

        await fixture.latch.open()
        for (index, answer) in answers.enumerated() {
            #expect(try await answer.value == PassObservingModel.answer(to: Self.prompts[index]))
        }
        #expect(fixture.passes.recorded.map(\.prompt) == Self.prompts)
        #expect(await fixture.observer.maximumActive == 1)
        #expect(await queue.isRunning == false)
        withExtendedLifetime((first, second, fromFirst, fromSecond, hold)) {}
    }

    // MARK: - Embedding

    @Test("a router embed call and a direct Extras embedder of one key share one load and one queue")
    @MainActor
    func routerEmbedAndDirectEmbedderShareTheEntryQueue() async throws {
        let dir = RouterTestFixtures.makeTempDir(prefix: "PoolEntryQueueTests")
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

        // The direct call holds the model. The router call waits in the queue
        // of the pool entry, so it never enters the model at the same time.
        let directEmbedder = try PooledEmbedder(hold: directHold)
        let directCall = Task { try await directEmbedder.embed(texts: Self.texts) }
        await directLoader.embedding.entered.wait()
        let routerCall = Task { try await profile.embedding.embed(texts: Self.texts) }
        #expect(
            await BoundedWait.conditionReached("the router embed call waits in the queue of the pool entry") {
                await directHold.queue.waitingCount == 1
            })

        directLoader.embedding.gate.signal()
        directLoader.embedding.gate.signal()
        let expected = [[Float](repeating: Self.vectorElement, count: RouterTestFixtures.stubDimension)]
        #expect(try await directCall.value == expected)
        #expect(try await routerCall.value == expected)
        #expect(directLoader.embedding.peakActiveCalls == 1)
        #expect(await directHold.queue.isRunning == false)
        withExtendedLifetime((router, profile)) {}
    }
}
