import Foundation
import FoundationModelsLlamaCpp

/// Builds the bytes of the header and the metadata section of a GGUF file,
/// with no tensor, so a sizing test can give a GGUF header of any shape
/// without a model file.
///
/// The layout is the one that `GGUFHeader.parse(prefix:)` reads: the magic,
/// the version, the tensor count, the count of the metadata values, then
/// each key, its `gguf_type` and its value, all little-endian.
enum GGUFHeaderFixtures {
    /// The GGUF magic.
    private static let magic = Data("GGUF".utf8)

    /// The GGUF version of the built headers.
    private static let version: UInt32 = 3

    /// The `gguf_type` of a `UINT32` value.
    private static let integerType: UInt32 = 4

    /// The `gguf_type` of a `STRING` value.
    private static let textType: UInt32 = 8

    /// The `gguf_type` of an `ARRAY` value.
    private static let arrayType: UInt32 = 9

    /// The metadata key of the architecture.
    private static let architectureKey = "general.architecture"

    /// The metadata key of the target layers of a DFlash drafter.
    private static let dflashTargetLayersKey = "dflash.target_layers"

    /// Builds the bytes of a header with no tensor.
    ///
    /// - Parameters:
    ///   - architecture: The architecture (`general.architecture`). The other
    ///     keys are under this prefix.
    ///   - values: The `UINT32` values under the prefix of the architecture,
    ///     by the key after the prefix, e.g. `"block_count"`.
    ///   - targetLayers: The `UINT32` array of `dflash.target_layers`, or
    ///     `nil` for a header with no such key.
    /// - Returns: The bytes.
    private static func bytes(
        architecture: String,
        values: KeyValuePairs<String, UInt32>,
        targetLayers: [UInt32]? = nil
    ) -> Data {
        var data = magic
        append(version, to: &data)
        append(UInt64(0), to: &data)
        let arrayCount = targetLayers == nil ? 0 : 1
        append(UInt64(values.count + 1 + arrayCount), to: &data)
        append(text: architectureKey, to: &data)
        append(textType, to: &data)
        append(text: architecture, to: &data)
        for (key, value) in values {
            append(text: "\(architecture).\(key)", to: &data)
            append(integerType, to: &data)
            append(value, to: &data)
        }
        if let targetLayers {
            append(text: dflashTargetLayersKey, to: &data)
            append(integers: targetLayers, to: &data)
        }
        return data
    }

    /// The attention heads of each dense model and of the drafter.
    private static let denseAttentionHeads: UInt32 = 8

    /// The K and V heads of each block of the dense model, of the hybrid
    /// model and of the drafter.
    private static let fewKeyValueHeads: UInt32 = 2

    /// The blocks of the dense model.
    private static let denseBlocks: UInt32 = 4

    /// The training context of the dense model and of the drafter, in tokens.
    private static let denseContext: UInt32 = 8_192

    /// The width of the embeddings of the dense model and of the drafter.
    private static let denseEmbeddingWidth: UInt32 = 256

    /// The blocks of the second dense model.
    private static let otherDenseBlocks: UInt32 = 8

    /// The training context of the second dense model, in tokens.
    private static let otherDenseContext: UInt32 = 16_384

    /// The width of the embeddings of the second dense model.
    private static let otherDenseEmbeddingWidth: UInt32 = 512

    /// The K and V heads of each block of the second dense model.
    private static let otherDenseKeyValueHeads: UInt32 = 4

    /// The blocks of the hybrid model.
    private static let hybridBlocks: UInt32 = 8

    /// The training context of the hybrid model, in tokens.
    private static let hybridContext: UInt32 = 262_144

    /// The width of the embeddings of the hybrid model.
    private static let hybridEmbeddingWidth: UInt32 = 2_048

    /// The attention heads of the hybrid model.
    private static let hybridAttentionHeads: UInt32 = 16

    /// The width of one K head and of one V head of the hybrid model.
    private static let hybridHeadWidth: UInt32 = 256

    /// Every how many blocks the hybrid model has an attention block.
    private static let hybridAttentionInterval: UInt32 = 4

    /// The kernel of the convolution of a recurrent block.
    private static let convolutionKernel: UInt32 = 4

    /// The inner width of a recurrent block.
    private static let recurrentInnerSize: UInt32 = 4_096

    /// The state width of a recurrent block.
    private static let recurrentStateSize: UInt32 = 128

    /// The groups of a recurrent block.
    private static let recurrentGroups: UInt32 = 16

