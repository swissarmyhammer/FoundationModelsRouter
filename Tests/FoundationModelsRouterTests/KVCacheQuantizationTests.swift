import Foundation
import FoundationModelsLlamaCpp
import Synchronization
import Testing

@testable import FoundationModelsRouter

/// Proves that a quantized KV cache (task ^2fet0gs) shrinks the KV term of
/// the footprint as each engine stores it, and that the KV cache of a profile
/// (task ^vp19r4r) reaches each pool key and each load of a language model.
@Suite("A quantized KV cache sizes and loads as each engine stores it")
struct KVCacheQuantizationTests {
    /// A context that is not a multiple of the 256 cells llama.cpp pads to.
    private static let unpaddedContext = 1_000

    /// An MLX architecture whose head is one quantization group of 64.
    private static let mlxArch = Footprint(weightBytes: 0, layers: 2, kvHeads: 4, headDim: 64)

    /// The K and V elements of ``mlxArch`` at 16 tokens: 2 × 2 × 16 × 4 × 64.
    private static let mlxElements: Int64 = 16_384

    /// The bytes of the fp16 scale and bias of each group of 64 elements.
    private static let groupOverheadBytes: Int64 = 4

    @Test("an unquantized MLX KV cache is fp16")
    func mlxUnquantizedIsFP16() {
        #expect(Self.mlxArch.kvBytes(context: 16) == Self.mlxElements * 2)
    }

    @Test(
        "an affine MLX KV cache stores bits per element and an fp16 scale and bias per group of 64",
        arguments: [(KVCacheQuantization.bits8, Int64(8)), (.bits4, Int64(4))])
    func mlxAffineBytes(quantization: KVCacheQuantization, bits: Int64) {
        let footprint = Self.mlxArch.quantizingKVCache(quantization)
        let expected = Self.mlxElements * bits / 8 + Self.mlxElements / 64 * Self.groupOverheadBytes

        #expect(footprint.kvBytes(context: 16) == expected)
        #expect(footprint.footprint(context: 16) == expected)
    }

