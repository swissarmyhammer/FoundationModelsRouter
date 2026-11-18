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
             "num_key_value_heads": 8, "head_dim": 128, "hidden_size": \(hidden), "max_position_embeddings": \(maxPositions)}
            """.utf8)
    }

    /// The sizing keys of the Qwen3.8 27B `config.json` and of its MTP head:
    /// 64 layers.
    private static let qwen38Config = qwen35Config(layers: 64, heads: 24, hidden: 5_120)

    /// The sizing keys of the Qwen3.5 9B `config.json` and of its MTP head:
    /// 32 layers.
    private static let qwen35NineBConfig = qwen35Config(layers: 32, heads: 16, hidden: 4_096)

    /// `mlx-community/Qwen3.8-27B-4bit`, with the weight sizes of the Hugging
    /// Face cache of 2026-10-29.
    static let qwen38TwentySevenB4Bit = RawRepoMetadata(
        configJSON: qwen38Config, treeJSON: HubTreeListing.shards([5_343_268_662, 5_354_185_130, 5_357_087_557]))

    /// `mlx-community/Qwen3.8-27B-MTP-4bit`, the MTP head of
    /// ``qwen38TwentySevenB4Bit``.
    static let qwen38TwentySevenBMTP4Bit = RawRepoMetadata(
        configJSON: qwen38Config, treeJSON: HubTreeListing.shards([238_934_137]))

    /// `mlx-community/Qwen3.5-9B-4bit`, with the weight sizes of the Hub on
    /// 2026-11-18.
    static let qwen35NineB4Bit = RawRepoMetadata(
        configJSON: qwen35NineBConfig, treeJSON: HubTreeListing.shards([5_349_771_222, 600_449_850]))

    /// `mlx-community/Qwen3.5-9B-MTP-4bit`, the MTP head of
    /// ``qwen35NineB4Bit``, with the weight size of the Hub on 2026-11-18.
    static let qwen35NineBMTP4Bit = RawRepoMetadata(
        configJSON: qwen35NineBConfig, treeJSON: HubTreeListing.shards([136_884_332]))

    /// `mlx-community/Qwen3-4B-4bit`.
    static let qwen3FourB4Bit = RawRepoMetadata(
        configJSON: qwen3Config(layers: 36, heads: 32, hidden: 2_560, maxPositions: 40_960),
        treeJSON: HubTreeListing.shards([2_263_022_529]))

    /// `mlx-community/Qwen3-Embedding-0.6B-4bit-DWQ`.
    static let qwen3Embedding4Bit = RawRepoMetadata(
        configJSON: qwen3Config(layers: 28, heads: 16, hidden: 1_024, maxPositions: 32_768),
        treeJSON: HubTreeListing.shards([335_296_756]))
}
