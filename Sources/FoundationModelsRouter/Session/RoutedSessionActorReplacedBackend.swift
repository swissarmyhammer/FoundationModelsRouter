import Foundation
import FoundationModels

/// What the session measured before it replaced ``RoutedSessionActor/backend``
/// after a stop: a watch stop (task ^3anq1yz) or a compaction yield (task
/// ^8szxhab). It holds the usage of the stopped call, and the size of the
/// render that the next pass receives.
///
/// A replaced backend starts a usage count of its own, so the end of the
/// stopped submission cannot read the stopped call from the backend. It
/// reads this measure instead.
struct ReplacedBackendMeasure {
    /// The usage of the stopped call, or `nil` when the session has no call
    /// to report: the backend reports no usage, or the call ended at a tool
    /// call whose open already reported it.
    let stoppedCall: GenerationCallUsage?

    /// The tokens that the stopped call adds to the usage that the backend
    /// reported: the counted tokens that stand for the counts the backend
    /// did not report.
    let addedUsage: (input: Int, output: Int)

    /// The size of the render that the next pass receives, as the session's
    /// ``RoutedSessionActor/tokenCounter`` counts it, or `nil` when the
    /// session did not count it: the backend reports no usage, the counter
    /// cannot render the transcript, or the stop sets the measured context
    /// itself.
    let renderTokens: Int?

    /// The measure of a stop on a backend that reports no usage: no call,
    /// no added tokens, and no render size.
    static let unmeasured = ReplacedBackendMeasure(
        stoppedCall: nil, addedUsage: (input: 0, output: 0), renderTokens: nil)
}

/// ``RoutedSessionActor``'s record of a stopped attempt on a replaced
/// ``RoutedSessionActor/backend``.
extension RoutedSessionActor {
    /// Puts `rebuilt` into ``backend``, and records the stopped attempt.
    ///
    /// Call it after the session read the usage of the attempt and took
    /// `measure` from the backend that ran the attempt. The baseline given
    /// to the finish is the count of the replaced backend minus
    /// `usageOfAttempt`, so the finish records the usage of the attempt and
    /// not the new count minus the old baseline.
    ///
    /// - Parameters:
    ///   - rebuilt: The rebuilt transcript of the stopped attempt, whole.
    ///   - attempt: The stopped attempt.
    ///   - usageOfAttempt: The usage of the attempt, or `nil` when the backend
    ///     reports no usage.
    ///   - stopReason: The reason of the stop, or `nil` to read the reason
    ///     from the entries of the attempt.
    ///   - measure: What the session measured before the replace.
    func replaceBackendAndRecord(
        with rebuilt: [Transcript.Entry], attempt: StoppedAttempt, usageOfAttempt: (input: Int, output: Int)?,
        stopReason: FinishReason?, measure: ReplacedBackendMeasure
    ) async {
        backend = backend.replacingTranscript(Transcript(entries: rebuilt))
        _ = await finishSubmissionAndRequeueIfUnattached(
            grammar: attempt.grammar, since: attempt.started,
            usageBefore: Self.usageDelta(before: usageOfAttempt, after: backend.usageTokenCounts()),
            responseTokenCeiling: attempt.responseTokenCeiling.resolved, pendingEvents: attempt.pendingEvents,
            onEvent: attempt.onEvent, stopReason: stopReason, replacedBackend: measure)
    }
}
