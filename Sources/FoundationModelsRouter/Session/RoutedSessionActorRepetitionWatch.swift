import Foundation
import FoundationModels
import FoundationModelsExtras
import Logging

/// The repetition watch of one session: the watch of the model call in
/// flight, the stop it found, and the recoveries of the answer in flight.
struct RepetitionWatchState {
    /// The last watch id that ``RoutedSessionActor/runWatchedModelCall(composedPrompt:_:)``
    /// handed out. Monotonic.
    var lastWatchId: UInt64 = 0

    /// The id of the watch over the model call in flight, or `nil` between
    /// calls. A stop from any other watch is too late and does not count.
    var activeWatchId: UInt64?

    /// The stop that the watch of the attempt in flight found, or `nil`.
    var stop: WatchStopMarker?

    /// How many recoveries the running answer ran, after repetition stops
    /// and reasoning stops together. The pump sets it to zero for each new
    /// answer (``RoutedSessionActor/startAnswerLimits()``), and a
    /// continuation submission of the same answer keeps it.
    var recoveriesThisAnswer = 0
}

/// The report of one stop of the watch: a call that repeats itself
/// (task ^1hcwaqy), or a pass whose reasoning reached the reasoning token
/// limit (task ^hm9trt5).
enum WatchStopReport: Sendable {
    /// The call no longer wrote new lines.
    case repetition(RepetitionStop)

    /// The pass reasoned and did not act.
    case reasoning(ReasoningStop)

    /// The number of the recovery attempt that follows the stop, or `nil`
    /// when the answer has no recovery left.
    var recovery: Int? {
        switch self {
        case .repetition(let stop):
            return stop.recovery
        case .reasoning(let stop):
            return stop.recovery
        }
    }

    /// The event that the answer emits for the stop.
    var event: SessionEvent {
        switch self {
        case .repetition(let stop):
            return .repetitionStopped(stop)
        case .reasoning(let stop):
            return .reasoningStopped(stop)
        }
    }

    /// The finish reason that the stopped attempt closes with.
    var finishReason: FinishReason {
        switch self {
        case .repetition:
            return .repeatedLines
        case .reasoning(let stop):
            return stop.passFinishReason
        }
    }

    /// The prompt of the recovery that follows the stop.
    var continuationPrompt: String {
        switch self {
        case .repetition:
            return RoutedSessionActor.repetitionStopContinuationPrompt
        case .reasoning:
            return RoutedSessionActor.reasoningStopContinuationPrompt
        }
    }

    /// The log category, the message and the metadata key of the log line
    /// of the stop.
    var logLine: (category: RouterTelemetry.LogCategory, message: Logger.Message, metadataKey: String) {
        switch self {
        case .repetition:
            return (
                .repetitionStop, "a repetition stop ends the model call",
                RouterTelemetry.LogMetadataKey.repetitionStop
            )
        case .reasoning:
            return (
                .reasoningStop, "a reasoning stop ends the model call",
                RouterTelemetry.LogMetadataKey.reasoningStop
            )
        }
    }

    /// The one-line rendering of the report, as the log line gives it.
    var description: String {
        switch self {
        case .repetition(let stop):
            return stop.description
        case .reasoning(let stop):
            return stop.description
        }
    }
}

/// The marker a session sets when its watch stops a model call, and the
/// facts it needs to go on after the stop.
struct WatchStopMarker: Sendable {
    /// The report of the stop, as the log line and the event give it.
    let report: WatchStopReport

    /// For each watched entry id, the UTF-8 length of its text that holds no
    /// repeated part. See ``RepetitionFinding/keptUTF8Lengths``. Empty for a
    /// reasoning stop, which keeps the whole reasoning so far.
    let keptUTF8Lengths: [String: Int]

    /// The live transcript that the watch read last, before the stop.
    let liveEntries: [Transcript.Entry]
}

/// Removes the repeated part of a stopped attempt from the render that the
/// model receives next (task ^1hcwaqy).
///
/// The recorded transcript keeps each entry whole. Only the render changes:
/// each watched entry keeps its text up to the end of its last new line,
/// and an entry with no text left leaves the render.
enum RepeatedPartRemoval {
    /// `entries` with the repeated part of each watched entry removed.
    ///
    /// - Parameters:
    ///   - entries: The transcript of the stopped attempt, whole.
    ///   - keptUTF8Lengths: For each watched entry id, the UTF-8 length to keep.
    /// - Returns: The render entries.
    static func render(of entries: [Transcript.Entry], keeping keptUTF8Lengths: [String: Int]) -> [Transcript.Entry] {
        entries.compactMap { entry in
            guard let kept = keptUTF8Lengths[entry.id] else { return entry }
            return trimmed(entry, toUTF8Length: kept)
        }
    }

