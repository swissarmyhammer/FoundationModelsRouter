import Foundation
import FoundationModels
import Testing

@testable import FoundationModelsRouter

/// Spike for kanban task dws80ms (compaction epic — compaction_plan.md §6.1,
/// build-order step 1): de-risks the core compaction mechanism *before* any
/// of `CompactionSegment`, the compactor pipeline, or `RoutedSession.compact()`
/// is built. Two things had to be proven first: that a *synthesized*
/// `Transcript.Entry` — a summary entry Router fabricates itself, and an
/// elision-placeholder entry replacing an old `toolOutput` payload — survives
/// the recording mirror (``TranscriptEntryMapper`` → ``TranscriptEntryPayload``
/// → ``TranscriptTree/effectiveTranscript(forSession:registry:)`` in
/// `TranscriptReconstruction.swift`), and whether Apple's FoundationModels SDK
/// ships any native transcript-condensing primitive Router should defer to
/// instead of building its own.
///
/// ## Verdict 1 — native condensing: BUILD, not defer.
///
/// Searched the installed macOS 27 SDK's `FoundationModels.framework` public
/// interface for any compaction/condensing primitive:
///
/// ```
/// $ F=".../FoundationModels.swiftmodule/arm64e-apple-macos.swiftinterface"
/// $ grep -inE "compact|condens|summar|trim|prune|fold|truncat" "$F"
/// (no matches)
/// ```
///
/// Zero hits, over the whole framework. The only context-window-related
/// surface the SDK exposes at all is `LanguageModelSession.contextSize` (a
/// read-only `Int`) and the `LanguageModelError.contextSizeExceeded` /
/// deprecated `GenerationError.exceededContextWindowSize` failure cases —
/// nothing that folds, summarizes, elides, or trims a transcript. There is
/// nothing native to defer to or build on top of: compaction_plan.md's
/// from-scratch design (§1) is the only option.
///
/// ## Verdict 2 — entry ids: controllable at synthesis; preserved end to end
/// through the recording mirror.
///
/// The same `.swiftinterface` shows every `Transcript.Entry` case's `id` is a
/// settable `var String` supplied at construction —
/// `init(id: String = UUID().uuidString, ...)` for `.instructions`, `.prompt`,
/// `.response`, and `.reasoning`; a *required*, no-default `id:` for
/// `.toolCalls` and `.toolOutput`. So a synthesized entry's id is fully
/// controllable: a fresh id for a new summary entry, or — deliberately — the
/// *same* id an old `.toolOutput` carried, to mark an elision placeholder as
/// replacing it in place rather than being a new, unrelated entry. This is
/// exactly what `CompactionSegment` (compaction_plan.md §1.2) depends on: it
/// references live-window and folded entries *by id*.
///
/// What this hermetic suite proves is the disk half of that dependency: once
/// synthesized, an id survives ``TranscriptEntryMapper/event(from:)`` →
/// ``TranscriptEntryPayload`` → JSONL →
/// ``TranscriptTree/effectiveTranscript(forSession:registry:)`` exactly,
/// whether it is a brand-new id or a deliberately reused one. Whether a live
/// `LanguageModelSession(transcript:)` *also* preserves those same ids on
/// ingest (rather than reassigning them) is a separate, runtime-only question
/// this hermetic suite cannot answer by construction — see the gated
/// `CompactionSpikeIntegrationTests` suite in
/// `Tests/FoundationModelsRouterIntegrationTests/` (`FM_ROUTER_INTEGRATION_TESTS`)
/// for that half, and its own header comment for the verdict once run.
@Suite("Compaction spike: synthesized Transcript.Entry round-trip through the recording mirror")
struct CompactionSpikeTests {
    // MARK: - Fixtures: synthesized entries no real model turn ever produced

    /// The id an "old" `.toolOutput` entry carried before compaction folded
    /// it — reused, deliberately, by ``makeElisionPlaceholder()`` below.
    private static let oldToolOutputId = "tooloutput-old-1"

