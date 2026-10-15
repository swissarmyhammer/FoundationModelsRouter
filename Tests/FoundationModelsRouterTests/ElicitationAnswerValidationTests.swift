import Foundation
import Testing

@testable import FoundationModelsExtras
@testable import FoundationModelsRouter

/// Exercises the mail of an accepted form answer that breaks the requested
/// schema of its question (task ^fzjcwrm).
///
/// ``ToolContext/elicit(_:)`` gives the run a decline with the reason
/// ``ElicitationRequestedSchema/invalidAnswerReasonPrefix`` and the failure
/// for such an answer. The ``MailBody/elicitationAnswer(id:response:)`` mail
/// of ``RoutedSession/respond(elicitationId:response:)`` carries the same
/// decline. Thus the model and the run see the same answer. A valid answer
/// keeps its content in the mail.
///
/// The question goes through the journal of the session, so the session
/// records its requested schema. Each test fixes its order with the post of
/// the question and the return of each call. It reads no clock. The suite
/// runs on ``MailQueueFixtures``, and it needs no network and no GPU.
@Suite("The mail of an accepted form answer agrees with the answer that the run gets")
struct ElicitationAnswerValidationTests {
    /// The suite's temp-directory prefix, handed to
    /// ``RouterTestFixtures/makeTempDir(prefix:)``.
    private static let tempDirPrefix = "ElicitationAnswerValidationTests"

    /// The prompt of the first submission. It attaches the journal of the
    /// session to the outbox, so the journal records the question.
    private static let firstPrompt = "first message"

    /// The name of the one property of the declared schemas.
    private static let nameField = "name"

    /// A field that no declared schema has.
    private static let unknownField = "nickname"

    /// What one answered question gave.
    private struct AnsweredQuestion {
        /// The answer that the run got.
        let run: ElicitationResponse

        /// Each prompt that reached the backend, joined in order.
        let prompts: String

        /// The prompt text of the answer mail of the question with
        /// `response`.
        ///
        /// - Parameters:
        ///   - id: The id of the question.
        ///   - response: The answer that the mail carries.
        /// - Returns: The prompt text of that mail.
        static func mailText(of id: ULID, _ response: ElicitationResponse) -> String? {
            Mail(sender: .elicitation(id), body: .elicitationAnswer(id: id, response: response)).promptText
        }
    }

    /// A form question with one string property, the name, that the schema
    /// requires.
    ///
    /// - Parameter id: The id of the question.
    /// - Returns: The question.
    private static func requiredNameQuestion(_ id: ULID) -> ElicitationRequest {
        ElicitationRequest(
            message: "name?", elicitationId: id,
            requestedSchema: ElicitationRequestedSchema(
                properties: [nameField: .string(ElicitationStringSchema())], required: [nameField]))
    }

    /// A form question with no properties: it asks for a free answer.
    ///
    /// - Parameter id: The id of the question.
    /// - Returns: The question.
    private static func freeQuestion(_ id: ULID) -> ElicitationRequest {
        ElicitationRequest(message: "anything?", elicitationId: id, requestedSchema: ElicitationRequestedSchema(properties: [:]))
    }

    /// Asks `request` through the journal of a new session, answers it with
    /// `response` through ``RoutedSession/respond(elicitationId:response:)``,
    /// and waits until the session is idle.
    ///
    /// The post of the question returns after the journal recorded it, so
    /// the session knows its schema before the answer.
    ///
    /// - Parameters:
    ///   - request: The question.
    ///   - response: The answer of the user.
    /// - Returns: The answer that the run got, and the prompts of the backend.
    /// - Throws: When a step of the session throws, or the answer is not
    ///   delivered.
    private static func answer(
        _ request: ElicitationRequest, with response: ElicitationResponse
    ) async throws -> AnsweredQuestion {
        let dir = RouterTestFixtures.makeTempDir(prefix: tempDirPrefix)
        defer { try? FileManager.default.removeItem(at: dir) }
        let backend = MailQueueFixtures.Backend(script: [:])
        let (session, profile) = try await MailQueueFixtures.makeSession(over: backend, dir: dir)
        _ = try await session.respond(to: firstPrompt)

        let postings = ElicitationPostings(forwardingTo: session.outbox)
        let context = PendingElicitationFixtures.makeContext(for: session, postingTo: postings)
        let answering = Task { try await context.elicit(request) }
        try await postings.waitForPosts(1)

        let delivery = await session.respond(elicitationId: request.elicitationId.description, response: response)
        try #require(delivery == .delivered)
        let run = try await answering.value
        #expect(await session.becomesIdle())
        await session.close()
        withExtendedLifetime(profile) {}
        return AnsweredQuestion(run: run, prompts: backend.prompts.joined(separator: "\n"))
    }

