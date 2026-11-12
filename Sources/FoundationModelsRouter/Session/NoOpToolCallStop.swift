import FoundationModels
import FoundationModelsExtras

/// The host check that tells the session which tool call does no work
/// (tasks ^rw72f4j and ^zetnz36).
///
/// A model that waits for a pending operation can make one tool call after
/// another that does nothing, for example a `runCode` call whose snippet
/// calls no tool. The session never runs such a call. Every other call of
/// the same round runs, and its result goes into the context as usual. At
/// the end of the round the session stops the generation:
///
/// - When the round has a real call, the answer goes on with the real
///   results, and the context holds no trace of the no-op call.
/// - When the round has only no-op calls and at least one operation of the
///   session is pending, the answer ends, and the context holds no trace of
///   the no-op calls. The injected result of the pending operation is the
///   next message that starts the model.
/// - When the round has only no-op calls and nothing is pending, nothing can
///   arrive, so the answer ends. Each no-op call gets a fixed output that
///   tells the model why (``RoutedSessionActor/noOpToolCallEndReason``), and
///   the reply of the answer is the last text of the model.
///
/// A no-op call never runs, so it is never progress for the recovery budget
/// of the repetition watch (``RepetitionDetection/recoveriesPerAnswer``).
///
/// The router does not know which call of a tool does no work. The host that
/// owns the tool knows it, so the host gives this check on
/// ``SessionConfiguration/isNoOpToolCall``. The check is a closure, so the
/// session's `index.md` does not record it. A restore gets it again
/// from the host, through the `isNoOpToolCall` argument of
/// ``RoutedModel/restoreSession(id:recordingRoot:instructions:tools:toolOutputProtection:isNoOpToolCall:userPresence:hookSessionKey:claimingRuns:transcriptReader:switchingModel:)``.
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
/// end of a round that held a no-op tool call, and the facts it needs to go
/// on (tasks ^rw72f4j and ^zetnz36).
struct NoOpToolCallStop: Sendable {
    /// The backend transcript read inside the tool call, before the stop.
    let liveEntries: [Transcript.Entry]

    /// The results of the real calls of the round, in order. Empty when the
    /// round held only no-op calls.
    let results: [ToolResultAppend]

    /// Whether an operation of the session was pending at the stop
    /// (``RoutedSessionActor/hasPendingOperation()``): its result then
    /// starts the model later.
    let operationPending: Bool
}

/// ``RoutedSessionActor``'s handling of a no-op tool call (tasks ^rw72f4j
/// and ^zetnz36).
///
/// Before each tool body of the session's own open model call,
/// ``checkToolCallForNoOp(toolName:arguments:)`` asks the host check
/// (``isNoOpToolCall``). The body of a marked call never runs. It waits
/// until every real call of its round gave its result
/// (``noteRealToolResult(_:)``). Then the session reads whether an operation
/// is pending (``hasPendingOperation()``), sets the stop marker and cancels
/// ``inFlightModelCall``. The SDK runs the calls of one round at the same
/// time, so the real calls run to their end.
///
/// The failed attempt then goes on in
/// ``continueAfterNoOpToolCallStop(_:attempt:body:)``. A round with a real
/// call records the attempt with the real results and with no no-op call,
/// and goes on in one more submission of the same answer, with
/// ``noOpToolCallContinuationPrompt``: the model continues with the real
/// results. A round of only no-op calls ends the answer. While an operation
/// is pending, the attempt holds no no-op call, and the pump delivers the
/// result of the pending operation as the next message when it settles
/// (``RoutedSessionActor/settledRunDeliveryPrompt``). With nothing pending,
/// each no-op call gets ``noOpToolCallEndReason`` as its output, and the
/// answer ends with the last text of the model.
///
/// This is not a stop of the repetition watch: it has no count and no
/// recovery, and it does not change the render of the watch.
extension RoutedSessionActor {
    /// The prompt of the submission that goes on after a round that held a
    /// no-op call and a real call. The rebuilt transcript holds the results of
    /// the real calls and no trace of the no-op call.
    static let noOpToolCallContinuationPrompt = "Your tool results are above. Continue the task."

