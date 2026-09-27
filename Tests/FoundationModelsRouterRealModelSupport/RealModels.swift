import FoundationModelsRouter

/// The real (non-tiny) `mlx-community` models the gated integration suite
/// resolves against actual hardware, replacing the former `SmolLM-135M`
/// placeholder that every file in that target used to share.
///
/// The `standard` slot names Muse Glimmer, the general substitute for the
/// Qwen3.6 pair this suite used before. Qwen3.5/3.6 give their linear/GDN
/// layers a `MambaCache`, which is not trimmable, and one non-trimmable
/// entry stops prefix reuse for the whole cache list — so those models lost
/// prompt caching. Muse Glimmer has no recurrent layers: every entry in its
/// cache list (a `RotatingKVCache` for the sliding-attention layers, a
/// `StandardKVCache` for the rest) is trimmable, and its ATEM tool protocol
/// carries a purpose-built reuse rule for tool continuations.
///
/// Muse Glimmer is registered in `VLMModelFactory`, so the router links
/// `MLXVLM` to put that factory in the runtime registry (see `Package.swift`
/// and `LiveModelLoader.swift`). It is a vision-language model, but the
/// text-only path is deliberate, not accidental: its processor returns a
/// pure-text input when no image is supplied.
public enum RealModels {
    /// `.standard` slot: Muse Glimmer, a dense text-plus-vision model this
    /// suite drives text-only, in the `mxfp4` quantization.
    ///
    /// `mxfp4` replaced the affine `4bit` repository on 2026-09-08. The two
    /// hold the same weights at the same bit width; `mxfp4` stores a shared
    /// floating-point scale for each block of 32, which MLX decodes through
    /// its own `fp_quantized` kernels. The Qwen 3.8 tool-answer suite drives
    /// the same quantization, so every large model this package loads reads
    /// the same weight format.
    public static let standard: ModelRef = "mlx-community/Muse-Glimmer-30B-mxfp4"

    /// `.flash` slot: Qwen3 4B, a small model the gated suites already load
    /// (see `PromptCacheBudgetIntegrationTests` and
    /// `RealToolAnswerComparisonTests`).
    ///
    /// The `standard` and `flash` slots of one resolved profile never use
    /// the same model: a synchronous tool call runs a selection call on
    /// `flash` inside an open submission on `standard`, and each model has
    /// one FIFO work queue, so one model in both slots would wait on itself.
    /// The published Muse Glimmer repositories differ only in quantization,
    /// so the flash slot names a different, smaller model. Qwen3 4B has no
    /// recurrent layers, so its whole cache list is trimmable, as
    /// ``standard``'s is.
    public static let flash: ModelRef = "mlx-community/Qwen3-4B-4bit"

    /// `.embedding` slot: unchanged. Muse Glimmer is not an embedder, and
    /// this repository is small enough that co-residency alongside the
    /// generation model above is never the constraint.
    public static let embedding: ModelRef = "mlx-community/Qwen3-Embedding-0.6B-4bit-DWQ"

    /// The context budget every gated suite requests when loading
    /// `standard`/`flash`. The former tiny profile's `512`/`2048`
    /// budgets were too small even for the SmolLM suite's own cumulative
    /// prompts of many messages (a real run overflowed a 2048-token structural
    /// cap); Muse Glimmer's own window is far larger than this.
    public static let context = 8192
}
