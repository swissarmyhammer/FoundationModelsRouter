import Foundation
import Testing

@testable import FoundationModelsRouter

/// Exercises the session index: `recordings/<routerId>/sessions.jsonl` gains
/// one appended record per session at creation, written at the two creation
/// points that know the facts — root vending
/// (``RoutedModel/makeSession(instructions:workingDirectory:)`` /
/// ``RoutedModel/makeGuidedSession(grammar:instructions:workingDirectory:)``)
/// and ``RoutedSessionActor/fork(workingDirectory:)`` — making the fork
/// hierarchy first-class, queryable data instead of something implicit in
/// directory nesting.
///
/// Everything runs against stubs — a stub ``ModelLoader``, a canned LLM
/// container backed by ``StubSessionBackend``, and a ``JSONLRecorder``/
/// ``InMemoryRecorder`` writing into a temp directory — so the suite needs no
/// network and no GPU, mirroring ``TranscriptNestingTests``' scaffolding.
@Suite("Session index: sessions.jsonl fork manifest")
struct SessionIndexTests {
    // MARK: - Stub containers

    /// A stand-in for a loaded LLM container that returns canned text, no MLX.
    ///
    /// Forwards `instructions` into the backend's synthetic transcript when
    /// `forwardInstructions` is set, so a test can model a session whose SDK
    /// transcript opens with a leading `.instructions` entry the way a real
    /// `LanguageModelSession` given instructions would.
    private struct CannedLLMContainer: LoadedLLMContainer {
        let text: String
        var forwardInstructions = false

        func makeSession(instructions: String?) -> any LanguageModelSessionBackend {
            StubSessionBackend(responseText: text, instructions: forwardInstructions ? instructions : nil)
        }
    }

    /// A stand-in for a loaded embedder container, no MLX.
    private struct StubEmbeddingContainer: LoadedEmbeddingContainer {
        let dimension: Int
        func embed(texts: [String]) async throws -> [[Float]] {
            texts.map { _ in [Float](repeating: 0.5, count: dimension) }
        }
    }

    // MARK: - Stubs

    private struct StubProbe: MachineProbe {
        let chip: String
        let totalRAM: Int64
        let recommendedMaxWorkingSetSize: Int64
    }

    private struct StubMetadataSource: MetadataSource {
        let raw: RawRepoMetadata
        func fetchRawMetadata(repo: String, revision: String?) async throws -> RawRepoMetadata { raw }
    }

    /// A ``ModelLoader`` that returns canned containers with no download or GPU.
    private struct StubModelLoader: ModelLoader {
        let dimension: Int
        let text: String
        var forwardInstructions = false

        func loadLLM(
            ref: ModelRef,
            slot: ModelSlot,
            context: Int,
            reporting: @escaping @Sendable (DownloadProgress) -> Void
        ) async throws -> any LoadedLLMContainer {
            reporting(DownloadProgress(bytesDownloaded: 1, bytesTotal: 1))
            return CannedLLMContainer(text: text, forwardInstructions: forwardInstructions)
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
    private static let cannedText = "canned response"

    private static func makeTempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SessionIndexTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Builds a router wired with the stubs, an explicit recorder, and a durable
    /// recordings root (so vended sessions nest their transcripts — and index —
    /// under it).
    ///
    /// - Parameters:
    ///   - forwardInstructions: When `true`, a vended session's instructions
    ///     flow into its ``StubSessionBackend``'s synthetic transcript as a
    ///     leading `.instructions` entry, modeling an instructed real
    ///     `LanguageModelSession`.
    ///   - recordingLevel: How much to record; defaults to ``RecordingLevel/full``.
    private static func makeRouter(
        recorder: any TranscriptRecorder,
        cacheDir: URL,
        recordingsDir: URL,
        forwardInstructions: Bool = false,
        maxConcurrentForks: Int = 4,
        recordingLevel: RecordingLevel = .full
    ) -> Router {
        Router(
            maxConcurrentForks: maxConcurrentForks,
            cacheDir: cacheDir,
            recordingsDir: recordingsDir,
            recorder: recorder,
            recordingLevel: recordingLevel,
            probe: StubProbe(chip: "Apple Test", totalRAM: 64 << 30, recommendedMaxWorkingSetSize: 48 << 30),
            metadataSource: StubMetadataSource(raw: rawMetadata),
            loader: StubModelLoader(dimension: stubDimension, text: cannedText, forwardInstructions: forwardInstructions)
        )
    }

    /// Reads every session index record for `router`'s recording root.
    private func records(router: Router, recordingsDir: URL) throws -> [SessionIndexRecord] {
        try SessionIndexWriter.read(
            under: recordingsDir.appendingPathComponent(router.id.description, isDirectory: true)
        )
    }

    // MARK: - Root + forks produce records with the correct lineage

    @Test("root + two forks + grandfork produce 4 records with correct parentId chain and paths")
    @MainActor
    func rootTwoForksAndGrandforkProduceFourRecords() async throws {
        let cacheDir = Self.makeTempDir()
        let recordingsDir = Self.makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: cacheDir)
            try? FileManager.default.removeItem(at: recordingsDir)
        }

