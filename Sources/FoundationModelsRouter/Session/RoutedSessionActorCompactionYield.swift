import Foundation
import FoundationModels
import os

/// The logger for a compaction inside an answer: at a tool-result boundary or
/// at a ceiling stop.
private let compactionYieldLogger = makeModuleLogger(category: "CompactionYield")

/// ``RoutedSessionActor``'s compaction inside an answer: at a tool-result
/// boundary, and after an attempt that stopped at its output token ceiling
/// (``compactsAfterCeilingStop(_:)``).
///
/// A tool-using submission grows at each tool result, while the model call is
/// in flight. The check at the start of the answer sees none of that growth.
/// So each tool result goes through ``noteToolResult(_:)``: when the context
/// crosses ``TokenBudget/triggerTokens``, the session sets the yield marker
/// and cancels the model call. The failed attempt then goes on in
/// ``continueAfterCompactionYield(_:attempt:body:)``: the session rebuilds
/// the stopped attempt's transcript, records it, compacts it, and runs one
/// more submission of the same answer with ``compactionContinuationPrompt``.
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

    /// Checks the compaction trigger at one tool result of the running
    /// submission.
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
    /// a stop is outstanding against the answer, when the answer already
    /// yielded and that compaction applied no summary, or when a yield is
    /// already set.
    ///
    /// Before the check, the boundary is a settled point of the transcript
    /// (``settleTranscriptAtToolResult()``).
    ///
    /// - Parameter result: The tool result that the model reads next.
    func noteToolResult(_ result: ToolResultAppend) {
        settleTranscriptAtToolResult()
        guard let budget = autoCompactionBudget, let modelCall = inFlightModelCall,
            !isWorkCancelled, !compactionYieldsStopped, toolResultWatch.yield == nil
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
            \(budget.triggerTokens, privacy: .public); the model call stops and the answer compacts
            """
        )
        modelCall.cancel()
    }

    /// Takes the transcript as a settled point at a tool-result boundary
    /// (`generation-queue.md`, section 5.8), when the call comes from a tool
    /// call of this session's own open model call. There the SDK waits in the
    /// tool call, so no call writes the transcript. The calls of the open
    /// round have no output yet; a fork removes them
    /// (``SettledTranscript/removingUnansweredCalls()``).
    ///
    /// A tool body that outlived its model call is in no open model call of
    /// this session (``ModelCallMark/isOpenModelCall(of:)``), and settles
    /// nothing: another call can write the transcript by then.
    private func settleTranscriptAtToolResult() {
        guard ModelCallMark.current?.isOpenModelCall(of: id) == true else { return }
        settleTranscript()
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
    /// submission, the engine had not yet reported the usage of the call that
    /// asked for the tool, and the newest snapshot reported zero. Without the
    /// third source, the first tool result could not cross the trigger.
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
        let known = InFlightTranscript.addingAttemptPrompt(
            to: InFlightTranscript.merging(liveEntries, with: [snapshot?.entries ?? []]),
            entryIdsBeforeAttempt: toolResultWatch.entryIdsBeforeAttempt, text: toolResultWatch.composedPrompt)
        return (try? tokenCounter.count(Transcript(entries: known))) ?? 0
    }

    /// Takes the yield marker of the attempt that just failed.
    ///
    /// A stop outstanding against the answer wins: the failure is then a user
    /// stop, and the marker is dropped.
    ///
    /// - Returns: The marker, or `nil` when the attempt did not yield.
    func takeCompactionYield() -> CompactionYield? {
        defer { toolResultWatch.yield = nil }
        guard !isWorkCancelled else { return nil }
        return toolResultWatch.yield
    }

    /// Records the stopped attempt, compacts, and runs one more submission of
    /// the same answer.
    ///
    /// 1. The rebuilt transcript (``InFlightTranscript``) goes into
    ///    ``backend``, and the ordinary diff records its entries. They are on
    ///    disk before the compaction takes them out of the live window.
    /// 2. The measured context becomes the context at the yield, so the
    ///    compaction scales its count onto the engine's scale.
    /// 3. ``performAutoCompaction(prompt:budget:)`` compacts, and the answer
    ///    emits ``SessionEvent/compaction(_:)``.
    /// 4. The next attempt sends ``compactionContinuationPrompt``.
    ///
    /// When the compaction applied no summary, the answer does not yield
    /// again, because the next tool result would cross the same trigger at
    /// once.
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
        _ = await finishSubmissionAndRequeueIfUnattached(
            grammar: attempt.grammar, since: attempt.started, usageBefore: attempt.usageBefore,
            responseTokenCeiling: attempt.responseTokenCeiling.resolved, pendingEvents: attempt.pendingEvents,
            onEvent: attempt.onEvent)
        usageState = .measured(input: yield.measuredTokens, output: 0)
        return try await compactAndContinue(
            attempt: attempt, continuationPrompt: Self.compactionContinuationPrompt, body: body)
    }

    /// Compacts the transcript, and runs one more submission of the same
    /// answer with `continuationPrompt`.
    ///
    /// ``performAutoCompaction(prompt:budget:)`` compacts, and the answer
    /// emits ``SessionEvent/compaction(_:)``. When the compaction applied no
    /// summary, the answer does not compact inside itself again
    /// (``compactionYieldsStopped``): the next attempt would cross the same
    /// trigger at once. This is the one stop rule. It is not a count.
    ///
    /// - Parameters:
    ///   - attempt: The attempt that stopped.
    ///   - continuationPrompt: The prompt of the next attempt.
    ///   - body: The model work to run.
    /// - Returns: The response text of the next attempt.
    /// - Throws: What the compaction or the next attempt throws.
    private func compactAndContinue(
        attempt: StoppedAttempt,
        continuationPrompt: String,
        body: @escaping @Sendable (String) async throws -> String
    ) async throws -> String {
        if let budget = autoCompactionBudget {
            let result = try await performAutoCompaction(prompt: autoCompactionPrompt, budget: budget)
            attempt.onEvent?(.compaction(result))
            compactionYieldsStopped = result.summaryEntryId == nil
        }
        return try await runContinuation(after: attempt, prompt: continuationPrompt, body: body)
    }

    /// Whether an attempt that ended with `finishReason` compacts and goes on
    /// in the same answer (task ^46bz58k).
    ///
    /// An attempt that stops at its output token ceiling returns: it does not
    /// throw, and the session keeps its entries. When the measured context is
    /// at or over ``TokenBudget/triggerTokens``, a compaction makes room, and
    /// the answer goes on. When the context is under the trigger, a compaction
    /// does not help a cut output, and the answer ends as truncated.
    ///
    /// Only ``FinishReason/maxTokens`` is a ceiling stop. An output that ended
    /// inside the reasoning before the ceiling
    /// (``FinishReason/endedInsideReasoning``) had room left, so it does not
    /// compact and does not get ``ceilingStopContinuationPrompt`` (task
    /// ^gfxd7av).
    ///
    /// Nothing compacts when the session has no ``autoCompactionBudget``, when
    /// a stop is outstanding against the answer, or when an earlier compaction
    /// of the answer applied no summary (``compactionYieldsStopped``).
    ///
    /// - Parameter finishReason: Why the attempt stopped.
    /// - Returns: `true` when the attempt stopped at the ceiling over the trigger.
    func compactsAfterCeilingStop(_ finishReason: FinishReason) -> Bool {
        guard finishReason == .maxTokens, let budget = autoCompactionBudget,
            !isWorkCancelled, !compactionYieldsStopped,
            let measuredTokens = usageState.measuredTokens
        else { return false }
        return measuredTokens >= budget.triggerTokens
    }

    /// Compacts after an attempt that stopped at its output token ceiling
    /// over the trigger, and runs one more submission of the same answer with
    /// ``ceilingStopContinuationPrompt``.
    ///
    /// The attempt is already recorded, so the next attempt carries no
    /// pending events.
    ///
    /// - Parameters:
    ///   - attempt: The attempt that stopped at the ceiling.
    ///   - body: The model work to run.
    /// - Returns: The response text of the next attempt.
    /// - Throws: What the compaction or the next attempt throws.
    func continueAfterCeilingStop(
        attempt: StoppedAttempt,
        body: @escaping @Sendable (String) async throws -> String
    ) async throws -> String {
        compactionYieldLogger.notice(
            """
            session \(self.id.description, privacy: .public): an attempt stopped at its output token \
            ceiling with the context at or over the trigger; the answer compacts and goes on
            """
        )
        return try await compactAndContinue(
            attempt: attempt, continuationPrompt: Self.ceilingStopContinuationPrompt, body: body)
    }

    /// The prompt of the attempt that goes on after a compaction at a
    /// ceiling stop.
    ///
    /// The compacted transcript already holds the original prompt and the
    /// cut output, so the attempt does not send the original prompt again.
    static let ceilingStopContinuationPrompt =
        "The context was compacted. Your last output was cut off at the token ceiling. Continue the task."
}

/// The facts of a generate attempt that a compaction yield or a ceiling stop
/// stopped: what the recording of the attempt and the next submission of the
/// answer need.
struct StoppedAttempt {
    /// The grammar in force for the answer.
    let grammar: Grammar?

    /// The composed prompt of the attempt.
    let composedPrompt: String

    /// The ids of the backend entries from before the attempt.
    let entryIdsBeforeAttempt: Set<String>

    /// The start time of the attempt.
    let started: Date

    /// The cumulative backend usage when the attempt started.
    let usageBefore: (input: Int, output: Int)?

    /// The token ceiling of each submission of the answer.
    let responseTokenCeiling: ResponseTokenCeiling

    /// The events the attempt carried in its preamble.
    let pendingEvents: [OperationEvent]

    /// The event sink of the answer, or `nil`.
    let onEvent: ((SessionEvent) -> Void)?

    /// Whether a recoverable context overflow compacts and retries once.
    let allowOverflowRetry: Bool

    /// How many rejected tool calls the answer sent back to the model.
    let rejectedCallRetries: Int
}