    /// A dense model: four attention blocks of two K and V heads of 32
    /// elements each, with a training context of 8192 tokens.
    static let denseBytes = bytes(
        architecture: "llama",
        values: [
            "block_count": denseBlocks,
            "context_length": denseContext,
            "embedding_length": denseEmbeddingWidth,
            "attention.head_count": denseAttentionHeads,
            "attention.head_count_kv": fewKeyValueHeads,
        ])

    /// A second dense model with a different training context, as a second
    /// quantization of a repository can carry.
    static let otherDenseBytes = bytes(
        architecture: "llama",
        values: [
            "block_count": otherDenseBlocks,
            "context_length": otherDenseContext,
            "embedding_length": otherDenseEmbeddingWidth,
            "attention.head_count": denseAttentionHeads,
            "attention.head_count_kv": otherDenseKeyValueHeads,
        ])

    /// A hybrid model: eight blocks, every fourth one with attention, and a
    /// recurrent state in each other block, as Qwen3.5 has.
    static let hybridBytes = bytes(
        architecture: "qwen35",
        values: [
            "block_count": hybridBlocks,
            "context_length": hybridContext,
            "embedding_length": hybridEmbeddingWidth,
            "attention.head_count": hybridAttentionHeads,
            "attention.head_count_kv": fewKeyValueHeads,
            "attention.key_length": hybridHeadWidth,
            "attention.value_length": hybridHeadWidth,
            "full_attention_interval": hybridAttentionInterval,
            "ssm.conv_kernel": convolutionKernel,
            "ssm.inner_size": recurrentInnerSize,
            "ssm.state_size": recurrentStateSize,
            "ssm.group_count": recurrentGroups,
        ])

    /// The `UINT32` values of each DFlash drafter: one block, under the
    /// prefix of its architecture.
    private static let dflashDrafterValues: KeyValuePairs<String, UInt32> = [
        "block_count": 1,
        "context_length": denseContext,
        "embedding_length": denseEmbeddingWidth,
        "attention.head_count": denseAttentionHeads,
        "attention.head_count_kv": fewKeyValueHeads,
    ]

    /// The target layers of the DFlash drafter that llama.cpp loads.
    private static let dflashTargetLayers: [UInt32] = [1, 2, 3]

    /// A drafter with the architecture `dflash-draft` of the fork
    /// converters, which mainline llama.cpp does not load as DFlash.
    static let forkDFlashDrafterBytes = bytes(architecture: "dflash-draft", values: dflashDrafterValues)

    /// A drafter with the architecture `dflash` and its
    /// `dflash.target_layers` key, which mainline llama.cpp loads as DFlash.
    static let dflashDrafterBytes = bytes(
        architecture: "dflash", values: dflashDrafterValues, targetLayers: dflashTargetLayers)

    /// A drafter with the architecture `dflash` and no
    /// `dflash.target_layers` key, as an older converter writes it, which
    /// mainline llama.cpp does not load as DFlash.
    static let noTargetLayersDFlashDrafterBytes = bytes(architecture: "dflash", values: dflashDrafterValues)

    /// A dense model with no training context (`context_length`).
    static let noContextBytes = bytes(
        architecture: "llama",
        values: ["block_count": denseBlocks, "attention.head_count": denseAttentionHeads])

    /// Appends a GGUF string: its 64-bit length and its UTF-8 bytes.
    ///
    /// - Parameters:
    ///   - text: The string.
    ///   - data: The bytes to append to.
    private static func append(text: String, to data: inout Data) {
        let utf8 = Data(text.utf8)
        append(UInt64(utf8.count), to: &data)
        data.append(utf8)
    }

    /// Appends a GGUF array of `UINT32` values: its `gguf_type`, the
    /// `gguf_type` of its elements, its 64-bit count and its elements.
    ///
    /// - Parameters:
    ///   - integers: The elements.
    ///   - data: The bytes to append to.
    private static func append(integers: [UInt32], to data: inout Data) {
        append(arrayType, to: &data)
        append(integerType, to: &data)
        append(UInt64(integers.count), to: &data)
        for integer in integers {
            append(integer, to: &data)
        }
    }

    /// Appends a little-endian integer.
    ///
    /// - Parameters:
    ///   - integer: The integer.
    ///   - data: The bytes to append to.
    private static func append<Integer: FixedWidthInteger>(_ integer: Integer, to data: inout Data) {
        withUnsafeBytes(of: integer.littleEndian) { data.append(contentsOf: $0) }
    }
}
