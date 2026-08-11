import Foundation
import FoundationModels
import FoundationModelsRouterTestSupport
import Testing

@testable import FoundationModelsRouter

/// Task ^w8dzvee: the deterministic, GPU-free half of the four-way tool-turn
/// comparison.
///
/// One scenario — a turn asking for **two** tool calls at once, so a mis-keyed
/// completion is visible where one call would hide it — run through both
/// `RoutedSession` surfaces over a scripted model, and compared as whole
/// normalized transcripts. The gated `RealToolTurnComparisonTests` runs the
/// same scenario against a real model and compares its outcome to this one.
///
/// **This drives the production backend.** `ScriptedToolCallingContainer` vends
/// `MLXFoundationModelsSessionBackend` itself, so the real `pumpStream` and the
/// real `respond` are what a scripted turn runs through. The suite that shipped
/// alongside defects D1 and D2 used a hand-written stand-in backend carrying its
/// own copy of the snapshot conversion, which is why neither defect was visible
/// from a green run.
@Suite("A scripted tool-using turn behaves identically on both session surfaces")
struct ScriptedToolTurnComparisonTests {
    /// The suite's temp-directory prefix, handed to
    /// ``RouterTestFixtures/makeTempDir(prefix:)``.
    private static let tempDirPrefix = "ScriptedToolTurnComparisonTests"

    /// The model-facing name the scenario's first call names.
    private static let firstTool = "scenario-tool-a"

    /// The model-facing name the scenario's second call names.
    private static let secondTool = "scenario-tool-b"

    /// The prose the narrated variant emits before its tool calls — the text
    /// the SDK strands in a superseded `.response` entry at the tool boundary,
    /// and that defect D2 appended to the answer.
    private static let narration = "Let me look both of those up. "

    /// The scenario: one round asking for two independent calls at once.
    ///
    /// - Parameter narration: Prose to emit before the calls, or `nil` for the
    ///   shape `MLXLanguageModel`'s own executor produces (a call, no prose).
    /// - Returns: The script to play out.
    private static func script(narration: String? = nil) -> ScriptedTurnScript {
        ScriptedTurnScript(
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
            narration: narration)
    }

    /// A fresh pair of scenario tools, so two runs never read each other's log.
    ///
    /// - Returns: The tools to mount, in call order.
    private static func makeTools() -> [any Tool] {
        [MarkerEmittingTool(name: firstTool), MarkerEmittingTool(name: secondTool)]
    }

    /// Runs the scenario once through `respond(to:)`.
    ///
    /// The whole-response surface derives no ``SessionEvent``s at all, so its
    /// outcome carries no call ids — an asymmetry of the surfaces themselves,
    /// not of this harness.
    ///
    /// - Parameter narration: Prose the model emits before its calls, or `nil`.
    /// - Returns: The run's answer and normalized transcript.
    /// - Throws: Whatever building or driving the session throws.
    private static func respondRun(narration: String? = nil) async throws -> ToolTurnRunOutcome {
        let fixture = try await ScriptedSessionFixture.make(
            playing: script(narration: narration),
            mounting: makeTools(),
            tempDirPrefix: tempDirPrefix)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let answer = try await fixture.session.respond(to: ScriptedToolFixture.prompt)
        return ToolTurnRunOutcome(
            answer: answer,
            calledIds: [],
            completedIds: [],
            failedIds: [],
            entries: fixture.transcriptEntries())
    }

    /// Runs the scenario once through `streamEvents(to:)`, accumulating the
    /// text twice — once applying ``SessionEvent/textReset`` and once ignoring
    /// it — plus every tool id the turn reported.
    ///
    /// - Parameter narration: Prose the model emits before its calls, or `nil`.
    /// - Returns: The run's answer, ids, and normalized transcript.
    /// - Throws: Whatever building or driving the session throws.
    private static func streamRun(narration: String? = nil) async throws -> ToolTurnRunOutcome {
        let fixture = try await ScriptedSessionFixture.make(
            playing: script(narration: narration),
            mounting: makeTools(),
            tempDirPrefix: tempDirPrefix)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        var answer = ""
        var rawAnswer = ""
        var calledIds: [String] = []
        var completedIds: [String] = []
        var failedIds: [String] = []
        for try await event in await fixture.session.streamEvents(to: ScriptedToolFixture.prompt) {
            switch event {
            case .textDelta(let delta):
                answer += delta
                rawAnswer += delta
            case .textReset:
                answer = ""
            case .toolCall(let id, _, _):
                calledIds.append(id)
            case .toolStatus(let id, .completed, _):
                completedIds.append(id)
            case .toolStatus(let id, .failed, _):
                failedIds.append(id)
            case .toolStatus, .reasoningDelta, .compaction, .discoveryPrimingFailed, .turnEnded:
                break
            }
        }
        return ToolTurnRunOutcome(
            answer: answer,
            rawAnswer: rawAnswer,
            calledIds: calledIds,
            completedIds: completedIds,
            failedIds: failedIds,
            entries: fixture.transcriptEntries())
    }

