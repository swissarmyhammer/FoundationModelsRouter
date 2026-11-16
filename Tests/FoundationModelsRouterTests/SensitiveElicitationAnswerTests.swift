import Foundation
import Testing

@testable import FoundationModelsExtras
@testable import FoundationModelsRouter

/// Exercises the answer mail of a sensitive question (task ^8nbwv8x,
/// `ElicitationRequest.sensitive`).
///
/// The answer to a sensitive question holds a secret, for example a token
/// that a tool asks for. The run gets the full answer. The
/// ``MailBody/elicitationAnswer(id:response:)`` mail goes into the prompt of
/// the model and into the recording, so it carries no content of the answer:
/// it tells the model that the user answered and that the tool has the
/// content. A decline of ``ToolContext/elicit(_:)`` for an answer that is not
/// valid can hold a value of the answer in its reason, so the mail of a
/// sensitive question carries a fixed reason in its place.
///
/// The record tests read ``AskedQuestions`` directly. The session tests ask
/// the question through the journal of a session on ``MailQueueFixtures``,
/// so they need no network and no GPU, and they read no clock.
@Suite("The answer mail of a sensitive question carries no content of the answer")
struct SensitiveElicitationAnswerTests {
    /// The name of the string field of the questions.
    private static let tokenField = "token"

    /// The secret that the user gives. It is a fake value.
    private static let secret = "fake-test-token-value"

    /// The reason of a decline of the user.
    private static let userReason = "not now"

    /// The accepted answer that holds the secret.
    private static let acceptedSecret = ElicitationResponse.accept(content: [tokenField: .string(secret)])

    /// A form question with one string field, ``tokenField``.
    ///
    /// - Parameter isSensitive: Whether the answer holds a secret.
    /// - Returns: The question, with a new id.
    private static func tokenQuestion(isSensitive: Bool) -> ElicitationRequest {
        ElicitationRequest(
            message: "token?", elicitationId: ULID.generate(),
            requestedSchema: ElicitationRequestedSchema(properties: [tokenField: .string(ElicitationStringSchema())]),
            sensitive: isSensitive)
    }

    /// The answer that a record with the one question `request` mails for
    /// `response`.
    ///
    /// - Parameters:
    ///   - request: The question.
    ///   - response: The answer of the user.
    /// - Returns: The mailed answer.
    private static func mailed(_ request: ElicitationRequest, _ response: ElicitationResponse) -> ElicitationResponse {
        var questions = AskedQuestions()
        questions.noteAsked(request, mailID: nil)
        return questions.mailedResponse(answering: request.elicitationId, with: response)
    }

    /// The prompt text of the answer mail of `request` for `response`. The
    /// mail comes from ``ElicitationAnswerValidationTests/AnsweredQuestion/mailText(of:_:)``.
    ///
    /// - Parameters:
    ///   - request: The question.
    ///   - response: The answer of the user.
    /// - Returns: The prompt text, or an empty string.
    private static func mailText(_ request: ElicitationRequest, _ response: ElicitationResponse) -> String {
        let id = request.elicitationId
        return ElicitationAnswerValidationTests.AnsweredQuestion.mailText(of: id, mailed(request, response)) ?? ""
    }

    // MARK: - The record

    /// The production change that makes this test fail: a mail that carries
    /// the content of a sensitive answer.
    @Test("the answer mail of an accepted sensitive question holds no content")
    func aSensitiveAcceptMailsNoContent() {
        let text = Self.mailText(Self.tokenQuestion(isSensitive: true), Self.acceptedSecret)

        #expect(!text.contains(Self.secret))
    }

    /// The production change that makes this test fail: a mail of a
    /// sensitive answer that does not tell the model that the tool has the
    /// content.
    @Test("the answer mail of an accepted sensitive question tells the model that the tool has the content")
    func aSensitiveAcceptMailSaysTheToolHasTheContent() {
        let text = Self.mailText(Self.tokenQuestion(isSensitive: true), Self.acceptedSecret)

        #expect(text.contains(AskedQuestions.withheldContentNote))
    }

    /// The production change that makes this test fail: a mail that removes
    /// the content of a question that is not sensitive.
    @Test("the answer mail of a question that is not sensitive holds the content")
    func aNotSensitiveAcceptMailsTheContent() {
        let mailed = Self.mailed(Self.tokenQuestion(isSensitive: false), Self.acceptedSecret)

        #expect(mailed == Self.acceptedSecret)
    }

