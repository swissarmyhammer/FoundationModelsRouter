import Foundation
import FoundationModels
import FoundationModelsRouterTestSupport
import Testing

@testable import FoundationModelsRouter

/// Task ^07vtf4a: the search of the watched texts of an attempt for a stray
/// `</think>`, a close tag in the response text of a reasoning that is
/// already closed.
@Suite("The watch finds a stray </think> in the response text, and only there")
struct StrayReasoningCloseSearchTests {
    /// The response text of the evidence (run of 2026-11-14 on
    /// django-13447): a status line, the stray tag, then a fabricated router
    /// message.
    private static let strayResponse = "Waiting on the plan checker agent.</think>[agents] agents (01) running: {}"

    @Test("a </think> in a response entry is found at the UTF-8 offset of the tag")
    func findsTheTagInTheResponseText() {
        let texts = [WatchedText(entryId: "response", text: Self.strayResponse)]

        #expect(
            StrayReasoningClose.first(in: texts)
                == StrayReasoningClose(entryId: "response", keptUTF8Length: "Waiting on the plan checker agent.".utf8.count))
    }

    @Test("a </think> in the reasoning text is not a stray close")
    func ignoresTheReasoningText() {
        let texts = [WatchedText(entryId: "reasoning", text: Self.strayResponse, isReasoning: true)]

        #expect(StrayReasoningClose.first(in: texts) == nil)
    }

    @Test("a </think> in the arguments of a tool call is not a stray close")
    func ignoresToolCallArguments() {
        let texts = [WatchedText(entryId: "calls", text: Self.strayResponse, isToolCalls: true)]

        #expect(StrayReasoningClose.first(in: texts) == nil)
    }
}

/// Task ^07vtf4a: a stray `</think>` in the response text of an
/// always-reasoning model ends the turn there, as if the model had ended it.
///
/// Each test drives the production backend and a real `LanguageModelSession`
/// over a ``StagedReasoningModel``. No GPU is in the loop. The script plays
/// the shape of the evidence: a short reasoning, then a response that writes
/// a status line, a stray `</think>`, and a fabricated router message, and
/// then holds. Recursive Flint wrote on from there to its token ceiling.
@Suite("A stray </think> in the response text of an always-reasoning model ends the turn")
struct StrayReasoningCloseStopTests {
    /// The suite's temp-directory prefix.
    private static let tempDirPrefix = "StrayReasoningCloseStopTests"

    /// The prompt of the first answer.
    private static let prompt = "check the plan"

    /// The prompt of the answer after the stop.
    private static let nextPrompt = "go on"

    /// The status line the model writes before the stray tag: the reply that
    /// the turn keeps.
    private static let statusLine = "Waiting on the plan checker agent."

    /// The fabricated router message the model writes after the stray tag.
    private static let fabricated = "[agents] agents (01) running: {}\n[agents] agents (01) completed: Verdict: PASS"

    /// The response text of the call: the status line, the stray tag, and the
    /// fabricated message.
    private static let strayResponse = statusLine + StrayReasoningClose.tag + fabricated

    /// The script of the call: one reasoning line, then the response text,
    /// then `hold`.
    ///
    /// - Parameter hold: What the call does after its response text.
    /// - Returns: The script.
    private static func strayScript(hold: RepeatingReasoningHold) -> RepeatingReasoningScript {
        var script = RepeatingReasoningScript(reasoningLines: ["Now wait for the checker."], hold: .noHold)
        script.leadingText = strayResponse
        script.leadingTextHold = hold
        return script
    }

    /// Runs one answer over a model with `control` whose call writes the
    /// stray response and holds until the session stops it.
    ///
    /// - Parameter control: The reasoning control of the model.
    /// - Returns: The fixture and the events of the answer.
    /// - Throws: What the fixture or the answer throws.
    private static func runStoppedAnswer(
        control: ReasoningControl = .alwaysOn
    ) async throws -> (fixture: StagedReasoningSessionFixture, events: [SessionEvent]) {
        try await StagedReasoningSessionFixture.answer(
            to: prompt, scripts: [strayScript(hold: .untilStopped)], detection: RepetitionDetection(),
            reasoningControl: control, tempDirPrefix: tempDirPrefix)
    }

    /// The texts of the `.response` entries of `transcript`.
    ///
    /// - Parameter transcript: A render that the model received.
    /// - Returns: The text of each response entry, in order.
    private static func responseTexts(of transcript: Transcript) -> [String] {
        WatchedText.attemptTexts(in: Array(transcript), excluding: []).filter { !$0.isReasoning && !$0.isToolCalls }
            .map(\.text)
    }

    @Test("the reply keeps the text before the stray </think> and drops the tag and what follows")
    func replyDropsTheTagAndWhatFollows() async throws {
        let (fixture, events) = try await Self.runStoppedAnswer()
        defer { await fixture.end() }

        #expect(events.answers.map(\.reply) == [Self.statusLine])
    }

    @Test("the turn ends at the stray </think> with no recovery call")
    func turnEndsWithNoRecovery() async throws {
        let (fixture, _) = try await Self.runStoppedAnswer()
        defer { await fixture.end() }

        #expect(fixture.log.renders.count == 1)
    }

    @Test("the stopped submission ends as completed, as if the model had ended it")
    func submissionEndsCompleted() async throws {
        let (fixture, events) = try await Self.runStoppedAnswer()
        defer { await fixture.end() }

        #expect(events.submissionEnds.map(\.finishReason) == [.completed])
    }

    @Test("the next call receives the response cut before the stray </think>")
    func nextRenderHoldsTheCutResponse() async throws {
        let (fixture, _) = try await Self.runStoppedAnswer()
        defer { await fixture.end() }

        _ = try await collect(fixture.session.streamEvents(to: Self.nextPrompt))

        let next = try #require(fixture.log.renders.last)
        #expect(Self.responseTexts(of: next) == [Self.statusLine])
    }

    @Test("a detection that is not enabled does not stop an always-reasoning model at a stray </think>")
    func disabledDetectionDoesNotStop() async throws {
        var detection = RepetitionDetection()
        detection.isEnabled = false

        // A detection that is not enabled starts no watch, so no code of the
        // session can stop the call, and the call needs no hold.
        let (fixture, events) = try await StagedReasoningSessionFixture.answer(
            to: Self.prompt, scripts: [Self.strayScript(hold: .noHold)], detection: detection,
            reasoningControl: .alwaysOn, tempDirPrefix: Self.tempDirPrefix)
        defer { await fixture.end() }

        #expect(events.streamedText.contains(RepeatingReasoningModel.Executor.answerText))
    }

    @Test("a switchable model writes past a </think> in its response text")
    func switchableModelIsNotStopped() async throws {
        let gate = ReasoningHoldGate()
        let fixture = try await StagedReasoningSessionFixture.make(
            scripts: [Self.strayScript(hold: .untilOpened(gate))], detection: RepetitionDetection(),
            reasoningControl: .switchable, tempDirPrefix: Self.tempDirPrefix)
        defer { await fixture.end() }
        let actor = try #require(fixture.session as? RoutedSessionActor)
        // The call waits on the gate after its response text. The gate opens
        // only after the watch read that whole text and found no stop, so a
        // stop could only come before the call ends.
        let opener = Task { try await gate.open(afterWatchOf: actor, readsResponse: Self.strayResponse) }
        defer { opener.cancel() }

        let events = try await fixture.endingOnThrow {
            try await collect(fixture.session.streamEvents(to: Self.prompt))
        }

        #expect(events.streamedText.contains(RepeatingReasoningModel.Executor.answerText))
    }
}