    /// The answer the scenario's turn must produce, composed from the two
    /// markers only its tools could have supplied.
    private static var expectedAnswer: String {
        ScriptedToolFixture.answerPrefix
            + ToolTurnScenario.markers.joined(separator: ScriptedToolFixture.answerSeparator)
    }

    @Test("both surfaces produce the same transcript, with no prose before the calls")
    func surfacesAgreeOnTranscript() async throws {
        let responded = try await Self.respondRun()
        let streamed = try await Self.streamRun()

        #expect(
            responded.transcript == streamed.transcript,
            """
            the surfaces produced different transcripts.
            respond(to:):
            \(responded.transcriptDescription)
            streamEvents(to:):
            \(streamed.transcriptDescription)
            """)
        #expect(responded.answer == Self.expectedAnswer)
        #expect(streamed.answer == Self.expectedAnswer)
    }

    @Test("both surfaces produce the same transcript across a narrated tool boundary")
    func surfacesAgreeOnTranscriptWithNarration() async throws {
        let responded = try await Self.respondRun(narration: Self.narration)
        let streamed = try await Self.streamRun(narration: Self.narration)

        #expect(
            responded.transcript == streamed.transcript,
            """
            the surfaces produced different transcripts.
            respond(to:):
            \(responded.transcriptDescription)
            streamEvents(to:):
            \(streamed.transcriptDescription)
            """)
    }

    @Test("the transcript of a two-call turn has the entry kinds a tool turn must have")
    func transcriptCarriesToolCallsAndToolOutputs() async throws {
        let kinds = try await Self.streamRun().transcript.map(\.kind)

        #expect(
            kinds == [.instructions, .prompt, .toolCalls, .toolOutput, .toolOutput, .response],
            "unexpected transcript shape: \(kinds.map(\.rawValue))")
    }

    @Test("every completed tool status names a call the turn announced")
    func completedStatusIdsMatchCalledIds() async throws {
        let outcome = try await Self.streamRun()

        #expect(outcome.calledIds.count == 2, "the scenario asks for two calls in one turn")
        #expect(Set(outcome.completedIds) == Set(outcome.calledIds))
        #expect(outcome.completedIds.count == outcome.calledIds.count)
        #expect(outcome.failedIds.isEmpty)
    }

    @Test("the streamed answer is the answer respond(to:) returns, character for character")
    func streamedAnswerEqualsRespondedAnswer() async throws {
        let responded = try await Self.respondRun(narration: Self.narration)
        let streamed = try await Self.streamRun(narration: Self.narration)

        #expect(responded.answer == Self.expectedAnswer)
        #expect(
            streamed.answer == responded.answer,
            """
            the streamed answer is not the answer respond(to:) returned.
            streamed:  \(streamed.answer.debugDescription)
            responded: \(responded.answer.debugDescription)
            """)
    }

    @Test("superseded pre-tool text is still delivered, and is no longer the answer")
    func supersededTextIsDeliveredButNotTheAnswer() async throws {
        let streamed = try await Self.streamRun(narration: Self.narration)

        #expect(
            streamed.rawAnswer == Self.narration + Self.expectedAnswer,
            """
            a consumer that ignores the reset must still receive every fragment
            the model produced, superseded prose included.
            raw: \(streamed.rawAnswer.debugDescription)
            """)
        #expect(
            !streamed.answer.contains(Self.narration),
            "the narration is not part of the answer once the reset is applied")
    }
}
