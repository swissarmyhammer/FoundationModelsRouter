import Foundation
import FoundationModelsRouterTestSupport
import Testing

@testable import FoundationModelsExtras
@testable import FoundationModelsRouter

/// Exercises task ^rkh6k6m: ``SessionEvent/elicitationCompleted(_:)``. The
/// session sends it one time when the run plane completes an accepted
/// URL-mode question that its journal recorded, from each source: the client
/// (``RoutedSession/complete(elicitationId:)``) or the tool that asked
/// (`ToolContext.complete(elicitationId:)`).
///
/// Each test fixes the order of the work. The question waits on a fake
/// background run of the session, and its context posts through
/// ``ElicitationPostings`` to the outbox of the session. A post to that sink
/// ends after the journal of the session handled it, so the test waits for
/// the count of the posts, and then reads the outputs. The test then closes
/// the session and reads its feed to the end. The tests read the order of
/// the outputs, not a clock.
///
/// The run plane of Extras posts the completion, waits for the end of that
/// post, and only then resumes the run. Thus the completion comes before the
/// first event of the resumed run, and one test reads that order through a
/// real background run.
@Suite("An accepted URL question whose flow completes gives one elicitationCompleted event")
struct ElicitationCompletedEventTests {
    // MARK: - Constants

    /// The prefix of the directory of each session.
    private static let prefix = "ElicitationCompletedEventTests"

    /// The posts of one question: its `.elicitation` event.
    private static let questionPosts = 1

    /// The completions of one question.
    private static let oneCompletion = 1

    /// The completions after one more completion post of the same question.
    private static let twoCompletions = 2

    // MARK: - Helpers

    /// One session whose fake background run waits on an open question, and
    /// a feed of the session.
    private struct AskedQuestion {
        /// The fixture of the session.
        let fixture: BackgroundingSessionFixture

        /// The feed of the session, from before the question.
        var feed: AsyncStream<SessionOutput>.Iterator

        /// The context that asked the question.
        let context: ToolContext

        /// The sink of the context. It forwards each post to the outbox of the
        /// session.
        let postings: ElicitationPostings

        /// The id of the question.
        let id: ULID

        /// The wait of the run for its answer.
        let answer: Task<ElicitationResponse, any Error>

        /// The gate that holds the fake run open.
        let runGate: RunLatch

        /// Accepts the question through the session.
        ///
        /// - Returns: What the run plane did with the accept.
        func accept() async -> ElicitationAnswerDelivery {
            await fixture.session.respond(elicitationId: id.description, response: .accept(content: nil))
        }

        /// Opens the gate of the run, closes the session, and reads the feed
        /// to its end.
        ///
        /// - Returns: Each output of the feed, in order.
        mutating func outputsToTheEnd() async -> [SessionOutput] {
            await fixture.end(opening: [runGate])
            return await SessionWorkEventTests.remainingOutputs(of: &feed)
        }
    }

    /// Makes a session with a fake background run whose context asks a
    /// question, and returns when the journal of the session recorded the
    /// question.
    ///
    /// - Parameter makeRequest: Makes the question from its id.
    /// - Returns: The question and its session.
    /// - Throws: What the fixture throws, or ``ConditionNeverHeld``.
    private static func ask(_ makeRequest: (ULID) -> ElicitationRequest) async throws -> AskedQuestion {
        let fixture = try await BackgroundingSessionFixture.make(prefix: prefix, tools: [])
        let session = try fixture.sessionActor()
        await session.attachOutboxJournalIfNeeded()
        let feed = await fixture.session.streamSessionEvents().makeAsyncIterator()
        let runGate = RunLatch()
        let token = await trackFakeRun(on: session.runPlane, latch: runGate)
        let postings = ElicitationPostings(forwardingTo: fixture.session.outbox)
        let context = PendingElicitationFixtures.makeContext(
            for: fixture.session, postingTo: postings, completionToken: token)
        let id = ULID.generate()
        let request = makeRequest(id)
        let answer = Task { try await context.elicit(request) }
        try await postings.waitForPosts(questionPosts)
        return AskedQuestion(
            fixture: fixture, feed: feed, context: context, postings: postings, id: id, answer: answer,
            runGate: runGate)
    }

