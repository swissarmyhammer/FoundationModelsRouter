import Testing

import FoundationModelsRouter

/// Holds the events of a submission and of an answer to the access level a
/// consumer outside this package needs (tasks ^ake8sax, ^1psqdm9 and
/// ^x7cxsg3). A consumer such as an agent host shows "waiting for the model"
/// between ``SessionEvent/submissionQueued(_:)`` and
/// ``SessionEvent/submissionStarted(_:)``, "generating" until
/// ``SessionEvent/submissionEnded(_:)``, and the end of the answer at
/// ``SessionEvent/answered(_:)`` or ``SessionEvent/answerFailed(_:)``. A
/// submission that finds the worker free sends no
/// ``SessionEvent/submissionQueued(_:)``.
///
/// The import is plain, with no `@testable`, so a case that loses `public`
/// stops this file from compiling before a single test runs. A consumer
/// cannot mint a ``SubmissionID``, so the three submission cases are proved by
/// the switch that compiles, and the two answer cases at run time.
@Suite("SessionEvent submission and answer events over a plain import")
struct GenerationSubmissionEventPublicSurfaceTests {
    /// The label a consumer shows for `event`, or `nil` for an event that is
    /// not about a submission or an answer.
    ///
    /// - Parameter event: The event to read.
    /// - Returns: The label.
    private static func submissionLabel(for event: SessionEvent) -> String? {
        switch event {
        case .submissionQueued:
            "waiting for the model"
        case .submissionStarted:
            "generating"
        case .submissionEnded:
            "submitted"
        case .answered:
            "answered"
        case .answerFailed:
            "no answer"
        default:
            nil
        }
    }

    /// The payload of a submission event that a consumer keys its view on:
    /// the id of the submission.
    ///
    /// - Parameter event: The event to read.
    /// - Returns: The id of the submission, or `nil` for another event.
    private static func submissionId(of event: SessionEvent) -> SubmissionID? {
        switch event {
        case .submissionQueued(let id):
            id
        case .submissionStarted(let start):
            start.submissionId
        case .submissionEnded(let end):
            end.submissionId
        default:
            nil
        }
    }

    @Test("a consumer matches the answer events by name, and no other event reads as one")
    func aConsumerMatchesTheAnswerEvents() {
        let answer = SessionAnswer(
            reply: "", messageIds: [], usage: nil, compactions: [], toolCalls: [], toolInvocations: [])
        let failure = AnswerFailure(messageIds: [], reason: .cancelled)

        #expect(Self.submissionLabel(for: .answered(answer)) == "answered")
        #expect(Self.submissionLabel(for: .answerFailed(failure)) == "no answer")
        #expect(Self.submissionLabel(for: .textReset) == nil)
        #expect(Self.submissionId(of: .answered(answer)) == nil)
    }
}
