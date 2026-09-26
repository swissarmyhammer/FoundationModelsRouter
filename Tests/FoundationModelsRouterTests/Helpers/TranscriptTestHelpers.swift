import Foundation
import FoundationModels

@testable import FoundationModelsRouter

/// Shared fixture builders for constructing ``Transcript``s in tests: a
/// leading `.instructions` entry and the entries of one or more answers. The
/// entries of an answer are a `.prompt`, optionally a
/// `.toolCalls`/`.toolOutput` pair, and a `.response`.
///
/// The suites that build transcripts share these builders, so the fixture
/// shape is in one place only.
enum TranscriptFixtures {
    /// A single `.instructions` entry carrying a fixed system prompt — the
    /// header every fixture transcript below prefixes its answers with.
    static func makeInstructions() -> Transcript.Entry {
        .instructions(
            Transcript.Instructions(
                id: "instr-1",
                segments: [.text(Transcript.TextSegment(id: "instr-text-1", content: "you are a helpful assistant"))],
                toolDefinitions: []
            )
        )
    }

    /// Builds the entries of one answer: a `.prompt`, optionally a
    /// `.toolCalls`/`.toolOutput` pair (when `toolOutputText` is not `nil`),
    /// and a `.response`.
    ///
    /// - Parameters:
    ///   - index: The index of the answer, which every entry id of the answer
    ///     carries.
    ///   - promptText: The text of the prompt.
    ///   - toolOutputText: The text of the tool output, or `nil` for an answer
    ///     with no tool call.
    ///   - responseText: The text of the response.
    /// - Returns: The entries of the answer, in order.
    /// - Throws: What `GeneratedContent(json:)` throws.
    static func makeAnswerEntries(
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
                    segments: [.text(Transcript.TextSegment(id: "response-\(index)-text", content: responseText))]
                )
            )
        )
        return entries
    }

    /// The entries of `answerCount` answers, each with a tool-call/tool-output
    /// pair, indices `1...answerCount`.
    static func makeAnswerEntryLists(
        _ answerCount: Int, toolOutputText: String = "tool result"
    ) throws -> [[Transcript.Entry]] {
        try (1...answerCount).map { try Self.makeAnswerEntries(index: $0, toolOutputText: toolOutputText) }
    }

    /// Builds a raw compaction boundary `.response` entry: a text segment
    /// with `summaryText` (id `<entryId>-text`) plus a `.structure`
    /// ``CompactionSegment`` — the shape
    /// ``CompactionSegment/boundaryEntry(id:summaryText:content:)`` produces,
    /// built directly so the segment id is deterministic (the production
    /// construction generates its own segment id).
    ///
    /// The segment content carries fixed fixture values — `[entryId]` as the
    /// live window, one compacted entry id, `["Summarization"]` as the applied
    /// stages, and the `"default"` prompt name — so tests that only assert on
    /// ids, summary text, and token counts share one construction.
    ///
    /// - Parameters:
    ///   - entryId: The boundary entry's own `Transcript.Entry.id`.
    ///   - segmentId: The persisted ``CompactionSegment/id``.
    ///   - summaryText: The model-visible summary text.
    ///   - tokensBefore: The pre-compaction token count the segment records.
    ///   - tokensAfter: The post-compaction token count the segment records.
    /// - Returns: The boundary entry.
    static func makeCompactionEntry(
        entryId: String,
        segmentId: String,
        summaryText: String,
        tokensBefore: Int,
        tokensAfter: Int
    ) -> Transcript.Entry {
        .response(
            Transcript.Response(
                id: entryId,
                segments: [
                    .text(Transcript.TextSegment(id: "\(entryId)-text", content: summaryText)),
                    CompactionSegment(
                        id: segmentId,
                        content: CompactionSegment.Content(
                            liveWindowEntryIds: [entryId],
                            compactedEntryIds: ["compacted-1"],
                            tokensBefore: tokensBefore,
                            tokensAfter: tokensAfter,
                            stagesApplied: ["Summarization"],
                            promptName: "default")
                    ).transcriptSegment,
                ]))
    }

    /// Builds a `.response`-kind event carrying a text summary segment plus a
    /// ``CompactionSegment`` — the exact shape a real compaction's
    /// summary entry takes (see ``CompactionSegment/boundaryEntry(id:summaryText:content:)``).
    ///
    /// Shared by `TranscriptReconstructionTests` and
    /// `SessionTreeRestorationTests` — both exercise task x3nggmx's
    /// checkpoint-aware reconstruction/restoration and need this exact
    /// fixture shape.
    static func compactionCheckpointEvent(
        seq: Int,
        sessionId: ULID,
        routerId: ULID,
        entryId: String,
        summaryText: String = "summary",
        content: CompactionSegment.Content
    ) throws -> TranscriptEvent {
        let contentJSON = String(data: try JSONEncoder().encode(content), encoding: .utf8)!
        return TranscriptEvent(
            routerId: routerId,
            sessionId: sessionId,
            seq: seq,
            ts: Date(timeIntervalSince1970: TimeInterval(seq)),
            kind: .response,
            text: summaryText,
            entry: TranscriptEntryPayload(
                entryId: entryId,
                segments: [
                    .text(id: "\(entryId)-text", content: summaryText),
                    .structure(
                        id: "\(entryId)-segment",
                        schemaName: CompactionSegment.schemaName,
                        contentJSON: contentJSON
                    ),
                ],
                assetIds: []
            )
        )
    }
}
