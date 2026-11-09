import Foundation

/// The raw resident-memory estimate for one model: `weightBytes + kvBytes(context)`.
///
/// The KV cache is fp16 regardless of weight quantization. Overhead is not
/// modeled. The fit step compares this raw estimate with the budget.
///
/// An MLX model is sized from its `config.json`, layer by layer
/// (``Cache/attention(layers:kvHeads:headDim:)``). That estimate does not
/// size recurrent state. A model with recurrent layers (Mamba or another
/// state-space model, such as the linear layers of Qwen3.5 and Qwen3.6) keeps
/// a fixed-size state for each such layer in place of a KV cache.
/// ``kvBytes(context:)`` counts every layer it is given as an attention
/// layer, so the estimate is wrong for such a model, and the prompt-cache
/// budget that the pool computes from it is wrong by the same amount.
///
/// A GGUF model is sized from its GGUF header (``Cache/gguf(_:)``), as
/// llama.cpp allocates its context: the padded KV cache of the blocks with a
/// KV cache, and the recurrent state of a hybrid model.
struct Footprint: Sendable, Equatable {
    /// How the memory of the context of a model grows with the context.
    enum Cache: Sendable, Equatable {
        /// An fp16 KV cache of `layers` layers of `kvHeads` K and V heads of
        /// `headDim` elements: an MLX model, or an embedder with no layer.
        case attention(layers: Int, kvHeads: Int, headDim: Int)

        /// The context of a GGUF model, as its header sizes it.
        case gguf(GGUFCacheSizing)
    }

    /// Bytes per cached element (fp16).
    private static let cacheElementBytes: Int64 = 2

    /// The two cache tensors per token: keys and values.
    private static let keyValueTensors: Int64 = 2

    /// Resident weight bytes: the weight files of the model.
    let weightBytes: Int64

    /// How the memory of the context grows with the context.
    let cache: Cache

    /// Creates a footprint from already-resolved architecture values.
    ///
    /// - Parameters:
    ///   - weightBytes: The resident weight bytes.
    ///   - layers: The count of the layers with a KV cache. Zero for an embedder.
    ///   - kvHeads: The effective key/value heads, with the GQA fallback applied.
    ///   - headDim: The per-head dimension, with the `head_dim` fallback applied.
    init(weightBytes: Int64, layers: Int, kvHeads: Int, headDim: Int) {
        self.weightBytes = weightBytes
        self.cache = .attention(layers: layers, kvHeads: kvHeads, headDim: headDim)
    }

    /// Creates the footprint of a GGUF model.
    ///
    /// - Parameters:
    ///   - weightBytes: The bytes of the shards of the model and of its projector.
    ///   - cache: The context of the model, as its header sizes it.
    init(weightBytes: Int64, cache: GGUFCacheSizing) {
        self.weightBytes = weightBytes
        self.cache = .gguf(cache)
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
    ///
    /// A Core ML model that runs on the Apple Neural Engine (ANE) is counted in
    /// full against the memory budget. The ANE has no memory of its own. On
    /// Apple silicon the CPU, the GPU and the ANE share one pool of unified
    /// memory. The compiled model weights are mapped into that same pool, so an
    /// ANE model takes bytes that an MLX model could use. The count is
    /// `weightBytes`, the size of the Core ML package, with no discount for the
    /// ANE. A discount would let joint fit choose a set of models that does not
    /// fit in memory. The cost of this rule is that fit can be too strict, but
    /// the system never commits more than the host has.
    static func embedder(weightBytes: Int64) -> Footprint {
        Footprint(weightBytes: weightBytes, layers: 0, kvHeads: 0, headDim: 0)
    }

    /// The bytes of the context of the model at `context` tokens.
    ///
    /// For an MLX model it is the fp16 KV cache:
    /// `2 × layers × context × kvHeads × headDim × 2`. For a GGUF model it is
    /// ``GGUFCacheSizing/bytes(context:)``: the padded KV cache and the
    /// recurrent state.
    ///
    /// - Parameter context: The context, in tokens.
    /// - Returns: The bytes; `0` for an embedder.
    func kvBytes(context: Int) -> Int64 {
        switch cache {
        case .attention(let layers, let kvHeads, let headDim):
            Self.keyValueTensors
                * Int64(layers)
                * Int64(context)
                * Int64(kvHeads)
                * Int64(headDim)
                * Self.cacheElementBytes
        case .gguf(let sizing):
            sizing.bytes(context: context)
        }
    }

    /// The raw resident-memory estimate: `weightBytes + kvBytes(context)`. Overhead is excluded.
    func footprint(context: Int) -> Int64 {
        weightBytes + kvBytes(context: context)
    }
}