    private static func makeInstructions() -> Transcript.Entry {
        .instructions(
            Transcript.Instructions(
                id: "instr-1",
                segments: [.text(Transcript.TextSegment(id: "instr-text-1", content: "you are a helpful assistant"))],
                toolDefinitions: []
            )
        )
    }

    /// The real `.toolCalls` entry that requested the tool output compaction
    /// will later elide — untouched by compaction (only `toolOutput`
    /// payloads shrink; `toolCalls`/`toolOutput` pairing survives, per
    /// compaction_plan.md §1.3).
    private static func makeOldToolCallsEntry() throws -> Transcript.Entry {
        .toolCalls(
            Transcript.ToolCalls(
                id: "calls-old-1",
                [
                    Transcript.ToolCall(
                        id: "call-old-1",
                        toolName: "search",
                        arguments: try GeneratedContent(json: #"{"query":"weather"}"#)
                    )
                ]
            )
        )
    }

    /// The synthesized elision-placeholder entry a `ToolOutputElision` stage
    /// (compaction_plan.md §1.3) would produce: a *new* `.toolOutput` value
    /// that reuses ``oldToolOutputId`` — the id of the real tool output it
    /// replaces — so it marks itself as an in-place fold rather than an
    /// unrelated new entry, with the payload itself shrunk to a one-line
    /// placeholder naming the tool.
    private static func makeElisionPlaceholder() -> Transcript.Entry {
        .toolOutput(
            Transcript.ToolOutput(
                id: oldToolOutputId,
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
        )
    }

    /// The synthesized summary entry a `Summarization` stage would append: a
    /// `.response` entry no real model turn produced, carrying a fresh id and
    /// a single text segment — compaction_plan.md §1.2's "text segment the
    /// model reads as prior context" (minus its `CompactionSegment`, a later
    /// build-order step this spike does not need).
    private static func makeSummaryEntry() -> Transcript.Entry {
        .response(
            Transcript.Response(
                id: "summary-1",
                assetIDs: [],
                segments: [
                    .text(
                        Transcript.TextSegment(
                            id: "summary-text-1",
                            content: "Summary: the user asked about the weather; the assistant looked it up via `search`."
                        )
                    )
                ]
            )
        )
    }

    // MARK: - Direct mapper round trips

    @Test("a synthesized summary .response entry (never produced by a real turn) round-trips through the mapper with an identical id and text")
    func summaryEntryRoundTripsThroughMapper() throws {
        let original = Self.makeSummaryEntry()
        let (kind, payload, text) = TranscriptEntryMapper.event(from: original)
        #expect(kind == .response)
        #expect(payload.entryId == "summary-1")
        #expect(text == "Summary: the user asked about the weather; the assistant looked it up via `search`.")

        let rebuilt = try TranscriptEntryMapper.entry(from: payload, kind: kind)
        #expect(rebuilt == original)
        #expect(rebuilt.id == "summary-1")
    }

    /// At this single-entry level the mapper has no notion of "reused" vs.
    /// "fresh" id — it round-trips whatever string `payload.entryId` carries,
    /// same as `TranscriptEntryMapperTests.toolOutputRoundTrips()` already
    /// proves for an ordinary `.toolOutput` entry. What makes id *reuse*
    /// specifically meaningful — that this id still resolves to exactly one
    /// entry, in the right position, when it shares a value with what it
    /// replaced — is exercised only where two entries coexist, i.e. in
    /// `synthesizedTranscriptRoundTripsThroughFullRecordingMirror()` below.
    /// Kept here anyway as the fast, isolated confirmation that this
    /// specific elision-placeholder shape (a one-line replacement segment
    /// under the id compaction would deliberately reuse) round-trips at all.
    @Test("a synthesized elision-placeholder .toolOutput entry round-trips through the mapper, preserving its id")
    func elisionPlaceholderRoundTripsThroughMapperPreservingReusedId() throws {
        let original = Self.makeElisionPlaceholder()
        let (kind, payload, text) = TranscriptEntryMapper.event(from: original)
        #expect(kind == .toolOutput)
        #expect(payload.entryId == Self.oldToolOutputId)
        #expect(text == "[elided: original \"search\" output omitted by compaction]")

        let rebuilt = try TranscriptEntryMapper.entry(from: payload, kind: kind)
        #expect(rebuilt == original)
        #expect(rebuilt.id == Self.oldToolOutputId)
    }

    // MARK: - Full recording-mirror round trip: mapper -> payload -> JSONL -> reconstruction

    @Test("a whole synthesized transcript — instructions, an old toolCalls, an elision-placeholder toolOutput reusing the old entry's id, and a synthesized summary response — records through the mirror and reconstructs with identical structure")
    @MainActor
    func synthesizedTranscriptRoundTripsThroughFullRecordingMirror() async throws {
        let cacheDir = Self.makeTempDir()
        let recordingsDir = Self.makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: cacheDir)
            try? FileManager.default.removeItem(at: recordingsDir)
        }

        let synthesized: [Transcript.Entry] = [
            Self.makeInstructions(),
            try Self.makeOldToolCallsEntry(),
            // Replaces the old toolOutput in place, reusing its id — see
            // makeElisionPlaceholder()'s doc comment.
            Self.makeElisionPlaceholder(),
            Self.makeSummaryEntry(),
        ]

        let backend = SpikeBackend()
        backend.entries = synthesized
        let container = SpikeLLMContainer(backend: backend)
        let router = Self.makeRouter(
            container: container,
            recorder: JSONLRecorder(directory: recordingsDir),
            cacheDir: cacheDir,
            recordingsDir: recordingsDir
        )
        let profile = try await router.resolve(profile: Self.profile, reporting: ResolutionProgress())

        let session = profile.standard.makeSession()
        // Drives the chokepoint once so its post-generation diff persists
        // `synthesized`. SpikeBackend never mutates `entries` itself (see its
        // own doc comment), so with a `persistedEntryCount` baseline of 0 this
        // turn's diff finds and persists exactly the four synthesized entries
        // above, unchanged — precisely what a real `compact()` call would do:
        // hand the recorder a freshly rewritten transcript to persist, not a
        // transcript the SDK itself produced turn by turn.
        _ = try await session.respond(to: "irrelevant — this turn exists only to trigger the recording chokepoint")

        let routerDirectory = recordingsDir.appendingPathComponent(router.id.description, isDirectory: true)
        let tree = try TranscriptTree.load(under: routerDirectory)
        let reconstructed = Array(try tree.effectiveTranscript(forSession: session.id))

        #expect(reconstructed == synthesized)
        #expect(reconstructed.map(\.id) == synthesized.map(\.id))
        // The elision placeholder's id is literally the id the tool output it
        // replaced carried — still present, still unique, still positioned
        // exactly where the old entry was.
        #expect(reconstructed[2].id == Self.oldToolOutputId)
    }

