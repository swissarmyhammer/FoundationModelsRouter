import FoundationModels
import FoundationModelsExtras

/// The host check that tells the session which tool call does no work
/// (task ^rw72f4j).
///
/// A model that waits for a pending operation can make one tool call after
/// another that does nothing, for example a `runCode` call whose snippet
/// calls no tool. While at least one operation of the session is pending,
/// the session does not run such a call, does not answer it, and does not put
/// it in the context. Every other call of the same round runs, and its result
/// goes into the context as usual. When the round has no other call, the
/// session stops the generation and waits: the injected result of the pending
/// operation is the next message that starts the model. With no pending
/// operation, the check changes nothing.
///
/// The router does not know which call of a tool does no work. The host that
/// owns the tool knows it, so the host gives this check on
/// ``SessionConfiguration/isNoOpToolCall``. The check is a closure, so the
/// sidecar does not record it. A fork inherits it. A restore gets it again
/// from the host, through the `isNoOpToolCall` argument of
/// ``RoutedModel/restoreSession(id:recordingRoot:instructions:tools:toolOutputProtection:isNoOpToolCall:userPresence:)``.
///
/// - Parameters:
///   - toolName: The name of the called tool.
///   - arguments: The arguments of the call.
/// - Returns: `true` when the call does no work.
public typealias NoOpToolCallCheck = @Sendable (_ toolName: String, _ arguments: GeneratedContent) -> Bool

/// The no-op check that runs before each tool body of one model call
/// (task ^rw72f4j).
///
/// The session binds one check for each model call on the task of the
/// submission, as it binds the repetition check
/// (``ToolCallRepetitionCheck``), and the SDK gives it to each tool body that
/// it runs inside the call. ``SessionCheckedTool`` runs it first, before the
/// repetition check, so a no-op call that the session does not run never
/// counts in the repetition watch.
struct ToolCallNoOpCheck: Sendable {
    /// The check of the model call that the current task runs in, or `nil`
    /// outside a model call.
    @TaskLocal static var current: ToolCallNoOpCheck?

    /// The session operation that checks the tool call.
    private let check: @Sendable (_ toolName: String, _ arguments: GeneratedContent) async throws -> Void

    /// Makes the check of one model call.
    ///
    /// - Parameter check: The session operation that checks the tool call. It
    ///   throws when the tool body must not run.
    init(check: @escaping @Sendable (_ toolName: String, _ arguments: GeneratedContent) async throws -> Void) {
        self.check = check
    }

    /// Runs the check for one tool call.
    ///
    /// - Parameters:
    ///   - toolName: The name of the tool whose body is about to run.
    ///   - arguments: The arguments of the call, or `nil` when they do not
    ///     give their generated content. Such a call is never a no-op.
    /// - Throws: `CancellationError` when the call is a no-op that the
    ///   session does not run.
    func run(toolName: String, arguments: GeneratedContent?) async throws {
        guard let arguments else { return }
        try await check(toolName, arguments)
    }
}

/// What the session knows about the round of tool calls in flight, for the
/// no-op check (task ^rw72f4j): the `.toolCalls` entry of the round, the
/// results of its real calls so far, and the count of its real calls.
///
/// ``RoutedSessionActor/openGenerationCallLedger(usageBefore:responseTokenCeiling:)``
/// starts a new value for each attempt. A tool result or a no-op call of a
/// later round starts a new value for that round (``enter(callsEntryId:)``).
struct NoOpToolCallRound {
    /// The id of the `.toolCalls` entry of the round, or `nil` before the
    /// session saw the round.
    private(set) var callsEntryId: String?

    /// The results of the real calls of the round, in the order they came
    /// back.
    private(set) var results: [ToolResultAppend] = []

    /// The count of the real calls of the round, or `nil` while no no-op
    /// call of the round asked for it.
    private(set) var realCallCount: Int?

