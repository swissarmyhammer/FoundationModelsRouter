import FoundationModelsRouter

/// The real (non-tiny) `mlx-community` models the gated integration suite
/// resolves against actual hardware, replacing the former `SmolLM-135M`
/// placeholder that every file in this target used to share.
///
/// `standard` and `flash` are deliberately two distinct, capable models
/// (rather than one tiny repo filling both slots) so the suite's
/// slot-differentiation assertions have something real to tell apart, and so
/// tool-calling/multi-turn recall — capabilities a 135M-parameter toy model
/// cannot reliably demonstrate — are actually exercised.
enum RealModels {
    /// `.standard` slot: a dense causal LM.
    static let standard: ModelRef = "mlx-community/Qwen3.6-27B-mxfp4"

    /// `.flash` slot: a mixture-of-experts causal LM with few active
    /// parameters per token despite a larger total parameter count than
    /// `standard` — the "fast" model.
    static let flash: ModelRef = "mlx-community/Qwen3.6-35B-A3B-mxfp4"

    /// `.embedding` slot: unchanged from the former tiny profile — small
    /// enough that co-residency alongside either generation model above is
    /// never the constraint.
    static let embedding: ModelRef = "mlx-community/Qwen3-Embedding-0.6B-4bit-DWQ"

    /// The context budget every gated suite in this target requests when
    /// loading `standard`/`flash`. The former tiny profile's `512`/`2048`
    /// budgets were too small even for the SmolLM suite's own cumulative
    /// multi-turn prompts (a real run overflowed a 2048-token structural
    /// cap); real Qwen3.6 models comfortably exceed this.
    static let context = 8192
}
