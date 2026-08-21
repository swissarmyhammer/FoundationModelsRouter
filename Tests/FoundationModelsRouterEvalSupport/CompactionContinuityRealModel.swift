import FoundationModelsRouter

/// The real `mlx-community` model the gated CONTINUITY tier resolves against
/// actual hardware — deliberately its own constant, even on a day it names
/// the same model as ``CompactionEvalRealModel``.
///
/// ## Why it is its own constant
///
/// The continuity tier and the two fact-retention tiers shared one constant
/// until task ^m03heaa moved the fact-retention canary to
/// `mlx-community/Qwen2.5-3B-Instruct-4bit` and split this one off, so that
/// each tier's floors and wall clock stay measured against a subject that
/// tier names for itself. A later swap of either tier's subject then moves
/// one constant and one set of floors, and never the other tier's.
///
/// ## Why it is Qwen2.5-3B, and no longer the 1B Llama (task ^mx4jqrn)
///
/// This constant held `mlx-community/Llama-3.2-1B-Instruct-4bit` until task
/// ^mx4jqrn, and the floors were that model's measured baselines of
/// 2026-08-19: 7 of 10 tasks with at least one fact in the answer and 4 of
/// 10 with both. Task ^xx02yn6's redesign of the summarization prompt for
/// Qwen3.8-27B took the 1B the other way, as it took the fact-retention
/// canary: measured on 2026-08-20 under the redesigned prompt, the 1B
/// answered 1 of 10 tasks with at least one fact and 0 of 10 with both, so
/// the tier was red on `main` against floors of 0.6 and 0.3. Under Qwen2.5-3B
/// the same ten tasks kept their floors, but cost 219.1 seconds of suite wall
/// clock on 2026-08-20 and 99.5 on 2026-08-21 — against task ^k0d30s4's
/// two-minute budget, which `gatedEvalSuiteTimeLimitMinutes` states. So the
/// tier moved to the 3B AND to a four-task shape, which
/// ``compactionContinuityFastTierIDs`` states with its measurement, and the
/// floors were re-derived from the 3B's own run over those four tasks — see
/// ``compactionContinuityFastFactsSurvivedFloor`` and
/// ``compactionContinuityFastAnswersCorrectFloor``. Lowering the floors to the
/// 1B's 0.1 and 0.0 was refused: a floor that low lets a change break almost
/// every task and still pass, the defect ^m03heaa removed on the
/// fact-retention side.
///
/// It stands beside ``CompactionEvalRealModel`` in this module because the
/// fast continuity budget states its `limit` from ``context``, and that
/// budget is a value this module owns.
enum CompactionContinuityRealModel {
    /// The `mlx-community/Qwen2.5-3B-Instruct-4bit` HuggingFace model
    /// reference the continuity tier resolves — 1.6 GB on disk, the same
    /// family as the standard model the redesigned summarization prompt is
    /// written for, and a real instruct model that writes no `<think>` block,
    /// so ``compactionEvalReasoningTokenHeadroom`` stays correct for it. See
    /// the type's own doc comment for the measured trail behind the choice.
    // Only `CompactionContinuityEvalRealSubjectRunner`, in the
    // IntegrationTests package, reads this. Periphery reads only this
    // package's index, thus it finds no reader.
    // periphery:ignore
    static let ref: ModelRef = "mlx-community/Qwen2.5-3B-Instruct-4bit"

    /// The maximum context window, in tokens, to load ``ref`` with — passed
    /// straight through to ``LiveModelLoader/loadLLM(ref:slot:context:reporting:)``.
    ///
    /// The fast continuity tier's synthetic budget states its `limit` as this
    /// same number, so a measured context fill and the budget's trigger stay
    /// on one scale — see ``compactionContinuityFastBudget``.
    static let context = 8192
}
