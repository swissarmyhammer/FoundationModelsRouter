import Foundation
import FoundationModels
import Testing

@testable import FoundationModelsRouter

/// The fixtures that the suites of the mail queue share
/// (`mailbox.md`, sections 4 and 5): `MailQueueBatchTests`,
/// `MailSignalTests` and `MailSubscriptionTests`. Other suites that run on
/// the same backend also start their held answer with
/// ``startHeldAnswer(_:on:backend:sourceLocation:)``, and wait for a prompt
/// with ``waitForPrompts(_:on:endingWhenIdle:sourceLocation:)``.
///
/// Each session runs on ``SessionMessagePumpTests/PumpProbeBackend``, a stub
/// backend that records each prompt and can hold a call open on a
/// ``RunLatch``. The suites need no network and no GPU.
enum MailQueueFixtures {
    /// The backend that the suites script.
    typealias Backend = SessionMessagePumpTests.PumpProbeBackend

    /// The tool name of each run event that the fixtures make.
    static let runTool = "mail-probe"

    /// The op string of each run event that the fixtures make.
    static let runOp = "probe run"

    /// The correlation id of each run event that the fixtures make. No
    /// background run of a session has this token, so the run mail of a
    /// fixture never starts a submission by itself.
    static let runCorrelationID = "mail-probe-run"

    /// Makes a session over `backend`.
    ///
    /// - Parameters:
    ///   - backend: The backend the session runs on.
    ///   - dir: The temporary directory the router caches under.
    ///   - grammar: The grammar of a guided session, or `nil` for a session
    ///     with no grammar.
    /// - Returns: The session and the profile that keeps its models resident.
    static func makeSession(
        over backend: Backend, dir: URL, grammar: Grammar? = nil
    ) async throws -> (session: any RoutedSession, profile: LanguageModelProfile) {
        let profile = try await RouterTestFixtures.resolveStandardProfile(
            over: SessionMessagePumpTests.PumpProbeContainer(backend: backend), cacheDir: dir
        ).profile
        guard let grammar else { return (profile.standard.makeSession(), profile) }
        return (profile.standard.makeGuidedSession(grammar: grammar), profile)
    }

    /// Makes one progress event of the probe run.
    ///
    /// - Parameters:
    ///   - detail: The detail of the event.
    ///   - correlationID: The correlation id of the event.
    /// - Returns: The event.
    static func progressEvent(detail: String, correlationID: String = runCorrelationID) -> OperationEvent {
        OperationEvent(tool: runTool, op: runOp, correlationID: correlationID, kind: .progress, detail: detail)
    }

    /// Posts `event` to the outbox of `session`, and gives the id of the run
    /// mail that holds it.
    ///
    /// A progress event wakes no pump, so the mail stays in the queue until a
    /// submission takes it.
    ///
    /// - Parameters:
    ///   - event: The event to post.
    ///   - session: The session whose outbox gets the event.
    /// - Returns: The id of the queued run mail that holds `event`.
    /// - Throws: When no queued mail holds `event` after the post.
    static func post(_ event: OperationEvent, to session: any RoutedSession) async throws -> MailID {
        await session.outbox.post(event: event)
        let mail = try #require(session.outbox.queue.pending.last { $0.runEvent == event })
        return mail.id
    }

    /// Takes the queued run mail of `session` and puts it back held
    /// (``SessionOutbox/putBack(holding:)``), as the bound on the answers
    /// that mail alone starts does.
    ///
    /// - Parameter session: The session whose run mail goes on hold.
    /// - Returns: The ids of the held mail, in queue order.
    static func holdRunMail(of session: any RoutedSession) -> [MailID] {
        let taken = session.outbox.queue.take { candidate, _ in candidate.isRunMail }
        #expect(session.outbox.putBack(holding: taken).isEmpty)
        return taken.map(\.id)
    }

    /// The answer of `event`.
    ///
    /// - Parameter event: One event of a session.
    /// - Returns: The payload of ``SessionEvent/answered(_:)``, or `nil` for
    ///   another event.
    static func answer(of event: SessionEvent) -> SessionAnswer? {
        guard case .answered(let answer) = event else { return nil }
        return answer
    }

    /// The failure of `event`.
    ///
    /// - Parameter event: One event of a session.
    /// - Returns: The payload of ``SessionEvent/answerFailed(_:)``, or `nil`
    ///   for another event.
    static func failure(of event: SessionEvent) -> AnswerFailure? {
        guard case .answerFailed(let failure) = event else { return nil }
        return failure
    }

