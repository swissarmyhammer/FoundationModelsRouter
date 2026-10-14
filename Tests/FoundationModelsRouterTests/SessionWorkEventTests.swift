import Foundation
import FoundationModels
import FoundationModelsRouterTestSupport
import Testing

@testable import FoundationModelsExtras
@testable import FoundationModelsRouter

/// Exercises task ^5kbfsyv: the work events of a session.
/// ``SessionEvent/workStarted`` comes when the session gets work while it had
/// none, and ``SessionEvent/workEnded`` comes when the session has no work any
/// more, by the rules of ``RoutedSession/awaitIdle()``. Both have the origin
/// ``Origin/system``, and both come in order with the other outputs of
/// ``RoutedSession/streamSessionEvents()``. A background run that waits only
/// for the user is no work.
///
/// Everything runs against the scripted ``BackgroundingBackend`` and real
/// background tools of the session, so the suite needs no network and no
/// GPU. The tests read the order of the outputs, not a clock.
@Suite("A session sends one event when its work starts and one when its work ends")
struct SessionWorkEventTests {
    // MARK: - Fixtures

    /// A background tool whose run asks the user one question through
    /// `ToolContext.elicit(_:)`, and then returns. The run is open while the
    /// question is open, and it waits only for the user.
    struct AskingTool: Tool, BackgroundTool {
        let name = "asking_job"
        let description = "test-only background tool whose run asks the user one question"

        /// Whether the question is a URL-mode question. Else it is a
        /// form-mode question.
        let asksForURL: Bool

        var mount: ToolMount? {
            ToolMount(mode: .background, timeout: nil)
        }

        /// No wait: each call answers with its pending envelope at once.
        var inlineSettleGrace: TimeInterval { 0 }

        func call(arguments: BackgroundFixtureArguments) async throws -> String {
            guard let context = ToolContext.current else { return SessionWorkEventTests.noContextOutput }
            let request =
                asksForURL
                ? ElicitationRequest(
                    message: "Open the page", elicitationId: ULID.generate(), url: SessionWorkEventTests.approvalURL)
                : MountFixtures.proceedRequest()
            let response = try await context.elicit(request)
            return "answered: \(response.action.rawValue)"
        }
    }

    // MARK: - Constants

    /// The output of a latched background run.
    private static let runOutput = "the job is done"

    /// The output of ``AskingTool`` when no tool context is bound. A test
    /// never sees it.
    static let noContextOutput = "no context"

    /// The page of the URL-mode question of ``AskingTool``.
    static let approvalURL = URL(filePath: "/approve")

    /// The prompt of each caller message.
    private static let jobPrompt = "run the job"

    /// The answers of one caller message that starts a run whose terminal
    /// starts one more answer.
    private static let answersWithAMailAnswer = 2

    /// The work events of two pieces of work, one after the other.
    private static let twoChanges: [SessionEvent] = [.workStarted, .workEnded, .workStarted, .workEnded]

    // MARK: - Helpers

    /// Makes a session with `tools` over a ``BackgroundingBackend``.
    ///
    /// - Parameter tools: The tools of the session.
    /// - Returns: The fixture.
    /// - Throws: What the resolve of the profile throws.
    private static func makeFixture(tools: [any Tool]) async throws -> BackgroundingSessionFixture {
        try await BackgroundingSessionFixture.make(prefix: "SessionWorkEventTests", tools: tools)
    }

    /// Reads `feed` up to and including the next ``SessionEvent/workEnded``.
    ///
    /// - Parameter feed: The iterator of a feed of the session.
    /// - Returns: Each output read, in order. The last output is the work-end
    ///   event, unless the feed finished first.
    private static func outputs(
        throughNextWorkEnd feed: inout AsyncStream<SessionOutput>.Iterator
    ) async -> [SessionOutput] {
        var read: [SessionOutput] = []
        while let output = await feed.next() {
            read.append(output)
            if output.event == .workEnded {
                break
            }
        }
        return read
    }

    /// Reads `feed` until it finishes. ``RoutedSession/close()`` finishes it.
    ///
    /// - Parameter feed: The iterator of a feed of the session.
    /// - Returns: Each output read, in order.
    private static func remainingOutputs(of feed: inout AsyncStream<SessionOutput>.Iterator) async -> [SessionOutput] {
        var read: [SessionOutput] = []
        while let output = await feed.next() {
            read.append(output)
        }
        return read
    }

