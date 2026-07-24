/// The one type both sides of ``CompactionEvaluation``'s dataset use — Apple's
/// `Evaluation` protocol requires `Sample.ExpectedValue == Subject.Value`
/// (confirmed against the installed `Evaluations.framework`
/// `.swiftinterface`; the framework does not let a sample's ground-truth
/// type and its produced-subject type differ), so one `Codable` struct plays
/// both roles:
///
/// - As a sample's `expected` (``CompactionEvaluation/dataset``): only the
///   ground-truth fields are populated (``seedID``, ``plantedFact``,
///   ``targetTokens``, ``promptName``); the produced-side fields are their
///   zero values and are never read from this side.
/// - As a subject's `value` (``CompactionEvaluation/subject(from:)``'s
///   return): every field is populated — the ground truth carried forward
///   plus what the subject actually produced (``answer``, ``tokensBefore``,
///   ``tokensAfter``, ``stagesApplied``).
///
/// Evaluators (``CompactionEvaluation/evaluators``) read the ground-truth
/// side from `sample.expected` and the produced side from `subject.value`.
struct CompactionEvaluationOutcome: Codable, Sendable {
    /// Looks the full ``CompactionEvalSeed`` back up in
    /// ``CompactionEvaluation``'s in-memory table — `Transcript.Entry` itself
    /// never needs to be `Codable` this way (see ``CompactionEvalSeed``'s own
    /// doc comment).
    var seedID: String

    /// Ground truth: the fact planted in the seed's foldable head, kept for
    /// rationale/display purposes (e.g. a failing `FactRetention` metric's
    /// rationale).
    var plantedFact: String

    /// Ground truth: the short, distinctive value ``FactRetention`` actually
    /// checks the produced ``answer`` for — never the whole ``plantedFact``
    /// sentence, which a short targeted answer could never contain verbatim
    /// (see ``CompactionEvalFixtureSpec/factKeyPhrase``'s own doc comment).
    var factKeyPhrase: String

    /// Ground truth: the token ceiling ``UnderTarget`` checks the produced
    /// ``tokensAfter`` against — `budget.limit * budget.target`, rounded, the
    /// same arithmetic ``Compactor/compact(_:prompt:budget:summarizer:)``
    /// itself uses.
    var targetTokens: Int

    /// Ground truth: the ``CompactionPrompt/name`` this run folded with —
    /// stamped from ``CompactionEvaluation/prompt`` on every sample, so a
    /// fold's produced outcome is always attributable to the exact prompt
    /// that produced it (compaction_plan.md §5's hill-climbing loop).
    var promptName: String

    /// Produced: the resumed session's answer to the sample's question.
    var answer: String = ""

    /// Produced: the fold's estimated pre-compaction size, in tokens
    /// (``CompactionResult/tokensBefore``).
    var tokensBefore: Int = 0

    /// Produced: the fold's estimated post-compaction size, in tokens
    /// (``CompactionResult/tokensAfter``).
    var tokensAfter: Int = 0

    /// Produced: the compaction stages that actually ran
    /// (``CompactionResult/stagesApplied``).
    var stagesApplied: [String] = []
}
