import Foundation
import FoundationModels
import Testing

@testable import FoundationModelsRouter

/// A turn that runs out of output tokens must not look like a turn that
/// finished.
///
/// The MLX executor sends `["incompleteOutput": true]` as metadata on the
/// response entry when the output ends inside a thought. The output can end
/// there at the ceiling, or below the ceiling (task ^gfxd7av), and only the
/// output token count of the call tells the two apart. When the budget ends
/// inside the answer text, the unconstrained MLX path sends no metadata, and
/// the output token count of the call is equal to the ceiling. These tests
/// prove that ``TokenUsage/finishReason`` carries these facts to the host, first
/// over hand built transcript entries, then over a real `LanguageModelSession`
/// whose executor sends the same channel actions as MLX. A tool loop makes more
/// than one generation call in one turn, so the tests of a tool loop prove that
/// the count of the last call decides, and not the sum of all calls.
@Suite("Turn finish reason: a truncated turn is distinguishable from a finished turn")
struct TurnFinishReasonTests {
    /// The prefix of each temp directory this suite makes.
    private static let tempDirPrefix = "TurnFinishReasonTests"

    /// A ceiling a caller names, smaller than the context of the session.
    private static let requestedCeiling = 256

    /// An output token count below ``requestedCeiling``.
    private static let outputBelowCeiling = 42

    /// A prompt entry with `text`.
    ///
    /// - Parameter text: The prompt text.
    /// - Returns: The transcript entry.
    private static func prompt(_ text: String) -> Transcript.Entry {
        .prompt(Transcript.Prompt(segments: [.text(Transcript.TextSegment(content: text))]))
    }

    /// A response entry with `text` and the given metadata.
    ///
    /// - Parameters:
    ///   - text: The response text.
    ///   - metadata: The metadata the executor sent on the entry.
    /// - Returns: The transcript entry.
    private static func response(
        _ text: String, metadata: [String: any ConvertibleToGeneratedContent] = [:]
    ) -> Transcript.Entry {
        .response(
            Transcript.Response(
                metadata: metadata, segments: [.text(Transcript.TextSegment(content: text))]))
    }

    /// A reasoning entry with `text`.
    ///
    /// - Parameter text: The reasoning text.
    /// - Returns: The transcript entry.
    private static func reasoning(_ text: String) -> Transcript.Entry {
        .reasoning(Transcript.Reasoning(segments: [.text(Transcript.TextSegment(content: text))]))
    }

    /// A tool-calls entry with one call to a tool named `search`.
    ///
    /// - Returns: The transcript entry.
    private static func toolCalls() -> Transcript.Entry {
        .toolCalls(
            Transcript.ToolCalls(
                id: "calls-1",
                [
                    Transcript.ToolCall(
                        id: "call-1", toolName: "search",
                        arguments: GeneratedContent(properties: ["query": "weather"]))
                ]))
    }

    /// Reads the finish reason of `entries` with no known output count and no
    /// known ceiling, so only the metadata decides.
    ///
    /// - Parameter entries: The entries the attempt appended.
    /// - Returns: The finish reason.
    private static func metadataOnlyReason(_ entries: [Transcript.Entry]) -> FinishReason {
        FinishReason(turnEntries: entries, outputTokens: nil, lastCallOutputTokens: nil, responseTokenCeiling: nil)
    }

    // MARK: - The reading of the entries of one turn

    /// The entries of an attempt whose output ended inside its reasoning: a
    /// thought, then an empty response that carries `incompleteOutput`.
    private static let endedInsideReasoningEntries = [
        prompt("fix the bug"), reasoning("thinking"), response("", metadata: ["incompleteOutput": true]),
    ]

    @Test("a last response that carries incompleteOutput, with no known count, ends inside the reasoning")
    func flaggedLastResponseIsEndedInsideReasoning() {
        #expect(Self.metadataOnlyReason(Self.endedInsideReasoningEntries) == .endedInsideReasoning)
    }

    @Test("an output that ends inside the reasoning below the ceiling does not end at the token ceiling")
    func flaggedOutputBelowCeilingIsEndedInsideReasoning() {
        let reason = FinishReason(
            turnEntries: Self.endedInsideReasoningEntries, outputTokens: Self.outputBelowCeiling,
            lastCallOutputTokens: Self.outputBelowCeiling, responseTokenCeiling: Self.requestedCeiling)

        #expect(reason == .endedInsideReasoning)
    }

