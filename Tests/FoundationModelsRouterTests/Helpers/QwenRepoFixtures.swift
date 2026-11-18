import Foundation

@testable import FoundationModelsRouter

/// The sizing metadata of real Qwen repositories on the Hugging Face Hub:
/// the sizing keys of each `config.json` and the size of each weight shard.
/// A sizing test serves them from a stub metadata source, so it reads no
/// network and downloads no model.
enum QwenRepoFixtures {
    /// Every how many layers a Qwen3.5-family model has a full-attention
    /// layer. The other layers are linear attention.
    private static let fullAttentionInterval = 4

    /// The K and V heads of each attention layer of a Qwen3.5-family model.
    private static let qwen35KeyValueHeads = 4

    /// The width of one K head and of one V head of a Qwen3.5-family model.
    private static let qwen35HeadWidth = 256

    /// The native window of a Qwen3.5-family model, in tokens.
    private static let qwen35NativeWindow = 262_144

    /// The sizing keys of a Qwen3.5-family `config.json`: one full-attention
    /// layer in four, the other layers linear attention.
    ///
    /// - Parameters:
    ///   - layers: The `num_hidden_layers`.
    ///   - heads: The `num_attention_heads`.
    ///   - hidden: The `hidden_size`.
    /// - Returns: The bytes of the config.
    private static func qwen35Config(layers: Int, heads: Int, hidden: Int) -> Data {
        let layerTypes = (0..<layers).map {
            ($0 + 1) % fullAttentionInterval == 0 ? #""full_attention""# : #""linear_attention""#
        }
        return Data(
            """
            {"model_type": "qwen3_5", "text_config": {"num_hidden_layers": \(layers), "num_attention_heads": \(heads),
             "num_key_value_heads": \(qwen35KeyValueHeads), "head_dim": \(qwen35HeadWidth), "hidden_size": \(hidden),
             "max_position_embeddings": \(qwen35NativeWindow),
             "layer_types": [\(layerTypes.joined(separator: ","))]}}
            """.utf8)
    }

    /// The sizing keys of a Qwen3 `config.json`.
    ///
    /// - Parameters:
    ///   - layers: The `num_hidden_layers`.
    ///   - heads: The `num_attention_heads`.
    ///   - hidden: The `hidden_size`.
    ///   - maxPositions: The `max_position_embeddings`.
    /// - Returns: The bytes of the config.
    private static func qwen3Config(layers: Int, heads: Int, hidden: Int, maxPositions: Int) -> Data {
        Data(
            """
            {"model_type": "qwen3", "num_hidden_layers": \(layers), "num_attention_heads": \(heads),
             "num_key_value_heads": \(Qwen3.keyValueHeads), "head_dim": \(Qwen3.headWidth), "hidden_size": \(hidden),
             "max_position_embeddings": \(maxPositions)}
            """.utf8)
    }

    /// The values of the Qwen3 models: the keys of each `config.json` that
    /// all Qwen3 models share.
    private enum Qwen3 {
        /// The `num_key_value_heads` of each Qwen3 config.
        static let keyValueHeads = 8

        /// The `head_dim` of each Qwen3 config.
        static let headWidth = 128
    }

    /// The values of `mlx-community/Qwen3.8-27B-4bit` and of its MTP head
    /// on the Hub: the keys of the `config.json` and the size of each
    /// weight shard.
    private enum Qwen38TwentySevenB {
        /// The `num_hidden_layers` of the config.
        static let layers = 64

        /// The `num_attention_heads` of the config.
        static let heads = 24

        /// The `hidden_size` of the config.
        static let hidden = 5_120

        /// The size of the first weight shard, in bytes.
        static let firstShardBytes: Int64 = 5_343_268_662

        /// The size of the second weight shard, in bytes.
        static let secondShardBytes: Int64 = 5_354_185_130

        /// The size of the third weight shard, in bytes.
        static let thirdShardBytes: Int64 = 5_357_087_557

        /// The size of the one weight shard of the MTP head, in bytes.
        static let mtpShardBytes: Int64 = 238_934_137
    }

    /// The values of `mlx-community/Qwen3.5-9B-4bit` and of its MTP head on
    /// the Hub on 2026-11-18: the keys of the `config.json` and the size of
    /// each weight shard.
    private enum Qwen35NineB {
        /// The `num_hidden_layers` of the config.
        static let layers = 32

        /// The `num_attention_heads` of the config.
        static let heads = 16

        /// The `hidden_size` of the config.
        static let hidden = 4_096

        /// The size of the first weight shard, in bytes.
        static let firstShardBytes: Int64 = 5_349_771_222