    /// The work events of `outputs`, in order.
    ///
    /// - Parameter outputs: Outputs of a session.
    /// - Returns: Each ``SessionEvent/workStarted`` and
    ///   ``SessionEvent/workEnded`` event.
    private static func workEvents(of outputs: [SessionOutput]) -> [SessionEvent] {
        outputs.map(\.event).filter { $0 == .workStarted || $0 == .workEnded }
    }

    /// The position of the first output of `outputs` whose event `matches`.
    ///
    /// - Parameters:
    ///   - outputs: Outputs of a session.
    ///   - matches: The test of an event.
    /// - Returns: The position.
    /// - Throws: When no event of `outputs` matches.
    private static func position(
        in outputs: [SessionOutput], of matches: (SessionEvent) -> Bool
    ) throws -> Int {
        try #require(outputs.firstIndex { matches($0.event) })
    }

    /// The id of the question in the first ``SessionEvent/elicitationRequested(_:)``
    /// of `outputs`.
    ///
    /// - Parameter outputs: Outputs of a session.
    /// - Returns: The id, in the string form that
    ///   ``RoutedSession/respond(elicitationId:response:)`` takes.
    /// - Throws: When `outputs` holds no question.
    private static func questionId(in outputs: [SessionOutput]) throws -> String {
        let request = outputs.lazy.compactMap { output -> ElicitationRequest? in
            guard case .elicitationRequested(let event) = output.event else { return nil }
            return event.elicitation
        }.first
        return try #require(request).elicitationId.description
    }

    /// The session of `fixture` as its one concrete type.
    ///
    /// - Parameter fixture: The fixture.
    /// - Returns: The session actor.
    /// - Throws: When the session is not a ``RoutedSessionActor``.
    private static func actor(of fixture: BackgroundingSessionFixture) throws -> RoutedSessionActor {
        try #require(fixture.session as? RoutedSessionActor)
    }

    // MARK: - Tests

    @Test("a prompt gives the work-start event before the first output of its answer, and the work-end event after its answer")
    func aPromptGivesBothEventsAroundItsAnswer() async throws {
        let fixture = try await Self.makeFixture(tools: [])
        var feed = await fixture.session.streamSessionEvents().makeAsyncIterator()

        _ = try await fixture.session.respond(to: Self.jobPrompt)
        let outputs = await Self.outputs(throughNextWorkEnd: &feed)

        #expect(outputs.first == SessionOutput(origin: .system, event: .workStarted))
        #expect(outputs.last == SessionOutput(origin: .system, event: .workEnded))
        let answered = try Self.position(in: outputs) { if case .answered = $0 { true } else { false } }
        #expect(answered == outputs.count - 2)
        await fixture.end()
    }

    @Test("the work-end event comes after the outputs of a background run and of the answer that its terminal starts")
    func theWorkEndComesAfterTheRunOutputs() async throws {
        let gate = RunLatch()
        let fixture = try await Self.makeFixture(
            tools: [LatchedBackgroundToolRunner(name: "pending_job", gate: gate, output: Self.runOutput)])
        var feed = await fixture.session.streamSessionEvents().makeAsyncIterator()

        _ = try await fixture.session.respond(to: Self.jobPrompt)
        await gate.open()
        let outputs = await Self.outputs(throughNextWorkEnd: &feed)

        #expect(Self.workEvents(of: outputs) == [.workStarted, .workEnded])
        let settled = try Self.position(in: outputs) { if case .runSettled = $0 { true } else { false } }
        #expect(settled < outputs.count - 1)
        let answers = outputs.filter { if case .answered = $0.event { true } else { false } }
        #expect(answers.count == Self.answersWithAMailAnswer)
        await fixture.end()
    }

    @Test("each change of the work gives one event: two prompts one after the other give two pairs, and close gives none")
    func eachChangeGivesOneEvent() async throws {
        let fixture = try await Self.makeFixture(tools: [])
        var feed = await fixture.session.streamSessionEvents().makeAsyncIterator()

        _ = try await fixture.session.respond(to: Self.jobPrompt)
        let first = await Self.outputs(throughNextWorkEnd: &feed)
        _ = try await fixture.session.respond(to: Self.jobPrompt)
        let second = await Self.outputs(throughNextWorkEnd: &feed)
        await fixture.session.close()
        let rest = await Self.remainingOutputs(of: &feed)

        let outputs = first + second + rest
        #expect(Self.workEvents(of: outputs) == Self.twoChanges)
        #expect(outputs.filter { Self.workEvents(of: [$0]).count == 1 }.allSatisfy { $0.origin == .system })
        await fixture.end()
    }