    // MARK: - Stubs: a fully test-controlled "SDK transcript"

    /// A ``LanguageModelSessionBackend`` whose "SDK transcript" is entirely
    /// test-controlled: `respond`/`streamResponse` never mutate ``entries``
    /// themselves, so a test sets ``entries`` to whatever synthesized values
    /// it wants *before* calling `respond`, and the chokepoint's diff persists
    /// exactly that as new — the same technique
    /// `TranscriptFidelityTests.VariableTranscriptBackend` uses to test
    /// shrink-clamping, reused here to feed the chokepoint a synthesized
    /// (rather than shrunk) transcript.
    ///
    /// `@unchecked Sendable` is safe for the same reason as that type: every
    /// access is sequential, driven by this suite's single awaited
    /// `@MainActor` test method, one call at a time, with any actor-internal
    /// read further serialized by the model's own per-model serial gate.
    private final class SpikeBackend: LanguageModelSessionBackend, @unchecked Sendable {
        var entries: [Transcript.Entry] = []

        func respond(to prompt: String, maxTokens: Int?) async throws -> String { "ok" }

        func streamResponse(to prompt: String, maxTokens: Int?) -> AsyncThrowingStream<String, Error> {
            AsyncThrowingStream { continuation in
                continuation.yield("ok")
                continuation.finish()
            }
        }

