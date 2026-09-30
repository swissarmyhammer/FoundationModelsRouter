import Foundation
import FoundationModels
import FoundationModelsExtras
import FoundationModelsRouterTestSupport
import MLXFoundationModels
import Synchronization
import Testing

@testable import FoundationModelsRouter

/// Exercises the router side of the Extras model pool: the role of each
/// ``ModelSlot``, the loader that the router gives to the pool, and the rule
/// "the first loader of a key wins". Each test uses a private pool, so no test
/// sees the models of another test. No network, no GPU.
@Suite("Router loader in the Extras model pool")
struct SlotPoolLoaderTests {
    // MARK: - Fixed values

    /// The model that each test loads.
    private static let ref: ModelRef = "test/model"

    /// The weights of each test model. The private pool only counts them.
    private static let footprintBytes: Int64 = 1_000

    /// The session bytes of a generation hold.
    private static let sessionBytes: Int64 = 100

    /// The advisory context that the router gives with the slot.
    private static let context = 4_096

    /// The vector that the foreign embedding gives for each text.
    private static let foreignVector: [Float] = [1, 2, 3]

    // MARK: - Stubs

    /// An embedding model of a loader that is not the router's. It conforms to
    /// the Extras embed protocol only, not to ``LoadedEmbeddingContainer``.
    private struct ForeignEmbedding: PooledEmbedding {
        let dimension = SlotPoolLoaderTests.foreignVector.count
        func embed(texts: [String]) async throws -> [[Float]] {
            texts.map { _ in SlotPoolLoaderTests.foreignVector }
        }
    }

    /// A container of a loader that is not the router's, and that is no
    /// generation container.
    private struct ForeignContainer: Sendable {}

    /// A loader that is not the router's: loader A. It gives `container` for
    /// each key.
    private struct ForeignLoader: PooledModelLoader {
        let container: any Sendable
        func load(_ key: ModelPoolKey) async throws -> any Sendable { container }
        func evict(_ container: any Sendable) async {}
    }

    /// A generation container of the router's loader.
    private struct StubLLMContainer: LoadedLLMContainer {
        let tokenCounter: any TokenCounter = CharacterTokenCounter()
        func makeSession(instructions: String?) -> any LanguageModelSessionBackend {
            StubSessionBackend(shouldThrow: true)
        }
        func makeSession(transcript: Transcript) -> any LanguageModelSessionBackend {
            StubSessionBackend(shouldThrow: true)
        }
    }

    /// An embedding container of the router's loader. Its vectors differ from
    /// the vectors of ``ForeignEmbedding``.
    private struct StubEmbeddingContainer: LoadedEmbeddingContainer {
        let dimension = 1
        func embed(texts: [String]) async throws -> [[Float]] { texts.map { _ in [0] } }
    }

    /// One call that the router's loader received.
    private enum LoaderCall: Equatable {
        case loadLLM(ref: ModelRef, slot: ModelSlot, context: Int)
        case loadEmbedder(ref: ModelRef, slot: ModelSlot)
        case evict
    }

    /// The router's loader. It records each call, and sends one progress
    /// value to the `reporting` of each load.
    private final class RecordingModelLoader: ModelLoader {
        /// The progress value that each load reports.
        static let progress = DownloadProgress(bytesDownloaded: 1, bytesTotal: 2)

        private let recorded = Mutex<[LoaderCall]>([])

        /// The calls in the order they arrived.
        var calls: [LoaderCall] { recorded.withLock { $0 } }

        func loadLLM(
            ref: ModelRef, slot: ModelSlot, context: Int,
            reporting: @escaping @Sendable (DownloadProgress) -> Void
        ) async throws -> any LoadedLLMContainer {
            recorded.withLock { $0.append(.loadLLM(ref: ref, slot: slot, context: context)) }
            reporting(Self.progress)
            return StubLLMContainer()
        }

        func loadEmbedder(
            ref: ModelRef, slot: ModelSlot,
            reporting: @escaping @Sendable (DownloadProgress) -> Void
        ) async throws -> any LoadedEmbeddingContainer {
            recorded.withLock { $0.append(.loadEmbedder(ref: ref, slot: slot)) }
            reporting(Self.progress)
            return StubEmbeddingContainer()
        }

        func preload(container: any LoadedModelContainer) async throws {}

        func evict(container: any LoadedModelContainer) async {
            recorded.withLock { $0.append(.evict) }
        }
    }

    /// The error of ``DownloadThenFailLoader``.
    private struct LoadFailure: Error {}

