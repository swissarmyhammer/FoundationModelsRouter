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

    /// Whether the running answer ran its final pass: the one pass with the
    /// reasoning of the model off after a stop that found no recovery left
    /// (task ^0dcsd3t). A stop in or after the final pass ends the answer.
    /// The pump clears it for each new answer.
    var finalPassRan = false

    /// The run of identical consecutive tool calls of the running answer
    /// (task ^8eq31j0). The pump starts a new run for each new answer, and a
    /// recovery or the final pass of the same answer keeps it.
    var toolCallRun = IdenticalToolCallRun()
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
        summary.recovery
    }

    /// The short report of the stop, for the journal and the answer
    /// (task ^0dcsd3t).
    var summary: WatchStop {
        switch self {
        case .repetition(let stop):
            return WatchStop(stop)
        case .reasoning(let stop):
            return WatchStop(stop)
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
        summary.passFinishReason
    }

    /// The prompt of the recovery that follows the stop. A repetition stop
    /// on a repeated tool call names the tool and the count (task ^8eq31j0).
    var continuationPrompt: String {
        switch self {
        case .repetition(let stop):
            return stop.repeatedToolCall.map(RoutedSessionActor.repeatedToolCallContinuationPrompt)
                ?? RoutedSessionActor.repetitionStopContinuationPrompt
        case .reasoning:
            return RoutedSessionActor.reasoningStopContinuationPrompt
        }
    }

    /// The prompt of the final pass that follows the stop when no recovery
    /// is left: ``RoutedSessionActor/finalPassPrompt``, after the notice of
    /// the repeated tool call when the stop has one (task ^8eq31j0).
    var finalPassPrompt: String {
        guard let repeatedToolCall = summary.repeatedToolCall else { return RoutedSessionActor.finalPassPrompt }
        return RoutedSessionActor.repeatedToolCallNotice(repeatedToolCall) + " " + RoutedSessionActor.finalPassPrompt
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

    /// For each watched entry id, the UTF-8 ranges of its lines that are not
    /// repeats. See ``RepetitionFinding/keptUTF8Ranges``. Empty for a
    /// reasoning stop.
    let keptUTF8Ranges: [String: [KeptUTF8Range]]

    /// The live transcript that the watch read last, before the stop.
    let liveEntries: [Transcript.Entry]
}

/// ``RoutedSessionActor``'s repetition watch (task ^1hcwaqy): it reads the
/// reasoning, the text and the tool-call arguments of each model call of a
/// submission while the call is in flight, and again before each tool body
/// runs (``checkToolCallForRepetition(_:)``, task ^dzw15st). It stops a call
/// that no longer writes new lines, and a pass whose reasoning reaches
/// ``RepetitionDetection/reasoningTokenLimit`` (task ^hm9trt5). It recovers
/// as a ceiling stop does (``continueAfterCeilingStop(attempt:body:)``): the
/// stopped attempt is recorded whole, the repeated part leaves the render,
/// and the same answer goes on with the continuation prompt of the stop, at
/// most ``RepetitionDetection/recoveriesPerAnswer`` times in one answer.
///
/// Each recovery runs its model call with the reasoning of the model off
/// (``ReasoningOffRequest``), and the render closes the stopped reasoning
/// before the prompt of the recovery (``ReasoningClosure``). After the last
/// recovery, one final pass with the reasoning off asks for the final answer,
/// and the answer never ends with an empty reply (task ^0dcsd3t).
extension RoutedSessionActor {
    /// The end of each prompt of a recovery after a repetition stop: it tells
    /// the model to act.
    static let repetitionStopActRequest = """
        Stop reasoning. \
        Your next output must be one tool call that makes the change you decided on, or your final answer.
        """

    /// The prompt of the attempt that goes on after a repetition stop.
    ///
    /// The render already holds the original prompt and the new part of the
    /// stopped output, so the attempt does not send the original prompt again.
    static let repetitionStopContinuationPrompt =
        "Your last output repeated lines that you already wrote, so the session stopped it. "
        + repetitionStopActRequest

    /// The sentences that tell the model which tool call it repeated
    /// (task ^8eq31j0). A general text that tells the model not to repeat
    /// does not stop a loop of the same tool call, so the recovery prompt and
    /// the final pass prompt name the tool and the count.
    ///
    /// - Parameter call: The repeated tool call.
    /// - Returns: The sentences.
    static func repeatedToolCallNotice(_ call: RepeatedToolCall) -> String {
        """
        You called `\(call.toolName)` with the same arguments \(call.count) times in a row. \
        The output does not change. Do not call it again with these arguments.
        """
    }

    /// The prompt of the attempt that goes on after a repetition stop on a
    /// repeated tool call (task ^8eq31j0): the notice of the call, then the
    /// request to act.
    ///
    /// - Parameter call: The repeated tool call.
    /// - Returns: The prompt.
    static func repeatedToolCallContinuationPrompt(_ call: RepeatedToolCall) -> String {
        repeatedToolCallNotice(call) + " The session stopped your last output. " + repetitionStopActRequest
    }

    /// The prompt of the final pass of an answer: the pass after a stop that
    /// found no recovery left (task ^0dcsd3t).
    ///
    /// The tools of the session stay available in the final pass, and the
    /// work of an agent is in a tool call, not in its final text. So the
    /// prompt lets the model make one tool call that makes the change, and
    /// the tool loop then goes on to its end (task ^8eq31j0).
    static let finalPassPrompt = """
        No recovery is left, so this is your last output. Stop reasoning. \
        If a change is not made yet, make it now with one tool call. \
        Then give your final answer with what you know now.
        """

    /// The text of the response that closes a stopped reasoning in the render
    /// (``ReasoningClosure``, task ^0dcsd3t).
    static let reasoningClosureText = "(The session stopped this reasoning here.)"

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
    /// stop, sets the stop marker, and cancels ``inFlightModelCall``. The
    /// report names the tool call that the answer repeated up to the stop,
    /// when there is one (``RepetitionWatchState/toolCallRun``, task ^8eq31j0).
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
            detection: repetitionDetection, recovery: nextRecovery,
            repeatedToolCall: repetitionWatch.toolCallRun.repeatedToolCall)
        stopModelCall(
            WatchStopMarker(
                report: .repetition(report), keptUTF8Lengths: finding.keptUTF8Lengths,
                keptUTF8Ranges: finding.keptUTF8Ranges, liveEntries: liveEntries))
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
    /// window of repeated lines (task ^dzw15st), or when this call is the one
    /// that reaches ``RepetitionDetection/identicalToolCallLimit`` (task
    /// ^8eq31j0).
    ///
    /// The backend shows a tool call only after the model ended it, and the
    /// SDK then runs the tool. So the watch of the pass cannot stop a tool
    /// call whose arguments repeat. This check runs on the task of each tool
    /// body of this session's own open model call
    /// (``ToolCallRepetitionCheck``), where the SDK waits for the tool and
    /// writes no transcript, so the read of the transcript is safe. It adds
    /// `call` to the run of identical consecutive tool calls of the answer,
    /// reads the whole attempt with a new ``RepetitionDetector``, and a
    /// finding stops the call as the watch does
    /// (``noteRepetition(_:liveEntries:watchId:)``). A run that reaches the
    /// identical tool call limit stops the call with the counts of the
    /// detector so far, and the render keeps the whole text of the attempt:
    /// the rebuild removes the tool call that got no output.
    ///
    /// The check does not apply the reasoning token limit: a pass that wrote
    /// a tool call acts, and the limit stops only a pass that does not act.
    ///
    /// Nothing happens when the detection is not enabled, when no watch is
    /// active, or when the tool body is not in an open model call of this
    /// session.
    ///
    /// - Parameter call: The identity of the tool call whose body is about to
    ///   run, or `nil` when its arguments cannot be compared.
    /// - Throws: `CancellationError` when the watch stopped the call, before
    ///   or in this check. The tool body must then not run.
    func checkToolCallForRepetition(_ call: ToolCallIdentity?) throws {
        guard repetitionDetection.isEnabled, let watchId = repetitionWatch.activeWatchId,
            ModelCallMark.current?.isOpenModelCall(of: id) == true
        else { return }
        if repetitionWatch.stop == nil {
            repetitionWatch.toolCallRun.add(call)
            noteToolCallRepetition(watchId: watchId)
        }
        guard repetitionWatch.stop == nil else { throw CancellationError() }
    }

    /// Reads the whole attempt with a new ``RepetitionDetector`` and stops
    /// the model call when one window of repeated lines filled, or when the
    /// run of identical consecutive tool calls reached
    /// ``RepetitionDetection/identicalToolCallLimit`` (task ^8eq31j0).
    ///
    /// - Parameter watchId: The active watch.
    private func noteToolCallRepetition(watchId: UInt64) {
        let entries = backend.transcriptEntries()
        var detector = RepetitionDetector(detection: repetitionDetection, tokenCounter: tokenCounter)
        let texts = WatchedText.attemptTexts(in: entries, excluding: toolResultWatch.entryIdsBeforeAttempt)
        if let finding = detector.observe(texts) {
            noteRepetition(finding, liveEntries: entries, watchId: watchId)
        } else if let limit = repetitionDetection.identicalToolCallLimitInForce,
            repetitionWatch.toolCallRun.count >= limit
        {
            noteRepetition(detector.findingThatKeepsAll(), liveEntries: entries, watchId: watchId)
        }
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

    /// Records the stopped attempt whole, changes the render, and goes on
    /// with the same answer.
    ///
    /// 1. The answer emits the event of the stop
    ///    (``SessionEvent/repetitionStopped(_:)`` or
    ///    ``SessionEvent/reasoningStopped(_:)``).
    /// 2. The rebuilt transcript (``InFlightTranscript``) goes into
    ///    ``backend``, and the ordinary diff records its entries, whole. The
    ///    attempt closes with the finish reason of the stop
    ///    (``FinishReason/repeatedLines`` or ``FinishReason/reasoningTokenLimit``).
    /// 3. ``RepeatedPartRemoval`` cuts the repeated part out of ``backend``,
    ///    and closes the stopped reasoning (``ReasoningClosure``). The record
    ///    keeps each entry whole, and one
    ///    ``TranscriptEvent/Kind/repeatedPartRemoval`` event records the
    ///    change, so a restore makes the same change (task ^gg49g5e).
    /// 4. One ``TranscriptEvent/Kind/watchStop`` event records the stop.
    /// 5. The answer goes on (``recover(after:attempt:compacts:body:)``).
    ///
    /// - Parameters:
    ///   - marker: The stop marker of the stopped attempt.
    ///   - attempt: The stopped attempt.
    ///   - body: The model work to run.
    /// - Returns: The response text of the next attempt, or the text that
    ///   states the stop when the final pass gives no text.
    /// - Throws: What the next attempt throws.
    func continueAfterWatchStop(
        _ marker: WatchStopMarker,
        attempt: StoppedAttempt,
        body: @escaping @Sendable (String) async throws -> String
    ) async throws -> String {
        attempt.onEvent?(marker.report.event)
        let render = await recordStoppedAttempt(marker, attempt: attempt)
        replaceRender(with: render.entries)
        await recordRenderChange(render.change, grammar: attempt.grammar)
        await recordWatchStop(marker.report, grammar: attempt.grammar)
        return try await recover(after: marker.report, attempt: attempt, compacts: false, body: body)
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
    /// - Returns: The render that the next pass receives
    ///   (``RepeatedPartRemoval/renderAfterStop(of:keptUTF8Lengths:keptUTF8Ranges:closureText:)``),
    ///   and the change of the render.
    private func recordStoppedAttempt(
        _ marker: WatchStopMarker, attempt: StoppedAttempt
    ) async -> (entries: [Transcript.Entry], change: RepeatedPartRemovalSegment.Content) {
        let usageOfAttempt = Self.usageDelta(before: attempt.usageBefore, after: backend.usageTokenCounts())
        let rebuilt = InFlightTranscript.rebuilt(
            settledEntries: backend.transcriptEntries(), sources: [marker.liveEntries],
            entryIdsBeforeAttempt: attempt.entryIdsBeforeAttempt, composedPrompt: attempt.composedPrompt)
        let render = RepeatedPartRemoval.renderAfterStop(
            of: rebuilt, keptUTF8Lengths: marker.keptUTF8Lengths, keptUTF8Ranges: marker.keptUTF8Ranges,
            closureText: Self.reasoningClosureText)
        let measure = measureWatchStop(marker, rebuilt: rebuilt, render: render.entries)
        let usage = usageOfAttempt.map {
            (input: $0.input + measure.addedUsage.input, output: $0.output + measure.addedUsage.output)
        }
        await replaceBackendAndRecord(
            with: rebuilt, attempt: attempt, usageOfAttempt: usage, stopReason: marker.report.finishReason,
            measure: measure)
        return render
    }

    /// Replaces the render that the model receives with `entries`, and moves
    /// the recorded baseline to it, as a compaction does. The record keeps
    /// what it holds, and the next diff finds no divergence. The new backend
    /// runs no call yet, so the render is also the new settled transcript.
    ///
    /// - Parameter entries: The new render.
    func replaceRender(with entries: [Transcript.Entry]) {
        let render = Transcript(entries: entries)
        backend = backend.replacingTranscript(render)
        persistedEntryCount = render.count
        persistedBaseline = TranscriptDiffer.Baseline(transcript: render)
        settleTranscript()
    }

    /// Records the change that ``replaceRender(with:)`` made as one
    /// ``TranscriptEvent/Kind/repeatedPartRemoval`` event, after the entries
    /// of the stopped attempt (tasks ^gg49g5e and ^0dcsd3t). A change that
    /// changes nothing records nothing.
    ///
    /// The recorded entries stay whole, and the record holds no closing
    /// response. A restore reads this event and makes the same change of the
    /// rebuilt render, so a restored session gives the model the render that
    /// this session gives it.
    ///
    /// - Parameters:
    ///   - change: The change of the render.
    ///   - grammar: The grammar in force for the answer.
    func recordRenderChange(_ change: RepeatedPartRemovalSegment.Content, grammar: Grammar?) async {
        guard change.changesRender else { return }
        let segment = RepeatedPartRemovalSegment(content: change)
        await append(
            partial: makePartialEvent(
                kind: .repeatedPartRemoval, grammar: grammar, text: segment.description, entry: segment.eventPayload))
    }

    /// Records one stop of the watch as one ``TranscriptEvent/Kind/watchStop``
    /// event (task ^0dcsd3t): its kind, its tokens, its limit and its
    /// recovery. A host that logs only warnings reads the stop here.
    ///
    /// - Parameters:
    ///   - report: The report of the stop.
    ///   - grammar: The grammar in force for the answer.
    func recordWatchStop(_ report: WatchStopReport, grammar: Grammar?) async {
        let segment = WatchStopSegment(content: report.summary)
        await append(
            partial: makePartialEvent(
                kind: .watchStop, grammar: grammar, text: report.summary.description, entry: segment.eventPayload))
    }

    /// Goes on with the answer after a stop of the watch.
    ///
    /// With a recovery left, the next attempt sends the continuation prompt
    /// of the stop, with the reasoning of the model off (task ^0dcsd3t). When
    /// `compacts` is `true`, the answer compacts first, as after any ceiling
    /// stop. With no recovery left, the answer runs its final pass
    /// (``runFinalPass(after:attempt:body:)``).
    ///
    /// - Parameters:
    ///   - report: The report of the stop.
    ///   - attempt: The stopped attempt.
    ///   - compacts: Whether the answer compacts before the recovery.
    ///   - body: The model work to run.
    /// - Returns: The response text of the next attempt, or the text that
    ///   states the stop.
    /// - Throws: What the compaction or the next attempt throws.
    func recover(
        after report: WatchStopReport,
        attempt: StoppedAttempt,
        compacts: Bool,
        body: @escaping @Sendable (String) async throws -> String
    ) async throws -> String {
        guard let recovery = report.recovery else {
            return try await runFinalPass(after: report, attempt: attempt, body: body)
        }
        repetitionWatch.recoveriesThisAnswer = recovery
        guard compacts else {
            return try await runContinuation(
                after: attempt, prompt: report.continuationPrompt, reasoningOff: true, body: body)
        }
        return try await compactAndContinue(
            attempt: attempt, reason: .outputCeilingStop, continuationPrompt: report.continuationPrompt,
            reasoningOff: true, body: body)
    }

    /// Runs the final pass of the answer after a stop that found no recovery
    /// left (task ^0dcsd3t), and never gives an empty reply.
    ///
    /// The final pass sends ``WatchStopReport/finalPassPrompt`` with the
    /// reasoning of the model off, under the token ceiling of the stopped
    /// attempt (``StoppedAttempt/responseTokenCeiling``): the pass gets no
    /// limit of its own. The tools of the session stay available, so the pass
    /// can make a tool call, and the tool loop goes on to its end
    /// (task ^8eq31j0). It runs one time in an answer. When it gives no text,
    /// or when a stop comes in or after it, the reply is the text that states
    /// the stop (``WatchStop/stoppedAnswerText``).
    ///
    /// - Parameters:
    ///   - report: The report of the stop that found no recovery left.
    ///   - attempt: The stopped attempt.
    ///   - body: The model work to run.
    /// - Returns: The reply of the final pass, or the text that states the stop.
    /// - Throws: What the final pass throws.
    private func runFinalPass(
        after report: WatchStopReport,
        attempt: StoppedAttempt,
        body: @escaping @Sendable (String) async throws -> String
    ) async throws -> String {
        let stopText = report.summary.stoppedAnswerText
        guard !repetitionWatch.finalPassRan else { return stopText }
        repetitionWatch.finalPassRan = true
        let reply = try await runContinuation(
            after: attempt, prompt: report.finalPassPrompt, reasoningOff: true, body: body)
        return reply.allSatisfy(\.isWhitespace) ? stopText : reply
    }
}