    /// Whether every real call of the round gave its result. `false` while
    /// the count is not known.
    var isComplete: Bool {
        guard let realCallCount else { return false }
        return results.count >= realCallCount
    }

    /// Starts the round of `id`, when it is not the round of this value.
    ///
    /// - Parameter id: The id of the `.toolCalls` entry of the round.
    mutating func enter(callsEntryId id: String?) {
        guard id != callsEntryId else { return }
        self = NoOpToolCallRound(callsEntryId: id)
    }

    /// Adds the result of one real call of the round.
    ///
    /// - Parameter result: The tool result.
    mutating func append(_ result: ToolResultAppend) {
        results.append(result)
    }

    /// Records the count of the real calls of the round.
    ///
    /// - Parameter count: The count.
    mutating func noteRealCalls(_ count: Int) {
        realCallCount = count
    }
}

/// The marker a session sets when it stops the model call in flight at the
/// end of a round that held a no-op tool call while an operation is pending,
/// and the facts it needs to go on (task ^rw72f4j).
struct NoOpToolCallStop: Sendable {
    /// The backend transcript read inside the tool call, before the stop.
    let liveEntries: [Transcript.Entry]

    /// The results of the real calls of the round, in order. Empty when the
    /// round held only no-op calls.
    let results: [ToolResultAppend]
}

/// ``RoutedSessionActor``'s handling of a no-op tool call (task ^rw72f4j).
///
/// Before each tool body of the session's own open model call,
/// ``checkToolCallForNoOp(toolName:arguments:)`` asks the host check
/// (``isNoOpToolCall``). While at least one operation of the session is
/// pending (``hasPendingOperation()``), the body of a marked call does not
/// run. It waits until every real call of its round gave its result
/// (``noteRealToolResult(_:)``). Then the session sets the stop marker and
/// cancels ``inFlightModelCall``. The SDK runs the calls of one round at the
/// same time, so the real calls run to their end.
///
/// The failed attempt then goes on in
/// ``continueAfterNoOpToolCallStop(_:attempt:body:)``. The session records
/// the attempt with the real results and with no no-op call. A round with a
/// real call goes on in one more submission of the same answer, with
/// ``noOpToolCallContinuationPrompt``: the model continues with the real
/// results. A round of only no-op calls ends the answer, and the pump
/// delivers the result of the pending operation as the next message when it
/// settles (``RoutedSessionActor/settledRunDeliveryPrompt``).
///
/// This is not a stop of the repetition watch: it has no count and no
/// recovery, and it does not change the render of the watch.
extension RoutedSessionActor {
    /// The prompt of the submission that goes on after a round that held a
    /// no-op call and a real call. The rebuilt transcript holds the results of
    /// the real calls and no trace of the no-op call.
    static let noOpToolCallContinuationPrompt = "Your tool results are above. Continue the task."

    /// Holds the body of a no-op tool call while an operation of the session
    /// is pending, and stops the model call at the end of its round.
    ///
    /// A call that the host check does not mark, a call outside an open model
    /// call of this session, and a call while no operation is pending return
    /// at once: the tool body then runs.
    ///
    /// - Parameters:
    ///   - toolName: The name of the tool whose body is about to run.
    ///   - arguments: The arguments of the call.
    /// - Throws: `CancellationError` for a no-op call that the session does
    ///   not run. The tool body must then not run.
    func checkToolCallForNoOp(toolName: String, arguments: GeneratedContent) async throws {
        guard ModelCallMark.current?.isOpenModelCall(of: id) == true, isNoOpToolCall(toolName, arguments)
        else { return }
        guard await hasPendingOperation() else { return }
        await waitForTheRealCallsOfTheRound(ofNoOpCallOf: toolName)
        throw CancellationError()
    }

