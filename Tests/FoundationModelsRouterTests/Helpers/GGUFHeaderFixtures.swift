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

    /// The `gguf_type` of an `INT32` value.
    private static let signedIntegerType: UInt32 = 5

    /// The `gguf_type` of an `ARRAY` value.
    private static let arrayType: UInt32 = 9

    /// The metadata key of the architecture.
    private static let architectureKey = "general.architecture"

    /// The architecture of each dense model.
    private static let denseArchitecture = "llama"

    /// The metadata key of the target layers of a DFlash drafter.
    private static let dflashTargetLayersKey = "dflash.target_layers"

    /// A metadata value after the values under the prefix of the
    /// architecture: its full key, and the bytes of its `gguf_type` and of
    /// its value.
    private typealias TrailingValue = (key: String, typedValue: Data)

    /// Builds the bytes of a header with no tensor.
    ///
    /// - Parameters:
    ///   - architecture: The architecture (`general.architecture`). The other
    ///     keys are under this prefix.
    ///   - values: The `UINT32` values under the prefix of the architecture,
    ///     by the key after the prefix, e.g. `"block_count"`.
    ///   - trailing: The values after them, by their full key.
    /// - Returns: The bytes.
    private static func bytes(
        architecture: String, values: KeyValuePairs<String, UInt32>, trailing: [TrailingValue] = []
    ) -> Data {
        var data = magic
        append(version, to: &data)
        append(UInt64(0), to: &data)
        append(UInt64(values.count + 1 + trailing.count), to: &data)
        append(text: architectureKey, to: &data)
        append(textType, to: &data)
        append(text: architecture, to: &data)
        for (key, value) in values {
            append(text: "\(architecture).\(key)", to: &data)
            append(integerType, to: &data)
            append(value, to: &data)
        }
        for value in trailing {
            append(text: value.key, to: &data)
            data.append(value.typedValue)
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

    /// The values of the dense model, under the prefix of its architecture.
    private static let denseValues: KeyValuePairs<String, UInt32> = [
        "block_count": denseBlocks,
        "context_length": denseContext,
        "embedding_length": denseEmbeddingWidth,
        "attention.head_count": denseAttentionHeads,
        "attention.head_count_kv": fewKeyValueHeads,
    ]

    /// A dense model: four attention blocks of two K and V heads of 32
    /// elements each, with a training context of 8192 tokens.
    static let denseBytes = bytes(architecture: denseArchitecture, values: denseValues)

    /// A second dense model with a different training context, as a second
    /// quantization of a repository can carry.
    static let otherDenseBytes = bytes(
        architecture: denseArchitecture,
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
        architecture: "dflash", values: dflashDrafterValues,
        trailing: [(dflashTargetLayersKey, integerArray(dflashTargetLayers))])

    /// A drafter with the architecture `dflash` and no
    /// `dflash.target_layers` key, as an older converter writes it, which
    /// mainline llama.cpp does not load as DFlash.
    static let noTargetLayersDFlashDrafterBytes = bytes(architecture: "dflash", values: dflashDrafterValues)

    /// The count of the tokens of the large vocabulary, as Qwen3.5 has.
    private static let largeVocabularyTokenCount = 248_320

    /// The count of the BPE merges of the large vocabulary, as Qwen3.5 has.
    private static let largeVocabularyMergeCount = 247_587

    /// The UTF-8 length of the first token of the large vocabulary.
    private static let shortestTokenLength = 4

    /// The UTF-8 lengths the tokens of the large vocabulary span above the
    /// shortest: the tokens grow longer through the vocabulary, as the
    /// merged tokens of a BPE vocabulary do, so the first megabyte holds
    /// shorter tokens than the average.
    private static let tokenLengthSpan = 16

    /// The UTF-8 length of each merge of the large vocabulary.
    private static let mergeLength = 12

    /// The byte of each character of the strings of the large vocabulary.
    private static let filler = UInt8(ascii: "a")

    /// The size of the chat template of the large vocabulary, in bytes.
    private static let chatTemplateLength = 7_763

    /// A dense model with the tokenizer of Qwen3.5 after its values: the
    /// tokens, their types, the BPE merges and the chat template, in the
    /// order and the counts of the Qwen3.5 GGUF files. Its metadata section
    /// ends near 11 MB, as the one of `Qwen3.5-0.8B-Q8_0.gguf` does.
    static let largeVocabularyBytes = bytes(
        architecture: denseArchitecture,
        values: denseValues,
        trailing: [
            (
                "tokenizer.ggml.tokens",
                stringArray(
                    lengths: (0..<largeVocabularyTokenCount).lazy.map {
                        shortestTokenLength + $0 * tokenLengthSpan / largeVocabularyTokenCount
                    })
            ),
            ("tokenizer.ggml.token_type", signedIntegerArray(count: largeVocabularyTokenCount)),
            ("tokenizer.ggml.merges", stringArray(lengths: repeatElement(mergeLength, count: largeVocabularyMergeCount))),
            ("tokenizer.chat_template", typedString(length: chatTemplateLength)),
        ])

    /// The size of the long chat template, in bytes: three megabytes.
    private static let longChatTemplateLength = 3 << 20

    /// The count of the elements of the large array of each kind: four
    /// megabytes of `INT32` elements, or twelve of short strings.
    private static let largeArrayCount = 1 << 20

    /// The UTF-8 length of each string of the large array of strings.
    private static let largeArrayStringLength = 4

    /// A dense model with a chat template of three megabytes after its
    /// values: a metadata section that runs past the first read in a string,
    /// not in an array.
    static let longChatTemplateBytes = bytes(
        architecture: denseArchitecture,
        values: denseValues,
        trailing: [("tokenizer.chat_template", typedString(length: longChatTemplateLength))])

    /// The count of the scalar values of the header of many values.
    private static let manyValuesCount = 1 << 16

    /// A dense model with 65,536 `UINT32` values after its values, about
    /// 2.2 MB of keys and values with no array.
    static let manyValuesBytes = bytes(
        architecture: denseArchitecture,
        values: denseValues,
        trailing: (0..<manyValuesCount).map { index in
            var typedValue = Data()
            append(integerType, to: &typedValue)
            append(UInt32(index), to: &typedValue)
            return ("general.note.\(index)", typedValue)
        })

    /// A dense model with an array of four megabytes of `INT32` elements
    /// after its values, and no token array.
    static let largeIntegerArrayBytes = bytes(
        architecture: denseArchitecture,
        values: denseValues,
        trailing: [("tokenizer.ggml.token_type", signedIntegerArray(count: largeArrayCount))])

    /// A dense model with an array of about twelve megabytes of short
    /// strings after its values, and no token array.
    static let largeStringArrayBytes = bytes(
        architecture: denseArchitecture,
        values: denseValues,
        trailing: [
            (
                "tokenizer.ggml.merges",
                stringArray(lengths: repeatElement(largeArrayStringLength, count: largeArrayCount))
            )
        ])

    /// A dense model with no training context (`context_length`).
    static let noContextBytes = bytes(
        architecture: denseArchitecture,
        values: ["block_count": denseBlocks, "attention.head_count": denseAttentionHeads])

    /// The key after the prefix of the architecture of the decision type of
    /// a decision model: `<arch>.decision.type`.
    private static let decisionTypeKey = "decision.type"

    /// A dense model with a `STRING` decision type after its values, as a
    /// decision GGUF of llama.cpp has.
    ///
    /// - Parameters:
    ///   - decisionType: The text of the decision type, for example
    ///     `"h2o-lightning"`.
    ///   - keyArchitecture: The architecture of the prefix of the key. The
    ///     default is ``denseArchitecture``, the architecture of the model.
    /// - Returns: The bytes.
    static func decisionBytes(decisionType: String, keyArchitecture: String = denseArchitecture) -> Data {
        var typedValue = Data()
        append(textType, to: &typedValue)
        append(text: decisionType, to: &typedValue)
        return bytes(
            architecture: denseArchitecture, values: denseValues,
            trailing: [("\(keyArchitecture).\(decisionTypeKey)", typedValue)])
    }

    /// The `UINT32` value of the decision type of
    /// ``integerDecisionTypeBytes``.
    private static let integerDecisionType: UInt32 = 12

    /// A dense model whose decision type is a `UINT32` value, not a
    /// `STRING` value.
    static let integerDecisionTypeBytes: Data = {
        var typedValue = Data()
        append(integerType, to: &typedValue)
        append(integerDecisionType, to: &typedValue)
        return bytes(
            architecture: denseArchitecture, values: denseValues,
            trailing: [("\(denseArchitecture).\(decisionTypeKey)", typedValue)])
    }()

    /// Builds a `STRING` value of filler characters, with its `gguf_type`.
    ///
    /// - Parameter length: The UTF-8 length of the string.
    /// - Returns: The bytes.
    private static func typedString(length: Int) -> Data {
        var data = Data()
        append(textType, to: &data)
        append(fillerLength: length, to: &data)
        return data
    }

    /// Builds an `ARRAY` value of `STRING` elements of filler characters,
    /// with its `gguf_type`.
    ///
    /// - Parameter lengths: The UTF-8 length of each string.
    /// - Returns: The bytes.
    private static func stringArray(lengths: some Collection<Int>) -> Data {
        var data = arrayHeader(elementType: textType, count: lengths.count)
        for length in lengths {
            append(fillerLength: length, to: &data)
        }
        return data
    }

    /// Builds an `ARRAY` value of zero `INT32` elements, with its
    /// `gguf_type`.
    ///
    /// - Parameter count: The count of the elements.
    /// - Returns: The bytes.
    private static func signedIntegerArray(count: Int) -> Data {
        var data = arrayHeader(elementType: signedIntegerType, count: count)
        data.append(Data(count: count * MemoryLayout<Int32>.size))
        return data
    }

    /// Builds the start of an `ARRAY` value: its `gguf_type`, the
    /// `gguf_type` of its elements and their 64-bit count.
    ///
    /// - Parameters:
    ///   - elementType: The `gguf_type` of the elements.
    ///   - count: The count of the elements.
    /// - Returns: The bytes, which the elements follow.
    private static func arrayHeader(elementType: UInt32, count: Int) -> Data {
        var data = Data()
        append(arrayType, to: &data)
        append(elementType, to: &data)
        append(UInt64(count), to: &data)
        return data
    }

    /// Appends a GGUF string of filler characters: its 64-bit length and its
    /// bytes.
    ///
    /// - Parameters:
    ///   - length: The UTF-8 length of the string.
    ///   - data: The bytes to append to.
    private static func append(fillerLength length: Int, to data: inout Data) {
        append(stringBytes: Data(repeating: filler, count: length), to: &data)
    }

    /// Appends a GGUF string: its 64-bit length and its UTF-8 bytes.
    ///
    /// - Parameters:
    ///   - text: The string.
    ///   - data: The bytes to append to.
    private static func append(text: String, to data: inout Data) {
        append(stringBytes: Data(text.utf8), to: &data)
    }

    /// Appends the UTF-8 bytes of a GGUF string after their 64-bit length.
    ///
    /// - Parameters:
    ///   - utf8: The UTF-8 bytes of the string.
    ///   - data: The bytes to append to.
    private static func append(stringBytes utf8: Data, to data: inout Data) {
        append(UInt64(utf8.count), to: &data)
        data.append(utf8)
    }

    /// Builds an `ARRAY` value of `UINT32` elements, with its `gguf_type`.
    ///
    /// - Parameter integers: The elements.
    /// - Returns: The bytes.
    private static func integerArray(_ integers: [UInt32]) -> Data {
        var data = arrayHeader(elementType: integerType, count: integers.count)
        for integer in integers {
            append(integer, to: &data)
        }
        return data
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
