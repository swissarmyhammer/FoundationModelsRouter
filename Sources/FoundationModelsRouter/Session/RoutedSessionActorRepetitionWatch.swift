import Foundation
import FoundationModels
import os

/// The logger for a repetition stop.
private let repetitionStopLogger = makeModuleLogger(category: "RepetitionStop")

/// The repetition watch of one session: the watch of the model call in
/// flight, the stop it found, and the recoveries of the turn in flight.
struct RepetitionWatchState {
    /// The last watch id that ``RoutedSessionActor/runWatchedModelCall(composedPrompt:_:)``
    /// handed out. Monotonic.
    var lastWatchId: UInt64 = 0

    /// The id of the watch over the model call in flight, or `nil` between
    /// calls. A stop from any other watch is too late and does not count.
    var activeWatchId: UInt64?

    /// The stop that the watch of the attempt in flight found, or `nil`.
    var stop: RepetitionStopMarker?

    /// How many recoveries the turn in flight ran. ``RoutedSessionActor/beginTurn()``
    /// sets it to zero.
    var recoveriesThisTurn = 0
}

/// The marker a session sets when its watch stops a model call that
/// repeats itself, and the facts it needs to go on after the stop.
struct RepetitionStopMarker: Sendable {
    /// The report of the stop, as the log line and the event give it.
    let report: RepetitionStop

