import FoundationModelsRouter

/// The real `mlx-community` models the gated integration suite resolves
/// against actual hardware.
///
/// Both generation slots name dense Qwen3 models. Qwen3.5/3.6/3.8 give their
/// linear/GDN layers a `MambaCache`, which is not trimmable, and one
/// non-trimmable entry stops prefix reuse for the whole cache list, so those
/// models lose prompt caching. Every cache entry of a dense Qwen3 is
/// trimmable, so the prompt-cache suites can reuse a prefix.
///
/// The slots named Muse-Glimmer-30B until 2026-11-15. The CI runner
/// `mini-01` has 32 GB and decodes a 30B model at about 6 tokens a second,
/// so the suites of this slot alone took more than ten minutes there. The
/// suites test the router, not the model, and small models run them in a
/// fraction of that time.
public enum RealModels {
    /// `.standard` slot: Qwen3 4B, dense, in 4 bits.
    public static let standard: ModelRef = "mlx-community/Qwen3-4B-4bit"

    /// `.flash` slot: Qwen3 1.7B, dense, in 4 bits.
    ///
    /// The flash slot names a different, smaller model than ``standard``, so
    /// the gated suites run two generation models.
    public static let flash: ModelRef = "mlx-community/Qwen3-1.7B-4bit"

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
