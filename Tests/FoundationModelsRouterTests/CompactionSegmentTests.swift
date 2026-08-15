import Foundation
import FoundationModels
import Testing

@testable import FoundationModelsRouter

/// Exercises task vchknhc (compaction epic — compaction_plan.md §1.2,
/// build-order step 2): ``CompactionSegment``, the ``PersistableStructuredSegment``
/// carrying one compaction's fold metadata.
///
/// Everything runs hermetically — stub `LoadedLLMContainer`s and backends, a
/// `JSONLRecorder` writing into a temp directory — so the suite needs no
/// network and no GPU. Builds on the entry-id findings from the compaction
/// spike (task dws80ms, ``CompactionSpikeTests``): a synthesized `.response`
/// entry carrying a `.structure` segment round-trips through the recording
/// mirror with no production changes needed for the mapper/reconstruction
/// side; what this suite adds is the concrete ``CompactionSegment`` type
/// itself and proof that each reconstruction entry point rebuilds it from the
/// persisted schema name alone, so a compacted session restores with zero
/// consumer configuration.
@Suite("CompactionSegment: Codable round trip, recording-mirror round trip, and configuration-free restoration")
struct CompactionSegmentTests {
    // MARK: - Fixture content

    /// The parked-run summary `makeContent` carries by default, so every
    /// fixture-driven round trip in this suite also proves `pendingRuns`
    /// survives the path under test.
    private static let fixturePendingRun = CompactionSegment.PendingRunSummary(
        completionToken: "01AN4Z07BY79KA1307SR9X4MV5",
        op: "run task",
        latestProgressDetail: "step 3 of 5"
    )

    private static func makeContent(
        liveWindowEntryIds: [String] = ["summary-1", "tail-prompt-1", "tail-response-1"],
        foldedEntryIds: [String] = ["old-instr-1", "old-prompt-1", "old-response-1"],
        tokensBefore: Int = 12_000,
        tokensAfter: Int = 3_000,
        stagesApplied: [String] = ["ToolOutputElision", "TurnTruncation", "Summarization"],
        promptName: String = "default",
        pendingRuns: [CompactionSegment.PendingRunSummary]? = [fixturePendingRun]
    ) -> CompactionSegment.Content {
        CompactionSegment.Content(
            liveWindowEntryIds: liveWindowEntryIds,
            foldedEntryIds: foldedEntryIds,
            tokensBefore: tokensBefore,
            tokensAfter: tokensAfter,
            stagesApplied: stagesApplied,
            promptName: promptName,
            pendingRuns: pendingRuns
        )
    }

    // MARK: - Codable round trip (no mocks, no registry involved)

    @Test("CompactionSegment.Content encodes and decodes losslessly, preserving every fold-metadata field")
    func contentRoundTripsThroughCodable() throws {
        let original = Self.makeContent()
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(CompactionSegment.Content.self, from: data)
        #expect(decoded == original)
        #expect(decoded.liveWindowEntryIds == original.liveWindowEntryIds)
        #expect(decoded.foldedEntryIds == original.foldedEntryIds)
        #expect(decoded.tokensBefore == original.tokensBefore)
        #expect(decoded.tokensAfter == original.tokensAfter)
        #expect(decoded.stagesApplied == original.stagesApplied)
        #expect(decoded.promptName == original.promptName)
        #expect(decoded.pendingRuns == [Self.fixturePendingRun])
    }

    @Test(
        "CompactionSegment.Content with pendingRuns encodes and decodes losslessly, preserving each run's token, op, and latest progress"
    )
    func contentWithPendingRunsRoundTripsThroughCodable() throws {
        let original = Self.makeContent(pendingRuns: [
            CompactionSegment.PendingRunSummary(
                completionToken: "01AN4Z07BY79KA1307SR9X4MV3",
                op: "run task",
                latestProgressDetail: "halfway through"
            ),
            CompactionSegment.PendingRunSummary(
                completionToken: "01AN4Z07BY79KA1307SR9X4MV4",
                op: "fetch url",
                latestProgressDetail: nil
            ),
        ])
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(CompactionSegment.Content.self, from: data)
        #expect(decoded == original)
        #expect(decoded.pendingRuns?.count == 2)
        #expect(decoded.pendingRuns?.first?.completionToken == "01AN4Z07BY79KA1307SR9X4MV3")
        #expect(decoded.pendingRuns?.first?.op == "run task")
        #expect(decoded.pendingRuns?.first?.latestProgressDetail == "halfway through")
        #expect(decoded.pendingRuns?.last?.latestProgressDetail == nil)
    }