    /// For each watched entry id, the UTF-8 length of its text that holds no
    /// repeated part. See ``RepetitionFinding/keptUTF8Lengths``.
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
    /// - Parameters:
    ///   - entry: A watched `.reasoning` or `.response` entry.
    ///   - kept: The UTF-8 length of the text to keep.
    /// - Returns: The cut entry, the same entry when nothing is cut, or `nil`.
    private static func trimmed(_ entry: Transcript.Entry, toUTF8Length kept: Int) -> Transcript.Entry? {
        guard kept > 0 else { return nil }
        switch entry {
        case .reasoning(var reasoning):
            guard let segments = cut(reasoning.segments, toUTF8Length: kept) else { return entry }
            reasoning.segments = segments
            return .reasoning(reasoning)
        case .response(var response):
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
/// reasoning and the text of each model call of a turn while the call is in
/// flight, stops a call that no longer writes new lines, and recovers as a
/// ceiling stop does (``continueAfterCeilingStop(attempt:body:)``): the
/// stopped attempt is recorded whole, the repeated part leaves the render,
/// and the same turn goes on with ``repetitionStopContinuationPrompt``, at
/// most ``RepetitionDetection/recoveriesPerTurn`` times.
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
    /// ``noteRepetition(_:liveEntries:watchId:)``.
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
                guard let finding = detector.observe(texts) else { continue }
                await self?.noteRepetition(finding, liveEntries: entries, watchId: watchId)
                return
            }
        }
    }

    /// Stops the model call in flight for a repetition finding of the watch
    /// named by `watchId`.
    ///
    /// Nothing happens when that watch is no longer the active one, when no
    /// model call is in flight, when a stop is outstanding against the turn,
    /// or when a tool result already stopped the call for a compaction.
    /// Otherwise the session logs the stop, sets the stop marker, and cancels
    /// ``inFlightModelCall``.
    ///
    /// - Parameters:
    ///   - finding: What the detector found.
    ///   - liveEntries: The live transcript the watch read last.
    ///   - watchId: The watch that found it.
    func noteRepetition(_ finding: RepetitionFinding, liveEntries: [Transcript.Entry], watchId: UInt64) {
        guard repetitionWatch.activeWatchId == watchId, let modelCall = inFlightModelCall,
            !isTurnCancelled, toolResultWatch.yield == nil
        else { return }
        let recoveriesLeft = repetitionWatch.recoveriesThisTurn < repetitionDetection.recoveriesPerTurn
        let report = RepetitionStop(
            generatedTokens: finding.generatedTokens, countedLines: finding.countedLines,
            newLines: finding.newLines, tokensWithoutNewLine: finding.tokensWithoutNewLine,
            detection: repetitionDetection,
            recovery: recoveriesLeft ? repetitionWatch.recoveriesThisTurn + 1 : nil)
        repetitionWatch.stop = RepetitionStopMarker(
            report: report, keptUTF8Lengths: finding.keptUTF8Lengths, liveEntries: liveEntries)
        repetitionStopLogger.notice(
            "session \(self.id.description, privacy: .public): \(report.description, privacy: .public)")
        modelCall.cancel()
    }

    /// Takes the repetition stop marker of the attempt that just failed.
    ///
    /// A stop outstanding against the turn wins: the failure is then a user
    /// stop, and the marker is dropped.
    ///
    /// - Returns: The marker, or `nil` when the watch did not stop the attempt.
    func takeRepetitionStop() -> RepetitionStopMarker? {
        defer { repetitionWatch.stop = nil }
        guard !isTurnCancelled else { return nil }
        return repetitionWatch.stop
    }

    /// Records the stopped attempt whole, removes its repeated part from the
    /// render, and runs one more attempt of the same turn when the turn has a
    /// recovery left.
    ///
    /// 1. The turn emits ``SessionEvent/repetitionStopped(_:)``.
    /// 2. The rebuilt transcript (``InFlightTranscript``) goes into
    ///    ``backend``, and the ordinary diff records its entries, whole. The
    ///    attempt closes with ``FinishReason/repeatedLines``.
    /// 3. ``RepeatedPartRemoval`` cuts the repeated part out of ``backend``.
    ///    The record keeps it, and one
    ///    ``TranscriptEvent/Kind/repeatedPartRemoval`` event records the cut,
    ///    so a restore makes the same cut (task ^gg49g5e).
    /// 4. With a recovery left, the next attempt sends
    ///    ``repetitionStopContinuationPrompt``. With none, the turn ends with
    ///    the response text of the stopped attempt.
    ///
    /// - Parameters:
    ///   - marker: The stop marker of the stopped attempt.
    ///   - attempt: The stopped attempt.
    ///   - body: The model work to run.
    /// - Returns: The response text of the next attempt, or of the stopped
    ///   attempt when no recovery is left.
    /// - Throws: What the next attempt throws.
    func continueAfterRepetitionStop(
        _ marker: RepetitionStopMarker,
        attempt: StoppedAttempt,
        body: @escaping @Sendable (String) async throws -> String
    ) async throws -> String {
        attempt.onEvent?(.repetitionStopped(marker.report))
        let rebuilt = await recordStoppedAttempt(marker, attempt: attempt)
        replaceRender(with: RepeatedPartRemoval.render(of: rebuilt, keeping: marker.keptUTF8Lengths))
        await recordRepeatedPartRemoval(keeping: marker.keptUTF8Lengths, grammar: attempt.grammar)
        guard let recovery = marker.report.recovery else {
            return Self.responseText(of: rebuilt, excluding: attempt.entryIdsBeforeAttempt)
        }
        repetitionWatch.recoveriesThisTurn = recovery
        return try await runTurnAttempt(
            grammar: attempt.grammar, pendingEvents: [], ownPrompt: Self.repetitionStopContinuationPrompt,
            responseTokenCeiling: attempt.responseTokenCeiling, onEvent: attempt.onEvent,
            allowOverflowRetry: attempt.allowOverflowRetry, rejectedCallRetries: attempt.rejectedCallRetries, body)
    }

    /// Puts the rebuilt transcript of the stopped attempt into ``backend``
    /// and records it with the finish reason ``FinishReason/repeatedLines``.
    ///
    /// The usage of the attempt is read before the backend is replaced,
    /// because a replaced backend starts a usage count of its own. The
    /// baseline given to the finish is the count of the replaced backend
    /// minus the usage of the attempt, so the finish records the usage of
    /// the attempt.
    ///
    /// - Parameters:
    ///   - marker: The stop marker of the stopped attempt.
    ///   - attempt: The stopped attempt.
    /// - Returns: The rebuilt transcript, whole.
    private func recordStoppedAttempt(_ marker: RepetitionStopMarker, attempt: StoppedAttempt) async -> [Transcript.Entry] {
        let usageOfAttempt = Self.usageDelta(before: attempt.usageBefore, after: backend.usageTokenCounts())
        let rebuilt = InFlightTranscript.rebuilt(
            settledEntries: backend.transcriptEntries(), sources: [marker.liveEntries],
            entryIdsBeforeAttempt: attempt.entryIdsBeforeAttempt, composedPrompt: attempt.composedPrompt)
        backend = backend.replacingTranscript(Transcript(entries: rebuilt))
        _ = await finishTurnAndRequeueIfUnattached(
            grammar: attempt.grammar, since: attempt.started,
            usageBefore: Self.usageDelta(before: usageOfAttempt, after: backend.usageTokenCounts()),
            responseTokenCeiling: attempt.responseTokenCeiling.resolved, pendingEvents: attempt.pendingEvents,
            onEvent: attempt.onEvent, stopReason: .repeatedLines)
        return rebuilt
    }

    /// Replaces the render that the model receives with `entries`, and moves
    /// the recorded baseline to it, as a compaction does. The record keeps
    /// what it holds, and the next diff finds no divergence.
    ///
    /// - Parameter entries: The new render.
    private func replaceRender(with entries: [Transcript.Entry]) {
        let render = Transcript(entries: entries)
        backend = backend.replacingTranscript(render)
        persistedEntryCount = render.count
        persistedBaseline = TranscriptDiffer.Baseline(transcript: render)
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
    ///   - grammar: The grammar in force for the turn.
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
