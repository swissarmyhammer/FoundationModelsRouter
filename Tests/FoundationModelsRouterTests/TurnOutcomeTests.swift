import Foundation
import FoundationModels
import FoundationModelsRouterTestSupport
import Synchronization
import Testing

@testable import FoundationModelsRouter

/// Task ^1s8p8qt: the turn-outcome API owns the event fold, so a caller gets
/// the reply text plus tools, folds, and usage from one call instead of
/// re-implementing the ``SessionEvent`` switch — including the subtle
/// ``SessionEvent/textReset`` accumulation rule.
///
/// The scripted scenario is a narrated two-call turn: the narration is prose
/// the SDK strands in a superseded `.response` entry at the tool boundary, so
/// the turn emits a real ``SessionEvent/textReset`` and the reply invariant
/// (`TurnOutcome.reply` equals `respond(to:)`'s return, character for
/// character) is only reachable by actually applying the rule.
@Suite("TurnOutcome: one call drives a turn and owns the event fold")
struct TurnOutcomeTests {
    // MARK: - The scripted scenario

    /// The suite's temp-directory prefix, handed to
    /// ``RouterTestFixtures/makeTempDir(prefix:)``.
    private static let tempDirPrefix = "TurnOutcomeTests"

    /// The model-facing name the scenario's first call names.
    private static let firstTool = "outcome-tool-a"

    /// The model-facing name the scenario's second call names.
    private static let secondTool = "outcome-tool-b"

    /// The prose the scripted model emits before its tool calls — the text the
    /// SDK strands in a superseded `.response` entry at the tool boundary, so
    /// the turn emits a real ``SessionEvent/textReset``.
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

    /// The answer the scenario's turn must produce, composed from the two
    /// markers only its tools could have supplied.
    private static var expectedAnswer: String {
        ScriptedToolFixture.answer(fromToolOutputs: ToolTurnScenario.markers)
    }

    // MARK: - The reply invariant (acceptance)

