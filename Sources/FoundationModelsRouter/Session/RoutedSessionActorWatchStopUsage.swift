import Foundation
import FoundationModels
import Logging

/// ``RoutedSessionActor``'s usage of a watch stop (task ^3anq1yz).
///
/// The watch cancels the model call in flight. The MLX executor sends its one
/// usage update only after a call completes, so the backend reports no usage
/// for a cancelled call: no fed tokens and no generated tokens. Without this
/// measure, the stopped call had no ``SessionEvent/generationCall(_:)``, its
/// tokens were missing from the usage of the answer, and the fill of the
/// stopped submission did not measure the render.
extension RoutedSessionActor {
    /// Measures the stopped call and the render after a watch stop. Call it
    /// before ``backend`` is replaced.
    ///
    /// The stopped call received the rebuilt transcript up to the output of
    /// its pass (``ReasoningOnlyOutput/lastPassStart(in:)``), and it wrote the
    /// output of that pass. The counter gives each count that the backend did
    /// not report. The next pass receives `render`, and the counter gives its
    /// size.
    ///
    /// - Parameters:
    ///   - marker: The stop marker of the stopped attempt.
    ///   - rebuilt: The rebuilt transcript of the stopped attempt, whole.
    ///   - render: The render that the next pass receives.
    /// - Returns: The measure, or ``ReplacedBackendMeasure/unmeasured`` when the
    ///   backend reports no usage.
    func measureWatchStop(
        _ marker: WatchStopMarker, rebuilt: [Transcript.Entry], render: [Transcript.Entry]
    ) -> ReplacedBackendMeasure {
        measureStoppedCall(
            liveEntries: marker.liveEntries, finishReason: marker.report.finishReason,
            logCategory: marker.report.logLine.category, rebuilt: rebuilt, render: render)
    }

    /// Measures the call that a stop of the watch cancelled, and the render
    /// after the stop: the measure of ``measureWatchStop(_:rebuilt:render:)``
    /// for any stop of the watch, a stop at a stray `</think>` included (task
    /// ^07vtf4a). Call it before ``backend`` is replaced.
    ///
    /// - Parameters:
    ///   - liveEntries: The live transcript that the watch read last.
    ///   - finishReason: The finish reason that the stopped call closes with.
    ///   - logCategory: The log category of the stop, which the log line of a
    ///     counter that cannot render the transcript takes.
    ///   - rebuilt: The rebuilt transcript of the stopped attempt, whole.
    ///   - render: The render that the next pass receives.
    /// - Returns: The measure, or ``ReplacedBackendMeasure/unmeasured`` when the
    ///   backend reports no usage.
    func measureStoppedCall(
        liveEntries: [Transcript.Entry], finishReason: FinishReason, logCategory: RouterTelemetry.LogCategory,
        rebuilt: [Transcript.Entry], render: [Transcript.Entry]
    ) -> ReplacedBackendMeasure {
        guard backend.usageTokenCounts() != nil else { return .unmeasured }
        let passStart = ReasoningOnlyOutput.lastPassStart(in: rebuilt)
        let passOutput = Array(rebuilt[passStart...])
        let counted = (
            input: countedTokens(of: Array(rebuilt[..<passStart]), logCategory: logCategory) ?? 0,
            output: countedTextTokens(of: passOutput)
        )
        let stoppedCall = takeStoppedGenerationCall(
            counted: counted, endedAtToolCall: Self.endsAtToolCall(liveEntries), finishReason: finishReason,
            entryKind: GenerationCallEntryKind(leftBy: passOutput),
            toolCallCount: GenerationCallEntryKind.toolCallCount(of: passOutput))
        return ReplacedBackendMeasure(
            stoppedCall: stoppedCall?.usage, addedUsage: stoppedCall?.addedUsage ?? (input: 0, output: 0),
            renderTokens: countedTokens(of: render, logCategory: logCategory))
    }

    /// Whether the last pass of `liveEntries` ended at a tool call: its
    /// output ends with a `.toolCalls` entry.
    ///
    /// The rebuild of a stopped attempt removes a call that got no output,
    /// so this reads the live transcript that the watch read last.
    ///
    /// - Parameter liveEntries: The live transcript of the stopped attempt.
    /// - Returns: `true` when the last pass ended at a tool call.
    private static func endsAtToolCall(_ liveEntries: [Transcript.Entry]) -> Bool {
        let passOutput = Array(liveEntries[ReasoningOnlyOutput.lastPassStart(in: liveEntries)...])
        return GenerationCallEntryKind(leftBy: passOutput) == .toolCall
    }

    /// The tokens of the text that `entries` hold: the reasoning, the
    /// response text and the tool-call arguments, as this session's
    /// ``tokenCounter`` counts each text.
    ///
    /// - Parameter entries: The output entries of one pass.
    /// - Returns: The counted tokens of their text.
    private func countedTextTokens(of entries: [Transcript.Entry]) -> Int {
        WatchedText.attemptTexts(in: entries, excluding: []).reduce(0) { total, watched in
            total + tokenCounter.count(watched.text)
        }
    }

    /// The size of `entries` as this session's ``tokenCounter`` counts the
    /// rendered transcript.
    ///
    /// A counter that cannot render the transcript is not expected: the
    /// session logs it and the measure goes on without the count.
    ///
    /// - Parameters:
    ///   - entries: The transcript entries to count.
    ///   - logCategory: The log category of the stop, which the log line
    ///     takes.
    /// - Returns: The count, or `nil` when the counter throws.
    private func countedTokens(of entries: [Transcript.Entry], logCategory: RouterTelemetry.LogCategory) -> Int? {
        do {
            return try tokenCounter.count(Transcript(entries: entries))
        } catch {
            assertionFailure("the token counter cannot render the transcript of a watch stop")
            sessionLogger(logCategory).error(
                "the token counter cannot render the transcript of a watch stop; the usage of the stop stays unmeasured",
                metadata: RouterTelemetry.errorMetadata(error).merging([
                    RouterTelemetry.LogMetadataKey.sessionId: "\(id.description)"
                ]) { _, new in new })
            return nil
        }
    }
}
