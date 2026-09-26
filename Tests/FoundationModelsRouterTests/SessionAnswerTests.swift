import Foundation
import FoundationModels
import FoundationModelsRouterTestSupport
import Synchronization
import Testing

@testable import FoundationModelsRouter

/// The ``SessionAnswer`` API: one call sends a message and gives the final
/// answer of its chain. The answer has the reply, the tools, the compactions,
/// and the usage, so a caller does not write the ``SessionEvent`` switch again.
///
/// The scripted scenario is a narrated call of two tools. The SDK keeps the
/// narration in a superseded `.response` entry at the tool boundary, so the
/// session sends a real ``SessionEvent/textReset``. The reply must still be
/// the final reply only: `SessionAnswer.reply` is equal to the return of
/// `respond(to:)`, character for character.
@Suite("SessionAnswer: one call sends a message and gives the final answer of its chain")
struct SessionAnswerTests {
    // MARK: - The scripted scenario

    /// The suite's temp-directory prefix, handed to
    /// ``RouterTestFixtures/makeTempDir(prefix:)``.
    private static let tempDirPrefix = "SessionAnswerTests"

    /// The model-facing name the scenario's first call names.
    private static let firstTool = "outcome-tool-a"

    /// The model-facing name the scenario's second call names.
    private static let secondTool = "outcome-tool-b"

    /// The prose the scripted model emits before its tool calls — the text the
    /// SDK strands in a superseded `.response` entry at the tool boundary, so
    /// the session sends a real ``SessionEvent/textReset``.
    private static let narration = "Let me look both of those up. "

    /// Builds a fresh session over the narrated two-call script, with a fresh
    /// pair of scenario tools mounted — fresh per run, because a session
    /// consumes its script and two runs must never read each other's log.
    ///
    /// - Returns: The fixture whose `directory` the caller must remove.
    /// - Throws: Whatever building the session throws.
    private static func makeFixture() async throws -> ScriptedSessionFixture {
        try await ScriptedSessionFixture.make(
            playing: ScriptedTurnScript(
                rounds: [
                    [
                        ScriptedToolCall(
                            id: "call-first", toolName: firstTool,
                            argument: .literal(ToolTurnScenario.firstStep)),
                        ScriptedToolCall(
                            id: "call-second", toolName: secondTool,
                            argument: .literal(ToolTurnScenario.secondStep)),
                    ]
                ],
                narration: narration),
            mounting: [MarkerEmittingTool(name: firstTool), MarkerEmittingTool(name: secondTool)],
            tempDirPrefix: tempDirPrefix)
    }

    /// The reply the scenario must produce, composed from the two markers
    /// only its tools could have supplied.
    private static var expectedAnswer: String {
        ScriptedToolFixture.answer(fromToolOutputs: ToolTurnScenario.markers)
    }

    // MARK: - The reply invariant (acceptance)

