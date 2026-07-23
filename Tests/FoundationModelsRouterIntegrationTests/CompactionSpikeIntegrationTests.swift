import Foundation
import FoundationModels
import HuggingFace
import MLXHuggingFace
import MLXLMCommon
import Testing
import Tokenizers

@testable import FoundationModelsRouter

// MARK: - Gate

/// Reuses the same opt-in gating pattern as the rest of this target: unset
/// (the default, and on any CI/GPU-less box) this whole suite is skipped, so
/// `swift test` stays green without network or a GPU. Kept as its own
/// file-scoped constant rather than sharing another file's — Swift's
/// top-level `private` is file-scoped, not target-scoped.
private let compactionSpikeIntegrationEnvVar = "FM_ROUTER_INTEGRATION_TESTS"

private var compactionSpikeIntegrationEnabled: Bool {
    ProcessInfo.processInfo.environment[compactionSpikeIntegrationEnvVar] != nil
}

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
/// rebuild the inner session over after a fold — tolerates and completes a
/// turn over a transcript containing entries no real turn ever produced: a
/// synthesized summary `.response` entry and a synthesized elision-placeholder
/// `.toolOutput` entry reusing an old entry's id.
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
@Suite(
    "Gated real-model coverage: a rebuilt live LanguageModelSession over synthesized entries (task dws80ms)",
    .serialized,
    .timeLimit(.minutes(15)),
    .enabled(if: compactionSpikeIntegrationEnabled)
)
struct CompactionSpikeIntegrationTests {
    /// Loads the tiny model directly through a real ``LiveModelLoader`` and
    /// returns its concrete ``MLXFoundationModelsContainer``.
    private func makeContainer() async throws -> MLXFoundationModelsContainer {
        let loader = LiveModelLoader(
            downloader: #hubDownloader(),
            tokenizerLoader: #huggingFaceTokenizerLoader()
        )
        let loaded = try await loader.loadLLM(
            ref: compactionSpikeTinyModel,
            slot: .standard,
            context: RealModels.context,
            reporting: { _ in }
        )
        return try #require(loaded as? MLXFoundationModelsContainer)
    }

    /// The same synthesized shape ``CompactionSpikeTests`` proves round-trips
    /// through the recording mirror: instructions, a real `.toolCalls` entry,
    /// an elision-placeholder `.toolOutput` entry that reuses the old tool
    /// output's id (rather than being a new, unrelated entry), and a
    /// synthesized summary `.response` entry no real turn produced — the exact
    /// shape a `ToolOutputElision` + `Summarization` fold
    /// (compaction_plan.md §1.3) would leave behind.
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
        let elisionPlaceholder = Transcript.ToolOutput(
            id: "tooloutput-old-1",
            toolName: "search",
            segments: [
                .text(
                    Transcript.TextSegment(
                        id: "elision-text-1",
                        content: "[elided: original \"search\" output omitted by compaction]"
                    )
                )
            ]
        )
        let summary = Transcript.Response(
            id: "summary-1",
            assetIDs: [],
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
            .toolOutput(elisionPlaceholder),
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
    @Test("a live LanguageModelSession rebuilt over a transcript containing a synthesized summary entry and an elision-placeholder entry completes one turn without error")
    func rebuiltSessionOverSynthesizedTranscriptCompletesATurn() async throws {
        try await GatedSuiteSerialGate.shared.withPermit {
        let container = try await makeContainer()

        let synthesizedTranscript = try Self.makeSynthesizedTranscript()
        let synthesizedIds = Array(synthesizedTranscript).map(\.id)

        let backend = try #require(
            container.makeSession(transcript: synthesizedTranscript) as? MLXFoundationModelsSessionBackend
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
            maxTokens: 32
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

        await container.model.evict()
        }
    }
}
