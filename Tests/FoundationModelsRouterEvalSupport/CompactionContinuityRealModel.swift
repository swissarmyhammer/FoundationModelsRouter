import FoundationModelsRouter

/// The real `mlx-community` model that the gated CONTINUITY tier resolves on
/// actual hardware.
///
/// The tier's floors and wall clock are measured against this subject. When
/// the tier changes its subject, it changes this constant and its floors
/// together.
///
/// ## Why it is Qwen3.8-27B (task ^jhb7x54)
///
/// The product runs `mlx-community/Qwen3.8-27B-mxfp4` as its standard model.
/// On 2026-09-22 the owner decided that the gated compaction eval measures
/// that model. Task ^jhb7x54 records the first measurements on this model.
/// The section below is the history of the earlier subject.
///
/// ## Why it was Qwen2.5-3B, and no longer the 1B Llama (task ^mx4jqrn)
///
/// This constant held `mlx-community/Llama-3.2-1B-Instruct-4bit` until task
/// ^mx4jqrn, and the floors were that model's measured baselines of
/// 2026-08-19: 7 of 10 tasks with at least one fact in the answer and 4 of
/// 10 with both. Task ^xx02yn6's redesign of the summarization prompt for
/// Qwen3.8-27B made the 1B worse. Measured on 2026-08-20 under the
/// redesigned prompt, the 1B
/// answered 1 of 10 tasks with at least one fact and 0 of 10 with both, so
/// the tier was red on `main` against floors of 0.6 and 0.3. Under Qwen2.5-3B
/// the same ten tasks kept their floors, but cost 219.1 seconds of suite wall
/// clock on 2026-08-20 and 99.5 on 2026-08-21 — against task ^k0d30s4's
/// two-minute budget of that time. So the
/// tier moved to the 3B AND to a four-task shape, which
/// ``compactionContinuityFastTierIDs`` states with its measurement, and the
/// floors were re-derived from the 3B's own run over those four tasks — see
/// ``compactionContinuityFastFactsSurvivedFloor`` and
/// ``compactionContinuityFastAnswersCorrectFloor``. Lowering the floors to the
/// 1B's 0.1 and 0.0 was refused: a floor that low lets a change break almost
/// every task and still pass.
///
/// This type is in this module because the fast continuity budget states its
/// `limit` from ``context``, and this module owns that budget.
enum CompactionContinuityRealModel {
    /// The `mlx-community/Qwen3.8-27B-mxfp4` HuggingFace model reference
    /// the continuity tier resolves: the standard model the product runs.
    /// See the type's own doc comment for the decision (task ^jhb7x54).
    // Only `CompactionContinuityEvalRealSubjectRunner`, in the
    // IntegrationTests package, reads this. Periphery reads only this
    // package's index, thus it finds no reader.
    // periphery:ignore
    static let ref: ModelRef = "mlx-community/Qwen3.8-27B-mxfp4"

    /// The maximum context window, in tokens, to load ``ref`` with — passed
    /// straight through to ``LiveModelLoader/loadLLM(ref:slot:context:reporting:)``.
    ///
    /// The fast continuity tier's synthetic budget states its `limit` as this
    /// same number, so a measured context fill and the budget's trigger stay
    /// on one scale — see ``compactionContinuityFastBudget``.
    static let context = 8192
}
