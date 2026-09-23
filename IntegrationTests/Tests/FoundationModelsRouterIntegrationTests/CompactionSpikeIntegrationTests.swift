import FoundationModels
import FoundationModelsRouterTestSupport
import Testing

@testable import FoundationModelsRouter
@testable import FoundationModelsRouterRealModelSupport

/// The same real `mlx-community` generation model the rest of this target's
/// gated suites use for the `.standard` slot.
private let compactionSpikeTinyModel: ModelRef = RealModels.standard

// MARK: - Suite

/// The gated half of kanban task dws80ms's spike (see
/// `Tests/FoundationModelsRouterTests/CompactionSpikeTests.swift`'s header
/// comment for the hermetic half and both written verdicts). This suite
/// answers the one question the hermetic suite cannot: whether a live
/// `LanguageModelSession(transcript:)` — the exact API
/// ``RoutedSession/compact(prompt:budget:)`` (compaction_plan.md §1.4) will
/// rebuild the inner session over after a compaction — tolerates and completes a
/// turn over a transcript containing entries no real turn ever produced in
/// that order: a synthesized summary `.response` entry, next to a
/// `.toolCalls` and `.toolOutput` pair that keeps its old ids.
///
/// Builds directly over an already-loaded tiny model's
/// ``MLXFoundationModelsContainer`` (bypassing `Router.resolve(_:reporting:)`,
/// which would need a real `.flash`/`.embedding` download too) and calls
/// ``MLXFoundationModelsContainer/makeSession(transcript:)`` directly — the
/// same factory ``LiveModelLoader``'s live conformer exposes, and the one a
/// restored/compacted session is rebuilt through — rather than assembling a
/// full ``RoutedSessionActor``, since this spike's only question is whether
/// the SDK itself accepts the synthesized shape, not the router's own
/// bookkeeping around it (already covered hermetically elsewhere).
///
/// The three runs of 2026-08-20 measured this suite's one test at 17.5, then
/// 9.4, then 17.0 seconds. The suite has no time limit. A run ends when it
/// ends, or when the caller stops it.
@Suite(
    "Gated real-model coverage: a rebuilt live LanguageModelSession over synthesized entries (task dws80ms)",
    .serialized,
    .exclusiveRealModel
)
struct CompactionSpikeIntegrationTests {
    /// A synthesized transcript of the entry kinds a compaction's new snapshot
    /// holds: instructions, a `.toolCalls` entry and the `.toolOutput` entry
    /// it made, both with their old ids (the new snapshot keeps a protected
    /// tool output and its call word for word), and a synthesized summary
    /// `.response` entry no real turn produced.
    ///
    /// The tool output states no fact the test asks about, so the answer can
    /// come only from the summary entry.
    ///
    /// - Returns: The synthesized transcript.
    /// - Throws: What `GeneratedContent(json:)` throws for the call's arguments.
    private static func makeSynthesizedTranscript() throws -> Transcript {
        let instructions = Transcript.Instructions(
            id: "instr-1",
            segments: [.text(Transcript.TextSegment(content: "You are a terse, literal assistant."))],
            toolDefinitions: []
        )
        let oldToolCalls = Transcript.ToolCalls(
            id: "calls-old-1",
            [
                Transcript.ToolCall(
                    id: "call-old-1",
                    toolName: "search",
                    arguments: try GeneratedContent(json: #"{"query":"favorite number"}"#)
                )
            ]
        )
        let keptToolOutput = Transcript.ToolOutput(
            id: "tooloutput-old-1",
            toolName: "search",
            segments: [
                .text(
                    Transcript.TextSegment(
                        id: "kept-text-1",
                        content: "search found no stored document for this query."
                    )
                )
            ]
        )
        let summary = Transcript.Response(
            id: "summary-1",
            segments: [
                .text(
                    Transcript.TextSegment(
                        id: "summary-text-1",
                        content: "Summary: earlier in the conversation the user said their favorite number is 42."
                    )
                )
            ]
        )
        return Transcript(entries: [
            .instructions(instructions),
            .toolCalls(oldToolCalls),
            .toolOutput(keptToolOutput),
            .response(summary),
        ])
    }

    /// Task dws80ms's core acceptance criterion, proved against a real model:
    /// a live `LanguageModelSession` rebuilt over a transcript containing
    /// synthesized entries — never produced by any real turn — completes one
    /// turn without error.
    ///
    /// Also settles this spike's second written verdict empirically: whether
    /// the synthesized entries' ids (fully controllable at construction, per
    /// `CompactionSpikeTests`'s header comment) survive ingestion into a live
    /// session, or whether the SDK reassigns them. Recorded once observed —
    /// see the assertion below and this test's own inline result.
    @Test("a live LanguageModelSession rebuilt over a transcript containing a synthesized summary entry and a kept tool output completes one turn without error")
    func rebuiltSessionOverSynthesizedTranscriptCompletesATurn() async throws {
        let loaded = try await RealModelContainer.load(ref: compactionSpikeTinyModel)

        let synthesizedTranscript = try Self.makeSynthesizedTranscript()
        let synthesizedIds = Array(synthesizedTranscript).map(\.id)

        let backend = try #require(
            loaded.container.makeSession(transcript: synthesizedTranscript, samplingMode: loaded.samplingMode)
                as? MLXFoundationModelsSessionBackend
        )

        // Verdict 2 (empirical half): the ids as the live session actually
        // holds them immediately after `LanguageModelSession(transcript:)`
        // ingested the synthesized transcript, before any turn runs.
        let idsAfterIngest = Array(backend.session.transcript).map(\.id)
        #expect(idsAfterIngest == synthesizedIds)

        // The actual acceptance criterion: one live turn over this transcript
        // completes without throwing.
        let reply = try await backend.respond(
            to: "What is my favorite number? Answer with just the number, digits only.",
            maxTokens: GatedRealModelBudget.responseTokenCeiling
        )
        #expect(!reply.isEmpty)
        // The synthesized summary entry is real prior context to the model,
        // not inert bookkeeping: the answer must actually come from it, since
        // nothing else in this synthesized transcript states the fact.
        #expect(reply.contains("42"))

        // The synthesized entries are still present, in order, at the front
        // of the post-turn transcript — the live session only ever appends.
        let idsAfterTurn = Array(backend.session.transcript).map(\.id)
        #expect(Array(idsAfterTurn.prefix(synthesizedIds.count)) == synthesizedIds)

        await loaded.container.model.evict()
    }
}