    /// A URL-mode question.
    ///
    /// - Parameter id: The id of the question.
    /// - Returns: The question.
    private static func urlRequest(_ id: ULID) -> ElicitationRequest {
        ElicitationRequest(message: "Open the page", elicitationId: id, url: SessionWorkEventTests.approvalURL)
    }

    /// Each ``SessionEvent/elicitationCompleted(_:)`` of `outputs`, with its
    /// origin and its position.
    ///
    /// - Parameter outputs: Outputs of a session.
    /// - Returns: The completions, in order.
    private static func completions(
        in outputs: [SessionOutput]
    ) -> [(position: Int, origin: Origin, completion: ElicitationCompletion)] {
        outputs.enumerated().compactMap { position, output in
            guard case .elicitationCompleted(let completion) = output.event else { return nil }
            return (position, output.origin, completion)
        }
    }

    /// Checks that `outputs` hold exactly one completion of the question,
    /// with the origin of the question: the run mail that holds it.
    ///
    /// - Parameters:
    ///   - outputs: Outputs of a session.
    ///   - asked: The question.
    /// - Returns: The position of the completion.
    /// - Throws: When `outputs` hold no question or no completion.
    private static func soleCompletion(in outputs: [SessionOutput], of asked: AskedQuestion) throws -> Int {
        let found = completions(in: outputs)
        #expect(found.count == oneCompletion, "expected one completion of the question, got \(found.count)")
        let completion = try #require(found.first)
        #expect(completion.completion == ElicitationCompletion(elicitationId: asked.id))
        let requested = try #require(outputs.first { SessionEventCase.elicitationRequested.matches($0.event) })
        let isRunMail = if case .mail = requested.origin { true } else { false }
        #expect(isRunMail, "the question has the origin \(requested.origin), not its run mail")
        #expect(completion.origin == requested.origin)
        return completion.position
    }

    /// Checks that `outputs` hold no ``SessionEvent/elicitationEnded(_:)``.
    ///
    /// - Parameter outputs: Outputs of a session.
    private static func expectNoEnd(in outputs: [SessionOutput]) {
        #expect(firstPosition(in: outputs, where: SessionEventCase.elicitationEnded.matches) == nil)
    }

    // MARK: - Tests

    /// The production change that makes this test fail: an outbox that drops
    /// the completion that the run plane posts.
    @Test("a completion through the session gives one event with the id and the origin of the question, and no end")
    func aCompletionThroughTheSessionGivesOneEvent() async throws {
        var asked = try await Self.ask(Self.urlRequest)

        let accepted = await asked.accept()
        let completed = await asked.fixture.session.complete(elicitationId: asked.id.description)
        try await asked.postings.waitForCompletions(Self.oneCompletion)
        let response = try await asked.answer.value
        let outputs = await asked.outputsToTheEnd()

        #expect(accepted == .acceptedAwaitingCompletion)
        #expect(completed == .completed)
        #expect(response.action == .accept)
        _ = try Self.soleCompletion(in: outputs, of: asked)
        Self.expectNoEnd(in: outputs)
    }

    /// The production change that makes this test fail: a session that sends
    /// the completion only for its own ``RoutedSession/complete(elicitationId:)``,
    /// or that keeps a question that the tool completed open, so close ends
    /// it with ``SessionEvent/elicitationEnded(_:)``.
    @Test("a completion through the tool that asked gives one event after the work start, and no end")
    func aCompletionThroughTheToolGivesOneEvent() async throws {
        var asked = try await Self.ask(Self.urlRequest)

        let accepted = await asked.accept()
        let completed = await asked.context.complete(elicitationId: asked.id)
        try await asked.postings.waitForCompletions(Self.oneCompletion)
        let response = try await asked.answer.value
        let outputs = await asked.outputsToTheEnd()

        #expect(accepted == .acceptedAwaitingCompletion)
        #expect(completed == .completed)
        #expect(response.action == .accept)
        let completion = try Self.soleCompletion(in: outputs, of: asked)
        #expect(try position(of: .workStarted, in: outputs) < completion)
        Self.expectNoEnd(in: outputs)
    }

