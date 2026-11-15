import Foundation
import FoundationModels
import FoundationModelsRouterTestSupport
import Testing

@testable import FoundationModelsRouter

/// Task ^jw0yqvg: the recovery prompts and the final pass prompt ask for a
/// tool call only when the session has tools. A session with no tools gets
/// prompts that ask only for the final answer.
///
/// Each test drives the production backend and a real `LanguageModelSession`
/// over a ``RepeatingReasoningModel``. No GPU is in the loop. The session's
/// counter is the ``CharacterTokenCounter``: one token per character.
@Suite("The recovery prompts ask for a tool call only when the session has tools")
struct RecoveryPromptToolsTests {
    /// The suite's temp-directory prefix.
    private static let tempDirPrefix = "RecoveryPromptToolsTests"

    /// The prompt of every answer of this suite.
    private static let prompt = "fix the failing test"

    /// The word that each prompt for a session with no tools must not hold.
    private static let toolWord = "tool"

    /// The window of the repetition stop: small, so a short script fills it.
    private static let repetitionWindow = 200

    /// How many times the repeating script writes its cycle: far more than
    /// one ``repetitionWindow`` of tokens.
    private static let repetitionCycleCount = 40

    /// A script whose reasoning the session stops at the reasoning token
    /// limit.
    private static let reasoningStopScript = RepeatingReasoningScript.reasoningHeldAtLimit()

    /// A script whose reasoning repeats until the session stops it.
    private static let repetitionStopScript = RepeatingReasoningScript.repeating(
        newLines: ["First I read the failing test and its fixture."],
        cycle: ["Maybe the alias is resolved in the compiler.", "Let me look at how the compiler resolves it."],
        cycleCount: repetitionCycleCount, hold: .untilStopped)

    /// The tools of a session that has tools.
    private static var tools: [any Tool] {
        [CountingRunCodeTool(runs: RunCount())]
    }

    /// Runs one streamed answer over a fresh fixture, and gives the last
    /// prompt of the last render: the prompt of the recovery or of the final
    /// pass.
    ///
    /// - Parameters:
    ///   - script: What the first call writes.
    ///   - detection: The repetition detection of the session.
    ///   - tools: The tools the session mounts.
    /// - Returns: The last prompt text of the last render, or `nil`.
    /// - Throws: What the fixture or the answer throws.
    private static func lastPrompt(
        script: RepeatingReasoningScript,
        detection: RepetitionDetection = RepetitionDetection(),
        tools: [any Tool]
    ) async throws -> String? {
        let fixture = try await RepeatingReasoningSessionFixture.make(
            script: script, repeatsAfterStop: false, detection: detection, tools: tools,
            tempDirPrefix: tempDirPrefix)
        // A throw closes the session and removes the temp directory here.
        _ = try await fixture.endingOnThrow {
            try await fixture.answer(to: prompt)
        }
        await fixture.end()
        return fixture.log.renders.last?.promptTexts.last
    }

    @Test("with no tools, the recovery after a reasoning stop asks only for the final answer")
    func reasoningStopRecoveryWithNoToolsNamesNoTool() async throws {
        let prompt = try await Self.lastPrompt(script: Self.reasoningStopScript, tools: [])
        #expect(prompt.map { !$0.contains(Self.toolWord) } == true)
    }

    @Test("with tools, the recovery after a reasoning stop asks for one tool call or the final answer")
    func reasoningStopRecoveryWithToolsAsksForToolCall() async throws {
        let prompt = try await Self.lastPrompt(script: Self.reasoningStopScript, tools: Self.tools)
        #expect(prompt == RoutedSessionActor.reasoningStopContinuationPrompt)
    }

    @Test("with no tools, the recovery after a repetition stop asks only for the final answer")
    func repetitionStopRecoveryWithNoToolsNamesNoTool() async throws {
        let prompt = try await Self.lastPrompt(
            script: Self.repetitionStopScript, detection: RepetitionDetection(windowTokens: Self.repetitionWindow),
            tools: [])
        #expect(prompt.map { !$0.contains(Self.toolWord) } == true)
    }

    @Test("with tools, the recovery after a repetition stop asks for one tool call or the final answer")
    func repetitionStopRecoveryWithToolsAsksForToolCall() async throws {
        let prompt = try await Self.lastPrompt(
            script: Self.repetitionStopScript, detection: RepetitionDetection(windowTokens: Self.repetitionWindow),
            tools: Self.tools)
        #expect(prompt == RoutedSessionActor.repetitionStopContinuationPrompt)
    }

    @Test("with no tools, the final pass asks only for the final answer")
    func finalPassWithNoToolsNamesNoTool() async throws {
        let prompt = try await Self.lastPrompt(
            script: Self.reasoningStopScript, detection: RepetitionDetection(recoveriesPerAnswer: 0), tools: [])
        #expect(prompt.map { !$0.contains(Self.toolWord) } == true)
    }

    @Test("with tools, the final pass lets the model make one tool call")
    func finalPassWithToolsAllowsToolCall() async throws {
        let prompt = try await Self.lastPrompt(
            script: Self.reasoningStopScript, detection: RepetitionDetection(recoveriesPerAnswer: 0),
            tools: Self.tools)
        #expect(prompt == RoutedSessionActor.finalPassPrompt)
    }
}