    /// Whether `event` is ``SessionEvent/submissionStarted(_:)``.
    ///
    /// - Parameter event: One event of a session.
    /// - Returns: `true` for the start of a submission.
    static func isSubmissionStart(_ event: SessionEvent) -> Bool {
        guard case .submissionStarted = event else { return false }
        return true
    }

    /// The ids of the ``SessionEvent/cancelled(_:)`` events of `events`, in
    /// order.
    ///
    /// - Parameter events: The events of a session, in order.
    /// - Returns: The cancelled ids.
    static func cancelledIds(in events: [SessionEvent]) -> [MailID] {
        events.compactMap { event in
            guard case .cancelled(let mailID) = event else { return nil }
            return mailID
        }
    }

    /// Reads `subscription` to its end.
    ///
    /// - Parameter subscription: The output of one mail.
    /// - Returns: Each output of the mail, in order.
    static func readToEnd(_ subscription: MailSubscription<SessionOutput>) async -> [SessionOutput] {
        var outputs: [SessionOutput] = []
        for await output in subscription {
            outputs.append(output)
        }
        return outputs
    }

    /// The count of prompts that reach the backend when the held answer
    /// starts.
    private static let heldAnswerPrompts = 1

    /// Sends `prompt` to `session`, and waits until `backend` got it. The
    /// answer to the prompt then runs, and it waits at the hold of the first
    /// call of `backend`.
    ///
    /// This is the one step "start the held answer" of the suites. The
    /// session sends the prompt as one user message in reply mode
    /// (``RoutedSession/send(_:)-(String)``).
    ///
    /// The wait also ends when the session becomes idle (rule T1), as
    /// ``waitForPrompts(_:on:endingWhenIdle:sourceLocation:)`` states.
    ///
    /// - Parameters:
    ///   - prompt: The prompt of the held answer.
    ///   - session: The session.
    ///   - backend: The backend of the session.
    ///   - sourceLocation: The place of the call, for the failure.
    /// - Returns: The id of the held message.
    /// - Throws: What the send throws, the error of `#require` when the
    ///   session became idle before the prompt reached the backend, or
    ///   ``ConditionNeverHeld`` when the task is cancelled first.
    @discardableResult
    static func startHeldAnswer(
        _ prompt: String, on session: any RoutedSession, backend: some PromptCountingBackend,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws -> MailID {
        let held = try session.send(prompt)
        try await waitForPrompts(heldAnswerPrompts, on: backend, endingWhenIdle: session, sourceLocation: sourceLocation)
        return held
    }

    /// Waits until at least `count` prompts reached `backend`, or until
    /// `session` became idle (rule T1). When the session became idle and the
    /// count is still low, the wait throws ``FailureEventCameFirst``.
    ///
    /// Use this wait after a step that must start a submission, when no
    /// task of the test waits for the answer: a send, a ``RoutedSession/mail(_:)``,
    /// or a post of a terminal or a message of a run. The session is idle
    /// when no pump runs and no user-type mail waits
    /// (``RoutedSession/becomesIdle()``). A send puts its mail in the queue
    /// before it returns, and a post of a terminal or a message wakes the
    /// pump before it returns. So the session becomes idle only after a pump
    /// took the mail and ended, and that pump calls the backend before it
    /// ends. When the submission fails before it calls the backend, the pump
    /// ends with no prompt, and the wait ends. One failure stays quiet: mail
    /// that wakes no pump stays in the queue, so the session does not become
    /// idle, and no event ends the wait.
    ///
    /// - Parameters:
    ///   - count: How many prompts to wait for.
    ///   - backend: The backend of the session.
    ///   - session: The session whose idle state is the failure event.
    ///   - sourceLocation: The place of the call, for the failure.
    /// - Throws: ``FailureEventCameFirst`` when the session became idle first,
    ///   or ``ConditionNeverHeld`` when the test was cancelled first.
    static func waitForPrompts(
        _ count: Int, on backend: some PromptCountingBackend, endingWhenIdle session: any RoutedSession,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        try await waitForPrompts(
            count, on: backend, endingOnEndOf: { await session.becomesIdle() }, sourceLocation: sourceLocation)
    }

    /// Waits until at least `count` prompts reached `backend`, or until the
    /// work of `session` ended (rule T1). When the work ended and the count
    /// is still low, the wait throws ``FailureEventCameFirst``.
    ///
    /// The work ends when ``RoutedSession/awaitIdle()`` returns. Use this
    /// wait after a background run settled, when its terminal must start a
    /// submission with no caller call. The terminal of a settled run that
    /// waits in the outbox is work, so the work does not end until a pump
    /// took the terminal, called the backend and ended. The idle state of
    /// ``waitForPrompts(_:on:endingWhenIdle:sourceLocation:)`` does not see
    /// that terminal: between the settle and the wake of the pump it can hold,
    /// and the test then fails in a run that the program passes. The work of
    /// a session also includes each open background run, so the work of a
    /// session with an open run does not end.
    ///
    /// - Parameters:
    ///   - count: How many prompts to wait for.
    ///   - backend: The backend of the session.
    ///   - session: The session whose end of work is the failure event.
    ///   - sourceLocation: The place of the call, for the failure.
    /// - Throws: ``FailureEventCameFirst`` when the work ended first, or
    ///   ``ConditionNeverHeld`` when the test was cancelled first.
    static func waitForPrompts(
        _ count: Int, on backend: some PromptCountingBackend, endingWhenWorkEnds session: any RoutedSession,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        try await backend.changes.wait(
            until: { backend.promptCount >= count }, endingWhenWorkEnds: session, sourceLocation: sourceLocation)
    }

    /// Waits until at least `count` prompts reached `backend`, or until
    /// `failureEvent` returned in a task of its own (rule T1).
    ///
    /// - Parameters:
    ///   - count: How many prompts to wait for.
    ///   - backend: The backend of the session.
    ///   - failureEvent: A wait for the failure event. A cancel ends it.
    ///   - sourceLocation: The place of the call, for the failure.
    /// - Throws: ``FailureEventCameFirst`` when `failureEvent` returned first,
    ///   or ``ConditionNeverHeld`` when the test was cancelled first.
    private static func waitForPrompts(
        _ count: Int, on backend: some PromptCountingBackend,
        endingOnEndOf failureEvent: @escaping @Sendable () async -> Bool, sourceLocation: SourceLocation
    ) async throws {
        let ending = Task { await failureEvent() }
        // The cancel ends the wait for the failure event, so it leaves no
        // waiter on the signals of the session.
        defer { ending.cancel() }
        try await backend.waitForPrompts(count, endingOnEndOf: ending, sourceLocation: sourceLocation)
    }
}

/// A stub backend that counts the prompts it got, and signals each change
/// of that count on ``changes``. A test waits for a prompt with no clock
/// (``waitForPrompts(_:endingOnEndOf:sourceLocation:)``).
protocol PromptCountingBackend: Sendable {
    /// The signal of each change of the backend, sent after the change.
    var changes: ChangeSignal { get }