    @Test("the outcome's reply is respond(to:)'s return, character for character")
    func outcomeReplyEqualsRespondForTheSameScriptedToolUsingTurn() async throws {
        let respondFixture = try await Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: respondFixture.directory) }
        let outcomeFixture = try await Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: outcomeFixture.directory) }

        let responded = try await respondFixture.session.respond(to: ScriptedToolFixture.prompt)
        let outcome: TurnOutcome = try await outcomeFixture.session.respond(to: ScriptedToolFixture.prompt)

        #expect(responded == Self.expectedAnswer)
        #expect(
            outcome.reply == responded,
            """
            the outcome's reply is not the answer respond(to:) returned.
            outcome:   \(outcome.reply.debugDescription)
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

        let outcome = try await fixture.session.respond(to: ScriptedToolFixture.prompt) { event in
            observed.withLock { $0.append(event) }
        }

        // The callback saw the raw stream: every fragment the model produced,
        // superseded narration included, plus the reset itself — nothing was
        // pre-folded on the way to the observer.
        let events = observed.withLock { $0 }
        let rawText = events.compactMap { event -> String? in
            guard case .textDelta(let fragment) = event else { return nil }
            return fragment
        }
        .joined()
        #expect(rawText == Self.narration + Self.expectedAnswer)
        #expect(events.contains(.textReset))
        // While the outcome's reply has the reset applied.
        #expect(outcome.reply == Self.expectedAnswer)
    }

    // MARK: - Tools, both views

    @Test("the outcome carries the diff's tool calls and one closed live record per run")
    func outcomeCarriesToolCallsAndInvocationRecords() async throws {
        let fixture = try await Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let outcome: TurnOutcome = try await fixture.session.respond(to: ScriptedToolFixture.prompt)

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

        // No budget was set on this session, so the turn folded nothing.
        #expect(outcome.compactions.isEmpty)
    }

    // MARK: - The shared reducer (acceptance)

    /// The synthetic event shape of one narrated tool-using turn: a superseded
    /// draft, a reset, then the answer — the sequence both reducers must fold
    /// the same way.
    private static var narratedTurnEvents: [SessionEvent] {
        [
            .turnStarted(TurnStart(turnId: TurnID(1), promptId: nil)),
            .textDelta("Looking those "),
            .textDelta("up. "),
            .textReset,
            .textDelta("The answer "),
            .textDelta("is 4."),
            .turnEnded(TokenUsage(tokensIn: 3, tokensOut: 5, contextFill: 0.42)),
        ]
    }

    @Test("SessionProjection and TurnOutcome produce their text from the same shared reducer")
    @MainActor
    func projectionAndOutcomeAgreeOnTheReplyText() {
        let projection = SessionProjection()
        var fold = TurnOutcomeFold()
        for event in Self.narratedTurnEvents {
            projection.apply(event)
            fold.apply(event)
        }

        // The projection keeps the superseded draft as its own closed row —
        // its transcript is a faithful mirror — while the last text row is
        // the reply the reset rule leaves standing.
        let textRows = projection.transcript.compactMap { entry -> String? in
            guard case .text(let text) = entry.kind else { return nil }
            return text
        }
        #expect(textRows == ["Looking those up. ", "The answer is 4."])

        // The outcome's reply is that same last row: both consumers fold
        // their text through ``ResponseTextFold``, so they cannot drift.
        #expect(fold.outcome.reply == textRows.last)
    }

    @Test("the reset rule lives in ResponseTextFold: a reset clears the reply and the next fragment starts a new response")
    func responseTextFoldAppliesTheResetRule() {
        var fold = ResponseTextFold()

        // `append` is mutating, so each call is hoisted out of `#expect`.
        let firstBeganNew = fold.append("Draft ")
        let secondBeganNew = fold.append("one.")
        #expect(!firstBeganNew)
        #expect(!secondBeganNew)
        #expect(fold.reply == "Draft one.")

        fold.reset()
        #expect(fold.reply.isEmpty)

        let afterResetBeganNew = fold.append("Final.")
        let continuationBeganNew = fold.append(" Done.")
        #expect(afterResetBeganNew)
        #expect(!continuationBeganNew)
        #expect(fold.reply == "Final. Done.")
    }

    // MARK: - The fold's non-text accumulation

    @Test("the fold keeps the last usage, every compaction, and replaces an open invocation record with its close")
    func foldKeepsUsageCompactionsAndClosedInvocations() {
        var fold = TurnOutcomeFold()
        let folded = CompactionResult(
            summary: "folded", tokensBefore: 1000, tokensAfter: 400, stagesApplied: ["ToolOutputElision"])
        let open = ToolInvocationRecord(
            tool: "search", op: "search", correlationID: "token-1", sessionID: .generate(),
            openedAt: Date(timeIntervalSince1970: 100))

        fold.apply(.turnStarted(TurnStart(turnId: TurnID(1), promptId: nil)))
        fold.apply(.compaction(folded))
        fold.apply(.toolInvocation(open))
        fold.apply(.toolInvocation(open.closed(at: Date(timeIntervalSince1970: 102))))
        // A retried turn closes two attempts; the outcome keeps the last one.
        fold.apply(.turnEnded(TokenUsage(tokensIn: 10, tokensOut: 5, contextFill: 0.9)))
        fold.apply(.turnEnded(TokenUsage(tokensIn: 4, tokensOut: 2, contextFill: 0.4)))

        let outcome = fold.outcome
        #expect(outcome.usage == TokenUsage(tokensIn: 4, tokensOut: 2, contextFill: 0.4))
        #expect(outcome.contextFill == 0.4)
        #expect(outcome.compactions == [folded])
        #expect(outcome.toolInvocations.count == 1)
        #expect(outcome.toolInvocations.first?.closedAt != nil)
        #expect(outcome.toolInvocations.first?.correlationID == "token-1")
    }

    /// Folds `events` in order and returns the outcome.
    ///
    /// - Parameter events: The turn's events, in stream order.
    /// - Returns: The folded ``TurnOutcome``.
    private static func outcome(of events: [SessionEvent]) -> TurnOutcome {
        var fold = TurnOutcomeFold()
        for event in events {
            fold.apply(event)
        }
        return fold.outcome
    }

    /// The open record of the one call the live-driver-event tests fold.
    private static let openRecord = ToolInvocationRecord(
        tool: "search", op: "search", correlationID: "token-1", sessionID: .generate(),
        openedAt: Date(timeIntervalSince1970: 100))

    /// Folds one turn with one call twice — once plain, once with `event`
    /// between the call's close and the turn's end — and asserts the two
    /// outcomes are the same.
    ///
    /// - Parameter event: The event the outcome must not carry.
    private static func expectFoldIgnores(_ event: SessionEvent) {
        let open = openRecord
        let turnStarted = SessionEvent.turnStarted(TurnStart(turnId: TurnID(1), promptId: nil))
        let close = SessionEvent.toolInvocation(open.closed(at: Date(timeIntervalSince1970: 102)))
        let turnEnded = SessionEvent.turnEnded(TokenUsage(tokensIn: 4, tokensOut: 2, contextFill: 0.4))
        let plainTurn: [SessionEvent] = [turnStarted, .toolInvocation(open), close, turnEnded]
        let turnWithEvent: [SessionEvent] = [turnStarted, .toolInvocation(open), close, event, turnEnded]

        let outcomeWithEvent = outcome(of: turnWithEvent)

        // The fold saw the call: the comparison below is not between two empty outcomes.
        #expect(outcomeWithEvent.toolInvocations.count == 1)
        #expect(outcomeWithEvent == outcome(of: plainTurn))
    }

    @Test("the fold does not carry a toolCallReport: the outcome is the same with and without one")
    func foldDoesNotCarryAToolCallReport() {
        let open = Self.openRecord
        Self.expectFoldIgnores(
            .toolCallReport(
                ToolCallReport(
                    tool: open.tool, op: open.op, correlationID: open.correlationID, sessionID: open.sessionID,
                    attachments: [MountFixtures.firstAttachment])))
    }

    @Test("the fold does not carry an elicitationRequested: the outcome is the same with and without one")
    func foldDoesNotCarryAnElicitationRequested() {
        let open = Self.openRecord
        Self.expectFoldIgnores(
            .elicitationRequested(
                OperationEvent(
                    tool: open.tool, op: open.op, correlationID: open.correlationID, kind: .elicitation, detail: "",
                    elicitation: MountFixtures.proceedRequest())))
    }
}
