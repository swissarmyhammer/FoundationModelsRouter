import Foundation
import FoundationModels
import Testing

@testable import FoundationModelsRouter

/// Exercises task k36zy10 (compaction epic — compaction_plan.md §1.5, §3,
/// build-order step 6): ``RecordingLanguageModel/noteCompaction(_:)``, the
/// bare-session entry point that folds a fresh (post-compaction) transcript
/// into a handle's recording — the counterpart to `RoutedSession.compact()`
/// for a caller driving a bare `LanguageModelSession` directly over the
/// recording handle (the agent harness, the ACP bridge).
///
/// Unlike ``RecordingLanguageModel/sync(_:usage:)``'s differ, which is
/// count-based (only ever grows), a fold's compacted transcript is typically
/// *shorter* than what came before it and reorders entries relative to the
/// pre-fold history: the synthesized summary entry replaces a folded span,
/// and only the recent tail survives with its original ids. `noteCompaction`
/// therefore diffs by `Transcript.Entry.id` set membership rather than by
/// position — appending only entries never before recorded — and resets the
/// differ baseline to the compacted transcript so post-fold turns record as
/// ordinary (count-based) appends again.
///
/// Everything runs against a stub `LanguageModel` conformer wrapping a stub
/// ``LoadedLLMContainer`` and an ``InMemoryRecorder``, so the suite needs no
/// network and no GPU.
@Suite("noteCompaction: append-only fold recording on the RecordingLanguageModel handle")
struct NoteCompactionTests {
    // MARK: - Stub underlying LanguageModel

    /// A `LanguageModel` conformer that always replies with a fixed canned
    /// response — no tool calling needed for these tests.
    private struct StubUnderlyingModel: LanguageModel {
        let responseText: String

        var capabilities: LanguageModelCapabilities { LanguageModelCapabilities([]) }

        var executorConfiguration: Executor.Configuration {
            Executor.Configuration(responseText: responseText)
        }

        struct Executor: LanguageModelExecutor {
            struct Configuration: Sendable, Hashable {
                let responseText: String
            }

            typealias Model = StubUnderlyingModel

            private let configuration: Configuration

            init(configuration: Configuration) throws {
                self.configuration = configuration
            }

            func respond(
                to request: LanguageModelExecutorGenerationRequest,
                model: StubUnderlyingModel,
                streamingInto channel: LanguageModelExecutorGenerationChannel
            ) async throws {
                await channel.send(.response(action: .appendText(configuration.responseText, tokenCount: 1)))
            }
        }
    }

    // MARK: - Stub container

    private struct StubLanguageModelContainer: PlainTranscriptStubContainer {
        let model: StubUnderlyingModel

        func makeSession(instructions: String?) -> any LanguageModelSessionBackend {
            StubSessionBackend()
        }

        var languageModel: any LanguageModel { model }
    }

    // MARK: - Stubs (probe, embedder, metadata, loader)

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

    /// A ``ModelLoader`` that returns the given ``LoadedLLMContainer`` for
    /// every generation slot. No download, no GPU.
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

    // MARK: - Fixtures

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
            .appendingPathComponent("NoteCompactionTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func makeRouter(
        container: any LoadedLLMContainer,
        recorder: any TranscriptRecorder,
        cacheDir: URL
    ) -> Router {
        Router(
            cacheDir: cacheDir,
            recorder: recorder,
            probe: StubProbe(chip: "Apple Test", totalRAM: 64 << 30, recommendedMaxWorkingSetSize: 48 << 30),
            metadataSource: StubMetadataSource(raw: rawMetadata),
            loader: StubModelLoader(container: container, dimension: stubDimension)
        )
    }

