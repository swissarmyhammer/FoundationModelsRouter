import Foundation
import FoundationModels
import Testing

@testable import FoundationModelsRouter

/// A turn that runs out of output tokens must not look like a turn that
/// finished.
///
/// The MLX executor sends `["incompleteOutput": true]` as metadata on the
/// response entry when the budget ends inside a thought. These tests prove that
/// ``TokenUsage/finishReason`` carries that fact to the host, first over hand
/// built transcript entries, then over a real `LanguageModelSession` whose
/// executor sends the same channel actions as MLX.
@Suite("Turn finish reason: a truncated turn is distinguishable from a finished turn")
struct TurnFinishReasonTests {
    /// The prefix of each temp directory this suite makes.
    private static let tempDirPrefix = "TurnFinishReasonTests"

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

    // MARK: - The reading of the entries of one turn

    @Test("a last response that carries incompleteOutput ends the turn at the token ceiling")
    func flaggedLastResponseIsMaxTokens() {
        let entries = [Self.reasoning("thinking"), Self.response("", metadata: ["incompleteOutput": true])]

        #expect(FinishReason(turnEntries: entries) == .maxTokens)
    }

    @Test("a last response with no metadata ends the turn as completed")
    func unflaggedLastResponseIsCompleted() {
        let entries = [Self.reasoning("thinking"), Self.response("done")]

        #expect(FinishReason(turnEntries: entries) == .completed)
    }

    @Test("an incompleteOutput value of false ends the turn as completed")
    func falseFlagIsCompleted() {
        let entries = [Self.response("done", metadata: ["incompleteOutput": false])]

        #expect(FinishReason(turnEntries: entries) == .completed)
    }

    @Test("a flagged response that a later response follows does not end the turn")
    func onlyTheLastResponseDecides() {
        let entries = [
            Self.response("", metadata: ["incompleteOutput": true]),
            Self.reasoning("again"),
            Self.response("done"),
        ]

        #expect(FinishReason(turnEntries: entries) == .completed)
    }

    @Test("a turn with no response entry ends as completed")
    func noResponseIsCompleted() {
        #expect(FinishReason(turnEntries: [Self.reasoning("thinking")]) == .completed)
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
}
