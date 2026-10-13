import Foundation
import FoundationModels
import Testing

@testable import FoundationModelsRouter

/// The fixtures that the suites of the mail queue share
/// (`mailbox.md`, sections 4 and 5): `MailQueueBatchTests`,
/// `MailSignalTests` and `MailSubscriptionTests`.
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
}
