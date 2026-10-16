import Foundation
import FoundationModels
import Testing

@testable import FoundationModelsRouter

/// The fixtures that the suites of the mail queue share
/// (`mailbox.md`, sections 4 and 5): `MailQueueBatchTests`,
/// `MailSignalTests` and `MailSubscriptionTests`. `CancelAllSignalTests`
/// and `ElicitationCompletedEventTests` also start their held answer with
/// ``startHeldAnswer(_:on:backend:)``.
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
    /// - Parameters:
    ///   - prompt: The prompt of the held answer.
    ///   - session: The session.
    ///   - backend: The backend of the session.
    /// - Returns: The id of the held message.
    /// - Throws: What the send throws, or ``ConditionNeverHeld`` when the
    ///   task is cancelled before the submission reaches the backend.
    @discardableResult
    static func startHeldAnswer(
        _ prompt: String, on session: any RoutedSession, backend: some PromptCountingBackend
    ) async throws -> MailID {
        let held = try session.send(prompt)
        try await backend.waitForPrompts(heldAnswerPrompts)
        return held
    }
}

/// A stub backend that counts the prompts it got, and signals each change
/// of that count on ``changes``. A test waits for a prompt with no clock
/// (``waitForPrompts(_:)``).
protocol PromptCountingBackend: Sendable {
    /// The signal of each change of the backend, sent after the change.
    var changes: ChangeSignal { get }

    /// The count of prompts that the backend got so far.
    var promptCount: Int { get }
}

extension PromptCountingBackend {
    /// Waits until at least `count` prompts reached this backend.
    ///
    /// - Parameter count: How many prompts to wait for.
    /// - Throws: ``ConditionNeverHeld`` when the waiting task is cancelled
    ///   first.
    func waitForPrompts(_ count: Int) async throws {
        try await changes.wait(untilAtLeast: count, of: { self.promptCount })
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
