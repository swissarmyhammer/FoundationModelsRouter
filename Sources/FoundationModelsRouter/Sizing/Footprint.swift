import Foundation

/// The raw resident-memory estimate for one model: `weightBytes + kvBytes(context)`.
///
/// The KV cache is fp16 regardless of weight quantization. Overhead is not
/// modeled here; the fit step applies its own margin.
struct Footprint: Sendable, Equatable {
    /// Bytes per cached element (fp16).
    private static let cacheElementBytes: Int64 = 2

    /// The two cache tensors per token: keys and values.
    private static let keyValueTensors: Int64 = 2

    /// Resident weight bytes — `Σ size(*.safetensors)`.
    let weightBytes: Int64

    /// Number of transformer layers with a KV cache. Zero for an embedder.
    let layers: Int

    /// Effective key/value heads, with the GQA fallback applied.
    let kvHeads: Int

    /// Per-head dimension, with the `head_dim` fallback applied.
    let headDim: Int

    /// Creates a footprint from already-resolved architecture values.
    init(weightBytes: Int64, layers: Int, kvHeads: Int, headDim: Int) {
        self.weightBytes = weightBytes
        self.layers = layers
        self.kvHeads = kvHeads
        self.headDim = headDim
    }

    /// Creates a footprint from config-shaped fields and applies the fallbacks:
    /// a `nil` `numKeyValueHeads` uses `numAttentionHeads`, and a `nil` `headDim`
    /// is derived as `hiddenSize / numAttentionHeads`. One of `headDim` or
    /// `hiddenSize` is required.
    init(
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

    /// A footprint for an embedder, which has no KV cache. Its memory is its weights alone.
    static func embedder(weightBytes: Int64) -> Footprint {
        Footprint(weightBytes: weightBytes, layers: 0, kvHeads: 0, headDim: 0)
    }

    /// The fp16 KV cache bytes to decode `context` tokens:
    /// `2 × layers × context × kvHeads × headDim × 2`.
    ///
    /// - Returns: KV cache bytes; `0` for an embedder.
    func kvBytes(context: Int) -> Int64 {
        Self.keyValueTensors
            * Int64(layers)
            * Int64(context)
            * Int64(kvHeads)
            * Int64(headDim)
            * Self.cacheElementBytes
    }

    /// The raw resident-memory estimate: `weightBytes + kvBytes(context)`. Overhead is excluded.
    func footprint(context: Int) -> Int64 {
        weightBytes + kvBytes(context: context)
    }
}
