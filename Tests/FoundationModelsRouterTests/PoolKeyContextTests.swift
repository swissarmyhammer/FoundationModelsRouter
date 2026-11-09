import Foundation
import FoundationModels
import FoundationModelsExtras
import FoundationModelsRouterTestSupport
import Synchronization
import Testing

@testable import FoundationModelsRouter

/// Proves that the context a resolve decided reaches the key of each
/// generation model in the Extras model pool, so a loader that loads at a
/// fixed context (the GGUF loader) loads at it. A loader that ignores the
/// context drops it from the key, and an embedding key never carries one.
/// Each test uses a private pool. No network, no GPU.
@Suite("The resolved context in the pool key")
struct PoolKeyContextTests {
    // MARK: - Fixed values

    /// The model that each test loads.
    private static let ref: ModelRef = "test/context-model"

    /// The weights of each test model. The private pool only counts them.
    private static let footprintBytes: Int64 = 1_000

    /// The session bytes of a generation hold.
    private static let sessionBytes: Int64 = 100

    /// The smaller of the two contexts a test resolves.
    private static let smallContext = 4_096

    /// The larger of the two contexts a test resolves.
    private static let largeContext = 16_384

    /// The weights of the sized test model.
    private static let weightBytes: Int64 = 1_000_000

    /// The layers, and the attention heads of each layer, of the sized test
    /// model.
    private static let layerCount = 2

    /// The width of one attention head of the sized test model.
    private static let headWidth = 8

    // MARK: - Stubs

    /// A generation container of the router loader.
    private struct StubLLMContainer: LoadedLLMContainer {
        let tokenCounter: any TokenCounter = CharacterTokenCounter()
        func makeSession(instructions: String?) -> any LanguageModelSessionBackend {
            StubSessionBackend(shouldThrow: true)
        }
        func makeSession(transcript: Transcript) -> any LanguageModelSessionBackend {
            StubSessionBackend(shouldThrow: true)
        }
    }

    /// An embedding container of the router loader.
    private struct StubEmbeddingContainer: LoadedEmbeddingContainer {
        func embed(texts: [String]) async throws -> [[Float]] { texts.map { _ in [0] } }
    }

    /// A router loader that loads at a fixed context, as the live loader does
    /// for a GGUF model: its pool key keeps the context of the request. It
    /// records the context of each generation load.
    private final class ContextKeepingLoader: ModelLoader {
        private let contexts = Mutex<[Int]>([])

        /// The context of each generation load, in the order the loads came.
        var loadedContexts: [Int] { contexts.withLock { $0 } }

        func poolKey(for key: ModelPoolKey) async throws -> ModelPoolKey { key }

        func loadLLM(
            ref: ModelRef, slot: ModelSlot, context: Int,
            reporting: @escaping @Sendable (DownloadProgress) -> Void
        ) async throws -> any LoadedLLMContainer {
            contexts.withLock { $0.append(context) }
            return StubLLMContainer()
        }

        func loadEmbedder(
            ref: ModelRef, slot: ModelSlot,
            reporting: @escaping @Sendable (DownloadProgress) -> Void
        ) async throws -> any LoadedEmbeddingContainer {
            StubEmbeddingContainer()
        }

        func preload(container: any LoadedModelContainer) async throws {}
    }

    /// A model loader in place of `HubModelLoader`. Its pool key keeps the
    /// context, as `HubModelLoader` does for a GGUF model. It records the key
    /// of each load, and gives a container that is no generation model.
    private final class ContextKeepingPoolLoader: PooledModelLoader {
        private let keys = Mutex<[ModelPoolKey]>([])

        /// The key of each load, in the order the loads came.
        var loadedKeys: [ModelPoolKey] { keys.withLock { $0 } }

        func poolKey(for key: ModelPoolKey) async throws -> ModelPoolKey { key }

        func load(_ key: ModelPoolKey) async throws -> any Sendable {
            keys.withLock { $0.append(key) }
            return key
        }

        func evict(_ container: any Sendable) async {}
    }

    /// A router loader for the slot of `slot` at `context`.
    ///
    /// - Parameters:
    ///   - loader: The router loader.
    ///   - slot: The slot of the load.
    ///   - context: The context the resolve decided.
    /// - Returns: The slot loader.
    private static func slotLoader(
        over loader: any ModelLoader, slot: ModelSlot, context: Int
    ) -> SlotPoolLoader {
        SlotPoolLoader(loader: loader, slot: slot, context: context, reporting: { _ in })
    }