    @Test("previously recorded CompactionSegment.Content JSON without the pendingRuns field still decodes, with pendingRuns nil")
    func contentWithoutPendingRunsFieldStillDecodes() throws {
        // Exactly the JSON shape every CompactionSegment recorded before the
        // pendingRuns field existed carries — no `pendingRuns` key at all.
        let legacyJSON = Data(
            """
            {
                "liveWindowEntryIds": ["summary-1", "tail-prompt-1"],
                "foldedEntryIds": ["old-prompt-1", "old-response-1"],
                "tokensBefore": 12000,
                "tokensAfter": 3000,
                "stagesApplied": ["ToolOutputElision", "TurnTruncation", "Summarization"],
                "promptName": "default"
            }
            """.utf8)
        let decoded = try JSONDecoder().decode(CompactionSegment.Content.self, from: legacyJSON)
        #expect(decoded.pendingRuns == nil)
        #expect(decoded.liveWindowEntryIds == ["summary-1", "tail-prompt-1"])
        #expect(decoded.foldedEntryIds == ["old-prompt-1", "old-response-1"])
        #expect(decoded.tokensBefore == 12_000)
        #expect(decoded.tokensAfter == 3_000)
        #expect(decoded.stagesApplied == ["ToolOutputElision", "TurnTruncation", "Summarization"])
        #expect(decoded.promptName == "default")
    }

    @Test("CompactionSegment is Sendable, matching its all-let storage and its already-Sendable nested types")
    func compactionSegmentIsSendable() {
        // Locks in the Sendable guarantee a segment relies on to cross
        // actor/task boundaries. The conformance is inherited through
        // PersistableStructuredSegment (which refines Sendable); the explicit
        // restatement on CompactionSegment's declaration is documentation.
        // This call type-checks as long as the guarantee holds, from either
        // source.
        func requiresSendable<T: Sendable>(_: T.Type) {}
        requiresSendable(CompactionSegment.self)
    }

    @Test("CompactionSegment's default schemaName is the type's fully-qualified name")
    func defaultSchemaNameIsFullyQualifiedName() {
        #expect(CompactionSegment.schemaName == String(reflecting: CompactionSegment.self))
    }

    // MARK: - Mapper round trip: a summary entry carrying text + CompactionSegment

    @Test("a synthesized summary .response entry carrying a text segment and a CompactionSegment round-trips through TranscriptEntryMapper")
    func compactionSegmentRoundTripsThroughMapper() throws {
        let content = Self.makeContent()
        let segment = CompactionSegment(id: "compaction-1", content: content)
        let original = Transcript.Entry.response(
            Transcript.Response(
                id: "summary-1",
                segments: [
                    .text(Transcript.TextSegment(id: "summary-text-1", content: "Summary: ...")),
                    segment.transcriptSegment,
                ]
            )
        )

        let (kind, payload, text) = TranscriptEntryMapper.event(from: original)
        #expect(kind == .response)
        #expect(text == "Summary: ...")

        let rebuilt = try TranscriptEntryMapper.entry(from: payload, kind: kind)
        guard case .response(let rebuiltResponse) = rebuilt,
            case .structure(let rebuiltSegment) = rebuiltResponse.segments.last,
            let rebuiltCompaction = try CompactionSegment(structuredSegment: rebuiltSegment)
        else {
            Issue.record("expected a rebuilt .response entry with a .structure CompactionSegment")
            return
        }
        #expect(rebuiltCompaction.id == "compaction-1")
        #expect(rebuiltCompaction.content == content)
        #expect(rebuiltCompaction.content.pendingRuns == [Self.fixturePendingRun])
        #expect(rebuilt == original)
    }

