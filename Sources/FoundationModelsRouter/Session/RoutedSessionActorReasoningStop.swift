import Foundation
import FoundationModels

/// Reads the output of the last pass of an attempt, to find a pass that
/// reasoned and did not act (task ^hm9trt5).
enum ReasoningOnlyOutput {
    /// The text of the reasoning of the last pass of an attempt, when that
    /// pass wrote only reasoning: no tool call and no response text.
    ///
    /// The last pass is the output after the last `.prompt` or `.toolOutput`
    /// entry. A model can write its reply and then reason after it, so a pass
    /// that holds response text before its reasoning acted, and does not
    /// count.
    ///
    /// - Parameter entries: The entries the attempt appended, in transcript
    ///   order.
    /// - Returns: The joined text of the reasoning entries of the last pass,
    ///   or `nil` when that pass holds no reasoning text, or holds a tool
    ///   call or response text.
    static func trailingReasoningText(of entries: [Transcript.Entry]) -> String? {
        let passStart = entries.lastIndex(where: isPassInput).map { entries.index(after: $0) } ?? entries.startIndex
        let texts = entries[passStart...].map(reasoningText)
        guard !texts.contains(nil) else { return nil }
        let reasoning = texts.compactMap { $0 }.joined()
        return reasoning.isEmpty ? nil : reasoning
    }

    /// Whether `entry` is input that a pass reads: a `.prompt` or a
    /// `.toolOutput` entry.
    ///
    /// - Parameter entry: One entry of the attempt.
    /// - Returns: `true` for a `.prompt` or a `.toolOutput` entry.
    private static func isPassInput(_ entry: Transcript.Entry) -> Bool {
        switch entry {
        case .prompt, .toolOutput:
            return true
        case .instructions, .reasoning, .response, .toolCalls:
            return false
        @unknown default:
            return false
        }
    }

    /// The reasoning text that `entry` adds to a pass that wrote only
    /// reasoning: the text of a `.reasoning` entry, and no text for a
    /// `.response` entry with no text, as the MLX executor writes when the
    /// output ends inside the reasoning.
    ///
    /// - Parameter entry: One entry of the last pass.
    /// - Returns: The reasoning text, an empty text for an empty response, or
    ///   `nil` for an entry that acts: a tool call or response text.
    private static func reasoningText(_ entry: Transcript.Entry) -> String? {
        switch entry {
        case .reasoning(let reasoning):
            return WatchedText.text(of: reasoning.segments)
        case .response:
            return isEmptyResponse(entry) ? "" : nil
        case .instructions, .prompt, .toolCalls, .toolOutput:
            return nil
        @unknown default:
            return nil
        }
    }

    /// Whether `entry` is a `.response` entry with no text but white space,
    /// as the MLX executor writes when the output ends inside the reasoning.
    ///
    /// - Parameter entry: One entry of the attempt.
    /// - Returns: `true` for a `.response` entry with no text.
    private static func isEmptyResponse(_ entry: Transcript.Entry) -> Bool {
        guard case .response(let response) = entry else { return false }
        return WatchedText.text(of: response.segments).allSatisfy(\.isWhitespace)
    }
}

/// ``RoutedSessionActor``'s reasoning stop (task ^hm9trt5): a pass that
/// reasons and does not act stops, and a recovery tells the model to act.
///
/// Two stops lead to the recovery:
///
/// - The watch stops the call when the reasoning of the pass reaches
///   ``RepetitionDetection/reasoningTokenLimit``
///   (``noteReasoningLimit(_:liveEntries:watchId:)``). The answer goes on in
///   ``continueAfterWatchStop(_:attempt:body:)``, as after a repetition stop.
/// - A pass ends inside its reasoning, at its ceiling or before it, with no
///   tool call and no text (``reasoningEndStop(finishReason:attempt:)``). The
///   answer goes on in ``continueAfterReasoningEnd(_:response:attempt:body:)``,
///   and not with a continuation that ends the answer with no output.
///
/// Both recoveries count against ``RepetitionDetection/recoveriesPerAnswer``,
/// with the recoveries after repetition stops. A detection that is not
/// enabled stops nothing.
extension RoutedSessionActor {
    /// The prompt of the attempt that goes on after a reasoning stop.
    ///
    /// The render already holds the original prompt and the reasoning so
    /// far, so the attempt does not send the original prompt again.
    static let reasoningStopContinuationPrompt = """
        You reasoned for a long time and did not act, so the session stopped your reasoning. \
        Do not reason more. Act now: call a tool, or give your answer.
        """