    /// Whether at least one operation of the session is pending: a
    /// background run is open, or the mail holds a result that starts a
    /// submission by itself (``SessionOutbox/canStartASubmission(_:runTokens:)``).
    /// Held mail starts no submission, so it is not pending. A stop of a
    /// no-op call that is already set counts as pending.
    ///
    /// A run that waits only for the user is pending here, but it is no work
    /// for ``isIdle()``: the result of the run comes to the model later, so a
    /// no-op call stops while a question of the run is open.
    ///
    /// - Returns: `true` when the pump delivers a result to the model later.
    func hasPendingOperation() async -> Bool {
        guard noOpToolCallStop == nil else { return true }
        let runTokens = await readBackgroundRunTokens()
        let mail = await outbox.pending().events
        return !runTokens.open.isEmpty || SessionOutbox.canStartASubmission(mail, runTokens: runTokens)
    }

    /// Waits until every real call of the round of a no-op call gave its
    /// result, then stops the model call, or returns when another no-op call
    /// or another stop already ended the call.
    ///
    /// A cancel of the model call ends the wait, so a stop for another
    /// reason never leaves the body of the no-op call waiting.
    ///
    /// The wait is ``ChangeSignal/waitUntil(isolation:_:)`` on
    /// ``noOpRoundChanges``. It ends when a stop is set or when the round is
    /// complete. Only a complete round with no stop stops the model call.
    ///
    /// - Parameter toolName: The name of the tool of the no-op call.
    private func waitForTheRealCallsOfTheRound(ofNoOpCallOf toolName: String) async {
        noteNoOpCallOfTheRound()
        let roundEnded = await noOpRoundChanges.waitUntil {
            noOpToolCallStop != nil || noOpToolCallRound.isComplete
        }
        guard roundEnded, noOpToolCallStop == nil, mayStopForNoOpToolCall else { return }
        stopModelCall(forNoOpToolCallOf: toolName)
    }

    /// Reads the round of the no-op call in flight, and records the count of
    /// its real calls: the calls of the round that the host check does not
    /// mark.
    private func noteNoOpCallOfTheRound() {
        let calls = currentRoundCalls()
        noOpToolCallRound.enter(callsEntryId: calls?.id)
        let realCalls = (calls.map(Array.init) ?? []).filter { !isNoOpToolCall($0.toolName, $0.arguments) }
        noOpToolCallRound.noteRealCalls(realCalls.count)
    }

    /// The `.toolCalls` entry of the round in flight: the last one of the
    /// attempt, or `nil` when the attempt has none.
    ///
    /// Read from a tool body of this session's own open model call, where the
    /// SDK waits in the tool call and writes no transcript.
    private func currentRoundCalls() -> Transcript.ToolCalls? {
        for entry in backend.transcriptEntries().reversed()
        where !toolResultWatch.entryIdsBeforeAttempt.contains(entry.id) {
            guard case .toolCalls(let calls) = entry else { continue }
            return calls
        }
        return nil
    }

    /// Records the result of one real call of the round in flight, and wakes
    /// each no-op call of the round that waits (task ^rw72f4j).
    /// ``noteToolResult(_:)`` calls it for each tool result of the session's
    /// own open model call.
    ///
    /// - Parameter result: The tool result.
    func noteRealToolResult(_ result: ToolResultAppend) {
        guard ModelCallMark.current?.isOpenModelCall(of: id) == true else { return }
        noOpToolCallRound.enter(callsEntryId: currentRoundCalls()?.id)
        noOpToolCallRound.append(result)
        noOpRoundChanges.signal()
    }

    /// Whether the end of a round with a no-op call may stop the model call
    /// in flight: a model call is in flight, no stop is outstanding against
    /// the answer, and no tool result or watch already stopped the call.
    private var mayStopForNoOpToolCall: Bool {
        inFlightModelCall != nil && !isWorkCancelled && toolResultWatch.yield == nil && repetitionWatch.stop == nil
    }

