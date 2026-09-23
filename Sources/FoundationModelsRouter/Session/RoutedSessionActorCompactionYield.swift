import Foundation
import FoundationModels
import os

/// The logger for a compaction at a tool-result boundary.
private let compactionYieldLogger = makeModuleLogger(category: "CompactionYield")

/// ``RoutedSessionActor``'s compaction at a tool-result boundary inside a
/// turn.
///
/// A tool-using turn grows at each tool result, while the model call is in
/// flight. The turn-start check sees none of that growth. So each tool result
/// goes through ``noteToolResult(_:)``: when the context crosses
/// ``TokenBudget/triggerTokens``, the session sets the yield marker and
/// cancels the model call. The failed attempt then goes on in
/// ``continueAfterCompactionYield(_:attempt:body:)``: the session rebuilds
/// the stopped attempt's transcript, records it, compacts it, and runs one
/// more attempt of the same turn with ``compactionContinuationPrompt``.
///
/// The engine does not change: the compaction lands between two model calls.
extension RoutedSessionActor {
    /// The prompt of the attempt that goes on after a compaction at a tool
    /// result.
    ///
    /// The compacted transcript already holds the original prompt and the
    /// tool result, so the attempt does not send the original prompt again.
    static let compactionContinuationPrompt =
        "The context was compacted. Your last tool result is above. Continue the task."

    /// Checks the compaction trigger at one tool result of the turn in
    /// flight.
    ///
    /// The context is the context of the newest generation call, plus the
    /// tool results of that call's round (this session's ``tokenCounter``).
    /// The context of the call comes from the first source that has it
    /// (``contextOfNewestCall(snapshot:liveEntries:)``). Under the trigger, nothing
    /// changes. At or over the trigger, the session sets the yield marker and
    /// cancels ``inFlightModelCall``. The tool result still goes back to the
    /// tool's caller.
    ///
    /// Nothing happens when the session has no ``autoCompactionBudget``, when
    /// a stop is outstanding against the turn, when the turn already yielded
    /// and that compaction applied no summary, or when a yield is already set.
    ///
    /// - Parameter result: The tool result that the model reads next.
    func noteToolResult(_ result: ToolResultAppend) {
        guard let budget = autoCompactionBudget, let modelCall = inFlightModelCall,
            !isTurnCancelled, !compactionYieldsStopped, toolResultWatch.yield == nil
        else { return }
        toolResultWatch.append(result, tokens: tokenCounter.count(result.text))
        let snapshot = backend.inFlightResponse()
        let liveEntries = backend.transcriptEntries()
        let measuredTokens =
            contextOfNewestCall(snapshot: snapshot, liveEntries: liveEntries) + toolResultWatch.roundResultTokens
        guard measuredTokens >= budget.triggerTokens else { return }
        toolResultWatch.yield = CompactionYield(
            measuredTokens: measuredTokens, results: toolResultWatch.roundResults,
            liveEntries: liveEntries, snapshotEntries: snapshot?.entries ?? [])
        compactionYieldLogger.notice(
            """
            session \(self.id.description, privacy: .public): a tool result took the context to \
            \(measuredTokens, privacy: .public) tokens, at or over the trigger of \
            \(budget.triggerTokens, privacy: .public); the model call stops and the turn compacts
            """
        )
        modelCall.cancel()
    }

    /// The context of the newest generation call of the attempt in flight,
    /// in tokens, from the first source that has it:
    ///
    /// 1. the input and output of the newest call that ended in the ledger
    ///    (the engine's count);
    /// 2. the usage of the newest stream snapshot, when it is not zero;
    /// 3. this session's ``tokenCounter`` over the entries the session can
    ///    see: the backend transcript, the snapshot entries, and the
    ///    attempt's prompt when no entry of the attempt is a `.prompt` entry.
    ///
    /// Measured on Qwen3.8-27B (2026-09-23): at the first tool result of a
    /// turn, the engine had not yet reported the usage of the call that asked
    /// for the tool, and the newest snapshot reported zero. Without the third
    /// source, the first tool result could not cross the trigger.
    ///
    /// - Parameters:
    ///   - snapshot: The newest stream snapshot, or `nil`.
    ///   - liveEntries: The backend transcript, read inside the tool call.
    /// - Returns: The context of the newest call, in tokens.
    private func contextOfNewestCall(snapshot: InFlightResponse?, liveEntries: [Transcript.Entry]) -> Int {
        if let callTokens = toolResultWatch.newestCallTokens {
            return callTokens
        }
        if let snapshot, snapshot.contextTokens > 0 {
            return snapshot.contextTokens
        }
        let known = InFlightTranscript.withAttemptPrompt(
            InFlightTranscript.merging(liveEntries, with: [snapshot?.entries ?? []]),
            entryIdsBeforeAttempt: toolResultWatch.entryIdsBeforeAttempt, text: toolResultWatch.composedPrompt)
        return (try? tokenCounter.count(Transcript(entries: known))) ?? 0
    }