    /// Checks that the run got a decline for a content that is not valid,
    /// and that the mail carries that decline and not the content.
    ///
    /// - Parameters:
    ///   - answered: What the question gave.
    ///   - id: The id of the question.
    ///   - sent: The accepted answer that the user sent.
    private static func expectSameDecline(_ answered: AnsweredQuestion, of id: ULID, sent: ElicitationResponse) throws {
        #expect(answered.run.action == .decline)
        #expect(answered.run.content == nil)
        let reason = try #require(answered.run.reason)
        #expect(reason.hasPrefix(ElicitationRequestedSchema.invalidAnswerReasonPrefix))
        let declineText = try #require(AnsweredQuestion.mailText(of: id, answered.run))
        let acceptText = try #require(AnsweredQuestion.mailText(of: id, sent))
        #expect(answered.prompts.contains(declineText))
        #expect(!answered.prompts.contains(acceptText))
    }

    /// The production change that makes this test fail: a mail that carries
    /// the answer of the client, not the decline of the run.
    @Test("an accepted answer with no required field gives the run and the mail the same decline")
    func aMissingRequiredFieldMailsTheDecline() async throws {
        let id = ULID.generate()
        let sent = ElicitationResponse.accept(content: [:])

        let answered = try await Self.answer(Self.requiredNameQuestion(id), with: sent)

        try Self.expectSameDecline(answered, of: id, sent: sent)
    }

    /// The production change that makes this test fail: a mail that carries
    /// the answer of the client, not the decline of the run.
    @Test("an accepted answer with a key that the declared properties do not have gives the run and the mail the same decline")
    func anUnknownKeyMailsTheDecline() async throws {
        let id = ULID.generate()
        let sent = ElicitationResponse.accept(content: [Self.nameField: .string("Ada"), Self.unknownField: .string("A")])

        let answered = try await Self.answer(PendingElicitationFixtures.formRequest(elicitationId: id), with: sent)

        try Self.expectSameDecline(answered, of: id, sent: sent)
    }

    /// The production change that makes this test fail: a mail that declines
    /// a valid answer.
    @Test("a valid accepted answer reaches the run and the mail with its content")
    func aValidAnswerMailsItsContent() async throws {
        let id = ULID.generate()
        let sent = ElicitationResponse.accept(content: [Self.nameField: .string("Ada")])

        let answered = try await Self.answer(Self.requiredNameQuestion(id), with: sent)

        #expect(answered.run == sent)
        #expect(answered.prompts.contains(try #require(AnsweredQuestion.mailText(of: id, sent))))
    }

    /// The production change that makes this test fail: a mail that checks
    /// each key of a free answer against the empty properties.
    @Test("an accepted free answer with keys that no property names reaches the run and the mail with its content")
    func aFreeAnswerMailsItsContent() async throws {
        let id = ULID.generate()
        let sent = ElicitationResponse.accept(content: [Self.unknownField: .string("A"), Self.nameField: .number(1)])

        let answered = try await Self.answer(Self.freeQuestion(id), with: sent)

        #expect(answered.run == sent)
        #expect(answered.prompts.contains(try #require(AnsweredQuestion.mailText(of: id, sent))))
    }
}
