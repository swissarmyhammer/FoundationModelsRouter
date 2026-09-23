import FoundationModelsRouter

/// The real `mlx-community` model the gated fact-retention eval tier
/// resolves against actual hardware.
///
/// ## Why this is Qwen3.8-27B (task ^jhb7x54)
///
/// The product runs `mlx-community/Qwen3.8-27B-mxfp4` as its standard model.
/// On 2026-09-22 the owner decided that the gated tiers measure that model.
/// Thus a result of this tier is a result of the model we ship. Task
/// ^jhb7x54 records the first measurements on this model. The sections below
/// are the history of the earlier subjects.
///
/// ## Why this was Qwen2.5-3B, and no longer the 1B Llama
///
/// This eval drove `mlx-community/Muse-Glimmer-30B-4bit` until task `^k0d30s4`
/// set a budget of two minutes for each integration test — the 30B measured
/// 197.4 to 352.0 seconds for ONE fact-retention sample — and then
/// `mlx-community/Llama-3.2-1B-Instruct-4bit` until task ^m03heaa. The 1B
/// stopped serving as a canary when task ^xx02yn6 redesigned the
/// summarization prompt for Qwen3.8-27B (the standard model): the redesign
/// took the standard model from 0 of 7 to 5 of 7 stored subset summaries,
/// and the 1B the OTHER way, from 6 of 7 to 2 of 7. The 1B ignores the
/// stated size budget and writes about the background first, so the summary
/// the compaction of that day stored lost the facts stated later in the
/// span. These measurements predate task ^pke18c2's one-call compaction. The
/// floors derived from that baseline fell to 0.14, a bar a change that
/// breaks half of the retained seeds still clears.
///
/// Qwen2.5-3B-Instruct is the first candidate of ^m03heaa's trial order the
/// redesigned prompt serves: the same family as the standard model the
/// prompt is designed for, a real instruct model that writes no `<think>`
/// block, and it measured 6 of 7 subset summaries and 23 of 24
/// whole-dataset summaries under greedy decoding on 2026-08-20, at 63.5 and
/// 369.1 seconds of suite wall clock. It is 1.6 GB on disk against 18 GB
/// for `RealModels/standard`.
///
/// ## What the tier proves
///
/// The tier measures a real compaction through `Compactor`, a real
/// summarizer generation, and a real answering turn over the compacted
/// transcript, scored mechanically. The subject is the 27B standard model.
/// Thus the tier measures the same work the product does. The 3B measured a
/// smaller model in place of the 27B, and a fact it lost said nothing about
/// the 27B. That gap is closed.
///
/// The CONTINUITY tier resolves ``CompactionContinuityRealModel`` instead.
/// That constant also names Qwen3.8-27B since task ^jhb7x54. See that
/// constant for why the two stay separate.
///
/// It stands here rather than beside the runner that loads it because the
/// hermetic progress-line tests render the model-load lines and have to name
/// the same reference those lines carry.
enum CompactionEvalRealModel {
    /// The `mlx-community/Qwen3.8-27B-mxfp4` HuggingFace model reference
    /// this eval resolves: the standard model the product runs. See the
    /// type's own doc comment for the decision (task ^jhb7x54).
    static let ref: ModelRef = "mlx-community/Qwen3.8-27B-mxfp4"

    /// The maximum context window, in tokens, to load ``ref`` with — passed
    /// straight through to ``LiveModelLoader/loadLLM(ref:slot:context:reporting:)``.
    ///
    /// Unchanged by the model swaps. It is also the window of the one
    /// summarizer call: the call's input (the compaction prompt and the whole
    /// seed transcript) and its output share it, so the call's output ceiling
    /// is this window less the input. Every seed transcript, every summarizer
    /// call, and every resumed answering turn fits this window.
    // Only `CompactionEvalRealSubjectRunner`, in the IntegrationTests
    // package, reads this. Periphery reads only this package's index, thus
    // it finds no reader.
    // periphery:ignore
    static let context = 8192
}