    /// A router loader that downloads all the bytes of the model, and then
    /// fails to load it.
    private struct DownloadThenFailLoader: ModelLoader {
        /// The download that each load reports: all the bytes.
        static let download = DownloadProgress(bytesDownloaded: 2, bytesTotal: 2)

        func loadLLM(
            ref: ModelRef, slot: ModelSlot, context: Int,
            reporting: @escaping @Sendable (DownloadProgress) -> Void
        ) async throws -> any LoadedLLMContainer {
            reporting(Self.download)
            throw LoadFailure()
        }

        func loadEmbedder(
            ref: ModelRef, slot: ModelSlot,
            reporting: @escaping @Sendable (DownloadProgress) -> Void
        ) async throws -> any LoadedEmbeddingContainer {
            reporting(Self.download)
            throw LoadFailure()
        }

        func preload(container: any LoadedModelContainer) async throws {}

        func evict(container: any LoadedModelContainer) async {}
    }

    /// Keeps each progress value that a `reporting` callback receives.
    private final class ProgressSink: Sendable {
        private let values = Mutex<[DownloadProgress]>([])

        /// The values in the order they arrived.
        var received: [DownloadProgress] { values.withLock { $0 } }

        /// Keeps `progress`.
        func record(_ progress: DownloadProgress) { values.withLock { $0.append(progress) } }
    }

    // MARK: - Roles

    @Test("each slot maps to its pool role")
    func slotMapsToPoolRole() {
        #expect(ModelSlot.standard.poolRole == .llm)
        #expect(ModelSlot.flash.poolRole == .llm)
        #expect(ModelSlot.embedding.poolRole == .embedding)
    }

    // MARK: - First loader wins

    @Test("the router embeds through the Extras embed protocol with the container of the first loader")
    func routerEmbedsWithContainerOfFirstLoader() async throws {
        let pool = FoundationModelsExtras.ModelPool()
        let key = ModelPoolKey(ref: Self.ref, role: .embedding)
        let foreignHold = try await pool.acquire(
            key, footprintBytes: Self.footprintBytes, sessionBytes: 0,
            loader: ForeignLoader(container: ForeignEmbedding()))
        let routerLoader = RecordingModelLoader()
        let slotLoader = SlotPoolLoader(
            loader: routerLoader, slot: .embedding, context: Self.context, reporting: { _ in })

        let hold = try await slotLoader.acquireHold(
            of: Self.ref, in: pool, footprintBytes: Self.footprintBytes, sessionBytes: 0)
        let embedder = try PooledEmbeddingContainer(hold: hold)
        let vectors = try await embedder.embed(texts: ["one", "two"])

        #expect(hold.key == key)
        #expect(embedder.dimension == Self.foreignVector.count)
        #expect(vectors == [Self.foreignVector, Self.foreignVector])
        #expect(routerLoader.calls.isEmpty)
        withExtendedLifetime(foreignHold) {}
    }

