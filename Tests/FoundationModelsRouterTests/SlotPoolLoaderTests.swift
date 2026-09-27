import Foundation
import FoundationModels
import FoundationModelsExtras
import FoundationModelsRouterTestSupport
import MLXLMCommon
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

    /// Keeps each progress value that a `reporting` callback receives.
    private final class ProgressSink: Sendable {
        private let values = Mutex<[DownloadProgress]>([])

        /// The values in the order they arrived.
        var received: [DownloadProgress] { values.withLock { $0 } }

        /// Keeps `progress`.
        func record(_ progress: DownloadProgress) { values.withLock { $0.append(progress) } }
    }

    /// The failure of ``FailingDownloader``.
    private struct DownloadFailure: Error, Equatable {}

    /// A downloader that reports one progress value and then fails, so a live
    /// load stops before it reads a file.
    private struct FailingDownloader: Downloader {
        func download(
            id: String, revision: String?, matching patterns: [String], useLatest: Bool,
            progressHandler: @Sendable @escaping (Progress) -> Void
        ) async throws -> URL {
            let progress = Progress(totalUnitCount: 2)
            progress.completedUnitCount = 1
            progressHandler(progress)
            throw DownloadFailure()
        }
    }

    /// A tokenizer loader that a failed download never reaches.
    private struct UnusedTokenizerLoader: TokenizerLoader {
        func load(from directory: URL) async throws -> any Tokenizer { throw DownloadFailure() }
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
        let embedder = try PooledEmbedder(hold: hold)
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

        #expect(
            throws: PooledGenerationError.notAGenerationContainer(
                key: key, containerType: String(describing: ForeignContainer.self))
        ) {
            try hold.generationContainer()
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
        let container = try hold.generationContainer()

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
        let embedder = try PooledEmbedder(hold: hold)

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

        // The pool publishes the footprint with no resident model only after
        // the eviction job awaited the loader.
        let footprints = pool.footprints
        hold = nil
        for await footprint in footprints where footprint.resident.isEmpty { break }

        #expect(routerLoader.calls == [.loadLLM(ref: Self.ref, slot: .standard, context: Self.context), .evict])
    }

    // MARK: - The live loader

    @Test("the live loader loads an embedding key through the Extras loader protocol")
    func liveLoaderLoadsThroughExtrasProtocol() async throws {
        let sink = ProgressSink()
        let loader: any PooledModelLoader = LiveModelLoader(
            downloader: FailingDownloader(), tokenizerLoader: UnusedTokenizerLoader(),
            reporting: sink.record)

        await #expect(throws: DownloadFailure()) {
            _ = try await loader.load(ModelPoolKey(ref: Self.ref, role: .embedding))
        }
        #expect(sink.received == [DownloadProgress(bytesDownloaded: 1, bytesTotal: 2)])
    }
}