    @Test("a requested compaction is work: its events come between the work-start and the work-end events")
    func aRequestedCompactionIsWork() async throws {
        let fixture = try await Self.makeFixture(tools: [])
        var feed = await fixture.session.streamSessionEvents().makeAsyncIterator()

        fixture.session.compact(prompt: .default, budget: nil)
        let outputs = await Self.outputs(throughNextWorkEnd: &feed)

        #expect(outputs.first?.event == .workStarted)
        #expect(Self.workEvents(of: outputs) == [.workStarted, .workEnded])
        let started = try Self.position(in: outputs) { if case .compactionStarted = $0 { true } else { false } }
        #expect(started > 0)
        let ended = try Self.position(in: outputs) {
            switch $0 {
            case .compaction, .compactionFailed: true
            default: false
            }
        }
        #expect(ended < outputs.count - 1)
        await fixture.end()
    }

    @Test("a run that waits only for the user gives the work-end event, and isIdle() says idle while a pending operation stays")
    func aRunThatWaitsOnlyForTheUserIsNoWork() async throws {
        let fixture = try await Self.makeFixture(tools: [AskingTool(asksForURL: false)])
        let session = try Self.actor(of: fixture)
        var feed = await fixture.session.streamSessionEvents().makeAsyncIterator()

        _ = try await fixture.session.respond(to: Self.jobPrompt)
        let outputs = await Self.outputs(throughNextWorkEnd: &feed)

        let asked = try Self.position(in: outputs) { if case .elicitationRequested = $0 { true } else { false } }
        #expect(asked < outputs.count - 1)
        #expect(Self.workEvents(of: outputs) == [.workStarted, .workEnded])
        #expect(await session.runPlane.runsWaitingOnlyForUser().count == 1)
        #expect(await session.isIdle())
        #expect(await session.hasPendingOperation())
        #expect(await fixture.session.awaitIdle())
        await fixture.end()
    }

    @Test("an answer to the question of a run that waits only for the user gives the work-start event before each output of the resumed run")
    func anAnswerStartsWorkBeforeTheResumedRun() async throws {
        let fixture = try await Self.makeFixture(tools: [AskingTool(asksForURL: false)])
        var feed = await fixture.session.streamSessionEvents().makeAsyncIterator()
        _ = try await fixture.session.respond(to: Self.jobPrompt)
        let asking = await Self.outputs(throughNextWorkEnd: &feed)

        let delivery = await fixture.session.respond(
            elicitationId: try Self.questionId(in: asking), response: .decline)
        let resumed = await Self.outputs(throughNextWorkEnd: &feed)

        #expect(delivery == .delivered)
        #expect(resumed.first == SessionOutput(origin: .system, event: .workStarted))
        #expect(Self.workEvents(of: resumed) == [.workStarted, .workEnded])
        let settled = try Self.position(in: resumed) { if case .runSettled = $0 { true } else { false } }
        #expect(settled < resumed.count - 1)
        await fixture.end()
    }

    @Test("an accept of a URL question gives no work event, and its completion starts the work of the resumed run")
    func aURLAcceptIsNoWorkAndItsCompletionIs() async throws {
        let fixture = try await Self.makeFixture(tools: [AskingTool(asksForURL: true)])
        var feed = await fixture.session.streamSessionEvents().makeAsyncIterator()
        _ = try await fixture.session.respond(to: Self.jobPrompt)
        let asking = await Self.outputs(throughNextWorkEnd: &feed)
        let questionId = try Self.questionId(in: asking)

        let accepted = await fixture.session.respond(elicitationId: questionId, response: .accept(content: nil))
        let completed = await fixture.session.complete(elicitationId: questionId)
        let resumed = await Self.outputs(throughNextWorkEnd: &feed)

        #expect(accepted == .acceptedAwaitingCompletion)
        #expect(completed == .completed)
        #expect(resumed.first == SessionOutput(origin: .system, event: .workStarted))
        #expect(Self.workEvents(of: resumed) == [.workStarted, .workEnded])
        let settled = try Self.position(in: resumed) { if case .runSettled = $0 { true } else { false } }
        #expect(settled < resumed.count - 1)
        await fixture.end()
    }
}
