import FoundationModelsRouter

/// The real `mlx-community` model the gated fact-retention eval tier
/// resolves against actual hardware.
///
/// ## Why this is Qwen2.5-3B, and no longer the 1B Llama
///
/// This eval drove `mlx-community/Muse-Glimmer-30B-4bit` until task `^k0d30s4`
/// set a budget of two minutes for each integration test — the 30B measured
/// 197.4 to 352.0 seconds for ONE fact-retention sample — and then
/// `mlx-community/Llama-3.2-1B-Instruct-4bit` until task ^m03heaa. The 1B
/// stopped serving as a canary when task ^xx02yn6 redesigned the
/// summarization prompt and trim for Qwen3.8-27B (the standard model): the
/// redesign took the standard model from 0 of 7 to 5 of 7 stored subset
/// summaries, and the 1B the OTHER way, from 6 of 7 to 2 of 7 — it ignores
/// the stated size budget, enumerates background head-first, and the
/// last-resort cut then drops the facts stated later in the span. The floors
/// derived from that baseline fell to 0.14, a bar a change that breaks half
/// of the retained seeds still clears.
///
/// Qwen2.5-3B-Instruct is the first candidate of ^m03heaa's trial order the
/// redesigned prompt serves: the same family as the standard model the
/// prompt is designed for, a real instruct model that writes no `<think>`
/// block, and it measured 6 of 7 subset summaries and 23 of 24
/// whole-dataset summaries under greedy decoding on 2026-08-20, at 63.5 and
/// 369.1 seconds of suite wall clock. It is 1.6 GB on disk against 18 GB
/// for `RealModels/standard`.
///
/// ## What the tier proves, and what it does not
///
/// The tier still measures the real thing it always measured: a real fold
/// through `Compactor`, a real summarizer generation, and a real answering
/// turn over the folded transcript, scored mechanically. What it does NOT
/// prove is how the 27B standard model performs the same work. A fact the
/// 3B model retains says nothing about the 27B, and a fact it loses may
/// still survive under the larger model. That trade is task `^k0d30s4`'s
/// decision: a live measurement in seconds on every run, in place of a
/// stronger measurement nobody runs.
///
/// The CONTINUITY tier resolves ``CompactionContinuityRealModel`` instead —
/// its own constant, which names the same Qwen2.5-3B since task ^mx4jqrn;
/// see that constant for why the two stay separate.
///
/// It stands here rather than beside the runner that loads it because the
/// hermetic progress-line tests render the model-load lines and have to name
/// the same reference those lines carry.
enum CompactionEvalRealModel {
    /// The `mlx-community/Qwen2.5-3B-Instruct-4bit` HuggingFace model
    /// reference this eval resolves. See the type's own doc comment for the
    /// measured trail behind the choice (task ^m03heaa).
    static let ref: ModelRef = "mlx-community/Qwen2.5-3B-Instruct-4bit"

    /// The maximum context window, in tokens, to load ``ref`` with — passed
    /// straight through to ``LiveModelLoader/loadLLM(ref:slot:context:reporting:)``.
    ///
    /// Unchanged by the model swaps. Every seed transcript, every fold prompt
    /// chunk (bounded by ``Summarization/maxChunkTokens``), and every resumed
    /// answering turn fits this window.
    // Only `CompactionEvalRealSubjectRunner`, in the IntegrationTests
    // package, reads this. Periphery reads only this package's index, thus
    // it finds no reader.
    // periphery:ignore
    static let context = 8192
}