    /// `entry` with its text cut to `kept` UTF-8 bytes, or `nil` when no text
    /// is left.
    ///
    /// A watched `.toolCalls` entry stays whole (task ^dzw15st). The rebuild
    /// of a stopped attempt already removed a call that got no output
    /// (``InFlightTranscript/removingUnansweredCalls(from:entryIdsBeforeAttempt:)``),
    /// and a call that got an output keeps its arguments, so the output keeps
    /// its call.
    ///
    /// - Parameters:
    ///   - entry: A watched `.reasoning`, `.response` or `.toolCalls` entry.
    ///   - kept: The UTF-8 length of the text to keep.
    /// - Returns: The cut entry, the same entry when nothing is cut, or `nil`.
    private static func trimmed(_ entry: Transcript.Entry, toUTF8Length kept: Int) -> Transcript.Entry? {
        switch entry {
        case .reasoning(var reasoning):
            guard kept > 0 else { return nil }
            guard let segments = cut(reasoning.segments, toUTF8Length: kept) else { return entry }
            reasoning.segments = segments
            return .reasoning(reasoning)
        case .response(var response):
            guard kept > 0 else { return nil }
            guard let segments = cut(response.segments, toUTF8Length: kept) else { return entry }
            response.segments = segments
            return .response(response)
        case .instructions, .prompt, .toolCalls, .toolOutput:
            return entry
        @unknown default:
            return entry
        }
    }

    /// One text segment that holds the first `kept` UTF-8 bytes of the text
    /// of `segments`, or `nil` when the text is not longer than `kept`.
    ///
    /// The cut is at the end of a line, so it never splits a character.
    ///
    /// - Parameters:
    ///   - segments: The segments of the entry.
    ///   - kept: The UTF-8 length of the text to keep.
    /// - Returns: The new segments, or `nil` when nothing is cut.
    private static func cut(_ segments: [Transcript.Segment], toUTF8Length kept: Int) -> [Transcript.Segment]? {
        let utf8 = WatchedText.text(of: segments).utf8
        guard utf8.count > kept else { return nil }
        let keptText = String(decoding: utf8.prefix(kept), as: UTF8.self)
        return [.text(Transcript.TextSegment(content: keptText))]
    }
}

/// ``RoutedSessionActor``'s repetition watch (task ^1hcwaqy): it reads the
/// reasoning, the text and the tool-call arguments of each model call of a
/// submission while the call is in flight, and again before each tool body
/// runs (``checkToolCallForRepetition()``, task ^dzw15st). It stops a call
/// that no longer writes new lines, and a pass whose reasoning reaches
/// ``RepetitionDetection/reasoningTokenLimit`` (task ^hm9trt5). It recovers
/// as a ceiling stop does (``continueAfterCeilingStop(attempt:body:)``): the
/// stopped attempt is recorded whole, the repeated part leaves the render,
/// and the same answer goes on with the continuation prompt of the stop, at
/// most ``RepetitionDetection/recoveriesPerAnswer`` times in one answer.
extension RoutedSessionActor {
    /// The prompt of the attempt that goes on after a repetition stop.
    ///
    /// The render already holds the original prompt and the new part of the
    /// stopped output, so the attempt does not send the original prompt again.
    static let repetitionStopContinuationPrompt = """
        Your last output repeated lines that you already wrote, so the session stopped it. \
        Do not go over the same points again. Act now: call a tool, or give your answer.
        """

    /// Runs the model call of one attempt under the repetition watch.
    ///
    /// When ``repetitionDetection`` is not enabled, or the backend gives no
    /// transcript update, the call runs as it does with no watch. A stop that
    /// the watch finds after the call ended by itself does not count.
    ///
    /// - Parameters:
    ///   - composedPrompt: This attempt's composed prompt, handed to `body`.
    ///   - body: The model work to run.
    /// - Returns: The response text `body` produced.
    /// - Throws: What ``runCancellableModelCall(composedPrompt:_:)`` throws,
    ///   `CancellationError` included when the watch stopped the call.
    func runWatchedModelCall(
        composedPrompt: String,
        _ body: @escaping @Sendable (String) async throws -> String
    ) async throws -> String {
        repetitionWatch.stop = nil
        let watch = startRepetitionWatch()
        defer {
            watch?.cancel()
            repetitionWatch.activeWatchId = nil
        }
        let response = try await runCancellableModelCall(composedPrompt: composedPrompt, body)
        repetitionWatch.stop = nil
        return response
    }

