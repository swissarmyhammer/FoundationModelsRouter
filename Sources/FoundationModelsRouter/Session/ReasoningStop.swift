import Foundation

/// A report that one pass of a submission reasoned and did not act, carried
/// by ``SessionEvent/reasoningStopped(_:)`` (task ^hm9trt5).
///
/// Two stops make this report:
///
/// - The watch stopped the call because the reasoning of the pass reached
///   ``RepetitionDetection/reasoningTokenLimit``. ``passFinishReason`` is
///   ``FinishReason/reasoningTokenLimit``, and the event comes before the
///   ``SessionEvent/submissionEnded(_:)`` of the stopped submission.
/// - The pass ended inside its reasoning, at its ceiling
///   (``FinishReason/maxTokens``) or before it
///   (``FinishReason/endedInsideReasoning``), with no tool call and no text
///   after the reasoning. The submission is then already ended, so the event
///   comes after its ``SessionEvent/submissionEnded(_:)``.
///
/// The tokens are counted with the session's ``TokenCounter``.
public struct ReasoningStop: Sendable, Equatable, CustomStringConvertible {
    /// The reasoning tokens of the pass at the stop. For a stop of the
    /// watch, the tokens of the complete lines of the reasoning entry that
    /// the watch read. For a pass that ended inside its reasoning, the
    /// tokens of the whole reasoning text of the last pass of the attempt.
    public let reasoningTokens: Int

    /// The limit that the pass reached: ``RepetitionDetection/reasoningTokenLimit``
    /// for a stop of the watch, the token ceiling of the pass for
    /// ``FinishReason/maxTokens``, and `nil` for
    /// ``FinishReason/endedInsideReasoning``, where the engine or the model
    /// ended the pass before a limit.
    public let limit: Int?

    /// Why the pass ended: ``FinishReason/reasoningTokenLimit``,
    /// ``FinishReason/maxTokens`` or ``FinishReason/endedInsideReasoning``.
    public let passFinishReason: FinishReason

    /// The settings in force for the stop.
    public let detection: RepetitionDetection

    /// The number of the recovery attempt that follows the stop, from 1, or
    /// `nil` when the answer has no recovery left: one final pass, whose first
    /// model pass runs with the reasoning of the model off, then follows
    /// (tasks ^0dcsd3t and ^bhdj5v9).
    public let recovery: Int?

    /// Creates a report.
    ///
    /// - Parameters:
    ///   - reasoningTokens: The reasoning tokens of the pass at the stop.
    ///   - limit: The limit that the pass reached, or `nil`.
    ///   - passFinishReason: Why the pass ended.
    ///   - detection: The settings in force.
    ///   - recovery: The number of the recovery attempt that follows, or `nil`.
    public init(
        reasoningTokens: Int,
        limit: Int?,
        passFinishReason: FinishReason,
        detection: RepetitionDetection,
        recovery: Int?
    ) {
        self.reasoningTokens = reasoningTokens
        self.limit = limit
        self.passFinishReason = passFinishReason
        self.detection = detection
        self.recovery = recovery
    }

    /// A one-line rendering of this report, also used as the session's log
    /// line. It names each value of ``detection``.
    public var description: String {
        let next = detection.followingStepDescription(recovery: recovery)
        let reached = limit.map { "the limit of \($0) tokens" } ?? "no limit"
        return """
            the pass reasoned and did not act: it ended with \(passFinishReason) after \(reasoningTokens) \
            reasoning tokens, at \(reached); \(next) (\(detection.loggedValues))
            """
    }
}