    /// Takes the yield marker of the attempt that just failed.
    ///
    /// A stop outstanding against the turn wins: the failure is then a user
    /// stop, and the marker is dropped.
    ///
    /// - Returns: The marker, or `nil` when the attempt did not yield.
    func takeCompactionYield() -> CompactionYield? {
        defer { toolResultWatch.yield = nil }
        guard !isTurnCancelled else { return nil }
        return toolResultWatch.yield
    }

    /// Records the stopped attempt, compacts, and runs one more attempt of
    /// the same turn.
    ///
    /// 1. The rebuilt transcript (``InFlightTranscript``) goes into
    ///    ``backend``, and the ordinary diff records its entries. They are on
    ///    disk before the compaction takes them out of the live window.
    /// 2. The measured context becomes the context at the yield, so the
    ///    compaction scales its count onto the engine's scale.
    /// 3. ``performAutoCompaction(prompt:budget:)`` compacts, and the turn
    ///    emits ``SessionEvent/compaction(_:)``.
    /// 4. The next attempt sends ``compactionContinuationPrompt``.
    ///
    /// When the compaction applied no summary, the turn does not yield again,
    /// because the next tool result would cross the same trigger at once.
    ///
    /// - Parameters:
    ///   - yield: The yield marker of the stopped attempt.
    ///   - attempt: The stopped attempt.
    ///   - body: The model work to run.
    /// - Returns: The response text of the next attempt.
    /// - Throws: What the compaction or the next attempt throws.
    func continueAfterCompactionYield(
        _ yield: CompactionYield,
        attempt: StoppedAttempt,
        body: @escaping @Sendable (String) async throws -> String
    ) async throws -> String {
        let rebuilt = InFlightTranscript.rebuilt(
            settledEntries: backend.transcriptEntries(), yield: yield,
            entryIdsBeforeAttempt: attempt.entryIdsBeforeAttempt, composedPrompt: attempt.composedPrompt)
        backend = backend.replacingTranscript(Transcript(entries: rebuilt))
        _ = await finishTurnAndRequeueIfUnattached(
            grammar: attempt.grammar, since: attempt.started, usageBefore: attempt.usageBefore,
            responseTokenCeiling: attempt.responseTokenCeiling.resolved, pendingEvents: attempt.pendingEvents,
            onEvent: attempt.onEvent)
        usageState = .measured(input: yield.measuredTokens, output: 0)
        if let budget = autoCompactionBudget {
            let result = try await performAutoCompaction(prompt: autoCompactionPrompt, budget: budget)
            attempt.onEvent?(.compaction(result))
            compactionYieldsStopped = result.summaryEntryId == nil
        }
        return try await runTurnAttempt(
            grammar: attempt.grammar, pendingEvents: [], ownPrompt: Self.compactionContinuationPrompt,
            responseTokenCeiling: attempt.responseTokenCeiling, onEvent: attempt.onEvent,
            allowOverflowRetry: attempt.allowOverflowRetry, rejectedCallRetries: attempt.rejectedCallRetries, body)
    }
}

/// The facts of a generate attempt that a compaction yield stopped: what
/// the recording of the attempt and the next attempt of the turn need.
struct StoppedAttempt {
    /// The grammar in force for the turn.
    let grammar: Grammar?

    /// The composed prompt of the attempt.
    let composedPrompt: String

    /// The ids of the backend entries from before the attempt.
    let entryIdsBeforeAttempt: Set<String>

    /// The start time of the attempt.
    let started: Date

    /// The cumulative backend usage when the attempt started.
    let usageBefore: (input: Int, output: Int)?

    /// The token ceiling of the turn.
    let responseTokenCeiling: ResponseTokenCeiling

    /// The events the attempt carried in its preamble.
    let pendingEvents: [OperationEvent]

    /// The turn's event sink, or `nil`.
    let onEvent: ((SessionEvent) -> Void)?

    /// Whether a recoverable context overflow compacts and retries once.
    let allowOverflowRetry: Bool

    /// How many rejected tool calls the turn sent back to the model.
    let rejectedCallRetries: Int
}