    /// Starts the watch over the model call about to start, or does nothing
    /// when ``repetitionDetection`` is not enabled.
    ///
    /// The watch reads ``LanguageModelSessionBackend/transcriptUpdates()`` in a
    /// task of its own, feeds the text of the attempt's entries to a
    /// ``RepetitionDetector``, and reports the first finding to
    /// ``noteRepetition(_:liveEntries:watchId:)`` or
    /// ``noteReasoningLimit(_:liveEntries:watchId:)``.
    ///
    /// - Returns: The task of the watch, which the caller cancels, or `nil`.
    private func startRepetitionWatch() -> Task<Void, Never>? {
        guard repetitionDetection.isEnabled else { return nil }
        repetitionWatch.lastWatchId += 1
        let watchId = repetitionWatch.lastWatchId
        repetitionWatch.activeWatchId = watchId
        let updates = backend.transcriptUpdates()
        let entryIdsBeforeAttempt = toolResultWatch.entryIdsBeforeAttempt
        let detection = repetitionDetection
        let tokenCounter = tokenCounter
        return Task { [weak self] in
            var detector = RepetitionDetector(detection: detection, tokenCounter: tokenCounter)
            for await entries in updates {
                let texts = WatchedText.attemptTexts(in: entries, excluding: entryIdsBeforeAttempt)
                if let finding = detector.observe(texts) {
                    await self?.noteRepetition(finding, liveEntries: entries, watchId: watchId)
                    return
                }
                if let finding = detector.reasoningLimitFinding() {
                    await self?.noteReasoningLimit(finding, liveEntries: entries, watchId: watchId)
                    return
                }
            }
        }
    }

    /// The number of the recovery that follows a stop now, from 1, or `nil`
    /// when the running answer ran ``RepetitionDetection/recoveriesPerAnswer``
    /// recoveries already. Repetition stops and reasoning stops share the
    /// count.
    var nextRecovery: Int? {
        let recoveries = repetitionWatch.recoveriesThisAnswer
        return recoveries < repetitionDetection.recoveriesPerAnswer ? recoveries + 1 : nil
    }

    /// Whether the watch named by `watchId` may stop the model call in
    /// flight: that watch is the active one, a model call is in flight, no
    /// stop is outstanding against the answer, and no tool result already
    /// stopped the call for a compaction.
    ///
    /// - Parameter watchId: The watch that found a stop.
    /// - Returns: `true` when the watch may stop the call.
    func watchMayStopModelCall(watchId: UInt64) -> Bool {
        repetitionWatch.activeWatchId == watchId && inFlightModelCall != nil && !isWorkCancelled
            && toolResultWatch.yield == nil
    }

    /// Stops the model call in flight for a repetition finding of the watch
    /// named by `watchId`.
    ///
    /// Nothing happens when the watch may not stop the call
    /// (``watchMayStopModelCall(watchId:)``). Otherwise the session logs the
    /// stop, sets the stop marker, and cancels ``inFlightModelCall``.
    ///
    /// - Parameters:
    ///   - finding: What the detector found.
    ///   - liveEntries: The live transcript the watch read last.
    ///   - watchId: The watch that found it.
    func noteRepetition(_ finding: RepetitionFinding, liveEntries: [Transcript.Entry], watchId: UInt64) {
        guard watchMayStopModelCall(watchId: watchId) else { return }
        let report = RepetitionStop(
            generatedTokens: finding.generatedTokens, countedLines: finding.countedLines,
            newLines: finding.newLines, tokensWithoutNewLine: finding.tokensWithoutNewLine,
            detection: repetitionDetection, recovery: nextRecovery)
        stopModelCall(
            WatchStopMarker(
                report: .repetition(report), keptUTF8Lengths: finding.keptUTF8Lengths, liveEntries: liveEntries))
    }

    /// Logs the stop of `marker`, sets the marker, and cancels
    /// ``inFlightModelCall``.
    ///
    /// - Parameter marker: The stop marker of the call in flight.
    func stopModelCall(_ marker: WatchStopMarker) {
        repetitionWatch.stop = marker
        logWatchStop(marker.report)
        inFlightModelCall?.cancel()
    }

    /// Writes the log line of one stop of the watch, with the report under
    /// the metadata key of its kind.
    ///
    /// - Parameter report: The report of the stop.
    func logWatchStop(_ report: WatchStopReport) {
        let line = report.logLine
        sessionLogger(line.category).notice(
            line.message,
            metadata: [
                RouterTelemetry.LogMetadataKey.sessionId: "\(id.description)",
                line.metadataKey: "\(report.description)",
            ])
    }

