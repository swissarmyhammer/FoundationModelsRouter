import Testing

import FoundationModelsRouter

/// Holds ``SessionAnswer``, ``AnswerFailure`` and the answer members of
/// ``SessionProjection`` to the access level a consumer outside this package
/// needs (task ^x7cxsg3). A consumer reads the final answer of a chain from
/// ``SessionEvent/answered(_:)`` or ``SessionEvent/answerFailed(_:)``, and
/// makes both records itself in a fake event stream of its own tests.
///
/// The import is plain, with no `@testable`, so a member that loses `public`
/// stops this file from compiling before a single test runs.
@Suite("SessionAnswer and AnswerFailure over a plain import")
struct SessionAnswerPublicSurfaceTests {
    /// The reply of the fake answer.
    private static let reply = "the final reply"

    /// The input tokens of the fake answer.
    private static let tokensIn = 12

    /// The output tokens of the fake answer.
    private static let tokensOut = 5

    /// The context fill of the fake answer.
    private static let contextFill = 0.25

    /// The text of the error of the fake failure.
    private static let errorText = "the model failed"

    @Test("a consumer makes an answer and reads each of its fields")
    func aConsumerMakesAndReadsAnAnswer() {
        let usage = TokenUsage(tokensIn: Self.tokensIn, tokensOut: Self.tokensOut, contextFill: Self.contextFill)
        let answer = SessionAnswer(
            reply: Self.reply, messageIds: [], usage: usage, compactions: [], toolCalls: [], toolInvocations: [])

        #expect(answer.reply == Self.reply)
        #expect(answer.messageIds.isEmpty)
        #expect(answer.usage == usage)
        #expect(answer.contextFill == Self.contextFill)
        #expect(answer.compactions.isEmpty)
        #expect(answer.toolCalls.isEmpty)
        #expect(answer.toolInvocations.isEmpty)
    }

    @Test("a consumer makes a failure for each reason and reads it")
    func aConsumerMakesAndReadsAFailure() {
        let cancelled = AnswerFailure(messageIds: [], reason: .cancelled)
        let failed = AnswerFailure(messageIds: [], reason: .error(Self.errorText))

        #expect(cancelled.reason == .cancelled)
        #expect(failed.reason == .error(Self.errorText))
        #expect(failed.messageIds.isEmpty)
        #expect(cancelled != failed)
    }

    @Test("a projection reads the answer events and names no running submission before one starts")
    @MainActor
    func aProjectionReadsTheAnswerEvents() {
        let projection = SessionProjection()
        let answer = SessionAnswer(
            reply: Self.reply, messageIds: [], usage: nil, compactions: [], toolCalls: [], toolInvocations: [])

        projection.apply(.answered(answer))
        projection.apply(.answerFailed(AnswerFailure(messageIds: [], reason: .cancelled)))

        #expect(projection.currentSubmission == nil)
        #expect(projection.messagesAwaitingAnswer.isEmpty)
    }
}
