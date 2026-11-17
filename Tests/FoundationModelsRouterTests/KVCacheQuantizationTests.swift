import FoundationModelsLlamaCpp
import MLXLMCommon
import Testing

@testable import FoundationModelsRouter

/// Proves that a quantized KV cache (task ^2fet0gs) shrinks the KV term of
/// the footprint as each engine stores it, and that a live loader gives the
/// setting to the GGUF loader and reports it to the router.
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

    @Test("a live loader quantizes no KV cache by default")
    func liveLoaderDefault() throws {
        let loader = LiveModelLoader(offline: true)

        #expect(loader.kvCacheQuantization == nil)
        #expect(try loader.requireGGUFModelLoader().options.kvCacheType == .float16)
        #expect(try loader.requireHubModelLoader().kvCache == nil)
    }

    @Test(
        "a live loader gives its KV cache quantization to the MLX and GGUF loaders and reports it",
        arguments: [
            (KVCacheQuantization.bits8, LlamaLanguageModel.KVCacheType.quantized8),
            (.bits4, .quantized4),
        ])
    func liveLoaderGivesSetting(quantization: KVCacheQuantization, cacheType: LlamaLanguageModel.KVCacheType) throws {
        let loader = LiveModelLoader(offline: true, kvCacheQuantization: quantization)

        #expect(loader.kvCacheQuantization == quantization)
        #expect(try loader.requireGGUFModelLoader().options.kvCacheType == cacheType)
        #expect(
            try loader.requireHubModelLoader().kvCache
                == KVCacheConfiguration(
                    strategy: .affine(AffineKVCacheConfiguration(bits: Int(quantization.bits), groupSize: 64))))
    }
}