    /// The output of each no-op call of a round of only no-op calls while no
    /// operation of the session is pending (task ^zetnz36). It tells the
    /// model why its answer ended. The router does not know the tools of the
    /// host, so the text names no tool.
    static let noOpToolCallEndReason = """
        This tool call does no work here. Nothing is pending, so nothing can arrive, \
        and the answer ends. Write your report as text.
        """

    /// Holds the body of a no-op tool call, and stops the model call at the
    /// end of its round.
    ///
    /// A call that the host check does not mark and a call outside an open
    /// model call of this session return at once: the tool body then runs.
    ///
    /// - Parameters:
    ///   - toolName: The name of the tool whose body is about to run.
    ///   - arguments: The arguments of the call.
    /// - Throws: `CancellationError` for a no-op call that the session does
    ///   not run. The tool body must then not run.
    func checkToolCallForNoOp(toolName: String, arguments: GeneratedContent) async throws {
        guard SessionCallMark.current?.isOpenCall(of: id) == true, isNoOpToolCall(toolName, arguments)
        else { return }
        await waitForTheRealCallsOfTheRound(ofNoOpCallOf: toolName)
        throw CancellationError()
    }

    /// Whether at least one operation of the session is pending: a
    /// background run is open, or the mail holds a result that starts a
    /// submission by itself (``SessionOutbox/canStartASubmission(_:runTokens:)``).
    /// Held mail starts no submission, so it is not pending.
    ///
    /// A run that waits only for the user is pending here, but it is no work
    /// for ``isIdle()``: the result of the run comes to the model later, so a
    /// no-op call stops while a question of the run is open.
    ///
    /// - Returns: `true` when the pump delivers a result to the model later.
    func hasPendingOperation() async -> Bool {
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
    /// The stop reads whether an operation is pending at the end of the
    /// round, so a run that settled while the real calls ran counts.
    ///
    /// - Parameter toolName: The name of the tool of the no-op call.
    private func waitForTheRealCallsOfTheRound(ofNoOpCallOf toolName: String) async {
        noteNoOpCallOfTheRound()
        let roundEnded = await noOpRoundChanges.waitUntil {
            noOpToolCallStop != nil || noOpToolCallRound.isComplete
        }
        guard roundEnded, noOpToolCallStop == nil else { return }
        let operationPending = await hasPendingOperation()
        // The read suspends: another no-op call or another stop can land
        // meanwhile.
        guard modelCallMayStop, repetitionWatch.stop == nil else { return }
        stopModelCall(forNoOpToolCallOf: toolName, operationPending: operationPending)
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
    func currentRoundCalls() -> Transcript.ToolCalls? {
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
        guard SessionCallMark.current?.isOpenCall(of: id) == true else { return }
        noOpToolCallRound.enter(callsEntryId: currentRoundCalls()?.id)
        noOpToolCallRound.append(result)
        noOpRoundChanges.signal()
    }

    /// Logs the stop, sets the marker, wakes each no-op call of the round
    /// that waits, and cancels ``inFlightModelCall``.
    ///
    /// - Parameters:
    ///   - toolName: The name of the tool of the no-op call.
    ///   - operationPending: Whether an operation of the session is pending.
    private func stopModelCall(forNoOpToolCallOf toolName: String, operationPending: Bool) {
        noOpToolCallStop = NoOpToolCallStop(
            liveEntries: backend.transcriptEntries(), results: noOpToolCallRound.results,
            operationPending: operationPending)
        sessionLogger(.noOpToolCallStop).notice(
            "a round with a no-op tool call ends the model call",
            metadata: [
                RouterTelemetry.LogMetadataKey.sessionId: "\(id.description)",
                RouterTelemetry.LogMetadataKey.toolName: "\(toolName)",
                RouterTelemetry.LogMetadataKey.operationPending: "\(operationPending)",
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
    /// - A round with a real call: the rebuilt transcript
    ///   (``InFlightTranscript``) keeps every entry of the attempt, with no
    ///   unanswered no-op call
    ///   (``removingUnansweredNoOpCalls(from:entryIdsBeforeAttempt:)``) and
    ///   with the output of each real call of the round. One more submission
    ///   of the same answer goes on with the real results.
    /// - A round of only no-op calls while an operation is pending: the
    ///   rebuilt transcript holds no trace of a no-op call, and the answer
    ///   ends with an empty reply. The result of the operation starts the
    ///   model later.
    /// - A round of only no-op calls with nothing pending (task ^zetnz36):
    ///   nothing can arrive. Each no-op call gets
    ///   ``noOpToolCallEndReason`` as its output, so the model learns why its
    ///   answer ended, and the answer ends with the last text of the model in
    ///   the attempt.
    ///
    /// - Parameters:
    ///   - stop: The stop marker of the stopped attempt.
    ///   - attempt: The stopped attempt.
    ///   - body: The model work to run.
    /// - Returns: The response text of the next attempt when the round had a
    ///   real call; else the last text of the model in the attempt when
    ///   nothing is pending, or an empty reply.
    /// - Throws: What the next attempt throws.
    func continueAfterNoOpToolCallStop(
        _ stop: NoOpToolCallStop,
        attempt: StoppedAttempt,
        body: @escaping @Sendable (String) async throws -> String
    ) async throws -> String {
        guard stop.results.isEmpty else {
            await recordAttemptWithNoNoOpCall(stop, attempt: attempt)
            return try await runContinuation(after: attempt, prompt: Self.noOpToolCallContinuationPrompt, body: body)
        }
        guard !stop.operationPending else {
            await recordAttemptWithNoNoOpCall(stop, attempt: attempt)
            return ""
        }
        let rebuilt = await recordAttemptStoppedAtRound(
            liveEntries: stop.liveEntries,
            results: endReasons(answeringTheNoOpCallsOf: stop.liveEntries, attempt: attempt), attempt: attempt)
        return Self.lastResponseText(of: rebuilt, entryIdsBeforeAttempt: attempt.entryIdsBeforeAttempt)
    }

    /// Records the stopped attempt with the output of each real call of the
    /// round and with no unanswered no-op call, so the context holds no
    /// trace of a no-op call.
    ///
    /// - Parameters:
    ///   - stop: The stop marker of the stopped attempt.
    ///   - attempt: The stopped attempt.
    private func recordAttemptWithNoNoOpCall(_ stop: NoOpToolCallStop, attempt: StoppedAttempt) async {
        await recordAttemptStoppedAtRound(liveEntries: stop.liveEntries, results: stop.results, attempt: attempt) {
            removingUnansweredNoOpCalls(from: $0, entryIdsBeforeAttempt: attempt.entryIdsBeforeAttempt)
        }
    }

    /// One result with ``noOpToolCallEndReason`` for each unanswered no-op
    /// call of the attempt in `entries`, in transcript order.
    ///
    /// - Parameters:
    ///   - entries: The backend transcript read at the stop.
    ///   - attempt: The stopped attempt.
    /// - Returns: The results, which the rebuild pairs to the calls by tool
    ///   name and order.
    private func endReasons(
        answeringTheNoOpCallsOf entries: [Transcript.Entry], attempt: StoppedAttempt
    ) -> [ToolResultAppend] {
        let attemptEntries = entries.filter { !attempt.entryIdsBeforeAttempt.contains($0.id) }
        return InFlightTranscript.openCalls(in: attemptEntries)
            .filter { isNoOpToolCall($0.toolName, $0.arguments) }
            .map { ToolResultAppend(toolName: $0.toolName, arguments: $0.arguments, text: Self.noOpToolCallEndReason) }
    }

    /// The text of the last `.response` entry of the attempt in `entries`.
    ///
    /// - Parameters:
    ///   - entries: The rebuilt transcript.
    ///   - entryIdsBeforeAttempt: The ids of the entries from before the
    ///     attempt.
    /// - Returns: The text, or an empty text when the attempt wrote none.
    private static func lastResponseText(
        of entries: [Transcript.Entry], entryIdsBeforeAttempt: Set<String>
    ) -> String {
        for entry in entries.reversed() where !entryIdsBeforeAttempt.contains(entry.id) {
            guard case .response(let response) = entry else { continue }
            return WatchedText.text(of: response.segments)
        }
        return ""
    }

    /// `entries` with each no-op call of the attempt that has no output
    /// removed from its `.toolCalls` entry, and that entry removed when no
    /// call is left. A no-op call that got ``noOpToolCallEndReason`` as its
    /// output has an output and stays.
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