        func respond(to prompt: String, following grammar: Grammar, maxTokens: Int?) async throws -> String {
            try grammar.validateForXGrammar()
            return "ok"
        }

        func makeFork() -> any LanguageModelSessionBackend {
            let fork = SpikeBackend()
            fork.entries = entries
            return fork
        }

        func transcriptEntries() -> [Transcript.Entry] { entries }

        func usageTokenCounts() -> (input: Int, output: Int)? { nil }
    }

    /// A ``LoadedLLMContainer`` that always vends the one test-supplied
    /// ``SpikeBackend``.
    private struct SpikeLLMContainer: LoadedLLMContainer {
        let backend: SpikeBackend

        func makeSession(instructions: String?) -> any LanguageModelSessionBackend { backend }

        func makeSession(transcript: Transcript) -> any LanguageModelSessionBackend {
            backend.entries = Array(transcript)
            return backend
        }
    }

    private struct StubEmbeddingContainer: LoadedEmbeddingContainer {
        let dimension: Int
        func embed(texts: [String]) async throws -> [[Float]] {
            texts.map { _ in [Float](repeating: 0.5, count: dimension) }
        }
    }

    private struct StubProbe: MachineProbe {
        let chip: String
        let totalRAM: Int64
        let recommendedMaxWorkingSetSize: Int64
    }

    private struct StubMetadataSource: MetadataSource {
        let raw: RawRepoMetadata
        func fetchRawMetadata(repo: String, revision: String?) async throws -> RawRepoMetadata { raw }
    }

    /// A ``ModelLoader`` that returns a single, test-supplied
    /// ``LoadedLLMContainer`` for every generation slot. No download, no GPU.
    private struct StubModelLoader: ModelLoader {
        let container: any LoadedLLMContainer
        let dimension: Int

        func loadLLM(
            ref: ModelRef,
            slot: ModelSlot,
            context: Int,
            reporting: @escaping @Sendable (DownloadProgress) -> Void
        ) async throws -> any LoadedLLMContainer {
            reporting(DownloadProgress(bytesDownloaded: 1, bytesTotal: 1))
            return container
        }

        func loadEmbedder(
            ref: ModelRef,
            slot: ModelSlot,
            reporting: @escaping @Sendable (DownloadProgress) -> Void
        ) async throws -> any LoadedEmbeddingContainer {
            reporting(DownloadProgress(bytesDownloaded: 1, bytesTotal: 1))
            return StubEmbeddingContainer(dimension: dimension)
        }

        func preload(container: any LoadedModelContainer) async throws {}
    }

    // MARK: - Router/profile fixtures

    private static let configJSON = Data("""
        {
            "num_hidden_layers": 2,
            "num_attention_heads": 8,
            "num_key_value_heads": 2,
            "head_dim": 16,
            "hidden_size": 128
        }
        """.utf8)

    private static let treeJSON = Data("""
        [
            {"type": "file", "path": "model.safetensors", "size": 10000000}
        ]
        """.utf8)

    private static var rawMetadata: RawRepoMetadata {
        RawRepoMetadata(configJSON: configJSON, treeJSON: treeJSON)
    }

    private static let profile = ProfileDefinition(
        name: "coding",
        description: "test profile",
        standard: ["org/std-a"],
        flash: ["org/flash-a"],
        embedding: ["org/emb-a"]
    )

    private static let stubDimension = 8

    private static func makeTempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CompactionSpikeTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func makeRouter(
        container: any LoadedLLMContainer,
        recorder: any TranscriptRecorder,
        cacheDir: URL,
        recordingsDir: URL
    ) -> Router {
        Router(
            cacheDir: cacheDir,
            recordingsDir: recordingsDir,
            recorder: recorder,
            probe: StubProbe(chip: "Apple Test", totalRAM: 64 << 30, recommendedMaxWorkingSetSize: 48 << 30),
            metadataSource: StubMetadataSource(raw: rawMetadata),
            loader: StubModelLoader(container: container, dimension: stubDimension)
        )
    }
}
