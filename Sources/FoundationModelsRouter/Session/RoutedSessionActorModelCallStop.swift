import FoundationModels
import FoundationModelsExtras
import Logging

/// ``RoutedSessionActor``'s shared rules for a stop that ends the model call
/// in flight while the SDK waits in a tool call.
///
/// Each stop of the model call (a compaction yield, a no-op tool call, a
/// repetition, the delegate hint, run mail) sets its own marker and cancels
/// ``inFlightModelCall``. Only one stop may win a call, so each reads the
/// same guard before it sets its marker: ``modelCallMayStop``, plus the
/// markers it yields to. The stops at the end of a complete round, the
/// delegate hint and the run mail, share one protocol
/// (``stopModelCallAtCompleteRound(finding:losing:stop:category:message:)``)
/// and one record of the stopped attempt
/// (``recordAttemptStoppedAtRound(liveEntries:results:attempt:keeping:)``).
extension RoutedSessionActor {
    /// Whether a stop may end the model call in flight: a model call is in
    /// flight, no stop is outstanding against the answer, no tool result
    /// already stopped the call for a compaction, and no no-op tool call
    /// already stopped the call (``noOpToolCallStop``).
    var modelCallMayStop: Bool {
        inFlightModelCall != nil && !isWorkCancelled && toolResultWatch.yield == nil && noOpToolCallStop == nil
    }

    /// Whether no stop of the model call in flight is set: a stop may end
    /// the call (``modelCallMayStop``), and no repetition, delegate hint or
    /// run mail stop is set.
    var noStopOutstanding: Bool {
        modelCallMayStop && repetitionWatch.stop == nil && delegationHintStop == nil && runMailStop == nil
    }

    /// Whether every call of the round in flight gave its result. The
    /// boundary sees each result, so the last result of the round stops the
    /// call, and no call of the round loses its result.
    var roundIsComplete: Bool {
        noOpToolCallRound.results.count >= (currentRoundCalls()?.count ?? 1)
    }

    /// Stops the model call in flight at the tool result that completes a
    /// round, when `find` gives something to deliver.
    ///
    /// Nothing happens for a result outside the session's own open model
    /// call, while a stop is set (``noStopOutstanding``), before the last
    /// result of the round, or when `find` gives `nil`. `find` suspends, so
    /// another stop of the call can land meanwhile: the session then gives
    /// the candidate to `lose` and does not stop. Otherwise it gives the
    /// candidate to `stop`, which sets the marker, logs `message`, and
    /// cancels ``inFlightModelCall``.
    ///
    /// - Parameters:
    ///   - find: Reads what the stop delivers, or `nil` when nothing is due.
    ///   - lose: Takes back a candidate that another stop won over.
    ///   - stop: Sets the marker of the stop for the candidate.
    ///   - category: The log category of the stop.
    ///   - message: The log message of the stop.
    func stopModelCallAtCompleteRound<Candidate>(
        finding find: () async -> Candidate?,
        losing lose: (Candidate) -> Void = { _ in },
        stop: (Candidate) -> Void,
        category: RouterTelemetry.LogCategory,
        message: Logger.Message
    ) async {
        guard SessionCallMark.current?.isOpenCall(of: id) == true, noStopOutstanding, roundIsComplete else { return }
        guard let candidate = await find() else { return }
        guard noStopOutstanding else {
            lose(candidate)
            return
        }
        stop(candidate)
        sessionLogger(category).notice(
            message, metadata: [RouterTelemetry.LogMetadataKey.sessionId: "\(id.description)"])
        inFlightModelCall?.cancel()
    }

    /// Puts the rebuilt transcript of an attempt that a stop ended at a tool
    /// call into ``backend``, and records the attempt
    /// (``recordAttemptStoppedAtToolCall(_:attempt:)``).
    ///
    /// The rebuild (``InFlightTranscript``) reads the settled transcript of
    /// ``backend`` and `liveEntries`, each through `keep`, and pairs
    /// `results` to the open calls of the attempt.
    ///
    /// - Parameters:
    ///   - liveEntries: The backend transcript read at the stop.
    ///   - results: The results that answer the open calls of the attempt,
    ///     in order.
    ///   - attempt: The stopped attempt.
    ///   - keep: The entries of a transcript that the rebuild reads; all of
    ///     them by default.
    /// - Returns: The rebuilt transcript.
    @discardableResult
    func recordAttemptStoppedAtRound(
        liveEntries: [Transcript.Entry],
        results: [ToolResultAppend],
        attempt: StoppedAttempt,
        keeping keep: ([Transcript.Entry]) -> [Transcript.Entry] = { $0 }
    ) async -> [Transcript.Entry] {
        let rebuilt = InFlightTranscript.rebuilt(
            settledEntries: keep(backend.transcriptEntries()), sources: [keep(liveEntries)], results: results,
            entryIdsBeforeAttempt: attempt.entryIdsBeforeAttempt, composedPrompt: attempt.composedPrompt)
        await recordAttemptStoppedAtToolCall(rebuilt, attempt: attempt)
        return rebuilt
    }
}
