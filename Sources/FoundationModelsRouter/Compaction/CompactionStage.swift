import FoundationModels

/// A deterministic pipeline stage ``Compactor`` runs, in order, until the
/// transcript lands under target (compaction_plan.md §1.3).
///
/// Every conforming stage is a pure `Transcript -> Transcript` function: same
/// input, same output, no side effects — the property that lets
/// ``Compactor/compact(_:prompt:budget:summarizer:)`` try a stage, measure
/// the result, and stop as soon as the transcript is small enough, without
/// ever worrying about having mutated something it shouldn't.
///
/// Only the deterministic stages (``ToolOutputElision``, ``TurnTruncation``)
/// conform here. The model-assisted ``Summarization`` stage is async and
/// needs a prompt and a summarizer model, so it wires into the pipeline
/// through a different mechanism rather than this synchronous protocol — see
/// ``Compactor/compact(_:prompt:budget:summarizer:)``.
public protocol CompactionStage: Sendable {
    /// This stage's name, recorded in ``CompactionResult/stagesApplied`` (and,
    /// once a fold synthesizes a summary entry, in
    /// ``CompactionSegment/Content/stagesApplied``) — e.g.
    /// `"ToolOutputElision"`.
    static var stageName: String { get }

    /// Applies this stage to `transcript`, returning the result.
    ///
    /// - Parameter transcript: The transcript to transform.
    /// - Returns: The transformed transcript.
    func apply(_ transcript: Transcript) -> Transcript
}