    @Test("an output that ends inside the reasoning when its count reaches the ceiling ends at the token ceiling")
    func flaggedOutputAtCeilingIsMaxTokens() {
        let reason = FinishReason(
            turnEntries: Self.endedInsideReasoningEntries, outputTokens: Self.requestedCeiling,
            lastCallOutputTokens: Self.requestedCeiling, responseTokenCeiling: Self.requestedCeiling)

        #expect(reason == .maxTokens)
    }

    @Test("a last response with no metadata ends the turn as completed")
    func unflaggedLastResponseIsCompleted() {
        let entries = [Self.reasoning("thinking"), Self.response("done")]

        #expect(Self.metadataOnlyReason(entries) == .completed)
    }

    @Test("an incompleteOutput value of false ends the turn as completed")
    func falseFlagIsCompleted() {
        let entries = [Self.response("done", metadata: ["incompleteOutput": false])]

        #expect(Self.metadataOnlyReason(entries) == .completed)
    }

    @Test("a flagged response that a later response follows does not end the turn")
    func onlyTheLastResponseDecides() {
        let entries = [
            Self.response("", metadata: ["incompleteOutput": true]),
            Self.reasoning("again"),
            Self.response("done"),
        ]

        #expect(Self.metadataOnlyReason(entries) == .completed)
    }

    @Test("a turn with no response entry ends as completed")
    func noResponseIsCompleted() {
        #expect(Self.metadataOnlyReason([Self.reasoning("thinking")]) == .completed)
    }

    // MARK: - The output token count of one turn against its ceiling

    @Test("an attempt whose output count reaches the ceiling with no metadata ends at the token ceiling")
    func outputAtCeilingIsMaxTokens() {
        let entries = [Self.prompt("fix the bug"), Self.reasoning("thinking"), Self.response("The answer is")]

        let reason = FinishReason(
            turnEntries: entries, outputTokens: Self.requestedCeiling, lastCallOutputTokens: nil,
            responseTokenCeiling: Self.requestedCeiling)

        #expect(reason == .maxTokens)
    }

    @Test("an attempt whose output count is below the ceiling ends as completed")
    func outputBelowCeilingIsCompleted() {
        let entries = [Self.prompt("fix the bug"), Self.response("done")]

        let reason = FinishReason(
            turnEntries: entries, outputTokens: Self.outputBelowCeiling, lastCallOutputTokens: nil,
            responseTokenCeiling: Self.requestedCeiling)

        #expect(reason == .completed)
    }

    @Test("an attempt with no known ceiling ends as completed whatever its output count")
    func unknownCeilingIsCompleted() {
        let entries = [Self.prompt("fix the bug"), Self.response("done")]

        let reason = FinishReason(
            turnEntries: entries, outputTokens: Self.requestedCeiling, lastCallOutputTokens: nil,
            responseTokenCeiling: nil)

        #expect(reason == .completed)
    }

    @Test("an attempt with no known output count ends as completed")
    func unknownOutputIsCompleted() {
        let entries = [Self.prompt("fix the bug"), Self.response("done")]

        let reason = FinishReason(
            turnEntries: entries, outputTokens: nil, lastCallOutputTokens: nil,
            responseTokenCeiling: Self.requestedCeiling)

        #expect(reason == .completed)
    }

    @Test("an attempt that called a tool, with no known last call count, does not end at the ceiling on its summed count")
    func toolLoopOutputIsNotReadAgainstCeiling() {
        let entries = [
            Self.prompt("fix the bug"), Self.toolCalls(), Self.response("done"),
        ]

        let reason = FinishReason(
            turnEntries: entries, outputTokens: Self.requestedCeiling, lastCallOutputTokens: nil,
            responseTokenCeiling: Self.requestedCeiling)

        #expect(reason == .completed)
    }

    @Test("a seeded tool call before the prompt does not stop the output count from deciding")
    func seededToolCallBeforePromptStillReadsCount() {
        let entries = [
            Self.toolCalls(), Self.prompt("fix the bug"), Self.response("The answer is"),
        ]

        let reason = FinishReason(
            turnEntries: entries, outputTokens: Self.requestedCeiling, lastCallOutputTokens: nil,
            responseTokenCeiling: Self.requestedCeiling)

        #expect(reason == .maxTokens)
    }

    /// The entries of an attempt that called one tool and then answered.
    private static let toolLoopEntries = [
        prompt("fix the bug"), toolCalls(), response("The answer is"),
    ]

    @Test("an attempt that called a tool ends at the ceiling when its last call reaches the ceiling")
    func toolLoopLastCallAtCeilingIsMaxTokens() {
        let reason = FinishReason(
            turnEntries: Self.toolLoopEntries, outputTokens: Self.requestedCeiling + Self.outputBelowCeiling,
            lastCallOutputTokens: Self.requestedCeiling, responseTokenCeiling: Self.requestedCeiling)

        #expect(reason == .maxTokens)
    }