    /// Acquires ``ref`` in the slot of `slot` at `context` from `pool`.
    ///
    /// - Parameters:
    ///   - pool: The private pool.
    ///   - loader: The router loader.
    ///   - slot: The slot of the load.
    ///   - context: The context the resolve decided.
    /// - Returns: The hold.
    /// - Throws: What the load throws.
    private static func acquire(
        from pool: FoundationModelsExtras.ModelPool, over loader: any ModelLoader, slot: ModelSlot, context: Int
    ) async throws -> ModelHold {
        try await slotLoader(over: loader, slot: slot, context: context).acquireHold(
            of: ref, in: pool, footprintBytes: footprintBytes, sessionBytes: sessionBytes)
    }

    /// The key of ``ref`` as a generation model at `context`.
    private static func generationKey(context: Int) -> ModelPoolKey {
        ModelPoolKey(ref: ref, role: .llm, contextSize: context)
    }

    // MARK: - The slot loader

    @Test("a generation acquire keys the model at the context the resolve decided")
    func generationAcquireKeysTheResolvedContext() async throws {
        let hold = try await Self.acquire(
            from: FoundationModelsExtras.ModelPool(), over: ContextKeepingLoader(), slot: .standard,
            context: Self.largeContext)

        #expect(hold.key == Self.generationKey(context: Self.largeContext))
    }

    @Test("an embedding acquire keys the model with no context, even for a loader that keeps one")
    func embeddingAcquireKeysNoContext() async throws {
        let hold = try await Self.acquire(
            from: FoundationModelsExtras.ModelPool(), over: ContextKeepingLoader(), slot: .embedding,
            context: Self.largeContext)

        #expect(hold.key == ModelPoolKey(ref: Self.ref, role: .embedding))
    }

    @Test("a generation load of the slot loader loads at the context of the key the pool gives")
    func generationLoadUsesTheContextOfTheKey() async throws {
        let loader = ContextKeepingLoader()
        let slotLoader = Self.slotLoader(over: loader, slot: .flash, context: Self.smallContext)

        _ = try await slotLoader.load(Self.generationKey(context: Self.largeContext))

        #expect(loader.loadedContexts == [Self.largeContext])
    }

    @Test("a resident model at a larger context serves a resolve at a smaller one")
    func largerResidentContextServesASmallerResolve() async throws {
        let pool = FoundationModelsExtras.ModelPool()
        let loader = ContextKeepingLoader()
        let large = try await Self.acquire(from: pool, over: loader, slot: .standard, context: Self.largeContext)

        let small = try await Self.acquire(from: pool, over: loader, slot: .flash, context: Self.smallContext)

        #expect(small.key == Self.generationKey(context: Self.largeContext))
        #expect(loader.loadedContexts == [Self.largeContext])
        withExtendedLifetime(large) {}
    }

    @Test("a resolve at a larger context than the resident model loads a second copy")
    func smallerResidentContextLoadsASecondCopy() async throws {
        let pool = FoundationModelsExtras.ModelPool()
        let loader = ContextKeepingLoader()
        let small = try await Self.acquire(from: pool, over: loader, slot: .standard, context: Self.smallContext)

        let large = try await Self.acquire(from: pool, over: loader, slot: .flash, context: Self.largeContext)

        #expect(large.key == Self.generationKey(context: Self.largeContext))
        #expect(loader.loadedContexts == [Self.smallContext, Self.largeContext])
        withExtendedLifetime(small) {}
    }

    // MARK: - The live loader

    @Test("a generation load of the live loader gives its model loader the context the resolve decided")
    func liveGenerationLoadKeysTheResolvedContext() async throws {
        let modelLoader = ContextKeepingPoolLoader()
        let loader = LiveModelLoader(reporting: { _ in }, modelLoader: modelLoader)

        await #expect(throws: LiveModelLoaderError.self) {
            try await loader.loadLLM(ref: Self.ref, slot: .standard, context: Self.largeContext, reporting: { _ in })
        }

