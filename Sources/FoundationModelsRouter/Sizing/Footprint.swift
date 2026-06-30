import Foundation

/// The raw resident-memory estimate for one model, as a pure function of its
/// quantized weight size, its attention architecture, and the working context.
///
/// The estimate is `weightBytes + kvBytes(context)`:
///
/// - `weightBytes` is the sum of the repo's `*.safetensors` sizes. Quantized
///   weights load ≈ 1:1 from disk, so that sum is the resident weight bytes
///   directly — no need to derive them from the quant bit-width.
/// - `kvBytes` is the fp16 key/value cache the model materializes to decode
///   `context` tokens, sized from its attention shape.
///
/// Two deliberate omissions keep this layer pure:
///
/// - Activation, compute, and framework **overhead is not modeled here**. The
///   conservative `× 1.2` margin applied at the fit step absorbs it; these
///   functions return the *raw* estimate.
/// - The KV cache is **fp16 regardless of weight quant** (2 bytes per element),
///   because the cache is allocated in fp16 even when the weights are quantized.
///
/// The type is pure value data — `Sendable` and `Equatable`, no dependency on
/// MLX or any I/O — so the footprint arithmetic is testable with injected values.
public struct Footprint: Sendable, Equatable {
    /// Bytes per cached element. The KV cache is fp16 (2 bytes) irrespective of
    /// the weight quantization.
    private static let cacheElementBytes: Int64 = 2

    /// The two cache tensors materialized per token: keys and values.
    private static let keyValueTensors: Int64 = 2

    /// Resident weight bytes — `Σ size(*.safetensors)`, ≈ 1:1 from disk.
    public let weightBytes: Int64

    /// Number of transformer layers (`num_hidden_layers`). The KV cache is
    /// materialized once per layer. Zero for models without an autoregressive
    /// cache (see ``embedder(weightBytes:)``).
    public let layers: Int

    /// Effective key/value heads: `num_key_value_heads` under grouped-query
    /// attention, or `num_attention_heads` for multi-head attention. Resolved at
    /// construction; the GQA fallback lives in the config-shaped initializer.
    public let kvHeads: Int

    /// Per-head dimension: `head_dim`, or `hidden_size / num_attention_heads`
    /// when `head_dim` is absent. Resolved at construction.
    public let headDim: Int

    /// Creates a footprint from already-resolved architecture values.
    ///
    /// - Parameters:
    ///   - weightBytes: Resident weight bytes (`Σ *.safetensors`).
    ///   - layers: Transformer layer count (`num_hidden_layers`).
    ///   - kvHeads: Effective key/value head count (post GQA fallback).
    ///   - headDim: Per-head dimension (post `head_dim` fallback).
    public init(weightBytes: Int64, layers: Int, kvHeads: Int, headDim: Int) {
        self.weightBytes = weightBytes
        self.layers = layers
        self.kvHeads = kvHeads
        self.headDim = headDim
    }

    /// Creates a footprint from HuggingFace-config-shaped architecture fields,
    /// applying the two standard fallbacks:
    ///
    /// - **GQA fallback** — when `num_key_value_heads` is absent, multi-head
    ///   attention is assumed and `num_attention_heads` is used instead.
    /// - **head-dim fallback** — when `head_dim` is absent, it is derived as
    ///   `hidden_size / num_attention_heads`.
    ///
    /// - Parameters:
    ///   - weightBytes: Resident weight bytes (`Σ *.safetensors`).
    ///   - numHiddenLayers: Transformer layer count (`num_hidden_layers`).
    ///   - numAttentionHeads: Query head count (`num_attention_heads`).
    ///   - numKeyValueHeads: Key/value head count (`num_key_value_heads`); pass
    ///     `nil` for multi-head attention to fall back to `numAttentionHeads`.
    ///   - headDim: Per-head dimension (`head_dim`); pass `nil` to derive it
    ///     from `hiddenSize`.
    ///   - hiddenSize: Model hidden size (`hidden_size`); used only to derive
    ///     `headDim` when `headDim` is `nil`. Required in that case.
    public init(
        weightBytes: Int64,
        numHiddenLayers: Int,
        numAttentionHeads: Int,
        numKeyValueHeads: Int? = nil,
        headDim: Int? = nil,
        hiddenSize: Int? = nil
    ) {
        let resolvedKVHeads = numKeyValueHeads ?? numAttentionHeads
        let resolvedHeadDim: Int
        if let headDim {
            resolvedHeadDim = headDim
        } else if let hiddenSize {
            resolvedHeadDim = hiddenSize / numAttentionHeads
        } else {
            preconditionFailure("Footprint needs head_dim or hidden_size to derive the per-head dimension")
        }
        self.init(
            weightBytes: weightBytes,
            layers: numHiddenLayers,
            kvHeads: resolvedKVHeads,
            headDim: resolvedHeadDim
        )
    }

    /// A footprint for an embedder, which has **no autoregressive KV cache**.
    ///
    /// Modeled with zero KV dimensions so its ``kvBytes(context:)`` is always
    /// `0` and its ``footprint(context:)`` reduces to `weightBytes` — a single
    /// code path, no special-casing.
    ///
    /// - Parameter weightBytes: Resident weight bytes (`Σ *.safetensors`).
    /// - Returns: A footprint whose memory is its weights alone.
    public static func embedder(weightBytes: Int64) -> Footprint {
        Footprint(weightBytes: weightBytes, layers: 0, kvHeads: 0, headDim: 0)
    }

    /// The fp16 key/value cache bytes to decode `context` tokens.
    ///
    /// `2 × layers × context × kvHeads × headDim × 2` — the leading `2` is the
    /// key and value tensors, the trailing `2` is fp16 bytes per element.
    ///
    /// - Parameter context: Working context size in tokens.
    /// - Returns: KV cache bytes; `0` for models without a cache (embedders).
    public func kvBytes(context: Int) -> Int64 {
        Self.keyValueTensors
            * Int64(layers)
            * Int64(context)
            * Int64(kvHeads)
            * Int64(headDim)
            * Self.cacheElementBytes
    }

    /// The raw resident-memory estimate: `weightBytes + kvBytes(context)`.
    ///
    /// Overhead is intentionally excluded — the `× 1.2` fit-time margin absorbs
    /// it — so this is a raw estimate, not a budget-ready figure.
    ///
    /// - Parameter context: Working context size in tokens.
    /// - Returns: Estimated resident bytes for the model at `context`.
    public func footprint(context: Int) -> Int64 {
        weightBytes + kvBytes(context: context)
    }
}