    /// Stops the model call in flight before a tool body of it runs, when the
    /// text of the attempt with the arguments of its tool calls fills one
    /// window of repeated lines (task ^dzw15st).
    ///
    /// The backend shows a tool call only after the model ended it, and the
    /// SDK then runs the tool. So the watch of the pass cannot stop a tool
    /// call whose arguments repeat. This check runs on the task of each tool
    /// body of this session's own open model call
    /// (``ToolCallRepetitionCheck``), where the SDK waits for the tool and
    /// writes no transcript, so the read of the transcript is safe. It reads
    /// the whole attempt with a new ``RepetitionDetector``, and a finding
    /// stops the call as the watch does (``noteRepetition(_:liveEntries:watchId:)``).
    ///
    /// The check does not apply the reasoning token limit: a pass that wrote
    /// a tool call acts, and the limit stops only a pass that does not act.
    ///
    /// Nothing happens when the detection is not enabled, when no watch is
    /// active, or when the tool body is not in an open model call of this
    /// session.
    ///
    /// - Throws: `CancellationError` when the watch stopped the call, before
    ///   or in this check. The tool body must then not run.
    func checkToolCallForRepetition() throws {
        guard repetitionDetection.isEnabled, let watchId = repetitionWatch.activeWatchId,
            ModelCallMark.current?.isOpenModelCall(of: id) == true
        else { return }
        if repetitionWatch.stop == nil {
            let entries = backend.transcriptEntries()
            var detector = RepetitionDetector(detection: repetitionDetection, tokenCounter: tokenCounter)
            let texts = WatchedText.attemptTexts(in: entries, excluding: toolResultWatch.entryIdsBeforeAttempt)
            guard let finding = detector.observe(texts) else { return }
            noteRepetition(finding, liveEntries: entries, watchId: watchId)
        }
        guard repetitionWatch.stop == nil else { throw CancellationError() }
    }

    /// Takes the stop marker of the attempt that just failed.
    ///
    /// A stop outstanding against the answer wins: the failure is then a user
    /// stop, and the marker is dropped.
    ///
    /// - Returns: The marker, or `nil` when the watch did not stop the attempt.
    func takeWatchStop() -> WatchStopMarker? {
        defer { repetitionWatch.stop = nil }
        guard !isWorkCancelled else { return nil }
        return repetitionWatch.stop
    }

    /// Records the stopped attempt whole, removes its repeated part from the
    /// render, and runs one more submission of the same answer when the answer
    /// has a recovery left.
    ///
    /// 1. The answer emits the event of the stop
    ///    (``SessionEvent/repetitionStopped(_:)`` or
    ///    ``SessionEvent/reasoningStopped(_:)``).
    /// 2. The rebuilt transcript (``InFlightTranscript``) goes into
    ///    ``backend``, and the ordinary diff records its entries, whole. The
    ///    attempt closes with the finish reason of the stop
    ///    (``FinishReason/repeatedLines`` or ``FinishReason/reasoningTokenLimit``).
    /// 3. ``RepeatedPartRemoval`` cuts the repeated part out of ``backend``.
    ///    The record keeps it, and one
    ///    ``TranscriptEvent/Kind/repeatedPartRemoval`` event records the cut,
    ///    so a restore makes the same cut (task ^gg49g5e). A reasoning stop
    ///    cuts nothing, and records no cut.
    /// 4. With a recovery left, the next attempt sends the continuation
    ///    prompt of the stop. With none, the answer ends with the response
    ///    text of the stopped attempt.
    ///
    /// - Parameters:
    ///   - marker: The stop marker of the stopped attempt.
    ///   - attempt: The stopped attempt.
    ///   - body: The model work to run.
    /// - Returns: The response text of the next attempt, or of the stopped
    ///   attempt when no recovery is left.
    /// - Throws: What the next attempt throws.
    func continueAfterWatchStop(
        _ marker: WatchStopMarker,
        attempt: StoppedAttempt,
        body: @escaping @Sendable (String) async throws -> String
    ) async throws -> String {
        attempt.onEvent?(marker.report.event)
        let (rebuilt, render) = await recordStoppedAttempt(marker, attempt: attempt)
        replaceRender(with: render)
        if !marker.keptUTF8Lengths.isEmpty {
            await recordRepeatedPartRemoval(keeping: marker.keptUTF8Lengths, grammar: attempt.grammar)
        }
        guard let recovery = marker.report.recovery else {
            return Self.responseText(of: rebuilt, excluding: attempt.entryIdsBeforeAttempt)
        }
        repetitionWatch.recoveriesThisAnswer = recovery
        return try await runContinuation(after: attempt, prompt: marker.report.continuationPrompt, body: body)
    }