        let router = Self.makeRouter(
            recorder: JSONLRecorder(directory: recordingsDir),
            cacheDir: cacheDir,
            recordingsDir: recordingsDir
        )
        let profile = try await router.resolve(profile: Self.profile, reporting: ResolutionProgress())

        let root = profile.standard.makeSession()
        let forkA = try await root.fork(workingDirectory: nil)
        let forkB = try await root.fork(workingDirectory: nil)
        let grandfork = try await forkA.fork(workingDirectory: nil)

        let recorded = try records(router: router, recordingsDir: recordingsDir)
        #expect(recorded.count == 4)

        let bySessionId = Dictionary(uniqueKeysWithValues: recorded.map { ($0.sessionId, $0) })

        let rootRecord = try #require(bySessionId[root.id])
        #expect(rootRecord.parentId == nil)
        #expect(rootRecord.forkedAtEntryCount == 0)
        #expect(rootRecord.path == root.id.description)

        let forkARecord = try #require(bySessionId[forkA.id])
        #expect(forkARecord.parentId == root.id)
        #expect(forkARecord.path == "\(root.id.description)/\(forkA.id.description)")

        let forkBRecord = try #require(bySessionId[forkB.id])
        #expect(forkBRecord.parentId == root.id)
        #expect(forkBRecord.path == "\(root.id.description)/\(forkB.id.description)")

        let grandforkRecord = try #require(bySessionId[grandfork.id])
        #expect(grandforkRecord.parentId == forkA.id)
        #expect(grandforkRecord.path == "\(root.id.description)/\(forkA.id.description)/\(grandfork.id.description)")

        _ = forkB
    }

    // MARK: - forkedAtEntryCount baseline