    @Test("an attempt that called a tool ends as completed when only its earlier calls reach the ceiling")
    func toolLoopLastCallBelowCeilingIsCompleted() {
        let reason = FinishReason(
            turnEntries: Self.toolLoopEntries, outputTokens: Self.requestedCeiling + Self.outputBelowCeiling,
            lastCallOutputTokens: Self.outputBelowCeiling, responseTokenCeiling: Self.requestedCeiling)

        #expect(reason == .completed)
    }

    @Test("a last call count above the output count of the attempt is not a call of the attempt and does not decide")
    func lastCallCountAboveAttemptCountDoesNotDecide() {
        let reason = FinishReason(
            turnEntries: [], outputTokens: 0, lastCallOutputTokens: Self.requestedCeiling,
            responseTokenCeiling: Self.requestedCeiling)

        #expect(reason == .completed)
    }

    // MARK: - The whole turn over a live session backend

    @Test("a turn whose backend reports incompleteOutput below the ceiling closes with finishReason endedInsideReasoning")
    func turnEndedInsideReasoningReportsEndedInsideReasoning() async throws {
        let fixture = try await CeilingProbeSessionFixture.make(
            ending: .truncatedInsideReasoning, tempDirPrefix: Self.tempDirPrefix)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let outcome: SessionAnswer = try await fixture.session.respond(to: "fix the bug", maxTokens: nil)

        let usage = try #require(outcome.usage)
        #expect(usage.finishReason == .endedInsideReasoning)
    }

    @Test("a turn whose backend reports incompleteOutput at the ceiling closes with finishReason maxTokens")
    func reasoningTruncatedAtCeilingReportsMaxTokens() async throws {
        let fixture = try await CeilingProbeSessionFixture.make(
            ending: .truncatedInsideReasoningAtCeiling, tempDirPrefix: Self.tempDirPrefix)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let outcome: SessionAnswer = try await fixture.session.respond(
            to: "fix the bug", maxTokens: Self.requestedCeiling)

        let usage = try #require(outcome.usage)
        #expect(usage.finishReason == .maxTokens)
    }

    @Test("a turn whose model finishes closes with finishReason completed")
    func finishedTurnReportsCompleted() async throws {
        let fixture = try await CeilingProbeSessionFixture.make(
            ending: .finished, tempDirPrefix: Self.tempDirPrefix)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let outcome: SessionAnswer = try await fixture.session.respond(to: "fix the bug", maxTokens: nil)

        let usage = try #require(outcome.usage)
        #expect(usage.finishReason == .completed)
        #expect(outcome.reply == CeilingProbeLanguageModel.Executor.answerText)
    }

    @Test("a turn that finishes after a truncated turn reports completed")
    func finishReasonIsPerTurn() async throws {
        let fixture = try await CeilingProbeSessionFixture.make(
            ending: .truncatedOnFirstCallOnly, tempDirPrefix: Self.tempDirPrefix)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let first: SessionAnswer = try await fixture.session.respond(to: "first", maxTokens: nil)
        let second: SessionAnswer = try await fixture.session.respond(to: "second", maxTokens: nil)

        #expect(try #require(first.usage).finishReason == .endedInsideReasoning)
        #expect(try #require(second.usage).finishReason == .completed)
    }

    @Test(
        "a turn that reaches the ceiling in its answer text with no metadata closes with finishReason maxTokens",
        arguments: [nil, TurnFinishReasonTests.requestedCeiling])
    func answerTruncatedAtCeilingReportsMaxTokens(maxTokens: Int?) async throws {
        let fixture = try await CeilingProbeSessionFixture.make(
            ending: .truncatedInAnswerText, tempDirPrefix: Self.tempDirPrefix)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let outcome: SessionAnswer = try await fixture.session.respond(to: "fix the bug", maxTokens: maxTokens)

        let usage = try #require(outcome.usage)
        #expect(usage.finishReason == .maxTokens)
        #expect(outcome.reply == CeilingProbeLanguageModel.Executor.truncatedAnswerText)
    }

    @Test("a streamed turn that reaches the ceiling in its answer text closes with finishReason maxTokens")
    func streamedAnswerTruncatedAtCeilingReportsMaxTokens() async throws {
        let fixture = try await CeilingProbeSessionFixture.make(
            ending: .truncatedInAnswerText, tempDirPrefix: Self.tempDirPrefix)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let usage = try #require(await Self.closingUsage(ofStreamedTurnOn: fixture.session))

        #expect(usage.finishReason == .maxTokens)
    }