        /// The size of the second weight shard, in bytes.
        static let secondShardBytes: Int64 = 600_449_850

        /// The size of the one weight shard of the MTP head, in bytes.
        static let mtpShardBytes: Int64 = 136_884_332
    }

    /// The values of `mlx-community/Qwen3-4B-4bit` on the Hub: the keys of
    /// the `config.json` and the size of the weight shard.
    private enum Qwen3FourB {
        /// The `num_hidden_layers` of the config.
        static let layers = 36

        /// The `num_attention_heads` of the config.
        static let heads = 32

        /// The `hidden_size` of the config.
        static let hidden = 2_560

        /// The `max_position_embeddings` of the config.
        static let maxPositions = 40_960

        /// The size of the one weight shard, in bytes.
        static let shardBytes: Int64 = 2_263_022_529
    }

    /// The values of `mlx-community/Qwen3-Embedding-0.6B-4bit-DWQ` on the
    /// Hub: the keys of the `config.json` and the size of the weight shard.
    private enum Qwen3Embedding {
        /// The `num_hidden_layers` of the config.
        static let layers = 28

        /// The `num_attention_heads` of the config.
        static let heads = 16

        /// The `hidden_size` of the config.
        static let hidden = 1_024

        /// The `max_position_embeddings` of the config.
        static let maxPositions = 32_768

        /// The size of the one weight shard, in bytes.
        static let shardBytes: Int64 = 335_296_756
    }

    /// The sizing keys of the Qwen3.8 27B `config.json` and of its MTP head.
    private static let qwen38Config = qwen35Config(
        layers: Qwen38TwentySevenB.layers, heads: Qwen38TwentySevenB.heads, hidden: Qwen38TwentySevenB.hidden)

    /// The sizing keys of the Qwen3.5 9B `config.json` and of its MTP head.
    private static let qwen35NineBConfig = qwen35Config(
        layers: Qwen35NineB.layers, heads: Qwen35NineB.heads, hidden: Qwen35NineB.hidden)

    /// `mlx-community/Qwen3.8-27B-4bit`, with the weight sizes of the Hugging
    /// Face cache of 2026-10-29.
    static let qwen38TwentySevenB4Bit = RawRepoMetadata(
        configJSON: qwen38Config,
        treeJSON: HubTreeListing.shards([
            Qwen38TwentySevenB.firstShardBytes, Qwen38TwentySevenB.secondShardBytes,
            Qwen38TwentySevenB.thirdShardBytes,
        ]))

    /// `mlx-community/Qwen3.8-27B-MTP-4bit`, the MTP head of
    /// ``qwen38TwentySevenB4Bit``.
    static let qwen38TwentySevenBMTP4Bit = RawRepoMetadata(
        configJSON: qwen38Config, treeJSON: HubTreeListing.shards([Qwen38TwentySevenB.mtpShardBytes]))

    /// `mlx-community/Qwen3.5-9B-4bit`, with the weight sizes of the Hub on
    /// 2026-11-18.
    static let qwen35NineB4Bit = RawRepoMetadata(
        configJSON: qwen35NineBConfig,
        treeJSON: HubTreeListing.shards([Qwen35NineB.firstShardBytes, Qwen35NineB.secondShardBytes]))

    /// `mlx-community/Qwen3.5-9B-MTP-4bit`, the MTP head of
    /// ``qwen35NineB4Bit``, with the weight size of the Hub on 2026-11-18.
    static let qwen35NineBMTP4Bit = RawRepoMetadata(
        configJSON: qwen35NineBConfig, treeJSON: HubTreeListing.shards([Qwen35NineB.mtpShardBytes]))

    /// `mlx-community/Qwen3-4B-4bit`.
    static let qwen3FourB4Bit = RawRepoMetadata(
        configJSON: qwen3Config(
            layers: Qwen3FourB.layers, heads: Qwen3FourB.heads, hidden: Qwen3FourB.hidden,
            maxPositions: Qwen3FourB.maxPositions),
        treeJSON: HubTreeListing.shards([Qwen3FourB.shardBytes]))

    /// `mlx-community/Qwen3-Embedding-0.6B-4bit-DWQ`.
    static let qwen3Embedding4Bit = RawRepoMetadata(
        configJSON: qwen3Config(
            layers: Qwen3Embedding.layers, heads: Qwen3Embedding.heads, hidden: Qwen3Embedding.hidden,
            maxPositions: Qwen3Embedding.maxPositions),
        treeJSON: HubTreeListing.shards([Qwen3Embedding.shardBytes]))
}