    // MARK: - Recording-mirror round trip and default-argument restoration fixtures

    /// A ``LanguageModelSessionBackend`` whose "SDK transcript" is entirely
    /// test-controlled, mirroring ``CompactionSpikeTests``'s `SpikeBackend`:
    /// `respond`/`streamResponse` never mutate ``entries`` themselves, so a
    /// test sets ``entries`` to a synthesized transcript containing a
    /// ``CompactionSegment`` *before* calling `respond`, and the chokepoint's
    /// diff persists exactly that as new.
    ///
    /// `@unchecked Sendable` is safe because every access is sequential,
    /// driven by this suite's single awaited `@MainActor` test methods, one
    /// call at a time.
    private final class MutableEntriesBackend: LanguageModelSessionBackend, @unchecked Sendable {
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
            let fork = MutableEntriesBackend()
            fork.entries = entries
            return fork
        }

        func transcriptEntries() -> [Transcript.Entry] { entries }

        func usageTokenCounts() -> (input: Int, output: Int)? { nil }
    }

    /// A ``LoadedLLMContainer`` that always vends the one test-supplied
    /// ``MutableEntriesBackend`` from `makeSession(instructions:)`, and seeds
    /// it from a given transcript's entries for `makeSession(transcript:)`
    /// (the reconstruction path a fresh "restart" router drives).
    private struct MutableEntriesLLMContainer: LoadedLLMContainer {
        let backend: MutableEntriesBackend

        func makeSession(instructions: String?) -> any LanguageModelSessionBackend { backend }

        func makeSession(transcript: Transcript) -> any LanguageModelSessionBackend {
            backend.entries = Array(transcript)
            return backend
        }
    }

    /// The synthesized transcript a `Summarization` stage would produce: the
    /// original instructions, a folded old turn compaction subsequently
    /// replaces, and a synthesized summary `.response` entry carrying both a
    /// text segment and its ``CompactionSegment``.
    private static func makeSynthesizedTranscript() -> [Transcript.Entry] {
        let content = Self.makeContent(
            liveWindowEntryIds: ["instr-1", "summary-1"],
            foldedEntryIds: ["old-prompt-1", "old-response-1"]
        )
        return [
            .instructions(
                Transcript.Instructions(
                    id: "instr-1",
                    segments: [.text(Transcript.TextSegment(id: "instr-text-1", content: "you are a helpful assistant"))],
                    toolDefinitions: []
                )
            ),
            .response(
                Transcript.Response(
                    id: "summary-1",
                    segments: [
                        .text(Transcript.TextSegment(id: "summary-text-1", content: "Summary: prior turns folded.")),
                        CompactionSegment(id: "compaction-1", content: content).transcriptSegment,
                    ]
                )
            ),
        ]
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
            .appendingPathComponent("CompactionSegmentTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func makeRouter(
        id: ULID = .generate(),
        container: any LoadedLLMContainer,
        recorder: any TranscriptRecorder,
        cacheDir: URL,
        recordingsDir: URL
    ) -> Router {
        Router(
            id: id,
            cacheDir: cacheDir,
            recordingsDir: recordingsDir,
            recorder: recorder,
            probe: StubProbe(chip: "Apple Test", totalRAM: 64 << 30, recommendedMaxWorkingSetSize: 48 << 30),
            metadataSource: StubMetadataSource(raw: rawMetadata),
            loader: StubModelLoader(container: container, dimension: stubDimension)
        )
    }

    // MARK: - Recording-mirror round trip (effectiveTranscript)

    @Test("a synthesized transcript carrying a CompactionSegment records through the mirror and reconstructs identically through effectiveTranscript")
    @MainActor
    func compactionSegmentRoundTripsThroughRecordingMirror() async throws {
        let cacheDir = Self.makeTempDir()
        let recordingsDir = Self.makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: cacheDir)
            try? FileManager.default.removeItem(at: recordingsDir)
        }

        let synthesized = Self.makeSynthesizedTranscript()
        let backend = MutableEntriesBackend()
        backend.entries = synthesized
        let container = MutableEntriesLLMContainer(backend: backend)
        let router = Self.makeRouter(
            container: container,
            recorder: JSONLRecorder(directory: recordingsDir),
            cacheDir: cacheDir,
            recordingsDir: recordingsDir
        )
        let profile = try await router.resolve(profile: Self.profile, reporting: ResolutionProgress())

        let session = profile.standard.makeSession()
        _ = try await session.respond(to: "irrelevant — this turn exists only to trigger the recording chokepoint")

        let tree = try TranscriptTree.load(under: RouterTestFixtures.routerDirectory(routerId: router.id, recordingsDir: recordingsDir))
        // No caller setup at all: the segment rebuilds from its own persisted
        // schema name.
        let reconstructed = Array(try tree.effectiveTranscript(forSession: session.id))

        #expect(reconstructed == synthesized)
        guard case .response(let response) = reconstructed.last,
            case .structure(let segment) = response.segments.last,
            let compaction = try CompactionSegment(structuredSegment: segment)
        else {
            Issue.record("expected the reconstructed summary entry to carry a .structure CompactionSegment")
            return
        }
        #expect(compaction.content.foldedEntryIds == ["old-prompt-1", "old-response-1"])
        #expect(compaction.content.liveWindowEntryIds == ["instr-1", "summary-1"])
        #expect(compaction.content.pendingRuns == [Self.fixturePendingRun])
    }

    // MARK: - restoreSessionTree

    @Test("restoring a session tree containing a CompactionSegment succeeds with no caller configuration")
    @MainActor
    func restoreSessionTreeRestoresCompactionSegment() async throws {
        let cacheDir = Self.makeTempDir()
        let recordingsDir = Self.makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: cacheDir)
            try? FileManager.default.removeItem(at: recordingsDir)
        }

        let synthesized = Self.makeSynthesizedTranscript()
        let backend = MutableEntriesBackend()
        backend.entries = synthesized
        let container1 = MutableEntriesLLMContainer(backend: backend)
        let router1 = Self.makeRouter(
            container: container1,
            recorder: JSONLRecorder(directory: recordingsDir),
            cacheDir: cacheDir,
            recordingsDir: recordingsDir
        )
        let profile1 = try await router1.resolve(profile: Self.profile, reporting: ResolutionProgress())

        let root = profile1.standard.makeSession()
        _ = try await root.respond(to: "irrelevant — this turn exists only to trigger the recording chokepoint")

        // "Fresh process": a second, independently constructed Router/profile
        // pointed at the same router id and recordings directory — mirrors
        // SessionTreeRestorationTests' own restart simulation. Its container
        // never needs the mutable-entries capability: restoration only ever
        // calls its `makeSession(transcript:)`, which seeds a plain backend
        // from the given (already-reconstructed) transcript.
        let container2 = MutableEntriesLLMContainer(backend: MutableEntriesBackend())
        let router2 = Self.makeRouter(
            id: router1.id,
            container: container2,
            recorder: JSONLRecorder(directory: recordingsDir),
            cacheDir: cacheDir,
            recordingsDir: recordingsDir
        )
        let profile2 = try await router2.resolve(profile: Self.profile, reporting: ResolutionProgress())

        // No caller setup at all: the segment rebuilds from its own persisted
        // schema name.
        let restored = try await profile2.standard.restoreSessionTree(root: root.id)

        #expect(restored.root.id == root.id)
        let restoredTranscript = Array(
            try TranscriptTree.load(under: RouterTestFixtures.routerDirectory(routerId: router1.id, recordingsDir: recordingsDir))
                .effectiveTranscript(forSession: root.id)
        )
        #expect(restoredTranscript == synthesized)
    }

    // MARK: - makeLanguageModel(resuming:)

    @Test("resuming a session whose recorded transcript carries a CompactionSegment succeeds with no caller configuration")
    @MainActor
    func makeLanguageModelResumingRestoresCompactionSegment() async throws {
        let cacheDir = Self.makeTempDir()
        let recordingsDir = Self.makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: cacheDir)
            try? FileManager.default.removeItem(at: recordingsDir)
        }

        let router = Self.makeRouter(
            container: UndrivenLanguageModelContainer(),
            recorder: JSONLRecorder(directory: recordingsDir),
            cacheDir: cacheDir,
            recordingsDir: recordingsDir
        )
        let profile = try await router.resolve(profile: Self.profile, reporting: ResolutionProgress())

        // Record a synthesized transcript carrying a CompactionSegment onto a
        // fresh handle by syncing directly — sync(_:) diffs any given
        // Transcript against last-seen and records what's new, so this needs
        // no real model turn (see RecordingLanguageModel.sync(_:)'s doc
        // comment: "typically session.transcript at turn end", but any
        // Transcript works).
        let parentHandle = profile.standard.makeLanguageModel()
        let synthesized = Self.makeSynthesizedTranscript()
        await parentHandle.sync(Transcript(entries: synthesized))

        // No caller setup at all: the segment rebuilds from its own persisted
        // schema name.
        let (_, restored) = try profile.standard.makeLanguageModel(resuming: parentHandle.state.sessionId)

        #expect(Array(restored) == synthesized)
        guard case .response(let response) = Array(restored).last,
            case .structure(let segment) = response.segments.last,
            let compaction = try CompactionSegment(structuredSegment: segment)
        else {
            Issue.record("expected the resumed transcript's summary entry to carry a .structure CompactionSegment")
            return
        }
        #expect(compaction.content.promptName == "default")
        #expect(compaction.content.pendingRuns == [Self.fixturePendingRun])
    }

    // MARK: - A consumer's own segment type lives alongside the router's

    private struct Note: Codable, Equatable, Sendable {
        var body: String
    }

    private struct NoteSegment: PersistableStructuredSegment, Equatable, CustomStringConvertible {
        let id: String
        let content: Note

        var description: String { "Note: \(content.body)" }
    }

    @Test("a consumer's own segment type and the router's CompactionSegment both round-trip, each keyed on its own schema name")
    func consumerSegmentAndCompactionSegmentBothRoundTrip() throws {
        let compactionContent = Self.makeContent()
        let compactionEntry = Transcript.Entry.response(
            Transcript.Response(segments: [CompactionSegment(id: "c1", content: compactionContent).transcriptSegment])
        )
        let noteEntry = Transcript.Entry.response(
            Transcript.Response(segments: [NoteSegment(id: "n1", content: Note(body: "hello")).transcriptSegment])
        )
        #expect(CompactionSegment.schemaName != NoteSegment.schemaName)

        for (entry, assertion): (Transcript.Entry, (Transcript.Entry) -> Void) in [
            (compactionEntry, { rebuilt in
                guard case .response(let response) = rebuilt, case .structure(let segment) = response.segments.first,
                    let compaction = try? CompactionSegment(structuredSegment: segment)
                else {
                    Issue.record("expected a rebuilt .response entry with a .structure CompactionSegment")
                    return
                }
                #expect(compaction.content == compactionContent)
            }),
            (noteEntry, { rebuilt in
                guard case .response(let response) = rebuilt, case .structure(let segment) = response.segments.first,
                    let note = try? NoteSegment(structuredSegment: segment)
                else {
                    Issue.record("expected a rebuilt .response entry with a .structure NoteSegment")
                    return
                }
                #expect(note.content == Note(body: "hello"))
            }),
        ] {
            let (kind, payload, _) = TranscriptEntryMapper.event(from: entry)
            let rebuilt = try TranscriptEntryMapper.entry(from: payload, kind: kind)
            assertion(rebuilt)
        }
    }
}