    /// The production change that makes this test fail: a mail that changes
    /// the decline of the user for a sensitive question.
    @Test("the decline of a sensitive question mails the same answer as for a question that is not sensitive")
    func aSensitiveDeclineMailsTheSameAnswer() {
        let decline = ElicitationResponse.decline(reason: Self.userReason)

        let sensitive = Self.mailed(Self.tokenQuestion(isSensitive: true), decline)
        let plain = Self.mailed(Self.tokenQuestion(isSensitive: false), decline)

        #expect(sensitive == plain)
    }

    /// The production change that makes this test fail: a mail of a
    /// sensitive question that carries the reason of the check, which names
    /// a key of the answer.
    @Test("the decline of a sensitive answer that is not valid mails a reason with no value of the answer")
    func anInvalidSensitiveAnswerMailsNoValue() {
        let wrongKey = ElicitationResponse.accept(content: [Self.secret: .string(Self.userReason)])

        let mailed = Self.mailed(Self.tokenQuestion(isSensitive: true), wrongKey)

        #expect(mailed.reason?.contains(Self.secret) == false)
    }

    /// The production change that makes this test fail: a mail that keeps
    /// the reason of a decline that the check of a parent made, when a relay
    /// gives that decline to the level that asked.
    @Test("a decline of the check that comes to a sensitive question mails a reason with no value of the answer")
    func aCheckDeclineOfASensitiveQuestionMailsNoValue() {
        let checkDecline = ElicitationResponse.decline(
            reason: ElicitationRequestedSchema.invalidAnswerReasonPrefix + "the field \"\(Self.secret)\" is not valid")

        let mailed = Self.mailed(Self.tokenQuestion(isSensitive: true), checkDecline)

        #expect(mailed.reason?.contains(Self.secret) == false)
    }

    /// The production change that makes this test fail: a mail of a
    /// sensitive question whose fixed reason does not tell the model that
    /// the answer was not valid.
    @Test("the fixed reason of a sensitive answer that is not valid tells that the answer is not valid")
    func anInvalidSensitiveAnswerReasonKeepsThePrefix() {
        let wrongKey = ElicitationResponse.accept(content: [Self.secret: .string(Self.userReason)])

        let mailed = Self.mailed(Self.tokenQuestion(isSensitive: true), wrongKey)

        #expect(mailed.reason?.hasPrefix(ElicitationRequestedSchema.invalidAnswerReasonPrefix) == true)
    }

    // MARK: - The session

    /// The production change that makes this test fail: a session that gives
    /// the run the mailed answer in place of the answer of the user.
    @Test("the run of a sensitive question gets the content of the answer")
    func theRunOfASensitiveQuestionGetsTheContent() async throws {
        let answered = try await ElicitationAnswerValidationTests.answer(
            Self.tokenQuestion(isSensitive: true), with: Self.acceptedSecret)

        #expect(answered.run == Self.acceptedSecret)
    }

    /// The production change that makes this test fail: a session that mails
    /// the content of a sensitive answer to its model.
    @Test("no prompt of the model holds the content of a sensitive answer")
    func noPromptHoldsTheContentOfASensitiveAnswer() async throws {
        let answered = try await ElicitationAnswerValidationTests.answer(
            Self.tokenQuestion(isSensitive: true), with: Self.acceptedSecret)

        #expect(!answered.prompts.contains(Self.secret))
    }

    /// The production change that makes this test fail: a session that
    /// writes the content of a sensitive answer to its recording.
    @Test("the recording holds no content of a sensitive answer")
    func theRecordingHoldsNoContentOfASensitiveAnswer() async throws {
        let answered = try await ElicitationAnswerValidationTests.answer(
            Self.tokenQuestion(isSensitive: true), with: Self.acceptedSecret)

        #expect(!answered.recording.isEmpty)
        #expect(!answered.recording.contains(Self.secret))
    }

    /// The production change that makes this test fail: a session that mails
    /// the decline of ``ToolContext/elicit(_:)``, whose reason names a key of
    /// the sensitive answer, to its model.
    @Test("no prompt of the model holds a value of a sensitive answer that is not valid")
    func noPromptHoldsAValueOfAnInvalidSensitiveAnswer() async throws {
        let wrongKey = ElicitationResponse.accept(content: [Self.secret: .string(Self.userReason)])

        let answered = try await ElicitationAnswerValidationTests.answer(
            Self.tokenQuestion(isSensitive: true), with: wrongKey)

        #expect(!answered.prompts.contains(Self.secret))
    }
}