    @Test("an uninstructed session's fork taken after one turn records forkedAtEntryCount == 2")
    @MainActor
    func uninstructedForkAfterOneTurnRecordsForkedAtEntryCountOfTwo() async throws {
        let cacheDir = Self.makeTempDir()
        let recordingsDir = Self.makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: cacheDir)
            try? FileManager.default.removeItem(at: recordingsDir)
        }

        // `forwardInstructions: false` (the default) and no `instructions:`
        // passed to `makeSession()` below means the stub backend's synthetic
        // transcript opens empty (no leading `.instructions` entry) — the
        // assumption this test's exact count depends on. An *instructed*
        // session would open with one extra `.instructions` entry, making a
        // fork after one turn read `forkedAtEntryCount == 3` instead.
        let router = Self.makeRouter(
            recorder: JSONLRecorder(directory: recordingsDir),
            cacheDir: cacheDir,
            recordingsDir: recordingsDir
        )
        let profile = try await router.resolve(profile: Self.profile, reporting: ResolutionProgress())

        let root = profile.standard.makeSession()
        _ = try await root.respond(to: "hello")

        let fork = try await root.fork(workingDirectory: nil)

        let recorded = try records(router: router, recordingsDir: recordingsDir)
        let forkRecord = try #require(recorded.first { $0.sessionId == fork.id })
        // One turn == one `.prompt` entry + one `.response` entry == 2.
        #expect(forkRecord.forkedAtEntryCount == 2)
    }

    // MARK: - Guided session grammar

    @Test("a guided session's index record carries its grammar source; forks inherit it")
    @MainActor
    func guidedSessionRecordsGrammarSourceAndForkInheritsIt() async throws {
        let cacheDir = Self.makeTempDir()
        let recordingsDir = Self.makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: cacheDir)
            try? FileManager.default.removeItem(at: recordingsDir)
        }

        let router = Self.makeRouter(
            recorder: JSONLRecorder(directory: recordingsDir),
            cacheDir: cacheDir,
            recordingsDir: recordingsDir
        )
        let profile = try await router.resolve(profile: Self.profile, reporting: ResolutionProgress())

        let grammarSource = #"{"type":"object"}"#
        let root = profile.standard.makeGuidedSession(grammar: .jsonSchema(grammarSource))
        let fork = try await root.fork(workingDirectory: nil)

        let recorded = try records(router: router, recordingsDir: recordingsDir)
        let rootRecord = try #require(recorded.first { $0.sessionId == root.id })
        let forkRecord = try #require(recorded.first { $0.sessionId == fork.id })

        #expect(rootRecord.grammar == grammarSource)
        #expect(forkRecord.grammar == grammarSource)
    }

    // MARK: - Instructions inheritance

    @Test("a root session's index record carries its instructions; a fork inherits them")
    @MainActor
    func rootRecordsInstructionsAndForkInheritsThem() async throws {
        let cacheDir = Self.makeTempDir()
        let recordingsDir = Self.makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: cacheDir)
            try? FileManager.default.removeItem(at: recordingsDir)
        }

        let router = Self.makeRouter(
            recorder: JSONLRecorder(directory: recordingsDir),
            cacheDir: cacheDir,
            recordingsDir: recordingsDir
        )
        let profile = try await router.resolve(profile: Self.profile, reporting: ResolutionProgress())

        let instructions = "You are a terse assistant."
        let root = profile.standard.makeSession(instructions: instructions)
        let fork = try await root.fork(workingDirectory: nil)

        let recorded = try records(router: router, recordingsDir: recordingsDir)
        let rootRecord = try #require(recorded.first { $0.sessionId == root.id })
        let forkRecord = try #require(recorded.first { $0.sessionId == fork.id })

        #expect(rootRecord.instructions == instructions)
        #expect(forkRecord.instructions == instructions)
    }

    // MARK: - Concurrent forks

    @Test("concurrent forks each append exactly one record, with no lost or duplicated lines")
    @MainActor
    func concurrentForksEachAppendExactlyOneRecord() async throws {
        let cacheDir = Self.makeTempDir()
        let recordingsDir = Self.makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: cacheDir)
            try? FileManager.default.removeItem(at: recordingsDir)
        }

        let forkCount = 20
        let router = Self.makeRouter(
            recorder: JSONLRecorder(directory: recordingsDir),
            cacheDir: cacheDir,
            recordingsDir: recordingsDir,
            maxConcurrentForks: forkCount
        )
        let profile = try await router.resolve(profile: Self.profile, reporting: ResolutionProgress())

        let root = profile.standard.makeSession()

        let forkIds = try await withThrowingTaskGroup(of: ULID.self) { group in
            for _ in 0..<forkCount {
                group.addTask {
                    let fork = try await root.fork(workingDirectory: nil)
                    return fork.id
                }
            }
            var ids: [ULID] = []
            for try await id in group {
                ids.append(id)
            }
            return ids
        }

        let recorded = try records(router: router, recordingsDir: recordingsDir)
        // The root plus every concurrently-admitted fork, each exactly once.
        #expect(recorded.count == forkCount + 1)
        #expect(Set(recorded.map(\.sessionId)).count == forkCount + 1)
        for id in forkIds {
            #expect(recorded.contains { $0.sessionId == id })
        }
    }

    // MARK: - RecordingLevel.off

    @Test("RecordingLevel.off leaves no sessions.jsonl on disk")
    @MainActor
    func recordingLevelOffLeavesNoSessionsIndexFile() async throws {
        let cacheDir = Self.makeTempDir()
        let recordingsDir = Self.makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: cacheDir)
            try? FileManager.default.removeItem(at: recordingsDir)
        }

        let router = Self.makeRouter(
            recorder: JSONLRecorder(directory: recordingsDir),
            cacheDir: cacheDir,
            recordingsDir: recordingsDir,
            recordingLevel: .off
        )
        let profile = try await router.resolve(profile: Self.profile, reporting: ResolutionProgress())

        let root = profile.standard.makeSession()
        _ = try await root.respond(to: "hello")
        let fork = try await root.fork(workingDirectory: nil)
        _ = try await fork.respond(to: "hi")

        let indexFileURL = recordingsDir
            .appendingPathComponent(router.id.description, isDirectory: true)
            .appendingPathComponent("sessions.jsonl", isDirectory: false)
        #expect(!FileManager.default.fileExists(atPath: indexFileURL.path))
    }

    // MARK: - RecordingLevel.metadataOnly

    @Test("RecordingLevel.metadataOnly still writes the session index — only turn content is trimmed, not the index")
    @MainActor
    func metadataOnlyRecordingStillWritesSessionIndex() async throws {
        let cacheDir = Self.makeTempDir()
        let recordingsDir = Self.makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: cacheDir)
            try? FileManager.default.removeItem(at: recordingsDir)
        }

        let router = Self.makeRouter(
            recorder: JSONLRecorder(directory: recordingsDir),
            cacheDir: cacheDir,
            recordingsDir: recordingsDir,
            recordingLevel: .metadataOnly
        )
        let profile = try await router.resolve(profile: Self.profile, reporting: ResolutionProgress())

        let root = profile.standard.makeSession()
        let fork = try await root.fork(workingDirectory: nil)

        let recorded = try records(router: router, recordingsDir: recordingsDir)
        #expect(recorded.count == 2)
        #expect(recorded.contains { $0.sessionId == root.id && $0.parentId == nil })
        #expect(recorded.contains { $0.sessionId == fork.id && $0.parentId == root.id })
    }

    // MARK: - Best-effort write failure

    @Test("a forced session index write failure is logged and swallowed, never surfaced into fork/generation")
    func writeFailureIsLoggedAndSwallowed() async throws {
        // A regular file standing where the writer's directory should be: every
        // append's directory-create fails, so the write must be swallowed —
        // mirrors RecorderTests.jsonlSwallowsWriteError for JSONLRecorder.
        let blocker = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: false)
        try Data().write(to: blocker)
        defer { try? FileManager.default.removeItem(at: blocker) }

        let writer = SessionIndexWriter(directory: blocker)
        let record = SessionIndexRecord(
            sessionId: .generate(),
            parentId: nil,
            path: "root",
            forkedAtEntryCount: 0,
            slot: .standard,
            model: "org/model-a",
            instructions: nil,
            grammar: nil,
            createdAt: Date()
        )
        // Must return normally (non-throwing) and never crash.
        await writer.append(record)

        // The blocking file is untouched: nothing was written through it.
        let attributes = try FileManager.default.attributesOfItem(atPath: blocker.path)
        #expect((attributes[.type] as? FileAttributeType) == .typeRegular)
        #expect(try Data(contentsOf: blocker).isEmpty)
    }

    @Test("a session whose index writer can never write still forks and generates normally")
    @MainActor
    func sessionWithUnwritableIndexStillForksAndGenerates() async throws {
        let cacheDir = Self.makeTempDir()
        // The recordings root itself is a regular file, so every write under it —
        // both the session index's and the transcript recorder's, since a
        // session's `recordingDirectory` nests under this same root — fails to
        // create its directory. Best-effort failure must never surface into
        // `fork()`/`respond()`, which must still succeed and return the model's
        // real output regardless.
        let recordingsDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SessionIndexTests-blocker-\(UUID().uuidString)", isDirectory: false)
        try Data().write(to: recordingsDir)
        defer {
            try? FileManager.default.removeItem(at: cacheDir)
            try? FileManager.default.removeItem(at: recordingsDir)
        }

        let router = Self.makeRouter(
            recorder: JSONLRecorder(directory: recordingsDir),
            cacheDir: cacheDir,
            recordingsDir: recordingsDir
        )
        let profile = try await router.resolve(profile: Self.profile, reporting: ResolutionProgress())

        let root = profile.standard.makeSession()
        let response = try await root.respond(to: "hello")
        #expect(response == Self.cannedText)

        let fork = try await root.fork(workingDirectory: nil)
        let forkResponse = try await fork.respond(to: "hi")
        #expect(forkResponse == Self.cannedText)
    }

    // MARK: - read(under:) dedup

    @Test("read(under:) dedupes a sessions.jsonl fixture with a duplicate sessionId, keeping the first record")
    func readDedupesBySessionIdKeepingFirstRecord() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let writer = SessionIndexWriter(directory: dir)
        let sessionId = ULID.generate()
        // The first and duplicate records carry distinct `model`/`createdAt`
        // values (not just distinct `path`s) so the assertions below prove
        // dedup keeps the *first record's* fields intact through the
        // JSON round-trip, not merely its `path`.
        let firstCreatedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let first = SessionIndexRecord(
            sessionId: sessionId,
            parentId: nil,
            path: "first",
            forkedAtEntryCount: 0,
            slot: .standard,
            model: "org/model-a",
            instructions: nil,
            grammar: nil,
            createdAt: firstCreatedAt
        )
        let duplicate = SessionIndexRecord(
            sessionId: sessionId,
            parentId: nil,
            path: "second",
            forkedAtEntryCount: 0,
            slot: .standard,
            model: "org/model-b",
            instructions: nil,
            grammar: nil,
            createdAt: Date(timeIntervalSince1970: 1_700_000_500)
        )
        await writer.append(first)
        await writer.append(duplicate)

        let decoded = try SessionIndexWriter.read(under: dir)
        #expect(decoded.count == 1)
        #expect(decoded.first?.path == "first")
        #expect(decoded.first?.model == "org/model-a")
        #expect(decoded.first?.createdAt == firstCreatedAt)
    }
}
