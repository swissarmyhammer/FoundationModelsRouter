import Foundation
import FoundationModels
import Testing

@testable import FoundationModelsRouter

/// Exercises task vchknhc (compaction epic — compaction_plan.md §1.2,
/// build-order step 2): ``CompactionSegment``, the ``PersistableCustomSegment``
/// carrying one compaction's fold metadata, and its default registration in
/// ``CustomSegmentRegistry/routerDefault``.
///
/// Everything runs hermetically — stub `LoadedLLMContainer`s and backends, a
/// `JSONLRecorder` writing into a temp directory — so the suite needs no
/// network and no GPU. Builds on the entry-id findings from the compaction
/// spike (task dws80ms, ``CompactionSpikeTests``): a synthesized `.response`
/// entry carrying a `.custom` segment round-trips through the recording
/// mirror with no production changes needed for the mapper/reconstruction
/// side; what this suite adds is the concrete ``CompactionSegment`` type
/// itself and proof that every reconstruction entry point's *default*
/// `registry:` argument now knows about it, so a compacted session restores
/// with zero consumer configuration.
@Suite("CompactionSegment: Codable round trip, recording-mirror round trip, and default-registry restoration")
struct CompactionSegmentTests {
    // MARK: - Fixture content

    private static func makeContent(
        liveWindowEntryIds: [String] = ["summary-1", "tail-prompt-1", "tail-response-1"],
        foldedEntryIds: [String] = ["old-instr-1", "old-prompt-1", "old-response-1"],
        tokensBefore: Int = 12_000,
        tokensAfter: Int = 3_000,
        stagesApplied: [String] = ["ToolOutputElision", "TurnTruncation", "Summarization"],
        promptName: String = "default"
    ) -> CompactionSegment.Content {
        CompactionSegment.Content(
            liveWindowEntryIds: liveWindowEntryIds,
            foldedEntryIds: foldedEntryIds,
            tokensBefore: tokensBefore,
            tokensAfter: tokensAfter,
            stagesApplied: stagesApplied,
            promptName: promptName
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
    }

    @Test("CompactionSegment's default typeDiscriminator is the type's fully-qualified name")
    func defaultTypeDiscriminatorIsFullyQualifiedName() {
        #expect(CompactionSegment.typeDiscriminator == String(reflecting: CompactionSegment.self))
    }

    // MARK: - Mapper round trip: a summary entry carrying text + CompactionSegment

    @Test("a synthesized summary .response entry carrying a text segment and a CompactionSegment round-trips through TranscriptEntryMapper using CustomSegmentRegistry.routerDefault")
    func compactionSegmentRoundTripsThroughMapper() throws {
        let content = Self.makeContent()
        let segment = CompactionSegment(id: "compaction-1", content: content)
        let original = Transcript.Entry.response(
            Transcript.Response(
                id: "summary-1",
                assetIDs: [],
                segments: [
                    .text(Transcript.TextSegment(id: "summary-text-1", content: "Summary: ...")),
                    .custom(segment),
                ]
            )
        )

        let (kind, payload, text) = TranscriptEntryMapper.event(from: original)
        #expect(kind == .response)
        #expect(text == "Summary: ...")

        let rebuilt = try TranscriptEntryMapper.entry(from: payload, kind: kind, registry: .routerDefault)
        guard case .response(let rebuiltResponse) = rebuilt,
            case .custom(let rebuiltSegment) = rebuiltResponse.segments.last,
            let rebuiltCompaction = rebuiltSegment as? CompactionSegment
        else {
            Issue.record("expected a rebuilt .response entry with a .custom CompactionSegment")
            return
        }
        #expect(rebuiltCompaction.id == "compaction-1")
        #expect(rebuiltCompaction.content == content)
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
                    assetIDs: [],
                    segments: [
                        .text(Transcript.TextSegment(id: "summary-text-1", content: "Summary: prior turns folded.")),
                        .custom(CompactionSegment(id: "compaction-1", content: content)),
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

    private func routerDirectory(routerId: ULID, recordingsDir: URL) -> URL {
        recordingsDir.appendingPathComponent(routerId.description, isDirectory: true)
    }

    // MARK: - Recording-mirror round trip, all-default arguments (effectiveTranscript)

    @Test("a synthesized transcript carrying a CompactionSegment records through the mirror and reconstructs identically through effectiveTranscript's default (routerDefault) registry")
    @MainActor
    func compactionSegmentRoundTripsThroughRecordingMirrorWithDefaultRegistry() async throws {
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

        let tree = try TranscriptTree.load(under: routerDirectory(routerId: router.id, recordingsDir: recordingsDir))
        // No registry argument: exercises effectiveTranscript's default,
        // CustomSegmentRegistry.routerDefault.
        let reconstructed = Array(try tree.effectiveTranscript(forSession: session.id))

        #expect(reconstructed == synthesized)
        guard case .response(let response) = reconstructed.last,
            case .custom(let segment) = response.segments.last,
            let compaction = segment as? CompactionSegment
        else {
            Issue.record("expected the reconstructed summary entry to carry a .custom CompactionSegment")
            return
        }
        #expect(compaction.content.foldedEntryIds == ["old-prompt-1", "old-response-1"])
        #expect(compaction.content.liveWindowEntryIds == ["instr-1", "summary-1"])
    }

    // MARK: - restoreSessionTree, all-default arguments

    @Test("restoring a session tree containing a CompactionSegment through restoreSessionTree's default (routerDefault) registry succeeds with no caller configuration")
    @MainActor
    func restoreSessionTreeWithDefaultArgumentsRestoresCompactionSegment() async throws {
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

        // No registry argument: exercises restoreSessionTree's default,
        // CustomSegmentRegistry.routerDefault.
        let restored = try await profile2.standard.restoreSessionTree(root: root.id)

        #expect(restored.root.id == root.id)
        let restoredTranscript = Array(
            try TranscriptTree.load(under: routerDirectory(routerId: router1.id, recordingsDir: recordingsDir))
                .effectiveTranscript(forSession: root.id)
        )
        #expect(restoredTranscript == synthesized)
    }

    // MARK: - makeLanguageModel(resuming:), all-default arguments

    /// A minimal `LanguageModel` conformer satisfying
    /// ``LoadedLLMContainer/languageModel``'s requirement — never actually
    /// driven in this suite, since the test below only calls
    /// ``RecordingLanguageModel/sync(_:)`` directly with a fabricated
    /// transcript rather than driving a real `LanguageModelSession` turn.
    private struct UndrivenLanguageModel: LanguageModel {
        var capabilities: LanguageModelCapabilities { LanguageModelCapabilities([]) }
        var executorConfiguration: Executor.Configuration { Executor.Configuration() }

        struct Executor: LanguageModelExecutor {
            struct Configuration: Sendable, Hashable {}
            typealias Model = UndrivenLanguageModel

            init(configuration: Configuration) throws {}

            func respond(
                to request: LanguageModelExecutorGenerationRequest,
                model: UndrivenLanguageModel,
                streamingInto channel: LanguageModelExecutorGenerationChannel
            ) async throws {
                fatalError("UndrivenLanguageModel.Executor.respond: never driven in this suite")
            }
        }
    }

    private struct LanguageModelHandleContainer: PlainTranscriptStubContainer {
        func makeSession(instructions: String?) -> any LanguageModelSessionBackend {
            StubSessionBackend()
        }

        var languageModel: any LanguageModel { UndrivenLanguageModel() }
    }

    @Test("resuming a session whose recorded transcript carries a CompactionSegment through makeLanguageModel(resuming:)'s default (routerDefault) registry succeeds with no caller configuration")
    @MainActor
    func makeLanguageModelResumingWithDefaultArgumentsRestoresCompactionSegment() async throws {
        let cacheDir = Self.makeTempDir()
        let recordingsDir = Self.makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: cacheDir)
            try? FileManager.default.removeItem(at: recordingsDir)
        }

        let router = Self.makeRouter(
            container: LanguageModelHandleContainer(),
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

        // No registry argument: exercises makeLanguageModel(resuming:)'s
        // default, CustomSegmentRegistry.routerDefault.
        let (_, restored) = try profile.standard.makeLanguageModel(resuming: parentHandle.state.sessionId)

        #expect(Array(restored) == synthesized)
        guard case .response(let response) = Array(restored).last,
            case .custom(let segment) = response.segments.last,
            let compaction = segment as? CompactionSegment
        else {
            Issue.record("expected the resumed transcript's summary entry to carry a .custom CompactionSegment")
            return
        }
        #expect(compaction.content.promptName == "default")
    }

    // MARK: - Duplicate/consumer registration does not trap

    private struct Note: Codable, Equatable, Sendable {
        var body: String
    }

    private struct NoteSegment: PersistableCustomSegment, Equatable, CustomStringConvertible {
        let id: String
        let content: Note

        var description: String { "Note: \(content.body)" }
    }

    @Test("re-registering CompactionSegment on top of CustomSegmentRegistry.routerDefault does not trap, and it still round-trips")
    func reregisteringCompactionSegmentOnRouterDefaultDoesNotTrap() throws {
        var registry = CustomSegmentRegistry.routerDefault
        registry.register(CompactionSegment.self)

        let content = Self.makeContent()
        let entry = Transcript.Entry.response(
            Transcript.Response(assetIDs: [], segments: [.custom(CompactionSegment(id: "c1", content: content))])
        )
        let (kind, payload, _) = TranscriptEntryMapper.event(from: entry)
        let rebuilt = try TranscriptEntryMapper.entry(from: payload, kind: kind, registry: registry)
        guard case .response(let response) = rebuilt, case .custom(let segment) = response.segments.first,
            let compaction = segment as? CompactionSegment
        else {
            Issue.record("expected a rebuilt .response entry with a .custom CompactionSegment")
            return
        }
        #expect(compaction.content == content)
    }

    @Test("a consumer registering their own custom segment alongside CustomSegmentRegistry.routerDefault does not trap, and both segments round-trip")
    func consumerRegisteringOwnSegmentAlongsideRouterDefaultDoesNotTrap() throws {
        var registry = CustomSegmentRegistry.routerDefault
        registry.register(NoteSegment.self)

        let compactionContent = Self.makeContent()
        let compactionEntry = Transcript.Entry.response(
            Transcript.Response(assetIDs: [], segments: [.custom(CompactionSegment(id: "c1", content: compactionContent))])
        )
        let noteEntry = Transcript.Entry.response(
            Transcript.Response(assetIDs: [], segments: [.custom(NoteSegment(id: "n1", content: Note(body: "hello")))])
        )

        for (entry, assertion): (Transcript.Entry, (Transcript.Entry) -> Void) in [
            (compactionEntry, { rebuilt in
                guard case .response(let response) = rebuilt, case .custom(let segment) = response.segments.first,
                    let compaction = segment as? CompactionSegment
                else {
                    Issue.record("expected a rebuilt .response entry with a .custom CompactionSegment")
                    return
                }
                #expect(compaction.content == compactionContent)
            }),
            (noteEntry, { rebuilt in
                guard case .response(let response) = rebuilt, case .custom(let segment) = response.segments.first,
                    let note = segment as? NoteSegment
                else {
                    Issue.record("expected a rebuilt .response entry with a .custom NoteSegment")
                    return
                }
                #expect(note.content == Note(body: "hello"))
            }),
        ] {
            let (kind, payload, _) = TranscriptEntryMapper.event(from: entry)
            let rebuilt = try TranscriptEntryMapper.entry(from: payload, kind: kind, registry: registry)
            assertion(rebuilt)
        }
    }
}
