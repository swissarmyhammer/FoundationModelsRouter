import FoundationModelsRouter

/// The real `mlx-community` model every gated eval tier in this package
/// resolves against actual hardware.
///
/// ## Why this is the small model, and no longer `RealModels/standard`
///
/// This eval drove `mlx-community/Muse-Glimmer-30B-4bit` until task `^k0d30s4`
/// set a budget of two minutes for each integration test. The 30B model cannot
/// meet that budget: the gated run of 2026-08-18 measured 197.4 to 352.0
/// seconds for ONE fact-retention sample — two generations — so even a single
/// sample is over the whole budget. The small model is the same model the
/// three fast compaction smoke suites drive, for the same measured reasons
/// `CompactionSmokeIntegrationTests` records: it is a real instruct model, it
/// follows the compaction prompt's own section structure, and it writes no
/// `<think>` block, so a generation is its answer alone.
///
/// ## What the swap proves, and what it no longer proves
///
/// The tiers still measure the real thing they always measured: a real fold
/// through `Compactor`, a real summarizer generation, and a real answering
/// turn over the folded transcript, scored mechanically. What they NO LONGER
/// prove is how the 30B model — the model the slow gated suites drive —
/// performs the same work. A fact the 1B model retains says nothing about the
/// 30B, and a fact it loses may still survive under the larger model. That
/// trade is task `^k0d30s4`'s decision: a live measurement in seconds on every
/// run, in place of a stronger measurement nobody runs.
///
/// It stands here rather than beside the runner that loads it because the
/// hermetic progress-line tests render the model-load lines and have to name
/// the same reference those lines carry.
enum CompactionEvalRealModel {
    /// The `mlx-community/Llama-3.2-1B-Instruct-4bit` HuggingFace model
    /// reference this eval resolves — 680 MB on disk against 18 GB for
    /// `RealModels/standard`, and the model every fast compaction smoke suite
    /// already drives. See the type's own doc comment for the budget that
    /// forced the swap and for what the swap no longer proves.
    static let ref: ModelRef = "mlx-community/Llama-3.2-1B-Instruct-4bit"

    /// The maximum context window, in tokens, to load ``ref`` with — passed
    /// straight through to ``LiveModelLoader/loadLLM(ref:slot:context:reporting:)``.
    ///
    /// Unchanged by the model swap. Every seed transcript, every fold prompt
    /// chunk (bounded by ``Summarization/maxChunkTokens``), and every resumed
    /// answering turn fits this window, and the fast continuity tier's
    /// synthetic budget states its `limit` as this same number so a measured
    /// context fill and the budget's trigger stay on one scale.
    static let context = 8192
}
