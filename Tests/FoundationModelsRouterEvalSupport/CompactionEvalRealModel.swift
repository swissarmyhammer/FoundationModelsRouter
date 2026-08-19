import FoundationModelsRouter

/// The real (non-tiny) `mlx-community` model the eval resolves against actual
/// hardware — the same model `RealModels.standard` names for the real-model
/// integration suites, so the eval exercises genuinely capable multi-turn
/// recall rather than a toy model.
///
/// It stands here rather than beside the runner that loads it because the
/// hermetic progress-line tests render the model-load lines and have to name
/// the same reference those lines carry.
enum CompactionEvalRealModel {
    /// The `mlx-community/Muse-Glimmer-30B-4bit` HuggingFace model reference
    /// this runner resolves, the general substitute for the Qwen3.6 model
    /// this eval used before — see `RealModels` in the integration target for
    /// why Qwen lost prompt caching and Muse Glimmer keeps it.
    static let ref: ModelRef = "mlx-community/Muse-Glimmer-30B-4bit"

    /// The maximum context window, in tokens, to load ``ref`` with — passed
    /// straight through to ``LiveModelLoader/loadLLM(ref:slot:context:reporting:)``.
    static let context = 8192
}
