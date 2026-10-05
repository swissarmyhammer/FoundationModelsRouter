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
        let texts = entries[lastPassStart(in: entries)...].map(reasoningText)
        guard !texts.contains(nil) else { return nil }
        let reasoning = texts.compactMap { $0 }.joined()
        return reasoning.isEmpty ? nil : reasoning
    }

    /// The index of the first output entry of the last pass in `entries`:
    /// the index after the last `.prompt` or `.toolOutput` entry, or the
    /// start index when `entries` holds neither. The entries before it are
    /// the render that the last pass received.
    ///
    /// - Parameter entries: Transcript entries, in transcript order.
    /// - Returns: The start index of the output of the last pass.
    static func lastPassStart(in entries: [Transcript.Entry]) -> Int {
        entries.lastIndex(where: isPassInput).map { entries.index(after: $0) } ?? entries.startIndex
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
///   answer goes on in ``continueAfterReasoningEnd(_:attempt:body:)``.
///
/// Both recoveries count against ``RepetitionDetection/recoveriesPerAnswer``,
/// with the recoveries after repetition stops. Each recovery runs with the
/// reasoning of the model off, and after the last one a final pass with the
/// reasoning off asks for the final answer
/// (``recover(after:attempt:compacts:body:)``, task ^0dcsd3t). A detection
/// that is not enabled stops nothing.
extension RoutedSessionActor {
    /// The prompt of the attempt that goes on after a reasoning stop.
    ///
    /// The render already holds the original prompt and the reasoning so
    /// far, closed (``ReasoningClosure``), so the attempt does not send the
    /// original prompt again. The prompt is short and direct (task ^0dcsd3t).
    static let reasoningStopContinuationPrompt = """
        Stop reasoning. Your next output must be one tool call that makes the change you decided on, \
        or your final answer.
        """

    /// Stops the model call in flight for a reasoning limit finding of the
    /// watch named by `watchId`.
    ///
    /// Nothing happens when the watch may not stop the call
    /// (``watchMayStopModelCall(watchId:)``). Otherwise the session logs the
    /// stop, sets the stop marker, and cancels ``inFlightModelCall``. The
    /// marker cuts nothing, so the render keeps the reasoning so far, closed
    /// (``ReasoningClosure``).
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
        stopModelCall(
            WatchStopMarker(
                report: .reasoning(report), keptUTF8Lengths: [:], keptUTF8Ranges: [:], liveEntries: liveEntries))
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
    /// reasoning, closes that reasoning in the render, and goes on with the
    /// same answer.
    ///
    /// The attempt is already recorded, with its own finish reason. The
    /// answer emits ``SessionEvent/reasoningStopped(_:)``, the session logs
    /// the stop, the render closes the reasoning
    /// (``closeStoppedReasoning(grammar:)``), and one
    /// ``TranscriptEvent/Kind/watchStop`` event records the stop. Then
    /// ``recover(after:attempt:compacts:body:)`` goes on: when the attempt
    /// stopped at its ceiling with the context at or over the compaction
    /// trigger (``compactsAfterCeilingStop(_:)``), the recovery compacts
    /// first, as after any ceiling stop.
    ///
    /// - Parameters:
    ///   - stop: The report of the stop.
    ///   - attempt: The attempt that ended inside its reasoning.
    ///   - body: The model work to run.
    /// - Returns: The response text of the next attempt, or the text that
    ///   states the stop when the final pass gives no text.
    /// - Throws: What the compaction or the next attempt throws.
    func continueAfterReasoningEnd(
        _ stop: ReasoningStop,
        attempt: StoppedAttempt,
        body: @escaping @Sendable (String) async throws -> String
    ) async throws -> String {
        attempt.onEvent?(.reasoningStopped(stop))
        logWatchStop(.reasoning(stop))
        let compacts = compactsAfterCeilingStop(stop.passFinishReason)
        await closeStoppedReasoning(grammar: attempt.grammar)
        await recordWatchStop(.reasoning(stop), grammar: attempt.grammar)
        return try await recover(after: .reasoning(stop), attempt: attempt, compacts: compacts, body: body)
    }

    /// Closes the reasoning of the last pass of ``backend`` in the render
    /// (``ReasoningClosure``, task ^0dcsd3t), and records the change, so a
    /// restore makes the same change. Nothing changes when the last pass
    /// acted.
    ///
    /// - Parameter grammar: The grammar in force for the answer.
    private func closeStoppedReasoning(grammar: Grammar?) async {
        let render = RepeatedPartRemoval.renderAfterStop(
            of: backend.transcriptEntries(), keptUTF8Lengths: [:], keptUTF8Ranges: [:],
            closureText: Self.reasoningClosureText)
        guard render.change.changesRender else { return }
        replaceRender(with: render.entries)
        await recordRenderChange(render.change, grammar: grammar)
    }
}