    // MARK: - A tool loop over a live session backend

    /// Drives one turn through ``RoutedSession/streamEvents(to:maxTokens:)``
    /// under ``requestedCeiling``, and gives the usage of its last
    /// ``SessionEvent/submissionEnded(_:)``.
    ///
    /// - Parameter session: The session to drive the turn on.
    /// - Returns: The usage of the last submission, or `nil` when no
    ///   `submissionEnded` event came or the last one had no usage.
    /// - Throws: Whatever the stream throws.
    private static func closingUsage(ofStreamedTurnOn session: RoutedSession) async throws -> TokenUsage? {
        var closingUsage: TokenUsage?
        for try await event in await session.streamEvents(to: "fix the bug", maxTokens: requestedCeiling) {
            if case .submissionEnded(let end) = event { closingUsage = end.usage }
        }
        return closingUsage
    }

    /// Makes a fixture whose session mounts `tool` and whose model ends each
    /// call as `ending` says.
    ///
    /// - Parameters:
    ///   - ending: How each generation call ends.
    ///   - tool: The tool the first generation call asks for.
    /// - Returns: The fixture.
    /// - Throws: Whatever profile resolution throws.
    private static func toolLoopFixture(
        ending: CeilingProbeEnding, tool: MarkerEmittingTool
    ) async throws -> CeilingProbeSessionFixture {
        try await CeilingProbeSessionFixture.make(ending: ending, tools: [tool], tempDirPrefix: tempDirPrefix)
    }

    @Test(
        "a tool-calling turn whose last call reaches the ceiling in its answer text closes with finishReason maxTokens",
        arguments: [nil, TurnFinishReasonTests.requestedCeiling])
    func toolLoopAnswerTruncatedAtCeilingReportsMaxTokens(maxTokens: Int?) async throws {
        let tool = MarkerEmittingTool()
        let fixture = try await Self.toolLoopFixture(ending: .toolCallThenTruncatedInAnswerText, tool: tool)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let outcome: SessionAnswer = try await fixture.session.respond(to: "fix the bug", maxTokens: maxTokens)

        #expect(tool.calledSteps == [CeilingProbeLanguageModel.Executor.toolStep])
        #expect(outcome.reply == CeilingProbeLanguageModel.Executor.truncatedAnswerText)
        #expect(try #require(outcome.usage).finishReason == .maxTokens)
    }

    @Test("a tool-calling turn whose earlier call spends the ceiling and whose last call finishes closes with completed")
    func toolLoopFinishedAfterSpentToolCallReportsCompleted() async throws {
        let tool = MarkerEmittingTool()
        let fixture = try await Self.toolLoopFixture(ending: .toolCallThenFinished, tool: tool)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let outcome: SessionAnswer = try await fixture.session.respond(
            to: "fix the bug", maxTokens: Self.requestedCeiling)

        #expect(tool.calledSteps == [CeilingProbeLanguageModel.Executor.toolStep])
        #expect(outcome.reply == CeilingProbeLanguageModel.Executor.answerText)
        let usage = try #require(outcome.usage)
        #expect(usage.tokensOut > Self.requestedCeiling)
        #expect(usage.finishReason == .completed)
    }

    @Test("a streamed tool-calling turn whose last call reaches the ceiling in its answer text closes with maxTokens")
    func streamedToolLoopAnswerTruncatedAtCeilingReportsMaxTokens() async throws {
        let tool = MarkerEmittingTool()
        let fixture = try await Self.toolLoopFixture(ending: .toolCallThenTruncatedInAnswerText, tool: tool)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let usage = try #require(await Self.closingUsage(ofStreamedTurnOn: fixture.session))

        #expect(tool.calledSteps == [CeilingProbeLanguageModel.Executor.toolStep])
        #expect(usage.finishReason == .maxTokens)
    }

    @Test("a streamed tool-calling turn whose last call sends no text does not read the count of the earlier call")
    func streamedToolLoopWithSilentLastCallReportsCompleted() async throws {
        let tool = MarkerEmittingTool()
        let fixture = try await Self.toolLoopFixture(ending: .toolCallThenNoText, tool: tool)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let usage = try #require(await Self.closingUsage(ofStreamedTurnOn: fixture.session))

        #expect(tool.calledSteps == [CeilingProbeLanguageModel.Executor.toolStep])
        #expect(usage.finishReason == .completed)
    }
}
