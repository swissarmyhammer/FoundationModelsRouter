import FoundationModelsExtras
import Testing

@testable import FoundationModelsRouter

/// Exercises the prompt text of a mailed elicitation answer
/// (``Mail/promptText``).
///
/// The text is one line that names the elicitation id, the action and the
/// content. A decline or a cancel that gives a reason adds a line break, then
/// `reason: ` and the reason, so that the model sees why the user gave no
/// answer. An answer with no reason gives the same text as before.
///
/// The suite calls the property directly. It needs no network and no GPU.
@Suite("The prompt text of a mailed elicitation answer")
struct ElicitationAnswerPromptTextTests {
    /// The reason that a declining user gives.
    private static let declineReason = "I do not want to share my address."

    /// The reason that a cancelled elicitation gives.
    private static let cancelReason = "The user closed the form.\nThe question timed out."

    /// The mail of an elicitation answer, from a new elicitation id.
    ///
    /// - Parameter response: The answer of the user.
    /// - Returns: The elicitation id and the mail.
    private static func answerMail(_ response: ElicitationResponse) -> (id: ULID, mail: Mail) {
        let elicitationID = ULID()
        let mail = Mail(
            sender: .elicitation(elicitationID), body: .elicitationAnswer(id: elicitationID, response: response))
        return (elicitationID, mail)
    }

    /// The first line of the text of an answer with no content: the format
    /// that the session used before the reason line.
    ///
    /// - Parameters:
    ///   - elicitationID: The elicitation id.
    ///   - action: The action of the answer.
    /// - Returns: The line.
    private static func headerLine(_ elicitationID: ULID, _ action: String) -> String {
        "[answer to elicitation \(elicitationID.ulidString)] \(action): none"
    }

    @Test("a decline with a reason puts the reason on a line after the action")
    func declineWithReasonShowsTheReason() {
        let answer = Self.answerMail(.decline(reason: Self.declineReason))

        #expect(answer.mail.promptText == Self.headerLine(answer.id, "decline") + "\nreason: " + Self.declineReason)
    }

    @Test("a cancel with a reason puts the reason on a line after the action")
    func cancelWithReasonShowsTheReason() {
        let answer = Self.answerMail(.cancel(reason: Self.cancelReason))

        #expect(answer.mail.promptText == Self.headerLine(answer.id, "cancel") + "\nreason: " + Self.cancelReason)
    }

    @Test("a decline with no reason gives the same text as before")
    func declineWithNoReasonKeepsTheText() {
        let answer = Self.answerMail(.decline)

        #expect(answer.mail.promptText == Self.headerLine(answer.id, "decline"))
    }

    @Test("a cancel with no reason gives the same text as before")
    func cancelWithNoReasonKeepsTheText() {
        let answer = Self.answerMail(.cancel)

        #expect(answer.mail.promptText == Self.headerLine(answer.id, "cancel"))
    }
}
