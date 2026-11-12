import FoundationModels
import FoundationModelsExtras
import Logging

/// The marker a session sets when it stops the model call in flight to give
/// the delegate hint (``AgentDelegationHint``), and the facts it needs to go
/// on.
struct DelegationHintStop: Sendable {
    /// The text of the hint.
    let hint: String

    /// The backend transcript read at the tool result, before the stop.
    let liveEntries: [Transcript.Entry]

    /// The results of the calls of the round, in order.
    let results: [ToolResultAppend]
}

/// ``RoutedSessionActor``'s delivery of the delegate hint
/// (``AgentDelegationHint``).
///
/// The hint is not text in a tool result: a model that reads tool results as
/// data reads such a hint as data too. The hint is the prompt of a
/// submission instead, as a compaction yield or a no-op tool call stop gives
/// a prompt. At the tool result that completes a round of the session's own
/// open model call, ``noteDelegationHintDue()`` takes the hint from the
/// advisor, sets the marker and cancels the model call. The failed attempt
/// then goes on in ``continueAfterDelegationHint(_:attempt:body:)``. The
/// session records the attempt with every result of the round, and runs one
/// more submission of the same answer with the hint as its prompt
/// (``delegationHintPrompt(_:)``). The model reads the hint as its next
/// message, before it generates again.
///
/// The stop is part of the running answer: it takes no lease and queues no
/// mail, so the hint is no work. Another stop of the same attempt wins, and
/// the hint stays due for a later round.
extension RoutedSessionActor {
    /// The text before the hint in the prompt of the continuation.
    static let delegationHintPromptPrefix = "Your tool results are above. "

    /// The prompt of the submission that gives `hint`.
    ///
    /// - Parameter hint: The text of the hint.
    /// - Returns: The prompt.
    static func delegationHintPrompt(_ hint: String) -> String {
        delegationHintPromptPrefix + hint
    }

    /// Binds the advisor of the hint. The vending site calls it one time,
    /// before it returns the session.
    ///
    /// - Parameter advisor: The advisor, or `nil` for no hint.
    nonisolated func bind(delegationAdvisor advisor: AgentDelegationAdvisor?) {
        delegationAdvisorSlot.withLock { $0 = advisor }
    }

    /// Stops the model call in flight to give the hint, when the hint is due.
    ///
    /// The session's ``ToolResultAppendBoundary`` calls it after
    /// ``noteToolResult(_:)`` for each tool result. Nothing happens when the
    /// session has no advisor, or when the advisor gives no hint. The stop
    /// follows ``stopModelCallAtCompleteRound(finding:losing:stop:category:message:)``:
    /// a hint that another stop won over goes back to the advisor.
    func noteDelegationHintDue() async {
        guard let advisor = delegationAdvisorSlot.withLock({ $0 }) else { return }
        await stopModelCallAtCompleteRound(
            finding: { await advisor.takeHint() },
            losing: { _ in advisor.releaseHint() },
            stop: { hint in
                delegationHintStop = DelegationHintStop(
                    hint: hint, liveEntries: backend.transcriptEntries(), results: noOpToolCallRound.results)
            },
            category: .delegationHint,
            message: "a code change by hand ends the model call, and the next prompt gives the delegate hint")
    }

    /// Takes the hint marker of the attempt that just failed.
    ///
    /// A stop outstanding against the answer wins: the failure is then a user
    /// stop, the marker is dropped, and the hint stays due.
    ///
    /// - Returns: The marker, or `nil` when the hint did not stop the attempt.
    func takeDelegationHintStop() -> DelegationHintStop? {
        defer { delegationHintStop = nil }
        guard let stop = delegationHintStop else { return nil }
        guard !isWorkCancelled else {
            releaseDelegationHint()
            return nil
        }
        return stop
    }

    /// Gives the hint back to the advisor, so it stays due: another stop of
    /// the attempt won over it.
    func releaseDelegationHint() {
        delegationAdvisorSlot.withLock { $0 }?.releaseHint()
    }

    /// Records the stopped attempt with every result of its round, then runs
    /// one more submission of the same answer with the hint as its prompt.
    ///
    /// - Parameters:
    ///   - stop: The hint marker of the stopped attempt.
    ///   - attempt: The stopped attempt.
    ///   - body: The model work to run.
    /// - Returns: The response text of the next attempt.
    /// - Throws: What the next attempt throws.
    func continueAfterDelegationHint(
        _ stop: DelegationHintStop,
        attempt: StoppedAttempt,
        body: @escaping @Sendable (String) async throws -> String
    ) async throws -> String {
        try await continueAfterCompleteRound(
            liveEntries: stop.liveEntries, results: stop.results, attempt: attempt,
            prompt: Self.delegationHintPrompt(stop.hint), body: body)
    }
}
