import Foundation
import FoundationModels
import Testing

@testable import FoundationModelsRouter

/// Pins the unit ``Compactor/estimatedTokenCount(of:)-(Transcript)`` is
/// denominated in (task 5m97h14).
///
/// The estimate used to divide the JSON-encoded ``TranscriptEntryPayload``'s
/// byte size by ``Compactor/charsPerTokenEstimate`` — a ratio documented as
/// "the commonly cited average for English text under BPE-style tokenizers"
/// applied to bytes that are not English text at all, but the on-disk
/// envelope: `entryId`, every segment's `id`, the `"type"` discriminators,
/// braces, quotes, and string escaping. None of that is ever sent to a model,
/// so none of it is ever tokenized, and counting it inflated the estimate by a
/// fixed amount per entry (~125 bytes / ~31 phantom tokens with these
/// fixtures' short ids, ~180 bytes / ~45 with the SDK's real UUID ids) on top
/// of a ~1.8x inflation over a realistic transcript.
///
/// That mattered because the estimate is compared *absolutely* against
/// real-token quantities in two places: ``Compactor/compact(_:prompt:budget:summarizer:summarization:pendingRuns:)``
/// checks it against ``TokenBudget/targetTokens``, and `RoutedSessionActor`'s
/// fold writes ``CompactionResult/tokensAfter`` straight into
/// ``RoutedSession/contextFill``'s numerator, where every other writer puts
/// real tokenizer counts from `LanguageModelSession.usage`. Two units for one
/// number made a fold *raise* measured fill.
@Suite("Compaction token accounting: the transcript estimate counts content, not the JSON envelope")
struct CompactionTokenAccountingTests {
    /// A `.prompt` entry carrying exactly `text`, with ids of the caller's
    /// choosing — so a test can vary id length while holding content fixed.
    ///
    /// - Parameters:
    ///   - entryId: The entry's own id.
    ///   - segmentId: The single text segment's id.
    ///   - text: The segment's content.
    /// - Returns: The assembled entry.
    private static func promptEntry(entryId: String, segmentId: String, text: String) -> Transcript.Entry {
        .prompt(
            Transcript.Prompt(
                id: entryId,
                segments: [.text(Transcript.TextSegment(id: segmentId, content: text))]
            )
        )
    }

    // MARK: - The envelope is not content

    @Test("a transcript whose entries carry no content at all estimates zero tokens, however many entries it has")
    func contentlessEntriesEstimateZero() throws {
        let transcript = Transcript(
            entries: (1...10).map {
                Self.promptEntry(entryId: "prompt-\($0)", segmentId: "prompt-\($0)-text", text: "")
            }
        )

        #expect(Compactor.estimatedTokenCount(of: transcript) == 0)
    }

    @Test("the estimate is independent of how long entry and segment ids are")
    func estimateIgnoresIdLength() throws {
        let text = String(repeating: "the quick brown fox jumps over the lazy dog. ", count: 8)
        let shortIds = Transcript(entries: [Self.promptEntry(entryId: "p", segmentId: "s", text: text)])
        let uuidIds = Transcript(
            entries: [
                Self.promptEntry(entryId: UUID().uuidString, segmentId: UUID().uuidString, text: text)
            ]
        )

        #expect(Compactor.estimatedTokenCount(of: uuidIds) == Compactor.estimatedTokenCount(of: shortIds))
    }

    // MARK: - Agreement with the single-string overload

    @Test("a text-only transcript estimates exactly what the single-string overload estimates for its concatenated text")
    func transcriptEstimateAgreesWithStringEstimate() throws {
        let texts = [
            "Project brief: this session's internal vault code is CRIMSON-77.",
            "Architecture notes: the archive is split into per-outpost shards.",
            "Data-quality notes: a lone dash is an explicit missing value.",
        ]
        let transcript = Transcript(
            entries: texts.enumerated().map { index, text in
                Self.promptEntry(entryId: "prompt-\(index)", segmentId: "prompt-\(index)-text", text: text)
            }
        )

        #expect(
            Compactor.estimatedTokenCount(of: transcript)
                == Compactor.estimatedTokenCount(of: texts.joined())
        )
    }

    // MARK: - A compaction boundary's bookkeeping is not content

    @Test("a fold's own CompactionSegment adds nothing to the estimate, however many entry ids its manifest carries")
    func compactionSegmentManifestIsNotContent() throws {
        // A boundary entry's model-visible part is its `.text` segments; the
        // `CompactionSegment` beside them is bookkeeping the backend's
        // transcript rendering skips outright, so it must not be measured as
        // if a tokenizer would see it. The manifest is not a rounding error:
        // it names every entry in the live window *and* every entry the fold
        // dropped, so it grows with the transcript being folded.
        let summaryText = "The archive project's vault code is CRIMSON-77; three of six outposts are indexed."
        func boundaryEntry(includingCompactionSegment: Bool) -> Transcript.Entry {
            var segments: [Transcript.Segment] = [
                .text(Transcript.TextSegment(id: "boundary-text", content: summaryText))
            ]
            if includingCompactionSegment {
                segments.append(
                    .custom(
                        CompactionSegment(
                            content: CompactionSegment.Content(
                                liveWindowEntryIds: (0..<10).map { _ in UUID().uuidString },
                                foldedEntryIds: (0..<8).map { _ in UUID().uuidString },
                                tokensBefore: 2074,
                                tokensAfter: 1843,
                                stagesApplied: ["ToolOutputElision", "TurnTruncation", "Summarization"],
                                promptName: CompactionPrompt.default.name
                            )
                        )
                    )
                )
            }
            return .response(Transcript.Response(id: "boundary", assetIDs: [], segments: segments))
        }

        let withSegment = Compactor.estimatedTokenCount(of: Transcript(entries: [boundaryEntry(includingCompactionSegment: true)]))
        let withoutSegment = Compactor.estimatedTokenCount(
            of: Transcript(entries: [boundaryEntry(includingCompactionSegment: false)]))

        #expect(withSegment == withoutSegment)
        // And the text that *is* rendered still counts, so this is not a blanket
        // "boundary entries are free".
        #expect(withSegment == Compactor.estimatedTokenCount(of: summaryText))
    }

    // MARK: - Still honest about every content-bearing field

    @Test("the estimate still counts tool-call arguments and tool output, not only text segments")
    func estimateCountsToolContent() throws {
        let bareTurn = try TranscriptFixtures.makeTurn(index: 1)
        let toolTurn = try TranscriptFixtures.makeTurn(
            index: 1, toolOutputText: String(repeating: "tool result ", count: 20))

        #expect(
            Compactor.estimatedTokenCount(of: Transcript(entries: toolTurn))
                > Compactor.estimatedTokenCount(of: Transcript(entries: bareTurn))
        )
    }

    @Test("the estimate still counts a response's asset ids, which the recording level treats as content")
    func estimateCountsAssetIds() throws {
        func responseEntry(assetIDs: [String]) -> Transcript.Entry {
            .response(
                Transcript.Response(
                    id: "response-1",
                    assetIDs: assetIDs,
                    segments: [.text(Transcript.TextSegment(id: "response-1-text", content: "answer"))]
                )
            )
        }

        #expect(
            Compactor.estimatedTokenCount(of: Transcript(entries: [responseEntry(assetIDs: [UUID().uuidString])]))
                > Compactor.estimatedTokenCount(of: Transcript(entries: [responseEntry(assetIDs: [])]))
        )
    }
}
