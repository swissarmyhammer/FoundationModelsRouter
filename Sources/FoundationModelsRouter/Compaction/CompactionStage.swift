import FoundationModels

/// A deterministic pipeline stage ``Compactor`` runs, in order, until the
/// transcript lands under target. Every stage is a pure
/// `Transcript -> Transcript` function. ``Summarization`` is async and does
/// not conform.
package protocol CompactionStage: Sendable {
    /// This stage's name, recorded in ``CompactionResult/stagesApplied``.
    static var stageName: String { get }

    /// Applies this stage to `transcript`.
    ///
    /// - Parameter transcript: The transcript to transform.
    /// - Returns: The transformed transcript.
    func apply(_ transcript: Transcript) -> Transcript
}
