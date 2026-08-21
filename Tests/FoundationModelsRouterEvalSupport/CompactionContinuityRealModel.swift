import FoundationModelsRouter

/// The real `mlx-community` model the gated CONTINUITY tier resolves against
/// actual hardware — deliberately its own constant, and no longer
/// ``CompactionEvalRealModel``.
///
/// The continuity tier and the two fact-retention tiers shared one model
/// until task ^m03heaa moved the fact-retention canary to
/// `mlx-community/Qwen2.5-3B-Instruct-4bit`, the family the redesigned
/// summarization prompt is designed for. Under that 3B model the continuity
/// tier still cleared its floors, but its suite wall clock measured 219.1
/// seconds on 2026-08-20 — past task ^k0d30s4's two-minute budget, which
/// `gatedEvalSuiteTimeLimitMinutes` states as this tier's ceiling — where
/// the 1B model measured 26.2 to 41.4 seconds. The continuity floors
/// (``compactionContinuityFastFactsSurvivedFloor`` and
/// ``compactionContinuityFastAnswersCorrectFloor``) are the 1B model's own
/// measured baselines, so the tier keeps the subject its floors and its
/// budget were measured against.
///
/// It stands beside ``CompactionEvalRealModel`` in this module because the
/// fast continuity budget states its `limit` from ``context``, and that
/// budget is a value this module owns.
enum CompactionContinuityRealModel {
    /// The `mlx-community/Llama-3.2-1B-Instruct-4bit` HuggingFace model
    /// reference the continuity tier resolves — 680 MB on disk, a real
    /// instruct model that writes no `<think>` block, and the model the fast
    /// compaction smoke suites drive for the same measured reasons
    /// `CompactionSmokeIntegrationTests` records.
    static let ref: ModelRef = "mlx-community/Llama-3.2-1B-Instruct-4bit"

    /// The maximum context window, in tokens, to load ``ref`` with — passed
    /// straight through to ``LiveModelLoader/loadLLM(ref:slot:context:reporting:)``.
    ///
    /// The fast continuity tier's synthetic budget states its `limit` as this
    /// same number, so a measured context fill and the budget's trigger stay
    /// on one scale — see ``compactionContinuityFastBudget``.
    static let context = 8192
}
