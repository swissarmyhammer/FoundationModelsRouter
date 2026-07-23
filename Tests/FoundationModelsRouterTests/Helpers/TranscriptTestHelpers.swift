import Foundation
import FoundationModels

@testable import FoundationModelsRouter

/// Shared fixture builders for constructing ``Transcript``s in tests: a
/// leading `.instructions` entry (the untouchable header) and one or more
/// "turns" — a `.prompt`, optionally a `.toolCalls`/`.toolOutput` pair, and a
/// `.response` — the shape ``TranscriptTurns/split(_:)`` partitions a
/// transcript into.
///
/// Shared by `CompactionStageTests` and `CompactorPipelineTests` (both
/// exercise task vvjfkfb — compaction_plan.md §1.3's deterministic stages and
/// the `Compactor` pipeline) so the fixture shape lives in exactly one place.
enum TranscriptFixtures {
    /// A single `.instructions` entry carrying a fixed system prompt — the
    /// header every fixture transcript below prefixes its turns with.
    static func makeInstructions() -> Transcript.Entry {
        .instructions(
            Transcript.Instructions(
                id: "instr-1",
                segments: [.text(Transcript.TextSegment(id: "instr-text-1", content: "you are a helpful assistant"))],
                toolDefinitions: []
            )
        )
    }

    /// Builds one turn: a `.prompt`, optionally a `.toolCalls`/`.toolOutput`
    /// pair (when `toolOutputText` is non-nil), and a `.response` — the shape
    /// ``TranscriptTurns/split(_:)`` partitions a transcript into.
    static func makeTurn(
        index: Int,
        promptText: String = "question",
        toolOutputText: String? = nil,
        responseText: String = "answer"
    ) throws -> [Transcript.Entry] {
        var entries: [Transcript.Entry] = [
            .prompt(
                Transcript.Prompt(
                    id: "prompt-\(index)",
                    segments: [.text(Transcript.TextSegment(id: "prompt-\(index)-text", content: promptText))]
                )
            )
        ]
        if let toolOutputText {
            entries.append(
                .toolCalls(
                    Transcript.ToolCalls(
                        id: "calls-\(index)",
                        [
                            Transcript.ToolCall(
                                id: "call-\(index)",
                                toolName: "search",
                                arguments: try GeneratedContent(json: #"{"query":"q"}"#)
                            )
                        ]
                    )
                )
            )
            entries.append(
                .toolOutput(
                    Transcript.ToolOutput(
                        id: "toolOutput-\(index)",
                        toolName: "search",
                        segments: [.text(Transcript.TextSegment(id: "toolOutput-\(index)-text", content: toolOutputText))]
                    )
                )
            )
        }
        entries.append(
            .response(
                Transcript.Response(
                    id: "response-\(index)",
                    assetIDs: [],
                    segments: [.text(Transcript.TextSegment(id: "response-\(index)-text", content: responseText))]
                )
            )
        )
        return entries
    }

    /// `turnCount` turns, each with a tool-call/tool-output pair, indices
    /// `1...turnCount`.
    static func makeTurns(_ turnCount: Int, toolOutputText: String = "tool result") throws -> [[Transcript.Entry]] {
        try (1...turnCount).map { try Self.makeTurn(index: $0, toolOutputText: toolOutputText) }
    }
}