    /// The production change that makes this test fail: a journal that sends
    /// one event for each completion post, with no record of the questions
    /// that completed.
    @Test("a second completion of the same question gives no second event")
    func aSecondCompletionGivesNoEvent() async throws {
        var asked = try await Self.ask(Self.urlRequest)

        _ = await asked.accept()
        _ = await asked.fixture.session.complete(elicitationId: asked.id.description)
        try await asked.postings.waitForCompletions(Self.oneCompletion)
        let second = await asked.fixture.session.complete(elicitationId: asked.id.description)
        await asked.postings.post(elicitationCompleted: asked.id)
        try await asked.postings.waitForCompletions(Self.twoCompletions)
        let outputs = await asked.outputsToTheEnd()

        #expect(second == .noPendingElicitation)
        _ = try Self.soleCompletion(in: outputs, of: asked)
    }

    /// The production change that makes this test fail: a journal that sends
    /// the completion for each recorded question, also for a form-mode
    /// question.
    @Test("a completion post for a form question gives no event")
    func aFormQuestionGivesNoEvent() async throws {
        var asked = try await Self.ask { PendingElicitationFixtures.formRequest(elicitationId: $0) }

        await asked.postings.post(elicitationCompleted: asked.id)
        try await asked.postings.waitForCompletions(Self.oneCompletion)
        let declined = await asked.fixture.session.respond(elicitationId: asked.id.description, response: .decline)
        let response = try await asked.answer.value
        let outputs = await asked.outputsToTheEnd()

        #expect(declined == .delivered)
        #expect(response.action == .decline)
        #expect(Self.completions(in: outputs).isEmpty)
    }

    /// The production change that makes this test fail: a run plane that
    /// resumes the run before the post of the completion ends, so the
    /// terminal of the resumed run can reach the sink of the run first.
    ///
    /// The run is a real background run of ``SessionWorkEventTests/AskingTool``,
    /// whose events go through the sink queue of its run. Its return gate is
    /// open, so the first event of the resumed run is its terminal
    /// (``SessionEvent/runSettled(_:)``).
    @Test("the completion comes before the first event of the resumed run")
    func theCompletionComesBeforeTheResumedRun() async throws {
        let askGate = RunLatch()
        let returnGate = RunLatch()
        await returnGate.open()
        let fixture = try await BackgroundingSessionFixture.make(
            prefix: Self.prefix,
            tools: [SessionWorkEventTests.AskingTool(asksForURL: true, askGate: askGate, returnGate: returnGate)])
        var feed = await fixture.session.streamSessionEvents().makeAsyncIterator()
        let asking = try await SessionWorkEventTests.outputsUpToTheQuestion(
            of: fixture, askGate: askGate, feed: &feed)
        let id = try #require(try firstQuestion(in: asking).elicitation).elicitationId

        let accepted = await fixture.session.respond(elicitationId: id.description, response: .accept(content: nil))
        let completed = await fixture.session.complete(elicitationId: id.description)
        let resumed = await SessionWorkEventTests.outputs(
            from: &feed, through: { SessionEventCase.runSettled.matches($0) })

        #expect(accepted == .acceptedAwaitingCompletion)
        #expect(completed == .completed)
        let completion = try position(ofFirst: .elicitationCompleted, in: resumed)
        #expect(resumed[completion].event == .elicitationCompleted(ElicitationCompletion(elicitationId: id)))
        #expect(completion < (try position(ofFirst: .runSettled, in: resumed)))
        await fixture.end(opening: [askGate, returnGate])
    }

    /// The production change that makes this test fail: a journal that sends
    /// the completion for each id that the run plane posts, also for a
    /// question that it never recorded.
    @Test("a completion post for an unknown id gives no event")
    func anUnknownIdGivesNoEvent() async throws {
        var asked = try await Self.ask(Self.urlRequest)

        await asked.postings.post(elicitationCompleted: ULID.generate())
        try await asked.postings.waitForCompletions(Self.oneCompletion)
        let outputs = await asked.outputsToTheEnd()

        #expect(Self.completions(in: outputs).isEmpty)
    }
}
