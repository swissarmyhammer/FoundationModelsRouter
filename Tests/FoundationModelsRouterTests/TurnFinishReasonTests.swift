import Foundation
import FoundationModels
import Testing

@testable import FoundationModelsRouter

/// A turn that runs out of output tokens must not look like a turn that
/// finished.
///
/// The MLX executor sends `["incompleteOutput": true]` as metadata on the
/// response entry when the budget ends inside a thought. When the budget ends
/// inside the answer text, the unconstrained MLX path sends no metadata, and
/// the output token count of the call is equal to the ceiling. These tests
/// prove that ``TokenUsage/finishReason`` carries both facts to the host, first
/// over hand built transcript entries, then over a real `LanguageModelSession`
/// whose executor sends the same channel actions as MLX.
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
        FinishReason(turnEntries: entries, outputTokens: nil, responseTokenCeiling: nil)
    }

    // MARK: - The reading of the entries of one turn

    @Test("a last response that carries incompleteOutput ends the turn at the token ceiling")
    func flaggedLastResponseIsMaxTokens() {
        let entries = [Self.reasoning("thinking"), Self.response("", metadata: ["incompleteOutput": true])]

        #expect(Self.metadataOnlyReason(entries) == .maxTokens)
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
            turnEntries: entries, outputTokens: Self.requestedCeiling, responseTokenCeiling: Self.requestedCeiling)

        #expect(reason == .maxTokens)
    }

    @Test("an attempt whose output count is below the ceiling ends as completed")
    func outputBelowCeilingIsCompleted() {
        let entries = [Self.prompt("fix the bug"), Self.response("done")]

        let reason = FinishReason(
            turnEntries: entries, outputTokens: Self.outputBelowCeiling, responseTokenCeiling: Self.requestedCeiling)

        #expect(reason == .completed)
    }

    @Test("an attempt with no known ceiling ends as completed whatever its output count")
    func unknownCeilingIsCompleted() {
        let entries = [Self.prompt("fix the bug"), Self.response("done")]

        let reason = FinishReason(
            turnEntries: entries, outputTokens: Self.requestedCeiling, responseTokenCeiling: nil)

        #expect(reason == .completed)
    }

    @Test("an attempt with no known output count ends as completed")
    func unknownOutputIsCompleted() {
        let entries = [Self.prompt("fix the bug"), Self.response("done")]

        let reason = FinishReason(
            turnEntries: entries, outputTokens: nil, responseTokenCeiling: Self.requestedCeiling)

        #expect(reason == .completed)
    }

    @Test("an attempt that called a tool does not end at the ceiling on its summed output count")
    func toolLoopOutputIsNotReadAgainstCeiling() {
        let entries = [
            Self.prompt("fix the bug"), Self.toolCalls(), Self.response("done"),
        ]

        let reason = FinishReason(
            turnEntries: entries, outputTokens: Self.requestedCeiling, responseTokenCeiling: Self.requestedCeiling)

        #expect(reason == .completed)
    }

    @Test("a seeded tool call before the prompt does not stop the output count from deciding")
    func seededToolCallBeforePromptStillReadsCount() {
        let entries = [
            Self.toolCalls(), Self.prompt("fix the bug"), Self.response("The answer is"),
        ]

        let reason = FinishReason(
            turnEntries: entries, outputTokens: Self.requestedCeiling, responseTokenCeiling: Self.requestedCeiling)

        #expect(reason == .maxTokens)
    }

    // MARK: - The whole turn over a live session backend

    @Test("a turn whose backend reports incompleteOutput closes with finishReason maxTokens")
    func truncatedTurnReportsMaxTokens() async throws {
        let fixture = try await CeilingProbeSessionFixture.make(
            ending: .truncatedInsideReasoning, tempDirPrefix: Self.tempDirPrefix)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let outcome: TurnOutcome = try await fixture.session.respond(to: "fix the bug", maxTokens: nil)

        let usage = try #require(outcome.usage)
        #expect(usage.finishReason == .maxTokens)
    }

    @Test("a turn whose model finishes closes with finishReason completed")
    func finishedTurnReportsCompleted() async throws {
        let fixture = try await CeilingProbeSessionFixture.make(
            ending: .finished, tempDirPrefix: Self.tempDirPrefix)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let outcome: TurnOutcome = try await fixture.session.respond(to: "fix the bug", maxTokens: nil)

        let usage = try #require(outcome.usage)
        #expect(usage.finishReason == .completed)
        #expect(outcome.reply == CeilingProbeLanguageModel.Executor.answerText)
    }

    @Test("a turn that finishes after a truncated turn reports completed")
    func finishReasonIsPerTurn() async throws {
        let fixture = try await CeilingProbeSessionFixture.make(
            ending: .truncatedOnFirstCallOnly, tempDirPrefix: Self.tempDirPrefix)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let first: TurnOutcome = try await fixture.session.respond(to: "first", maxTokens: nil)
        let second: TurnOutcome = try await fixture.session.respond(to: "second", maxTokens: nil)

        #expect(try #require(first.usage).finishReason == .maxTokens)
        #expect(try #require(second.usage).finishReason == .completed)
    }

    @Test(
        "a turn that reaches the ceiling in its answer text with no metadata closes with finishReason maxTokens",
        arguments: [nil, TurnFinishReasonTests.requestedCeiling])
    func answerTruncatedAtCeilingReportsMaxTokens(maxTokens: Int?) async throws {
        let fixture = try await CeilingProbeSessionFixture.make(
            ending: .truncatedInAnswerText, tempDirPrefix: Self.tempDirPrefix)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let outcome: TurnOutcome = try await fixture.session.respond(to: "fix the bug", maxTokens: maxTokens)

        let usage = try #require(outcome.usage)
        #expect(usage.finishReason == .maxTokens)
        #expect(outcome.reply == CeilingProbeLanguageModel.Executor.truncatedAnswerText)
    }

    @Test("a streamed turn that reaches the ceiling in its answer text closes with finishReason maxTokens")
    func streamedAnswerTruncatedAtCeilingReportsMaxTokens() async throws {
        let fixture = try await CeilingProbeSessionFixture.make(
            ending: .truncatedInAnswerText, tempDirPrefix: Self.tempDirPrefix)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        var closingUsage: TokenUsage?
        for try await event in await fixture.session.streamEvents(
            to: "fix the bug", maxTokens: Self.requestedCeiling)
        {
            if case .turnEnded(let usage) = event { closingUsage = usage }
        }

        let usage = try #require(closingUsage)
        #expect(usage.finishReason == .maxTokens)
    }
}
