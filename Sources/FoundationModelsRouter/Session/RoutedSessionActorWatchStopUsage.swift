import Foundation
import FoundationModels
import Logging

/// What a watch stop measured before the session replaced ``RoutedSessionActor/backend``
/// (task ^3anq1yz): the usage of the stopped call, and the size of the render
/// that the next pass receives.
///
/// A replaced backend starts a usage count of its own, so the end of the
/// stopped submission cannot read the stopped call from the backend. It
/// reads this measure instead.
struct WatchStopMeasure {
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
    /// backend reports no usage or the counter cannot render the transcript.
    let renderTokens: Int?

    /// The measure of a stop on a backend that reports no usage: no call,
    /// no added tokens, and no render size.
    static let unmeasured = WatchStopMeasure(stoppedCall: nil, addedUsage: (input: 0, output: 0), renderTokens: nil)
}

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
    /// - Returns: The measure, or ``WatchStopMeasure/unmeasured`` when the
    ///   backend reports no usage.
    func measureWatchStop(
        _ marker: WatchStopMarker, rebuilt: [Transcript.Entry], render: [Transcript.Entry]
    ) -> WatchStopMeasure {
        guard backend.usageTokenCounts() != nil else { return .unmeasured }
        let passStart = ReasoningOnlyOutput.lastPassStart(in: rebuilt)
        let passOutput = Array(rebuilt[passStart...])
        let counted = (
            input: countedTokens(of: Array(rebuilt[..<passStart]), report: marker.report) ?? 0,
            output: countedTextTokens(of: passOutput)
        )
        let stoppedCall = takeStoppedGenerationCall(
            counted: counted, endedAtToolCall: Self.endsAtToolCall(marker.liveEntries),
            finishReason: marker.report.finishReason, entryKind: GenerationCallEntryKind(leftBy: passOutput))
        return WatchStopMeasure(
            stoppedCall: stoppedCall?.usage, addedUsage: stoppedCall?.addedUsage ?? (input: 0, output: 0),
            renderTokens: countedTokens(of: render, report: marker.report))
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
    ///   - report: The report of the stop, whose log category the log line
    ///     takes.
    /// - Returns: The count, or `nil` when the counter throws.
    private func countedTokens(of entries: [Transcript.Entry], report: WatchStopReport) -> Int? {
        do {
            return try tokenCounter.count(Transcript(entries: entries))
        } catch {
            assertionFailure("the token counter cannot render the transcript of a watch stop")
            sessionLogger(report.logLine.category).error(
                "the token counter cannot render the transcript of a watch stop; the usage of the stop stays unmeasured",
                metadata: RouterTelemetry.errorMetadata(error).merging([
                    RouterTelemetry.LogMetadataKey.sessionId: "\(id.description)"
                ]) { _, new in new })
            return nil
        }
    }
}
