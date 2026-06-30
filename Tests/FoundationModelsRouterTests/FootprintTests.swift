import Foundation
import Testing

@testable import FoundationModelsRouter

@Suite("Footprint")
struct FootprintTests {
    /// One megabyte in bytes — a convenient unit for weight sizes.
    private static let mb: Int64 = 1 << 20

    /// Contexts (tokens) for the monotonicity check, in strictly increasing order.
    private static let monotonicContexts: [Int] = [512, 1024, 2048, 4096, 8192, 16384]

    /// A small generative architecture with hand-computable KV math.
    private static func smallArch(weightBytes: Int64 = 1000) -> Footprint {
        Footprint(weightBytes: weightBytes, layers: 2, kvHeads: 4, headDim: 8)
    }

    @Test("kvBytes matches 2 * layers * ctx * kvHeads * headDim * 2 for a small arch")
    func kvBytesHandComputed() {
        // 2 (K+V) * 2 layers * 16 ctx * 4 kvHeads * 8 headDim * 2 (fp16) = 4096.
        #expect(Self.smallArch().kvBytes(context: 16) == 4096)
    }

    @Test("footprint adds weightBytes to the KV cache bytes")
    func footprintIsWeightsPlusKV() {
        let model = Self.smallArch(weightBytes: 1000)
        #expect(model.footprint(context: 16) == 1000 + 4096)
    }

    @Test("larger context strictly increases footprint")
    func footprintMonotonicInContext() {
        let model = Self.smallArch()
        let footprints = Self.monotonicContexts.map { model.footprint(context: $0) }
        for (smaller, larger) in zip(footprints, footprints.dropFirst()) {
            #expect(larger > smaller)
        }
    }

    @Test("GQA fallback: absent num_key_value_heads uses num_attention_heads")
    func gqaFallbackToAttentionHeads() {
        let mha = Footprint(
            weightBytes: 0,
            numHiddenLayers: 2,
            numAttentionHeads: 32,
            numKeyValueHeads: nil,
            headDim: 8
        )
        let explicit = Footprint(weightBytes: 0, layers: 2, kvHeads: 32, headDim: 8)
        #expect(mha.kvBytes(context: 16) == explicit.kvBytes(context: 16))
    }

    @Test("GQA: fewer key-value heads shrink the KV cache vs MHA")
    func gqaShrinksCacheVersusMHA() {
        let gqa = Footprint(
            weightBytes: 0,
            numHiddenLayers: 2,
            numAttentionHeads: 32,
            numKeyValueHeads: 8,
            headDim: 8
        )
        let mha = Footprint(
            weightBytes: 0,
            numHiddenLayers: 2,
            numAttentionHeads: 32,
            numKeyValueHeads: nil,
            headDim: 8
        )
        #expect(gqa.kvBytes(context: 16) < mha.kvBytes(context: 16))
    }

    @Test("headDim falls back to hidden_size / num_attention_heads")
    func headDimFallbackFromHiddenSize() {
        let resolved = Footprint(
            weightBytes: 0,
            numHiddenLayers: 2,
            numAttentionHeads: 8,
            numKeyValueHeads: 8,
            headDim: nil,
            hiddenSize: 512
        )
        // hidden_size 512 / 8 heads = 64 head_dim.
        let explicit = Footprint(weightBytes: 0, layers: 2, kvHeads: 8, headDim: 64)
        #expect(resolved.kvBytes(context: 16) == explicit.kvBytes(context: 16))
    }

    @Test("embedder footprint equals weightBytes with no KV term")
    func embedderFootprintIsWeightsOnly() {
        let embedder = Footprint.embedder(weightBytes: 42 * Self.mb)
        #expect(embedder.kvBytes(context: 8192) == 0)
        #expect(embedder.footprint(context: 8192) == 42 * Self.mb)
        #expect(embedder.footprint(context: 0) == embedder.footprint(context: 1_000_000))
    }
}