    /// Builds a synthesized summary `.response` entry carrying a text segment
    /// and a ``CompactionSegment`` — the shape a `Summarization` stage
    /// produces (compaction_plan.md §1.2), folding `foldedEntryIds` away and
    /// retaining `liveWindowEntryIds` (this summary's own id plus whatever
    /// tail survived) as the new live window.
    private static func makeSummaryEntry(
        id: String,
        liveWindowEntryIds: [String],
        foldedEntryIds: [String],
        summaryText: String = "Summary: prior turns folded."
    ) -> Transcript.Entry {
        .response(
            Transcript.Response(
                id: id,
                assetIDs: [],
                segments: [
                    .text(Transcript.TextSegment(id: "\(id)-text", content: summaryText)),
                    .custom(
                        CompactionSegment(
                            id: "\(id)-segment",
                            content: CompactionSegment.Content(
                                liveWindowEntryIds: liveWindowEntryIds,
                                foldedEntryIds: foldedEntryIds,
                                tokensBefore: 12_000,
                                tokensAfter: 3_000,
                                stagesApplied: ["TurnTruncation", "Summarization"],
                                promptName: "default"
                            )
                        )
                    ),
                ]
            )
        )
    }

    // MARK: - Two-turn fixture

    /// One handle, driven through two turns ("first"/"second"), each synced
    /// at turn end — the pre-fold history every test in this suite folds.
    /// `entries` is the resulting transcript: instructions, prompt1,
    /// response1, prompt2, response2.
    private struct Fixture {
        let handle: RecordingLanguageModel
        let recorder: InMemoryRecorder
        let entries: [Transcript.Entry]
        let dir: URL
    }

    @MainActor
    private static func makeTwoTurnFixture() async throws -> Fixture {
        let dir = makeTempDir()
        let recorder = InMemoryRecorder()
        let model = StubUnderlyingModel(responseText: "reply")
        let router = makeRouter(
            container: StubLanguageModelContainer(model: model),
            recorder: recorder,
            cacheDir: dir
        )
        let profile = try await router.resolve(profile: Self.profile, reporting: ResolutionProgress())

        let handle = profile.standard.makeLanguageModel()
        let session = LanguageModelSession(model: handle, tools: [], instructions: "be terse")
        _ = try await session.respond(to: "first")
        await handle.sync(session.transcript)
        _ = try await session.respond(to: "second")
        await handle.sync(session.transcript)

        return Fixture(handle: handle, recorder: recorder, entries: Array(session.transcript), dir: dir)
    }

    // MARK: - Exact-append semantics