    /// The count of prompts that the backend got so far.
    var promptCount: Int { get }
}

extension PromptCountingBackend {
    /// Waits until at least `count` prompts reached this backend, or until
    /// `task` ended (rule T1). When `task` ended and the count is still low,
    /// the wait throws ``FailureEventCameFirst``.
    ///
    /// The wait is ``ChangeSignal/wait(isolation:until:endingOnEndOf:sourceLocation:)``
    /// on ``changes``. Thus a prompt that came before `task` ended passes,
    /// also when the end signal comes first. In a test that passes, `task`
    /// must not end before the prompts came: for example `task` is the answer
    /// that the prompts start, and the backend holds its call.
    ///
    /// - Parameters:
    ///   - count: How many prompts to wait for.
    ///   - task: The task whose end is the failure event.
    ///   - sourceLocation: The place of the call, for the failure.
    /// - Throws: ``FailureEventCameFirst`` when `task` ended first, or
    ///   ``ConditionNeverHeld`` when the test was cancelled first.
    func waitForPrompts<Success: Sendable, Failure: Error>(
        _ count: Int, endingOnEndOf task: Task<Success, Failure>,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        try await changes.wait(
            until: { self.promptCount >= count }, endingOnEndOf: task, sourceLocation: sourceLocation)
    }
}

extension SessionMessagePumpTests.PumpProbeBackend: PromptCountingBackend {
    /// The count of ``prompts``.
    var promptCount: Int { prompts.count }
}

extension BackgroundingBackend: PromptCountingBackend {
    /// The count of ``receivedPrompts``.
    var promptCount: Int { receivedPrompts.count }
}