    @Test(
        "a quantized GGUF KV cache is the cache llama.cpp allocates for that type",
        arguments: [
            (KVCacheQuantization.bits8, LlamaLanguageModel.KVCacheType.quantized8),
            (.bits4, .quantized4),
        ])
    func ggufQuantizedBytes(quantization: KVCacheQuantization, cacheType: LlamaLanguageModel.KVCacheType) throws {
        let header = try GGUFHeader.parse(prefix: GGUFHeaderFixtures.denseBytes)
        let footprint = Footprint(weightBytes: 0, cache: GGUFCacheSizing(header: header))
            .quantizingKVCache(quantization)

        #expect(
            footprint.kvBytes(context: Self.unpaddedContext)
                == Int64(header.keyValueBytes(contextSize: Self.unpaddedContext, cacheType: cacheType)))
    }

    @Test("a quantized hybrid GGUF cache keeps its recurrent state at full size")
    func ggufRecurrentStateIsNotQuantized() throws {
        let header = try GGUFHeader.parse(prefix: GGUFHeaderFixtures.hybridBytes)
        let footprint = Footprint(weightBytes: 0, cache: GGUFCacheSizing(header: header))
            .quantizingKVCache(.bits8)
        let expected =
            header.keyValueBytes(contextSize: Self.unpaddedContext, cacheType: .quantized8)
            + header.recurrentStateBytes(sequenceCount: LlamaLanguageModel.Options.defaultMaxLiveSequences)

        #expect(footprint.kvBytes(context: Self.unpaddedContext) == Int64(expected))
    }

    @Test("an embedder has no KV cache to quantize")
    func embedderStaysWeightsOnly() {
        let embedder = Footprint.embedder(weightBytes: 42).quantizingKVCache(.bits4)

        #expect(embedder.kvBytes(context: 8192) == 0)
    }

    @Test("the router prices a quantized KV cache in each slot it sizes")
    func routerPricesQuantizedCache() throws {
        let ref: ModelRef = "org/model"
        let metadata = RepoMetadata(
            weightBytes: 1_000, numHiddenLayers: 2, numAttentionHeads: 4, numKeyValueHeads: 4, headDim: 64,
            hiddenSize: nil, nativeMaxContext: 32_768)
        let byRef: [ModelRef: Result<RepoMetadata, RepoMetadataError>] = [ref: .success(metadata)]
        func price(_ quantization: KVCacheQuantization?) throws -> Int64 {
            try Router.footprintBytes(
                for: ref, in: .standard, context: 16, metadataByRef: byRef, membership: [ref: [.standard]],
                residentKeys: [], kvCache: quantization
            ).get()
        }

        #expect(try price(nil) == 1_000 + Self.mlxElements * 2)
        #expect(try price(.bits8) == 1_000 + Self.mlxElements + Self.mlxElements / 64 * Self.groupOverheadBytes)
    }

    @Test("a live loader asks its model loader for the KV cache of each load")
    func liveLoaderKeysTheKVCache() async {
        let quantizations: [KVCacheQuantization?] = [nil, .bits8, .bits4]
        let modelLoader = KeyRecordingPoolLoader()
        let loader = LiveModelLoader(reporting: { _ in }, modelLoader: modelLoader)

        for quantization in quantizations {
            _ = try? await loader.loadLLM(
                ref: "org/model", slot: .standard, context: 4096, kvCache: quantization, reporting: { _ in })
        }

        #expect(modelLoader.loadedKeys.map(\.kvCache) == quantizations)
    }

    @Test("a resolve loads each language model of the profile with its KV cache, and the embedder with none")
    func resolveLoadsWithTheProfileKVCache() async throws {
        let dir = RouterTestFixtures.makeTempDir(prefix: "KVCacheQuantizationTests")
        defer { try? FileManager.default.removeItem(at: dir) }
        let spy = LoadSpy()
        let router = ResidencyFixtures.makeRouter(
            spy: spy, recommendedMaxWorkingSetSize: RouterTestFixtures.stubWorkingSet, cacheDir: dir)
        var profile = RouterTestFixtures.profile()
        profile.kvCacheQuantization = .bits8

        let resolved = try await router.resolve(profile: profile, reporting: ResolutionProgress())

        let kvCaches = await spy.llmLoadKVCaches
        #expect(!kvCaches.isEmpty)
        #expect(kvCaches.allSatisfy { $0 == .bits8 })
        #expect(await spy.embedderLoads.count == 1)
        withExtendedLifetime(resolved) {}
    }

    @Test("a resident fp16 model does not serve a profile that quantizes the KV cache of the same model")
    func residentOfAnotherKVCacheIsAnotherModel() async throws {
        let dir = RouterTestFixtures.makeTempDir(prefix: "KVCacheQuantizationTests")
        defer { try? FileManager.default.removeItem(at: dir) }
        let pool = ModelPool()
        let float16Spy = LoadSpy()
        let bits8Spy = LoadSpy()
        let float16Router = ResidencyFixtures.makeRouter(
            spy: float16Spy, recommendedMaxWorkingSetSize: RouterTestFixtures.stubWorkingSet, cacheDir: dir, pool: pool)
        let bits8Router = ResidencyFixtures.makeRouter(
            spy: bits8Spy, recommendedMaxWorkingSetSize: RouterTestFixtures.stubWorkingSet, cacheDir: dir, pool: pool)
        var bits8Profile = RouterTestFixtures.profile()
        bits8Profile.kvCacheQuantization = .bits8

        let float16 = try await float16Router.resolve(profile: RouterTestFixtures.profile(), reporting: ResolutionProgress())
        let bits8 = try await bits8Router.resolve(profile: bits8Profile, reporting: ResolutionProgress())

        #expect(await bits8Spy.llmLoads.sorted { $0.stringValue < $1.stringValue }
            == float16Spy.llmLoads.sorted { $0.stringValue < $1.stringValue })
        #expect(await bits8Spy.embedderLoads.isEmpty)
        withExtendedLifetime((float16, bits8)) {}
    }
}

/// A model loader in place of the Extras `HubModelLoader` that records the
/// key of each load, and gives a container that is no generation model.
private final class KeyRecordingPoolLoader: PooledModelLoader {
    private let keys = Mutex<[ModelPoolKey]>([])

    /// The key of each load, in the order the loads came.
    var loadedKeys: [ModelPoolKey] { keys.withLock { $0 } }

    func load(_ key: ModelPoolKey) async throws -> any Sendable {
        keys.withLock { $0.append(key) }
        return key
    }

    func evict(_ container: any Sendable) async {}
}
