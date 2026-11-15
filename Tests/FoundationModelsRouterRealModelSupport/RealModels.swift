import FoundationModelsRouter

/// The real `mlx-community` models the gated integration suite resolves
/// against actual hardware.
///
/// The `standard` slot names Qwen 3.8 27B, the standard model of the product.
/// 48 of its 64 layers are linear attention, whose recurrent cache cannot
/// rewind. The MLX fork keeps a checkpoint of those caches at the end of each
/// prompt (`PromptCacheCheckpoint`), so a next answer still reuses the
/// prefix, and the prompt-cache suites hold on it.
///
/// The slot named Muse-Glimmer-30B until 2026-11-15 (task ^467gchm). The
/// gated suites run only on a runner labelled `large-memory` (see
/// `.github/workflows/ci.yml`), so the slot runs the model the product runs.
public enum RealModels {
    /// `.standard` slot: Qwen 3.8 27B in the `mxfp4` quantization, the same
    /// reference as `StandardModels.qwen38`.
    public static let standard: ModelRef = "mlx-community/Qwen3.8-27B-mxfp4"

    /// `.flash` slot: Qwen3 4B, dense, in 4 bits.
    ///
    /// The flash slot names a different, smaller model than ``standard``, so
    /// the gated suites run two generation models.
    public static let flash: ModelRef = "mlx-community/Qwen3-4B-4bit"

    /// `.embedding` slot: small enough that co-residency alongside the
    /// generation models above is never the constraint.
    public static let embedding: ModelRef = "mlx-community/Qwen3-Embedding-0.6B-4bit-DWQ"

    /// The context budget every gated suite requests when loading
    /// `standard`/`flash`. The former tiny profile's `512`/`2048`
    /// budgets were too small even for the SmolLM suite's own cumulative
    /// prompts of many messages (a real run overflowed a 2048-token structural
    /// cap); the window of each model of this enum is far larger than this.
    public static let context = 8192
}