    @Test("noteCompaction appends exactly the unseen summary entry; retained tail entries are not re-recorded")
    @MainActor
    func appendsOnlyUnseenSummaryEntry() async throws {
        let fixture = try await Self.makeTwoTurnFixture()
        defer { try? FileManager.default.removeItem(at: fixture.dir) }

        let beforeEvents = await fixture.recorder.events
        #expect(beforeEvents.map(\.kind) == [.session, .instructions, .prompt, .response, .prompt, .response])

        let instructions = fixture.entries[0]
        let foldedPrompt1 = fixture.entries[1]
        let foldedResponse1 = fixture.entries[2]
        let tailPrompt2 = fixture.entries[3]
        let tailResponse2 = fixture.entries[4]

        let summary = Self.makeSummaryEntry(
            id: "summary-1",
            liveWindowEntryIds: [instructions.id, "summary-1", tailPrompt2.id, tailResponse2.id],
            foldedEntryIds: [foldedPrompt1.id, foldedResponse1.id]
        )
        let compacted = Transcript(entries: [instructions, summary, tailPrompt2, tailResponse2])

        await fixture.handle.noteCompaction(compacted)

        let afterEvents = await fixture.recorder.events
        #expect(afterEvents.count == beforeEvents.count + 1)
        #expect(Array(afterEvents.prefix(beforeEvents.count)) == beforeEvents)

        let appended = try #require(afterEvents.last)
        #expect(appended.kind == .response)
        #expect(appended.text == "Summary: prior turns folded.")
        #expect(appended.sessionId == fixture.handle.state.sessionId)

        // The appended entry round-trips a CompactionSegment through the mapper.
        let entryPayload = try #require(appended.entry)
        let rebuilt = try TranscriptEntryMapper.entry(from: entryPayload, kind: appended.kind, registry: .routerDefault)
        guard case .response(let response) = rebuilt, case .custom(let segment) = response.segments.last,
            let compactionSegment = segment as? CompactionSegment
        else {
            Issue.record("expected the appended entry to carry a .custom CompactionSegment")
            return
        }
        #expect(compactionSegment.content.foldedEntryIds == [foldedPrompt1.id, foldedResponse1.id])
        #expect(
            compactionSegment.content.liveWindowEntryIds
                == [instructions.id, "summary-1", tailPrompt2.id, tailResponse2.id])
    }

    // MARK: - Pre-fold events untouched

    @Test("pre-fold events remain byte-identical in the recorder after noteCompaction")
    @MainActor
    func preFoldEventsRemainIntact() async throws {
        let fixture = try await Self.makeTwoTurnFixture()
        defer { try? FileManager.default.removeItem(at: fixture.dir) }

        let beforeEvents = await fixture.recorder.events

        let instructions = fixture.entries[0]
        let tailPrompt2 = fixture.entries[3]
        let tailResponse2 = fixture.entries[4]
        let summary = Self.makeSummaryEntry(
            id: "summary-1",
            liveWindowEntryIds: [instructions.id, "summary-1", tailPrompt2.id, tailResponse2.id],
            foldedEntryIds: [fixture.entries[1].id, fixture.entries[2].id]
        )
        let compacted = Transcript(entries: [instructions, summary, tailPrompt2, tailResponse2])

        await fixture.handle.noteCompaction(compacted)

        let afterEvents = await fixture.recorder.events
        for (index, before) in beforeEvents.enumerated() {
            #expect(afterEvents[index] == before)
        }
        // Session id identical on every pre-fold event, unchanged by the fold.
        #expect(beforeEvents.allSatisfy { $0.sessionId == fixture.handle.state.sessionId })
        #expect(afterEvents.prefix(beforeEvents.count).allSatisfy { $0.sessionId == fixture.handle.state.sessionId })
    }

    // MARK: - Baseline reset: post-fold turns record as ordinary appends

    @Test("after noteCompaction, a follow-up turn over the same handle records as an ordinary append with no duplicates")
    @MainActor
    func followUpTurnAfterFoldRecordsAsOrdinaryAppend() async throws {
        let fixture = try await Self.makeTwoTurnFixture()
        defer { try? FileManager.default.removeItem(at: fixture.dir) }

        let instructions = fixture.entries[0]
        let tailPrompt2 = fixture.entries[3]
        let tailResponse2 = fixture.entries[4]
        let summary = Self.makeSummaryEntry(
            id: "summary-1",
            liveWindowEntryIds: [instructions.id, "summary-1", tailPrompt2.id, tailResponse2.id],
            foldedEntryIds: [fixture.entries[1].id, fixture.entries[2].id]
        )
        let compacted = Transcript(entries: [instructions, summary, tailPrompt2, tailResponse2])
        await fixture.handle.noteCompaction(compacted)

        let afterFoldEvents = await fixture.recorder.events

        // The caller contract: rebuild the session over the SAME handle with
        // the compacted transcript.
        let postFoldSession = LanguageModelSession(model: fixture.handle, tools: [], transcript: compacted)
        _ = try await postFoldSession.respond(to: "third")
        await fixture.handle.sync(postFoldSession.transcript)

        let finalEvents = await fixture.recorder.events
        #expect(Array(finalEvents.prefix(afterFoldEvents.count)) == afterFoldEvents)

        let newEvents = Array(finalEvents.suffix(from: afterFoldEvents.count))
        #expect(newEvents.map(\.kind) == [.prompt, .response])
        #expect(newEvents.allSatisfy { $0.sessionId == fixture.handle.state.sessionId })

        // Nothing pre-fold or retained-tail was duplicated: exactly 4
        // .response-kind events total (turn1, turn2, the fold's own summary
        // response, and the post-fold turn) — never re-recording the tail.
        let responseCount = finalEvents.filter { $0.kind == .response }.count
        #expect(responseCount == 4)
        // Same session id, same ULID, on every event across the whole
        // pre-fold/fold/post-fold history (requirement 4).
        #expect(finalEvents.allSatisfy { $0.sessionId == fixture.handle.state.sessionId })
    }

    // MARK: - Repeated compactions

    @Test("noteCompaction is idempotent: calling it twice with the identical compacted transcript appends nothing the second time")
    @MainActor
    func noteCompactionIsIdempotentForIdenticalTranscript() async throws {
        let fixture = try await Self.makeTwoTurnFixture()
        defer { try? FileManager.default.removeItem(at: fixture.dir) }

        let instructions = fixture.entries[0]
        let tailPrompt2 = fixture.entries[3]
        let tailResponse2 = fixture.entries[4]
        let summary = Self.makeSummaryEntry(
            id: "summary-1",
            liveWindowEntryIds: [instructions.id, "summary-1", tailPrompt2.id, tailResponse2.id],
            foldedEntryIds: [fixture.entries[1].id, fixture.entries[2].id]
        )
        let compacted = Transcript(entries: [instructions, summary, tailPrompt2, tailResponse2])

        await fixture.handle.noteCompaction(compacted)
        let afterFirstFold = await fixture.recorder.events

        await fixture.handle.noteCompaction(compacted)
        let afterSecondFold = await fixture.recorder.events

        #expect(afterSecondFold == afterFirstFold)
    }

    @Test("a second, later compaction folds only its own new span — nested compactions never re-record an earlier fold's summary")
    @MainActor
    func secondLaterCompactionFoldsOnlyNewSpan() async throws {
        let fixture = try await Self.makeTwoTurnFixture()
        defer { try? FileManager.default.removeItem(at: fixture.dir) }

        let instructions = fixture.entries[0]
        let tailPrompt2 = fixture.entries[3]
        let tailResponse2 = fixture.entries[4]
        let firstSummary = Self.makeSummaryEntry(
            id: "summary-1",
            liveWindowEntryIds: [instructions.id, "summary-1", tailPrompt2.id, tailResponse2.id],
            foldedEntryIds: [fixture.entries[1].id, fixture.entries[2].id]
        )
        let firstCompacted = Transcript(entries: [instructions, firstSummary, tailPrompt2, tailResponse2])
        await fixture.handle.noteCompaction(firstCompacted)

        // Drive one more turn over the folded handle.
        let session2 = LanguageModelSession(model: fixture.handle, tools: [], transcript: firstCompacted)
        _ = try await session2.respond(to: "third")
        await fixture.handle.sync(session2.transcript)

        let beforeSecondFold = await fixture.recorder.events

        // Fold again: this time only the ORIGINAL fold's summary is folded
        // away, retaining the third turn's prompt/response as the new tail.
        let entriesAfterSecondTurn = Array(session2.transcript)
        let thirdPrompt = entriesAfterSecondTurn[2]
        let thirdResponse = entriesAfterSecondTurn[3]
        let secondSummary = Self.makeSummaryEntry(
            id: "summary-2",
            liveWindowEntryIds: [instructions.id, "summary-2", thirdPrompt.id, thirdResponse.id],
            foldedEntryIds: ["summary-1"],
            summaryText: "Summary: everything through turn 2 folded again."
        )
        let secondCompacted = Transcript(entries: [instructions, secondSummary, thirdPrompt, thirdResponse])
        await fixture.handle.noteCompaction(secondCompacted)

        let afterSecondFold = await fixture.recorder.events
        #expect(afterSecondFold.count == beforeSecondFold.count + 1)
        #expect(Array(afterSecondFold.prefix(beforeSecondFold.count)) == beforeSecondFold)

        let appended = try #require(afterSecondFold.last)
        #expect(appended.kind == .response)
        #expect(appended.text == "Summary: everything through turn 2 folded again.")
    }
}