    /// Stops the model call in flight for a reasoning limit finding of the
    /// watch named by `watchId`.
    ///
    /// Nothing happens when the watch may not stop the call
    /// (``watchMayStopModelCall(watchId:)``). Otherwise the session logs the
    /// stop, sets the stop marker, and cancels ``inFlightModelCall``. The
    /// marker cuts nothing, so the render keeps the reasoning so far.
    ///
    /// - Parameters:
    ///   - finding: What the detector found.
    ///   - liveEntries: The live transcript the watch read last.
    ///   - watchId: The watch that found it.
    func noteReasoningLimit(_ finding: ReasoningLimitFinding, liveEntries: [Transcript.Entry], watchId: UInt64) {
        guard watchMayStopModelCall(watchId: watchId) else { return }
        let report = ReasoningStop(
            reasoningTokens: finding.reasoningTokens, limit: finding.limit, passFinishReason: .reasoningTokenLimit,
            detection: repetitionDetection, recovery: nextRecovery)
        stopModelCall(WatchStopMarker(report: .reasoning(report), keptUTF8Lengths: [:], liveEntries: liveEntries))
    }

    /// The reasoning stop of an attempt that ended inside its reasoning, at
    /// its ceiling (``FinishReason/maxTokens``) or before it
    /// (``FinishReason/endedInsideReasoning``), and whose last pass wrote only
    /// reasoning (``ReasoningOnlyOutput/trailingReasoningText(of:)``).
    ///
    /// - Parameters:
    ///   - finishReason: Why the attempt stopped.
    ///   - attempt: The attempt, already recorded.
    /// - Returns: The report of the stop, or `nil` when the detection is not
    ///   enabled, when a stop is outstanding against the answer, or when the
    ///   attempt did not end inside its reasoning.
    func reasoningEndStop(finishReason: FinishReason, attempt: StoppedAttempt) -> ReasoningStop? {
        guard repetitionDetection.isEnabled, !isWorkCancelled,
            finishReason == .maxTokens || finishReason == .endedInsideReasoning
        else { return nil }
        let entries = backend.transcriptEntries().filter { !attempt.entryIdsBeforeAttempt.contains($0.id) }
        guard let reasoning = ReasoningOnlyOutput.trailingReasoningText(of: entries) else { return nil }
        return ReasoningStop(
            reasoningTokens: tokenCounter.count(reasoning),
            limit: finishReason == .maxTokens ? attempt.responseTokenCeiling.resolved : nil,
            passFinishReason: finishReason, detection: repetitionDetection, recovery: nextRecovery)
    }

    /// Reports the reasoning stop of an attempt that ended inside its
    /// reasoning, and runs the recovery when the answer has one left.
    ///
    /// The attempt is already recorded, with its own finish reason. The
    /// answer emits ``SessionEvent/reasoningStopped(_:)`` and the session
    /// logs the stop. With a recovery left, the next attempt sends
    /// ``reasoningStopContinuationPrompt``. When the attempt stopped at its
    /// ceiling with the context at or over the compaction trigger
    /// (``compactsAfterCeilingStop(_:)``), the answer compacts first, as
    /// after any ceiling stop. With no recovery left, the answer ends with
    /// the response text of the attempt.
    ///
    /// - Parameters:
    ///   - stop: The report of the stop.
    ///   - response: The response text of the attempt.
    ///   - attempt: The attempt that ended inside its reasoning.
    ///   - body: The model work to run.
    /// - Returns: The response text of the next attempt, or `response` when
    ///   no recovery is left.
    /// - Throws: What the compaction or the next attempt throws.
    func continueAfterReasoningEnd(
        _ stop: ReasoningStop,
        response: String,
        attempt: StoppedAttempt,
        body: @escaping @Sendable (String) async throws -> String
    ) async throws -> String {
        attempt.onEvent?(.reasoningStopped(stop))
        logWatchStop(.reasoning(stop))
        guard let recovery = stop.recovery else { return response }
        repetitionWatch.recoveriesThisAnswer = recovery
        guard compactsAfterCeilingStop(stop.passFinishReason) else {
            return try await runContinuation(after: attempt, prompt: Self.reasoningStopContinuationPrompt, body: body)
        }
        return try await compactAndContinue(
            attempt: attempt, reason: .outputCeilingStop, continuationPrompt: Self.reasoningStopContinuationPrompt,
            body: body)
    }
}
