import FoundationModels
import FoundationModelsExtras
import Logging

/// The marker a session sets when it stops the model call in flight because
/// run mail that starts a submission arrived while the call ran its tools,
/// and the facts it needs to go on (task ^zetnz36).
struct RunMailStop: Sendable {
    /// The backend transcript read at the tool result, before the stop.
    let liveEntries: [Transcript.Entry]

    /// The results of the calls of the round, in order.
    let results: [ToolResultAppend]
}

/// ``RoutedSessionActor``'s delivery of run mail inside the running answer
/// (task ^zetnz36).
///
/// The pump runs one answer at a time, and a submission takes its mail only
/// when it starts. So the terminal of a background run that settles while
/// the model calls tools in one submission waits in the queue. Only the next
/// submission of the answer takes it (``takeMailJoiningTheAnswer()``). A
/// model that keeps calling tools never ends its submission, and before this
/// stop it learned the result only after its answer ended.
///
/// At the tool result that completes a round of the session's own open model
/// call, ``noteRunMailDue()`` looks for queued run mail that starts a
/// submission by itself (``SessionOutbox/canStartASubmission(_:runTokens:)``):
/// the terminal of a settled background run, or a message of a background
/// run. When it finds such mail, the session sets the marker and cancels the
/// model call. The failed attempt then goes on in
/// ``continueAfterRunMailStop(_:attempt:body:)``: the session records the
/// attempt with every result of the round, and runs one more submission of
/// the same answer. That submission takes the mail, so the model reads it
/// right after the tool results, in front of ``runMailContinuationPrompt``.
///
/// The mail of one stop does not stop the answer again
/// (``runMailStoppedIds``): a continuation that cannot take it, because an
/// earlier mail still screens, leaves it to the end of the answer. Another
/// stop of the same attempt wins, and its continuation takes the mail too.
extension RoutedSessionActor {
    /// The prompt of the submission that delivers the run mail. The mail
    /// stands just above it, after the tool results.
    static let runMailContinuationPrompt = """
        Your tool results are above. Background work you started reported just above. \
        Act on that report, and continue the task.
        """

    /// Stops the model call in flight to deliver the run mail that waits,
    /// when such mail waits.
    ///
    /// The session's ``ToolResultAppendBoundary`` calls it after
    /// ``noteDelegationHintDue()`` for each tool result. Nothing happens when
    /// the answer takes no joining mail, or when no new run mail starts a
    /// submission. The stop follows
    /// ``stopModelCallAtCompleteRound(finding:losing:stop:category:message:)``.
    func noteRunMailDue() async {
        guard answerTakesJoiningMail else { return }
        await stopModelCallAtCompleteRound(
            finding: { await newRunMailStartingASubmission() },
            stop: { mail in
                runMailStoppedIds.formUnion(mail.map(\.id))
                runMailStop = RunMailStop(liveEntries: backend.transcriptEntries(), results: noOpToolCallRound.results)
            },
            category: .runMailStop,
            message: """
                run mail arrived while the model called tools; \
                the model call ends, and the answer delivers the mail
                """)
    }

    /// The queued mail that no earlier run mail stop took, when it starts a
    /// submission by itself (``SessionOutbox/canStartASubmission(_:runTokens:)``).
    ///
    /// - Returns: The mail, or `nil` when it starts no submission.
    private func newRunMailStartingASubmission() async -> [SessionOutbox.PendingEvent]? {
        let runTokens = await readBackgroundRunTokens()
        let mail = await outbox.pending().events.filter { !runMailStoppedIds.contains($0.id) }
        return SessionOutbox.canStartASubmission(mail, runTokens: runTokens) ? mail : nil
    }

    /// Takes the run mail marker of the attempt that just failed.
    ///
    /// A stop outstanding against the answer wins: the failure is then a user
    /// stop, and the marker is dropped.
    ///
    /// - Returns: The marker, or `nil` when no run mail stopped the attempt.
    func takeRunMailStop() -> RunMailStop? {
        defer { runMailStop = nil }
        guard !isWorkCancelled else { return nil }
        return runMailStop
    }

    /// Records the stopped attempt with every result of its round, then runs
    /// one more submission of the same answer, which takes the run mail.
    ///
    /// - Parameters:
    ///   - stop: The run mail marker of the stopped attempt.
    ///   - attempt: The stopped attempt.
    ///   - body: The model work to run.
    /// - Returns: The response text of the next attempt.
    /// - Throws: What the next attempt throws.
    func continueAfterRunMailStop(
        _ stop: RunMailStop,
        attempt: StoppedAttempt,
        body: @escaping @Sendable (String) async throws -> String
    ) async throws -> String {
        try await continueAfterCompleteRound(
            liveEntries: stop.liveEntries, results: stop.results, attempt: attempt,
            prompt: Self.runMailContinuationPrompt, body: body)
    }

    /// Records an attempt that a stop ended at the end of a complete round,
    /// with every result of the round, then runs one more submission of the
    /// same answer with `prompt`. The delegate hint
    /// (``continueAfterDelegationHint(_:attempt:body:)``) and the run mail
    /// (``continueAfterRunMailStop(_:attempt:body:)``) go on this way.
    ///
    /// - Parameters:
    ///   - liveEntries: The backend transcript read at the stop.
    ///   - results: The results of the calls of the round, in order.
    ///   - attempt: The stopped attempt.
    ///   - prompt: The own prompt of the next submission.
    ///   - body: The model work to run.
    /// - Returns: The response text of the next attempt.
    /// - Throws: What the next attempt throws.
    func continueAfterCompleteRound(
        liveEntries: [Transcript.Entry],
        results: [ToolResultAppend],
        attempt: StoppedAttempt,
        prompt: String,
        body: @escaping @Sendable (String) async throws -> String
    ) async throws -> String {
        await recordAttemptStoppedAtRound(liveEntries: liveEntries, results: results, attempt: attempt)
        return try await runContinuation(after: attempt, prompt: prompt, body: body)
    }
}