    /// Logs the stop, sets the marker, wakes each no-op call of the round
    /// that waits, and cancels ``inFlightModelCall``.
    ///
    /// - Parameter toolName: The name of the tool of the no-op call.
    private func stopModelCall(forNoOpToolCallOf toolName: String) {
        noOpToolCallStop = NoOpToolCallStop(
            liveEntries: backend.transcriptEntries(), results: noOpToolCallRound.results)
        sessionLogger(.noOpToolCallStop).notice(
            "a round with a no-op tool call while an operation is pending ends the model call",
            metadata: [
                RouterTelemetry.LogMetadataKey.sessionId: "\(id.description)",
                RouterTelemetry.LogMetadataKey.toolName: "\(toolName)",
            ])
        noOpRoundChanges.signal()
        inFlightModelCall?.cancel()
    }

    /// Takes the stop marker of the attempt that just failed.
    ///
    /// A stop outstanding against the answer wins: the failure is then a user
    /// stop, and the marker is dropped.
    ///
    /// - Returns: The marker, or `nil` when no no-op tool call stopped the
    ///   attempt.
    func takeNoOpToolCallStop() -> NoOpToolCallStop? {
        defer { noOpToolCallStop = nil }
        guard !isWorkCancelled else { return nil }
        return noOpToolCallStop
    }

    /// Records the stopped attempt, then goes on with the real results or
    /// ends the answer.
    ///
    /// The rebuilt transcript (``InFlightTranscript``) keeps every entry of
    /// the attempt, with no unanswered no-op call
    /// (``removingUnansweredNoOpCalls(from:entryIdsBeforeAttempt:)``) and
    /// with the output of each real call of the round. So the context holds
    /// no trace of a no-op call.
    ///
    /// - Parameters:
    ///   - stop: The stop marker of the stopped attempt.
    ///   - attempt: The stopped attempt.
    ///   - body: The model work to run.
    /// - Returns: The response text of the next attempt when the round had a
    ///   real call, else an empty reply: the model did no work after the
    ///   stop.
    /// - Throws: What the next attempt throws.
    func continueAfterNoOpToolCallStop(
        _ stop: NoOpToolCallStop,
        attempt: StoppedAttempt,
        body: @escaping @Sendable (String) async throws -> String
    ) async throws -> String {
        let ids = attempt.entryIdsBeforeAttempt
        let rebuilt = InFlightTranscript.rebuilt(
            settledEntries: removingUnansweredNoOpCalls(from: backend.transcriptEntries(), entryIdsBeforeAttempt: ids),
            sources: [removingUnansweredNoOpCalls(from: stop.liveEntries, entryIdsBeforeAttempt: ids)],
            results: stop.results, entryIdsBeforeAttempt: ids, composedPrompt: attempt.composedPrompt)
        await recordAttemptStoppedAtToolCall(rebuilt, attempt: attempt)
        guard !stop.results.isEmpty else { return "" }
        return try await runContinuation(after: attempt, prompt: Self.noOpToolCallContinuationPrompt, body: body)
    }

    /// `entries` with each no-op call of the attempt that has no output
    /// removed from its `.toolCalls` entry, and that entry removed when no
    /// call is left. A no-op call that ran, because no operation was pending
    /// then, has an output and stays.
    ///
    /// - Parameters:
    ///   - entries: The entries to read.
    ///   - entryIdsBeforeAttempt: The ids of the entries from before the
    ///     attempt. Those entries do not change.
    /// - Returns: The entries with no unanswered no-op call.
    private func removingUnansweredNoOpCalls(
        from entries: [Transcript.Entry], entryIdsBeforeAttempt: Set<String>
    ) -> [Transcript.Entry] {
        let answered = InFlightTranscript.answeredCallIds(in: entries)
        return entries.compactMap { entry in
            guard !entryIdsBeforeAttempt.contains(entry.id), case .toolCalls(let calls) = entry else { return entry }
            let kept = calls.filter { answered.contains($0.id) || !isNoOpToolCall($0.toolName, $0.arguments) }
            guard kept.count < calls.count else { return entry }
            return kept.isEmpty ? nil : .toolCalls(Transcript.ToolCalls(id: calls.id, kept))
        }
    }
}