    @Test("a generation hold whose container is no generation container throws a clear error")
    func generationContainerOfForeignLoaderThrows() async throws {
        let pool = FoundationModelsExtras.ModelPool()
        let key = ModelPoolKey(ref: Self.ref, role: .llm)
        let foreignHold = try await pool.acquire(
            key, footprintBytes: Self.footprintBytes, sessionBytes: Self.sessionBytes,
            loader: ForeignLoader(container: ForeignContainer()))
        let slotLoader = SlotPoolLoader(
            loader: RecordingModelLoader(), slot: .standard, context: Self.context, reporting: { _ in })

        let hold = try await slotLoader.acquireHold(
            of: Self.ref, in: pool, footprintBytes: Self.footprintBytes, sessionBytes: Self.sessionBytes)

        await #expect(
            throws: PooledGenerationError.notAGenerationContainer(
                key: key, containerType: String(describing: ForeignContainer.self))
        ) {
            try await hold.generationContainer()
        }
        withExtendedLifetime(foreignHold) {}
    }

    // MARK: - The slot data of the router

    @Test("a generation load gets the slot, the context and the progress callback of the router")
    func generationLoadGetsSlotData() async throws {
        let pool = FoundationModelsExtras.ModelPool()
        let routerLoader = RecordingModelLoader()
        let sink = ProgressSink()
        let slotLoader = SlotPoolLoader(
            loader: routerLoader, slot: .flash, context: Self.context, reporting: sink.record)

        let hold = try await slotLoader.acquireHold(
            of: Self.ref, in: pool, footprintBytes: Self.footprintBytes, sessionBytes: Self.sessionBytes)
        let container = try await hold.generationContainer()

        #expect(hold.key == ModelPoolKey(ref: Self.ref, role: .llm))
        #expect(container is StubLLMContainer)
        #expect(routerLoader.calls == [.loadLLM(ref: Self.ref, slot: .flash, context: Self.context)])
        #expect(sink.received == [RecordingModelLoader.progress])
    }

    @Test("an embedding load gets the slot and the progress callback of the router")
    func embeddingLoadGetsSlotData() async throws {
        let pool = FoundationModelsExtras.ModelPool()
        let routerLoader = RecordingModelLoader()
        let sink = ProgressSink()
        let slotLoader = SlotPoolLoader(
            loader: routerLoader, slot: .embedding, context: Self.context, reporting: sink.record)

        let hold = try await slotLoader.acquireHold(
            of: Self.ref, in: pool, footprintBytes: Self.footprintBytes, sessionBytes: 0)
        let embedder = try PooledEmbeddingContainer(hold: hold)

        #expect(hold.key == ModelPoolKey(ref: Self.ref, role: .embedding))
        #expect(embedder.dimension == StubEmbeddingContainer().dimension)
        #expect(routerLoader.calls == [.loadEmbedder(ref: Self.ref, slot: .embedding)])
        #expect(sink.received == [RecordingModelLoader.progress])
    }

    @Test("the pool evicts a router container through the Extras loader protocol")
    func poolEvictsThroughRouterLoader() async throws {
        let pool = FoundationModelsExtras.ModelPool()
        let routerLoader = RecordingModelLoader()
        let slotLoader = SlotPoolLoader(
            loader: routerLoader, slot: .standard, context: Self.context, reporting: { _ in })
        var hold: ModelHold? = try await slotLoader.acquireHold(
            of: Self.ref, in: pool, footprintBytes: Self.footprintBytes, sessionBytes: Self.sessionBytes)
        #expect(hold != nil)

        // The release puts the eviction job in the admission queue, so the
        // next admission job runs after the eviction job awaited the loader.
        hold = nil
        #expect(try await pool.admittedFootprint.resident.isEmpty)

        #expect(routerLoader.calls == [.loadLLM(ref: Self.ref, slot: .standard, context: Self.context), .evict])
    }

    // MARK: - The progress stream of the pool

    @Test("a router load gives the bytes of its download to the progress stream of the pool")
    func routerLoadGivesDownloadBytesToPoolStream() async throws {
        let pool = FoundationModelsExtras.ModelPool()
        let stream = pool.progress(for: Self.ref)
        let slotLoader = SlotPoolLoader(
            loader: RecordingModelLoader(), slot: .standard, context: Self.context, reporting: { _ in })

        let hold = try await slotLoader.acquireHold(
            of: Self.ref, in: pool, footprintBytes: Self.footprintBytes, sessionBytes: Self.sessionBytes)

        let download = RecordingModelLoader.progress
        #expect(
            await Self.steps(of: stream) == [
                .downloading(completedBytes: download.bytesDownloaded, totalBytes: download.bytesTotal),
                .loading, .ready,
            ])
        withExtendedLifetime(hold) {}
    }

    @Test("a router download that has all its bytes reports the load to the progress stream of the pool")
    func completeRouterDownloadReportsLoadToPoolStream() async throws {
        let pool = FoundationModelsExtras.ModelPool()
        let stream = pool.progress(for: Self.ref)
        let slotLoader = SlotPoolLoader(
            loader: DownloadThenFailLoader(), slot: .embedding, context: Self.context, reporting: { _ in })

        await #expect(throws: LoadFailure.self) {
            try await slotLoader.acquireHold(of: Self.ref, in: pool, footprintBytes: Self.footprintBytes, sessionBytes: 0)
        }

        // The load fails, thus the pool adds no load step of its own: the
        // load step comes from the router loader.
        let download = DownloadThenFailLoader.download
        #expect(
            await Self.steps(of: stream) == [
                .downloading(completedBytes: download.bytesDownloaded, totalBytes: download.bytesTotal),
                .loading, .failed(LoadFailure().localizedDescription),
            ])
    }

    @Test("the live loader gives each step of its model loader to the pool, and the bytes to its callback")
    func liveLoaderGivesStepsToPoolAndBytesToCallback() async throws {
        let pool = FoundationModelsExtras.ModelPool()
        let stream = pool.progress(for: Self.ref)
        let sink = ProgressSink()
        let loader = Self.makeLiveLoader(modelLoader: RecordingPoolLoader(), reporting: sink.record)

        let hold = try await pool.acquire(
            ModelPoolKey(ref: Self.ref, role: .embedding), footprintBytes: Self.footprintBytes, sessionBytes: 0,
            loader: loader)

        #expect(await Self.steps(of: stream) == Self.reportedSteps + [.ready])
        #expect(sink.received == [Self.reportedDownload])
        withExtendedLifetime(hold) {}
    }

    /// Gives each value of `stream`, until the stream ends.
    ///
    /// - Parameter stream: A progress stream of the pool.
    /// - Returns: The values in order.
    private static func steps(of stream: AsyncStream<ModelLoadProgress>) async -> [ModelLoadProgress] {
        await stream.reduce(into: []) { steps, step in steps.append(step) }
    }

    // MARK: - The live loader

    @Test("the live loader loads an embedding key through the Extras loader protocol with its model loader")
    func liveLoaderLoadsEmbeddingKeyWithModelLoader() async throws {
        let sink = ProgressSink()
        let modelLoader = RecordingPoolLoader()
        let loader: any PooledModelLoader = Self.makeLiveLoader(modelLoader: modelLoader, reporting: sink.record)
        let key = ModelPoolKey(ref: Self.ref, role: .embedding)

        let container = try await loader.load(key)
        let embedding = try #require(container as? any PooledEmbedding)

        #expect(modelLoader.loadedKeys == [key])
        #expect(embedding.dimension == Self.foreignVector.count)
        #expect(try await embedding.embed(texts: ["one"]) == [Self.foreignVector])
        #expect(sink.received == [Self.reportedDownload])
    }

    @Test("the live loader loads an embedder of the router with its model loader")
    func liveLoaderLoadsEmbedderWithModelLoader() async throws {
        let sink = ProgressSink()
        let modelLoader = RecordingPoolLoader()
        let loader = Self.makeLiveLoader(modelLoader: modelLoader, reporting: { _ in })

        let embedder = try await loader.loadEmbedder(ref: Self.ref, slot: .embedding, reporting: sink.record)

        #expect(modelLoader.loadedKeys == [ModelPoolKey(ref: Self.ref, role: .embedding)])
        #expect(embedder.dimension == Self.foreignVector.count)
        #expect(try await embedder.embed(texts: ["one", "two"]) == [Self.foreignVector, Self.foreignVector])
        #expect(sink.received == [Self.reportedDownload])
    }

    @Test("the live loader evicts an embedding container through its model loader")
    func liveLoaderEvictsEmbeddingThroughModelLoader() async throws {
        let modelLoader = RecordingPoolLoader()
        let loader = Self.makeLiveLoader(modelLoader: modelLoader, reporting: { _ in })
        let embedder = try await loader.loadEmbedder(ref: Self.ref, slot: .embedding, reporting: { _ in })

        await loader.evict(container: embedder)

        #expect(modelLoader.evictedTypes == [String(describing: ForeignEmbedding.self)])
    }

    @Test("a generation load of the live loader goes to its model loader, and the resolution progress shows the download")
    @MainActor
    func liveGenerationLoadReportsDownloadToResolutionProgress() async throws {
        let modelLoader = RecordingPoolLoader()
        let loader = Self.makeLiveLoader(modelLoader: modelLoader, reporting: { _ in })
        let progress = ResolutionProgress()
        progress.slots[.standard] = SlotProgress(state: .downloading)

        // The test loader gives no MLXLanguageModel, thus the load fails
        // after the download. A unit test cannot wrap a real MLX model: its
        // load needs the metal library.
        await #expect(throws: LiveModelLoaderError.self) {
            try await loader.loadLLM(
                ref: Self.ref, slot: .standard, context: Self.context,
                reporting: Router.reporter(slot: .standard, progress: progress))
        }

        #expect(modelLoader.loadedKeys == [ModelPoolKey(ref: Self.ref, role: .llm)])
        #expect(
            await BoundedWait.conditionReached("the standard slot shows the bytes of the download") {
                await progress.slots[.standard]?.bytesDownloaded == Self.reportedDownload.bytesDownloaded
            })
        #expect(progress.slots[.standard]?.bytesTotal == Self.reportedDownload.bytesTotal)
    }

    @Test("a generation load of the live loader that fails after the load gives the container back to its model loader")
    func failedLiveGenerationLoadEvictsTheContainer() async throws {
        let modelLoader = RecordingPoolLoader()
        let loader = Self.makeLiveLoader(modelLoader: modelLoader, reporting: { _ in })

        await #expect(throws: LiveModelLoaderError.self) {
            try await loader.loadLLM(ref: Self.ref, slot: .standard, context: Self.context, reporting: { _ in })
        }

        #expect(modelLoader.evictedTypes == [String(describing: ForeignContainer.self)])
    }

    @Test("a generation load of the live loader throws a clear error when its model loader gives no MLXLanguageModel")
    func liveGenerationLoadOfForeignContainerThrows() async throws {
        let loader = Self.makeLiveLoader(modelLoader: RecordingPoolLoader(), reporting: { _ in })

        await #expect(
            throws: LiveModelLoaderError.notAnMLXLanguageModel(
                key: ModelPoolKey(ref: Self.ref, role: .llm),
                containerType: String(describing: ForeignContainer.self))
        ) {
            try await loader.loadLLM(ref: Self.ref, slot: .standard, context: Self.context, reporting: { _ in })
        }
    }

    @Test("the live loader evicts a generation container through its model loader")
    func liveLoaderEvictsGenerationThroughModelLoader() async throws {
        let modelLoader = RecordingPoolLoader()
        let loader = Self.makeLiveLoader(modelLoader: modelLoader, reporting: { _ in })

        await loader.evict(container: UnloadableMLXModel.liveContainer(repo: Self.ref.repo))

        #expect(modelLoader.evictedTypes == [String(describing: MLXLanguageModel.self)])
    }

    // MARK: - Live loader fixtures

    /// The bytes of the download that ``RecordingPoolLoader`` reports. They
    /// are not a round part of the total, so a scale or a fraction does not
    /// give them back.
    private static let reportedDownload = DownloadProgress(bytesDownloaded: 3_000, bytesTotal: 7_000)

    /// The steps that ``RecordingPoolLoader`` reports: the bytes of
    /// ``reportedDownload``, and then the load.
    private static let reportedSteps: [ModelLoadProgress] = [
        .downloading(
            completedBytes: reportedDownload.bytesDownloaded, totalBytes: reportedDownload.bytesTotal),
        .loading,
    ]

    /// A model loader in place of `MLXModelLoader`. It records each key it
    /// loads and the type of each container it evicts, and reports
    /// ``reportedSteps``. It gives a
    /// ``ForeignEmbedding`` for an embedding key, and a ``ForeignContainer``
    /// for a generation key: a real `MLXLanguageModel` would need the metal
    /// library when the live loader wraps it.
    private final class RecordingPoolLoader: PooledModelLoader {
        /// The keys and the evicted container types, under one lock.
        private let recorded = Mutex<(keys: [ModelPoolKey], evicted: [String])>(([], []))

        /// The keys of each load, in the order the loads came.
        var loadedKeys: [ModelPoolKey] { recorded.withLock { $0.keys } }

        /// The type of each evicted container, in the order of the evictions.
        var evictedTypes: [String] { recorded.withLock { $0.evicted } }

        func load(_ key: ModelPoolKey) async throws -> any Sendable {
            try await load(key: key) { _ in }
        }

        func load(
            key: ModelPoolKey, progressHandler: @escaping @Sendable (ModelLoadProgress) -> Void
        ) async throws -> any Sendable {
            recorded.withLock { $0.keys.append(key) }
            SlotPoolLoaderTests.reportedSteps.forEach(progressHandler)
            switch key.role {
            case .llm: return ForeignContainer()
            case .embedding: return ForeignEmbedding()
            }
        }

        func evict(_ container: any Sendable) async {
            recorded.withLock { $0.evicted.append(String(describing: type(of: container))) }
        }
    }

    /// Makes a live loader whose loads go to `modelLoader`.
    ///
    /// - Parameters:
    ///   - modelLoader: The loader of each model.
    ///   - reporting: Receives the progress of each load through the Extras
    ///     loader protocol.
    /// - Returns: The live loader.
    private static func makeLiveLoader(
        modelLoader: any PooledModelLoader, reporting: @escaping @Sendable (DownloadProgress) -> Void
    ) -> LiveModelLoader {
        LiveModelLoader(reporting: reporting, modelLoader: modelLoader)
    }
}

extension SlotPoolLoader {
    /// Gives a hold of `ref` in the role of ``slot`` in its own admission job
    /// of `pool`, as a caller that is not inside a job does.
    ///
    /// - Parameters:
    ///   - ref: The model.
    ///   - pool: The Extras model pool.
    ///   - footprintBytes: The weights and one session.
    ///   - sessionBytes: The session of this hold.
    /// - Returns: The hold.
    /// - Throws: What the load throws.
    fileprivate func acquireHold(
        of ref: ModelRef, in pool: ModelPool, footprintBytes: Int64, sessionBytes: Int64
    ) async throws -> ModelHold {
        try await pool.admit { admission in
            try await acquireHold(of: ref, in: admission, footprintBytes: footprintBytes, sessionBytes: sessionBytes)
        }
    }
}
