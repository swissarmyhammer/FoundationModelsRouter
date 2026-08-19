/// The one type both sides of ``CompactionContinuityEvaluation``'s dataset
/// use — mirrors ``CompactionEvaluationOutcome``'s own split:
///
/// - As a sample's `expected` (``CompactionContinuityEvaluation/dataset``):
///   only the ground-truth fields are populated (``taskID``,
///   ``factKeyPhrases``, ``expectedKeyPhrases``, ``targetTokens``,
///   ``expectedMinimumRecordedEntries``, ``promptName``); the produced-side
///   fields are their zero values and are never read from this side.
/// - As a subject's `value` (``CompactionContinuityEvaluation/subject(from:)``'s
///   return): every field is populated — the ground truth carried forward
///   plus what the subject actually produced (``finalAnswer``, ``foldCount``,
///   ``tokensBefore``, ``tokensAfter``, ``recordedEntryCount``, ``modelName``).
///
/// Evaluators (``CompactionContinuityEvaluation/evaluators``) read the
/// ground-truth side from `sample.expected` and the produced side from
/// `subject.value`.
struct CompactionContinuityOutcome: Codable, Sendable {
    /// Looks the full ``CompactionContinuitySeed`` back up in
    /// ``CompactionContinuityEvaluation``'s in-memory table.
    var taskID: String

    /// Ground truth: every individual planted fact's key phrase — checked
    /// independently (any one surviving is enough) by
    /// ``CompactionContinuityMetric/factsSurvived``.
    var factKeyPhrases: [String]

    /// Ground truth: every key phrase a fully correct completion of the
    /// task's final instruction must contain together — checked by
    /// ``CompactionContinuityMetric/answersCorrect``.
    var expectedKeyPhrases: [String]

    /// Ground truth: the token ceiling ``CompactionContinuityMetric/budgetHeld``
    /// checks the produced ``tokensAfter`` against — `budget.limit *
    /// budget.target`, rounded, the same arithmetic
    /// ``CompactionEvaluationOutcome/targetTokens`` uses.
    var targetTokens: Int

    /// Ground truth: the minimum number of recorded transcript entries a
    /// fully durable recording of the whole task should have produced —
    /// checked by ``CompactionContinuityMetric/recordingComplete``. See
    /// ``CompactionContinuitySeed/expectedMinimumRecordedEntries``.
    var expectedMinimumRecordedEntries: Int

    /// Ground truth: the ``CompactionPrompt/name`` this run folded with —
    /// stamped from ``CompactionContinuityEvaluation/prompt`` on every
    /// sample, so a run's produced outcome is always attributable to the
    /// exact prompt that produced it (compaction_plan.md §5's hill-climbing
    /// loop, mirrored here for continuity rather than fact-retention quality).
    var promptName: String

    /// Produced: the resumed session's answer to the task's final
    /// instruction.
    var finalAnswer: String = ""

    /// Produced: how many live folds actually ran while driving the task's
    /// steps — checked by ``CompactionContinuityMetric/foldOccurred``. Task
    /// 4ce0a1k's own "sized to be impossible without >=1 fold" requirement
    /// is a claim about the dataset; this is the runtime proof it held for
    /// this particular run.
    var foldCount: Int = 0

    /// Produced: the last fold's estimated pre-compaction size, in tokens,
    /// or `0` if ``foldCount`` is `0`.
    var tokensBefore: Int = 0

    /// Produced: the last fold's estimated post-compaction size, in tokens,
    /// or `0` if ``foldCount`` is `0`.
    var tokensAfter: Int = 0

    /// Produced: the number of transcript entries the subject's own durable
    /// recording actually persisted for this task, across every step —
    /// checked against ``expectedMinimumRecordedEntries`` by
    /// ``CompactionContinuityMetric/recordingComplete``.
    var recordedEntryCount: Int = 0

    /// Produced: the resolved model that actually drove this task — "fold
    /// counts + tokensBefore/After ride along keyed by resolved model" (task
    /// 4ce0a1k), so results are always attributable to which model produced
    /// them, not just which prompt.
    var modelName: String = ""
}