    @Test("the answer's reply is respond(to:)'s return, character for character")
    func answerReplyEqualsRespondForTheSameScriptedToolScript() async throws {
        let respondFixture = try await Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: respondFixture.directory) }
        let answerFixture = try await Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: answerFixture.directory) }

        let responded = try await respondFixture.session.respond(to: ScriptedToolFixture.prompt)
        let answer: SessionAnswer = try await answerFixture.session.respond(to: ScriptedToolFixture.prompt)

        #expect(responded == Self.expectedAnswer)
        #expect(
            answer.reply == responded,
            """
            the answer's reply is not the reply respond(to:) returned.
            answer:    \(answer.reply.debugDescription)
            responded: \(responded.debugDescription)
            """)
    }

    @Test("the plain respond(to:) call still resolves to the String overload")
    func plainRespondStillReturnsTheStringAnswer() async throws {
        let fixture = try await Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        // No type context and no observing argument: Swift must keep selecting
        // the original String-returning overload, so existing callers compile
        // and behave unchanged.
        let answer = try await fixture.session.respond(to: ScriptedToolFixture.prompt)

        #expect(answer == Self.expectedAnswer)
    }

    // MARK: - The observing callback

    @Test("the observing callback delivers every raw event live, reset not pre-applied")
    func observingDeliversTheRawEvents() async throws {
        let fixture = try await Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let observed = Mutex<[SessionEvent]>([])

        let answer = try await fixture.session.respond(to: ScriptedToolFixture.prompt) { event in
            observed.withLock { $0.append(event) }
        }

        // The callback saw the raw stream: every fragment the model produced,
        // superseded narration included, plus the reset itself — nothing was
        // pre-reduced on the way to the observer.
        let events = observed.withLock { $0 }
        let rawText = events.compactMap { event -> String? in
            guard case .textDelta(let fragment) = event else { return nil }
            return fragment
        }
        .joined()
        #expect(rawText == Self.narration + Self.expectedAnswer)
        #expect(events.contains(.textReset))
        // The answer's reply is the final reply only: the narration is not in it.
        #expect(answer.reply == Self.expectedAnswer)
        // The callback also saw the answer frame: the last event is the answer
        // that respond returned.
        #expect(events.last == .answered(answer))
    }

    // MARK: - Tools, both views

    @Test("the answer carries the diff's tool calls and one closed live record per run")
    func answerCarriesToolCallsAndInvocationRecords() async throws {
        let fixture = try await Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let outcome: SessionAnswer = try await fixture.session.respond(to: ScriptedToolFixture.prompt)

        // The diff-derived view: Apple's Transcript.ToolCall.id space.
        #expect(outcome.toolCalls.map(\.id) == ["call-first", "call-second"])
        #expect(outcome.toolCalls.map(\.name) == [Self.firstTool, Self.secondTool])
        #expect(outcome.toolCalls.map(\.status) == [.completed, .completed])
        #expect(outcome.toolCalls.map(\.summary) == ToolTurnScenario.markers)
        // The full output segments ride along too: each marker tool's output
        // entry carries one `.text` segment whose content is the marker.
        let outputTexts = outcome.toolCalls.map { call -> String? in
            guard let output = call.output, output.count == 1,
                case .text(_, let content) = output[0]
            else { return nil }
            return content
        }
        #expect(outputTexts == ToolTurnScenario.markers)

        // The live view: one record per run (the close record replaced the
        // open record), in the completionToken id space.
        #expect(outcome.toolInvocations.count == 2)
        #expect(outcome.toolInvocations.allSatisfy { $0.closedAt != nil })
        #expect(Set(outcome.toolInvocations.map(\.tool)) == [Self.firstTool, Self.secondTool])

        // The identity rule: neither id space is ever stamped into the other.
        let callIds = Set(outcome.toolCalls.map(\.id))
        #expect(outcome.toolInvocations.allSatisfy { !callIds.contains($0.correlationID) })

        // No budget was set on this session, so the chain compacted nothing.
        #expect(outcome.compactions.isEmpty)
    }

    // MARK: - The answer and the projection (acceptance)

    @Test("the answer's reply is what respond returns and is the projection's last text row for that answer")
    @MainActor
    func answerReplyEqualsRespondAndTheProjectionTextRow() async throws {
        let respondFixture = try await Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: respondFixture.directory) }
        let answerFixture = try await Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: answerFixture.directory) }
        let observed = Mutex<[SessionEvent]>([])

        let responded = try await respondFixture.session.respond(to: ScriptedToolFixture.prompt)
        let answer: SessionAnswer = try await answerFixture.session.respond(to: ScriptedToolFixture.prompt) {
            event in
            observed.withLock { $0.append(event) }
        }

        // The projection gets the same events that the answer came from.
        let projection = SessionProjection()
        for event in observed.withLock({ $0 }) {
            projection.apply(event)
        }

        // The projection keeps the superseded narration as its own closed
        // row, because its transcript is a faithful mirror. The last text row
        // is the final reply.
        let textRows = projection.transcript.compactMap { entry -> String? in
            guard case .text(let text) = entry.kind else { return nil }
            return text
        }
        #expect(textRows.first == Self.narration)

        // The answer does not reduce text: its reply is the final reply of the
        // chain. It is equal to what respond returns and to the last text row.
        #expect(answer.reply == responded)
        #expect(answer.reply == textRows.last)
    }

    @Test("the reset rule lives in ResponseTextReducer: a reset clears the reply and the next fragment starts a new response")
    func responseTextReducerAppliesTheResetRule() {
        var reducer = ResponseTextReducer()

        // `append` is mutating, so each call is hoisted out of `#expect`.
        let firstBeganNew = reducer.append("Draft ")
        let secondBeganNew = reducer.append("one.")
        #expect(!firstBeganNew)
        #expect(!secondBeganNew)
        #expect(reducer.reply == "Draft one.")

        reducer.reset()
        #expect(reducer.reply.isEmpty)

        let afterResetBeganNew = reducer.append("Final.")
        let continuationBeganNew = reducer.append(" Done.")
        #expect(afterResetBeganNew)
        #expect(!continuationBeganNew)
        #expect(reducer.reply == "Final. Done.")
    }

    // MARK: - The reducer's non-text accumulation

    /// The number of the second submission of the synthetic chain.
    private static let secondSubmissionNumber: UInt64 = 2

    /// The number of the third submission of the synthetic chain.
    private static let thirdSubmissionNumber: UInt64 = 3

    /// The usage of the first submission of the synthetic chain.
    private static let firstSubmissionUsage = TokenUsage(tokensIn: 10, tokensOut: 5, contextFill: 0.9)

    /// The usage of the last submission of the synthetic chain. Its finish
    /// reason is not the default, so the test sees which submission gives it.
    private static let lastSubmissionUsage = TokenUsage(
        tokensIn: 4, tokensOut: 2, contextFill: 0.4, finishReason: .maxTokens)

    /// The time the synthetic call opens, in seconds since 1970.
    private static let openedAtSeconds: TimeInterval = 100

    /// The time the synthetic call closes, in seconds since 1970.
    private static let closedAtSeconds: TimeInterval = 102

    /// The start event of the first submission of a synthetic chain.
    private static let firstSubmissionStarted = SessionEvent.submissionStarted(
        SubmissionStart(submissionId: SubmissionID(1), messageIds: [], cause: .message))

    @Test("the reducer sums the usage of the chain, keeps every compaction, and replaces an open invocation record with its close")
    func reducerSumsUsageAndKeepsCompactionsAndClosedInvocations() {
        var reducer = SessionAnswerReducer()
        let compacted = CompactionResult(
            summary: "compacted", tokensBefore: 1000, tokensAfter: 400, stagesApplied: ["ToolOutputElision"])
        let open = ToolInvocationRecord(
            tool: "search", op: "search", correlationID: "token-1", sessionID: .generate(),
            openedAt: Date(timeIntervalSince1970: Self.openedAtSeconds))
        let first = Self.firstSubmissionUsage
        let last = Self.lastSubmissionUsage

        reducer.apply(Self.firstSubmissionStarted)
        reducer.apply(.compaction(compacted))
        reducer.apply(.toolInvocation(open))
        reducer.apply(.toolInvocation(open.closed(at: Date(timeIntervalSince1970: Self.closedAtSeconds))))
        // A chain with three submissions. The second one has no usage, so it
        // adds nothing to the sum.
        reducer.apply(
            .submissionEnded(SubmissionEnd(submissionId: SubmissionID(1), usage: first, finishReason: .completed)))
        reducer.apply(
            .submissionEnded(
                SubmissionEnd(
                    submissionId: SubmissionID(Self.secondSubmissionNumber), usage: nil, finishReason: .completed)))
        reducer.apply(
            .submissionEnded(
                SubmissionEnd(
                    submissionId: SubmissionID(Self.thirdSubmissionNumber), usage: last,
                    finishReason: last.finishReason)))

        let answer = reducer.answer(reply: Self.expectedAnswer, messageIds: [])
        // The token counts are the sums. The fill and the finish reason come
        // from the last submission that had usage.
        #expect(
            answer.usage
                == TokenUsage(
                    tokensIn: first.tokensIn + last.tokensIn, tokensOut: first.tokensOut + last.tokensOut,
                    contextFill: last.contextFill, finishReason: last.finishReason))
        #expect(answer.contextFill == last.contextFill)
        #expect(answer.reply == Self.expectedAnswer)
        #expect(answer.messageIds.isEmpty)
        #expect(answer.compactions == [compacted])
        #expect(answer.toolInvocations.count == 1)
        #expect(answer.toolInvocations.first?.closedAt != nil)
        #expect(answer.toolInvocations.first?.correlationID == "token-1")
    }

    @Test("the reducer gives no usage when no submission of the chain had usage")
    func reducerGivesNoUsageWhenNoSubmissionHadUsage() {
        var reducer = SessionAnswerReducer()
        reducer.apply(Self.firstSubmissionStarted)
        reducer.apply(
            .submissionEnded(SubmissionEnd(submissionId: SubmissionID(1), usage: nil, finishReason: .completed)))

        let answer = reducer.answer(reply: Self.expectedAnswer, messageIds: [])

        #expect(answer.usage == nil)
        #expect(answer.contextFill == nil)
    }

    /// Reduces `events` in order and returns the answer.
    ///
    /// - Parameter events: The events of the chain, in stream order.
    /// - Returns: The reduced ``SessionAnswer``, with an empty reply and no
    ///   messages.
    private static func answer(of events: [SessionEvent]) -> SessionAnswer {
        var reducer = SessionAnswerReducer()
        for event in events {
            reducer.apply(event)
        }
        return reducer.answer(reply: "", messageIds: [])
    }

    /// The open record of the one call the live-driver-event tests reduce.
    private static let openRecord = ToolInvocationRecord(
        tool: "search", op: "search", correlationID: "token-1", sessionID: .generate(),
        openedAt: Date(timeIntervalSince1970: openedAtSeconds))

    /// Reduces one submission with one call two times — one time plain, one
    /// time with `event` between the call's close and the submission's end —
    /// and asserts that the two answers are the same.
    ///
    /// - Parameter event: The event the answer must not carry.
    private static func expectReducerIgnores(_ event: SessionEvent) {
        let open = openRecord
        let close = SessionEvent.toolInvocation(open.closed(at: Date(timeIntervalSince1970: closedAtSeconds)))
        let submissionEnded = SessionEvent.submissionEnded(
            SubmissionEnd(
                submissionId: SubmissionID(1), usage: lastSubmissionUsage,
                finishReason: lastSubmissionUsage.finishReason))
        let plainChain: [SessionEvent] = [firstSubmissionStarted, .toolInvocation(open), close, submissionEnded]
        let chainWithEvent: [SessionEvent] = [
            firstSubmissionStarted, .toolInvocation(open), close, event, submissionEnded,
        ]

        let answerWithEvent = answer(of: chainWithEvent)

        // The reducer saw the call: the comparison below is not between two empty answers.
        #expect(answerWithEvent.toolInvocations.count == 1)
        #expect(answerWithEvent == answer(of: plainChain))
    }

    @Test("the reducer does not carry a toolCallReport: the answer is the same with and without one")
    func reducerDoesNotCarryAToolCallReport() {
        let open = Self.openRecord
        Self.expectReducerIgnores(
            .toolCallReport(
                ToolCallReport(
                    tool: open.tool, op: open.op, correlationID: open.correlationID, sessionID: open.sessionID,
                    attachments: [MountFixtures.firstAttachment])))
    }

    @Test("the reducer does not carry an elicitationRequested: the answer is the same with and without one")
    func reducerDoesNotCarryAnElicitationRequested() {
        let open = Self.openRecord
        Self.expectReducerIgnores(
            .elicitationRequested(
                OperationEvent(
                    tool: open.tool, op: open.op, correlationID: open.correlationID, kind: .elicitation, detail: "",
                    elicitation: MountFixtures.proceedRequest())))
    }
}
