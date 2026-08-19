import FoundationModelsRouter

/// The real (non-tiny) `mlx-community` models the gated integration suite
/// resolves against actual hardware, replacing the former `SmolLM-135M`
/// placeholder that every file in that target used to share.
///
/// Both generation slots name Muse Glimmer, the general substitute for the
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
    /// suite drives text-only.
    public static let standard: ModelRef = "mlx-community/Muse-Glimmer-30B-4bit"

    /// `.flash` slot: Muse Glimmer again — only one Muse Glimmer repository
    /// is published, so the two generation slots name the same model.
    ///
    /// The router pools resident models by `(ModelRef, role)`, and both
    /// slots ask for the same reference at the same `context`, so they share
    /// one resident container instead of loading the weights twice. The
    /// suite's slot-differentiation and co-residency assertions therefore
    /// compare this model with itself; they still prove the routing path,
    /// but they can no longer tell two distinct models apart.
    public static let flash: ModelRef = "mlx-community/Muse-Glimmer-30B-4bit"

    /// `.embedding` slot: unchanged. Muse Glimmer is not an embedder, and
    /// this repository is small enough that co-residency alongside the
    /// generation model above is never the constraint.
    public static let embedding: ModelRef = "mlx-community/Qwen3-Embedding-0.6B-4bit-DWQ"

    /// The context budget every gated suite requests when loading
    /// `standard`/`flash`. The former tiny profile's `512`/`2048`
    /// budgets were too small even for the SmolLM suite's own cumulative
    /// multi-turn prompts (a real run overflowed a 2048-token structural
    /// cap); Muse Glimmer's own window is far larger than this.
    public static let context = 8192
}
