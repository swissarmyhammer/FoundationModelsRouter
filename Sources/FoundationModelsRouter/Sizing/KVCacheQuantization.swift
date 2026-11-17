import FoundationModelsLlamaCpp
import MLXLMCommon

/// How each generation model stores its KV cache (task ^2fet0gs): with fewer
/// bits for each element than the fp16 default.
///
/// The setting is the same for every model of a live loader
/// (``LiveModelLoader/init(reporting:cacheDirectory:tokenProvider:speculativeDecoding:offline:kvCacheQuantization:)``).
/// Each engine maps it to its own cache:
///
/// - An MLX model stores an affine cache: `bits` for each element, and an
///   fp16 scale and bias for each group of ``affineGroupSize`` elements.
/// - A GGUF model stores the llama.cpp block type of the same width: `Q8_0`
///   or `Q4_0`, a block of 32 elements with one fp16 scale.
///
/// Only the KV cache is quantized. The recurrent state of a hybrid model
/// (the linear layers of Qwen 3.8) keeps its size. A quantized cache takes
/// about half or a quarter of the memory, and its output can differ from the
/// fp16 cache on near-ties.
public enum KVCacheQuantization: Sendable, Hashable {
    /// 8 bits for each element.
    case bits8

    /// 4 bits for each element.
    case bits4

    /// The elements of an MLX affine group, each group with one scale and
    /// one bias.
    static let affineGroupSize: Int64 = 64

    /// The bytes of the scale and the bias of one affine group: two fp16
    /// values.
    private static let affineGroupOverheadBytes: Int64 = 4

    /// The bits of each element.
    var bits: Int64 {
        switch self {
        case .bits8: 8
        case .bits4: 4
        }
    }

    /// The llama.cpp cache type of the same width.
    var llamaCppCacheType: LlamaLanguageModel.KVCacheType {
        switch self {
        case .bits8: .quantized8
        case .bits4: .quantized4
        }
    }

    /// The MLX cache configuration of the same width: an affine cache with
    /// groups of ``affineGroupSize`` elements.
    var mlxCacheConfiguration: KVCacheConfiguration {
        // MLX accepts 8 and 4 bits with groups of 64, so the init does not
        // throw for any case.
        let affine = try! AffineKVCacheConfiguration(bits: Int(bits), groupSize: Int(Self.affineGroupSize))
        return KVCacheConfiguration(strategy: .affine(affine))
    }

    /// The bytes of an MLX affine cache of `elements` elements.
    ///
    /// - Parameter elements: The K and V elements of the cache.
    /// - Returns: The quantized elements, and the scale and bias of each group.
    func affineBytes(elements: Int64) -> Int64 {
        elements * bits / 8 + elements / Self.affineGroupSize * Self.affineGroupOverheadBytes
    }

    /// The bytes of a llama.cpp cache of this type, from the bytes of the
    /// same cache in fp16.
    ///
    /// A block of 32 elements takes 64 bytes in fp16, 34 in `Q8_0` and 18 in
    /// `Q4_0`. llama.cpp quantizes rows whose length is a multiple of the
    /// block, so the ratio is exact.
    ///
    /// - Parameter float16Bytes: The bytes of the cache in fp16.
    /// - Returns: The bytes of the cache of this type.
    func llamaCppBytes(float16Bytes: Int64) -> Int64 {
        let float16BlockBytes: Int64 = 64
        let blockBytes: Int64 =
            switch self {
            case .bits8: 34
            case .bits4: 18
            }
        return float16Bytes / float16BlockBytes * blockBytes
    }
}