    /// Puts the rebuilt transcript of the stopped attempt into ``backend``
    /// and records it with the finish reason of the stop.
    ///
    /// The usage of the attempt and the measure of the stop
    /// (``measureWatchStop(_:rebuilt:render:)``, task ^3anq1yz) are read
    /// before the backend is replaced, because a replaced backend starts a
    /// usage count of its own. The usage of the attempt adds the tokens of
    /// the stopped call that the backend did not report. The baseline
    /// given to the finish is the count of the replaced backend minus that
    /// usage, so the finish records the usage of the attempt.
    ///
    /// - Parameters:
    ///   - marker: The stop marker of the stopped attempt.
    ///   - attempt: The stopped attempt.
    /// - Returns: The rebuilt transcript, whole, and the render that the next
    ///   pass receives: the rebuilt transcript with the repeated part removed
    ///   (``RepeatedPartRemoval``).
    private func recordStoppedAttempt(
        _ marker: WatchStopMarker, attempt: StoppedAttempt
    ) async -> (rebuilt: [Transcript.Entry], render: [Transcript.Entry]) {
        let usageOfAttempt = Self.usageDelta(before: attempt.usageBefore, after: backend.usageTokenCounts())
        let rebuilt = InFlightTranscript.rebuilt(
            settledEntries: backend.transcriptEntries(), sources: [marker.liveEntries],
            entryIdsBeforeAttempt: attempt.entryIdsBeforeAttempt, composedPrompt: attempt.composedPrompt)
        let render = RepeatedPartRemoval.render(of: rebuilt, keeping: marker.keptUTF8Lengths)
        let measure = measureWatchStop(marker, rebuilt: rebuilt, render: render)
        let usage = usageOfAttempt.map {
            (input: $0.input + measure.addedUsage.input, output: $0.output + measure.addedUsage.output)
        }
        await replaceBackendAndRecord(
            with: rebuilt, attempt: attempt, usageOfAttempt: usage, stopReason: marker.report.finishReason,
            measure: measure)
        return (rebuilt, render)
    }

    /// Replaces the render that the model receives with `entries`, and moves
    /// the recorded baseline to it, as a compaction does. The record keeps
    /// what it holds, and the next diff finds no divergence. The new backend
    /// runs no call yet, so the render is also the new settled transcript.
    ///
    /// - Parameter entries: The new render.
    private func replaceRender(with entries: [Transcript.Entry]) {
        let render = Transcript(entries: entries)
        backend = backend.replacingTranscript(render)
        persistedEntryCount = render.count
        persistedBaseline = TranscriptDiffer.Baseline(transcript: render)
        settleTranscript()
    }

    /// Records the cut that ``replaceRender(with:)`` made as one
    /// ``TranscriptEvent/Kind/repeatedPartRemoval`` event, after the entries
    /// of the stopped attempt (task ^gg49g5e).
    ///
    /// The recorded entries stay whole. A restore reads this event and makes
    /// the same cut of the rebuilt render, so a restored session gives the
    /// model the render that this session gives it.
    ///
    /// - Parameters:
    ///   - keptUTF8Lengths: For each watched entry id, the UTF-8 length that
    ///     the render keeps.
    ///   - grammar: The grammar in force for the answer.
    private func recordRepeatedPartRemoval(keeping keptUTF8Lengths: [String: Int], grammar: Grammar?) async {
        let segment = RepeatedPartRemovalSegment(content: .init(keptUTF8Lengths: keptUTF8Lengths))
        await append(
            partial: makePartialEvent(
                kind: .repeatedPartRemoval, grammar: grammar, text: segment.description, entry: segment.eventPayload))
    }

    /// The joined text of the `.response` entries of the attempt in `entries`.
    ///
    /// - Parameters:
    ///   - entries: The rebuilt transcript of the stopped attempt.
    ///   - entryIdsBeforeAttempt: The ids of the entries from before the attempt.
    /// - Returns: The response text of the attempt, empty when it wrote none.
    private static func responseText(
        of entries: [Transcript.Entry], excluding entryIdsBeforeAttempt: Set<String>
    ) -> String {
        entries.compactMap { entry -> String? in
            guard !entryIdsBeforeAttempt.contains(entry.id), case .response(let response) = entry else {
                return nil
            }
            return WatchedText.text(of: response.segments)
        }.joined()
    }
}