        #expect(modelLoader.loadedKeys == [Self.generationKey(context: Self.largeContext)])
    }

    @Test("the live loader keys a model in the pool as its model loader does")
    func livePoolKeyIsThePoolKeyOfTheModelLoader() async throws {
        let loader = LiveModelLoader(reporting: { _ in }, modelLoader: ContextKeepingPoolLoader())

        let key = try await loader.poolKey(for: Self.generationKey(context: Self.largeContext))

        #expect(key == Self.generationKey(context: Self.largeContext))
    }

    @Test("a pool load of the live loader gives its model loader the context of the key")
    func livePoolLoadKeepsTheContextOfTheKey() async throws {
        let modelLoader = ContextKeepingPoolLoader()
        let loader: any PooledModelLoader = LiveModelLoader(reporting: { _ in }, modelLoader: modelLoader)

        await #expect(throws: LiveModelLoaderError.self) {
            try await loader.load(Self.generationKey(context: Self.largeContext))
        }

        #expect(modelLoader.loadedKeys == [Self.generationKey(context: Self.largeContext)])
    }

    // MARK: - Residency

    @Test("a resident key with no context serves a request at any context")
    func keyWithNoContextServesAnyContext() {
        let resident = ModelPoolKey(ref: Self.ref, role: .llm)

        #expect(resident.canServe(Self.generationKey(context: Self.largeContext)))
    }

    @Test("a resident key at a larger context serves a request at a smaller one")
    func largerKeyServesASmallerRequest() {
        let resident = Self.generationKey(context: Self.largeContext)

        #expect(resident.canServe(Self.generationKey(context: Self.smallContext)))
    }

    @Test("a resident key at a smaller context does not serve a request at a larger one")
    func smallerKeyDoesNotServeALargerRequest() {
        let resident = Self.generationKey(context: Self.smallContext)

        #expect(!resident.canServe(Self.generationKey(context: Self.largeContext)))
    }

    @Test("a resident key does not serve a request in another role")
    func keyDoesNotServeAnotherRole() {
        let resident = ModelPoolKey(ref: Self.ref, role: .embedding)

        #expect(!resident.canServe(Self.generationKey(context: Self.smallContext)))
    }

    @Test("a generation slot requests its model at the resolved context")
    func generationSlotRequestsTheResolvedContext() {
        #expect(
            ModelSlot.standard.poolKey(of: Self.ref, context: Self.largeContext)
                == Self.generationKey(context: Self.largeContext))
    }

    @Test("the embedding slot requests its model with no context")
    func embeddingSlotRequestsNoContext() {
        #expect(
            ModelSlot.embedding.poolKey(of: Self.ref, context: Self.largeContext)
                == ModelPoolKey(ref: Self.ref, role: .embedding))
    }

    @Test("the sizing charges one session for a model resident at a larger context")
    func sizingChargesOneSessionForALargerResidentContext() throws {
        let bytes = Self.generationFootprint(
            context: Self.smallContext, resident: Self.generationKey(context: Self.largeContext))

        #expect(try bytes.get() == Self.metadata.footprint.kvBytes(context: Self.smallContext))
    }

    @Test("the sizing charges a full load for a model resident at a smaller context")
    func sizingChargesAFullLoadForASmallerResidentContext() throws {
        let bytes = Self.generationFootprint(
            context: Self.largeContext, resident: Self.generationKey(context: Self.smallContext))

        #expect(try bytes.get() == Self.metadata.footprint.footprint(context: Self.largeContext))
    }

    /// The sizing of a generation model for ``ref``.
    private static let metadata = RepoMetadata(
        weightBytes: weightBytes, numHiddenLayers: layerCount, numAttentionHeads: layerCount,
        numKeyValueHeads: layerCount, headDim: headWidth, hiddenSize: nil, nativeMaxContext: largeContext)

    /// The footprint the router charges ``ref`` in the standard slot at
    /// `context` while `resident` is resident.
    ///
    /// - Parameters:
    ///   - context: The context of the candidate.
    ///   - resident: The one resident key of the pool.
    /// - Returns: The footprint, or the sizing error.
    private static func generationFootprint(
        context: Int, resident: ModelPoolKey
    ) -> Result<Int64, RepoMetadataError> {
        Router.footprintBytes(
            for: ref, context: context, metadataByRef: [ref: .success(metadata)],
            membership: [ref: [.standard]], residentKeys: [resident])
    }
}
