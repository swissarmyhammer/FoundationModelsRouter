import Foundation
import FoundationModels
import Testing

@testable import FoundationModelsRouter

/// Exercises the write-once per-session sidecar: every session's own directory
/// gains exactly one `session.json` at creation, carrying only the primary
/// facts about that session — `slot`, `model`, the resolved `context`,
/// `instructions`, `grammar`, `recordingLevel`, and, for a fork, the
/// `forkedAtEntryCount` cut point. Lineage and creation time are stated by the
/// directory nesting and the session ULID, so they are deliberately absent.
///
/// Everything runs against stubs — a stub ``ModelLoader``, a canned LLM
/// container backed by ``StubSessionBackend``, and a ``JSONLRecorder`` writing
/// into a temp directory — so the suite needs no network and no GPU, mirroring
/// ``TranscriptNestingTests``' scaffolding.
@Suite("Session sidecar: write-once session.json per session")
struct SessionSidecarTests {
    // MARK: - Stub containers

    /// A stand-in for a loaded LLM container that returns canned text, no MLX.
    private struct CannedLLMContainer: PlainTranscriptStubContainer {
        let text: String

        func makeSession(instructions: String?) -> any LanguageModelSessionBackend {
            StubSessionBackend(responseText: text)
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

        func loadLLM(
            ref: ModelRef,
            slot: ModelSlot,
            context: Int,
            reporting: @escaping @Sendable (DownloadProgress) -> Void
        ) async throws -> any LoadedLLMContainer {
            reporting(DownloadProgress(bytesDownloaded: 1, bytesTotal: 1))
            return CannedLLMContainer(text: text)
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

    private static let configJSON = Data(
        """
        {
            "num_hidden_layers": 2,
            "num_attention_heads": 8,
            "num_key_value_heads": 2,
            "head_dim": 16,
            "hidden_size": 128
        }
        """.utf8)

    private static let treeJSON = Data(
        """
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
            .appendingPathComponent("SessionSidecarTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Builds a router wired with the stubs, an explicit recorder, and a durable
    /// recordings root (so vended sessions nest their transcripts — and
    /// sidecars — under it).
    private static func makeRouter(
        recorder: any TranscriptRecorder,
        cacheDir: URL,
        recordingsDir: URL,
        maxConcurrentForks: Int = 4,
        recordingLevel: RecordingLevel = .full
    ) -> Router {
        Router(
            maxConcurrentForks: maxConcurrentForks,
            cacheDir: cacheDir,
            recordingsDir: recordingsDir,
            recorder: recorder,
            recordingLevel: recordingLevel,
            probe: StubProbe(
                chip: "Apple Test", totalRAM: 64 << 30, recommendedMaxWorkingSetSize: 48 << 30),
            metadataSource: StubMetadataSource(raw: rawMetadata),
            loader: StubModelLoader(dimension: stubDimension, text: cannedText)
        )
    }

    /// A sample sidecar with every field populated, for round-trip coverage.
    private static func sampleSidecar(forkedAtEntryCount: Int?) -> SessionSidecar {
        SessionSidecar(
            slot: .flash,
            model: "org/model-a",
            context: 8_192,
            instructions: "You are terse.",
            grammar: #"{"type":"object"}"#,
            recordingLevel: .metadataOnly,
            forkedAtEntryCount: forkedAtEntryCount,
            profile: SessionSidecar.ResolvedProfile(
                definitionName: "coding",
                standard: "org/std-a",
                flash: "org/flash-a",
                embedding: "org/emb-a",
                context: 8_192
            )
        )
    }

    // MARK: - Codable round-trip

    @Test("every sidecar field survives a write/read round-trip through the on-disk JSON")
    func everyFieldSurvivesAWriteReadRoundTrip() throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let sessionDir = dir.appendingPathComponent(ULID.generate().description, isDirectory: true)
        let original = Self.sampleSidecar(forkedAtEntryCount: 7)
        try SessionSidecar.write(original, to: sessionDir)

        let decoded = try #require(try SessionSidecar.read(in: sessionDir))
        #expect(decoded == original)
    }

    @Test("a root sidecar's absent forkedAtEntryCount round-trips as nil, not as zero")
    func absentForkedAtEntryCountRoundTripsAsNil() throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let sessionDir = dir.appendingPathComponent(ULID.generate().description, isDirectory: true)
        try SessionSidecar.write(Self.sampleSidecar(forkedAtEntryCount: nil), to: sessionDir)

        let decoded = try #require(try SessionSidecar.read(in: sessionDir))
        #expect(decoded.forkedAtEntryCount == nil)
    }

    @Test("reading a directory with no session.json returns nil rather than throwing")
    func readingADirectoryWithNoSidecarReturnsNil() throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        #expect(try SessionSidecar.read(in: dir) == nil)
    }

    @Test("reading an undecodable session.json throws rather than reporting an absent sidecar")
    func readingAnUndecodableSidecarThrows() throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        try Data("not json".utf8).write(
            to: dir.appendingPathComponent("session.json", isDirectory: false))
        #expect(throws: (any Error).self) { try SessionSidecar.read(in: dir) }
    }

    // MARK: - Atomic creation & write-once

    @Test("writing a sidecar creates the session's own directory along with it")
    func writingASidecarCreatesTheSessionDirectory() throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Two levels deep and not yet created, mirroring a fork's directory
        // under a root that has never itself been created.
        let sessionDir =
            dir
            .appendingPathComponent(ULID.generate().description, isDirectory: true)
            .appendingPathComponent(ULID.generate().description, isDirectory: true)
        #expect(!FileManager.default.fileExists(atPath: sessionDir.path))

        try SessionSidecar.write(Self.sampleSidecar(forkedAtEntryCount: 2), to: sessionDir)

        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: sessionDir.path, isDirectory: &isDirectory))
        #expect(isDirectory.boolValue)
        #expect(
            FileManager.default.fileExists(
                atPath: sessionDir.appendingPathComponent("session.json", isDirectory: false).path
            )
        )
    }

    @Test("a sidecar is write-once: a second write throws and leaves the first bytes untouched")
    func aSecondWriteThrowsAndLeavesTheOriginalIntact() throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let sessionDir = dir.appendingPathComponent(ULID.generate().description, isDirectory: true)
        try SessionSidecar.write(Self.sampleSidecar(forkedAtEntryCount: nil), to: sessionDir)
        let fileURL = sessionDir.appendingPathComponent("session.json", isDirectory: false)
        let firstBytes = try Data(contentsOf: fileURL)

        #expect(throws: (any Error).self) {
            try SessionSidecar.write(Self.sampleSidecar(forkedAtEntryCount: 99), to: sessionDir)
        }
        #expect(try Data(contentsOf: fileURL) == firstBytes)
    }

    // MARK: - Root + forks produce one sidecar each, nesting the lineage

    @Test("root + two forks + grandfork each write one sidecar into their own nested directory")
    @MainActor
    func rootTwoForksAndGrandforkEachWriteOneSidecar() async throws {
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

        let routerDir = recordingsDir.appendingPathComponent(router.id.description, isDirectory: true)
        let rootDir = routerDir.appendingPathComponent(root.id.description, isDirectory: true)
        let forkADir = rootDir.appendingPathComponent(forkA.id.description, isDirectory: true)
        let forkBDir = rootDir.appendingPathComponent(forkB.id.description, isDirectory: true)
        let grandforkDir = forkADir.appendingPathComponent(grandfork.id.description, isDirectory: true)

        // Every session's own directory carries exactly one sidecar; the fork
        // lineage is stated by the nesting alone.
        for directory in [rootDir, forkADir, forkBDir, grandforkDir] {
            _ = try #require(try SessionSidecar.read(in: directory))
        }

        // The root is a root: no cut point. Every fork has one.
        #expect(try SessionSidecar.read(in: rootDir)?.forkedAtEntryCount == nil)
        #expect(try SessionSidecar.read(in: forkADir)?.forkedAtEntryCount == 0)
        #expect(try SessionSidecar.read(in: grandforkDir)?.forkedAtEntryCount == 0)

        // Slot and model are the vending handle's.
        let rootSidecar = try #require(try SessionSidecar.read(in: rootDir))
        #expect(rootSidecar.slot == .standard)
        #expect(rootSidecar.model == profile.standard.chosen)
        #expect(rootSidecar.context == profile.standard.resolution.contextTokens)
        #expect(rootSidecar.recordingLevel == .full)
    }

    @Test("a run's whole recording tree holds only session.json and transcript.jsonl files")
    @MainActor
    func aRunWritesOnlySidecarsAndTranscripts() async throws {
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
        _ = try await root.respond(to: "hello")
        let fork = try await root.fork(workingDirectory: nil)
        _ = try await fork.respond(to: "hi")

        let routerDir = recordingsDir.appendingPathComponent(router.id.description, isDirectory: true)
        let rootDir = routerDir.appendingPathComponent(root.id.description, isDirectory: true)
        let forkDir = rootDir.appendingPathComponent(fork.id.description, isDirectory: true)

        #expect(try Set(Self.fileNames(directlyIn: routerDir)) == [root.id.description])
        #expect(
            try Set(Self.fileNames(directlyIn: rootDir)) == [
                "session.json", "transcript.jsonl", fork.id.description,
            ])
        #expect(try Set(Self.fileNames(directlyIn: forkDir)) == ["session.json", "transcript.jsonl"])
    }

    /// The names of everything directly inside `directory`, one level deep.
    private static func fileNames(directlyIn directory: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path)
    }

    // MARK: - The cut point is the diff baseline, not a second fact

    @Test("an uninstructed session's fork taken after one turn records forkedAtEntryCount == 2")
    @MainActor
    func uninstructedForkAfterOneTurnRecordsForkedAtEntryCountOfTwo() async throws {
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
        _ = try await root.respond(to: "hello")
        let fork = try await root.fork(workingDirectory: nil)

        let forkDir =
            recordingsDir
            .appendingPathComponent(router.id.description, isDirectory: true)
            .appendingPathComponent(root.id.description, isDirectory: true)
            .appendingPathComponent(fork.id.description, isDirectory: true)
        // One turn == one `.prompt` entry + one `.response` entry == 2 — the
        // same baseline the fork's own transcript diff persists from.
        #expect(try SessionSidecar.read(in: forkDir)?.forkedAtEntryCount == 2)
    }

    // MARK: - Ordering: the sidecar precedes any transcript event

    @Test("a session's sidecar exists before its transcript's first event is recorded")
    @MainActor
    func theSidecarExistsBeforeTheFirstTranscriptEvent() async throws {
        let cacheDir = Self.makeTempDir()
        let recordingsDir = Self.makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: cacheDir)
            try? FileManager.default.removeItem(at: recordingsDir)
        }

        // An observing recorder asserts the sidecar is already on disk at the
        // instant the very first event is appended — the ordering guarantee a
        // reader depends on to interpret any transcript it finds.
        let observed = ObservingRecorder(wrapping: JSONLRecorder(directory: recordingsDir))
        let router = Self.makeRouter(
            recorder: observed,
            cacheDir: cacheDir,
            recordingsDir: recordingsDir
        )
        let profile = try await router.resolve(profile: Self.profile, reporting: ResolutionProgress())

        let root = profile.standard.makeSession()
        _ = try await root.respond(to: "hello")
        let fork = try await root.fork(workingDirectory: nil)
        _ = try await fork.respond(to: "hi")

        let sidecarPresence = await observed.sidecarPresentAtFirstAppend
        #expect(sidecarPresence.count == 2)
        #expect(sidecarPresence.allSatisfy { $0 })
    }

    /// Wraps a recorder, noting for each session directory whether that
    /// session's `session.json` was already on disk when its first event was
    /// appended.
    private actor ObservingRecorder: TranscriptRecorder {
        private let wrapped: any TranscriptRecorder
        private var seenDirectories: Set<URL> = []
        /// One entry per distinct session directory, in first-append order.
        private(set) var sidecarPresentAtFirstAppend: [Bool] = []

        init(wrapping wrapped: any TranscriptRecorder) {
            self.wrapped = wrapped
        }

        func append(_ partial: TranscriptEvent.Partial, to directory: URL?) async {
            if let directory, seenDirectories.insert(directory).inserted {
                sidecarPresentAtFirstAppend.append(
                    FileManager.default.fileExists(
                        atPath: directory.appendingPathComponent("session.json", isDirectory: false).path
                    )
                )
            }
            await wrapped.append(partial, to: directory)
        }
    }

    // MARK: - Grammar and instructions

    @Test(
        "a guided session's sidecar carries its grammar source and instructions; forks inherit both")
    @MainActor
    func guidedSessionRecordsGrammarAndInstructionsAndForkInheritsThem() async throws {
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
        let instructions = "You are a terse assistant."
        let root = profile.standard.makeGuidedSession(
            grammar: .jsonSchema(grammarSource), instructions: instructions)
        let fork = try await root.fork(workingDirectory: nil)

        let rootDir =
            recordingsDir
            .appendingPathComponent(router.id.description, isDirectory: true)
            .appendingPathComponent(root.id.description, isDirectory: true)
        let forkDir = rootDir.appendingPathComponent(fork.id.description, isDirectory: true)

        let rootSidecar = try #require(try SessionSidecar.read(in: rootDir))
        let forkSidecar = try #require(try SessionSidecar.read(in: forkDir))

        #expect(rootSidecar.grammar == grammarSource)
        #expect(forkSidecar.grammar == grammarSource)
        #expect(rootSidecar.instructions == instructions)
        #expect(forkSidecar.instructions == instructions)
    }

    // MARK: - The resolved-profile facts the manifest used to hold

    @Test(
        "a root session's sidecar carries the resolved-profile facts; a fork's does not repeat them")
    @MainActor
    func rootSidecarCarriesResolvedProfileFactsAndForkDoesNot() async throws {
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
        let fork = try await root.fork(workingDirectory: nil)

        let rootDir =
            recordingsDir
            .appendingPathComponent(router.id.description, isDirectory: true)
            .appendingPathComponent(root.id.description, isDirectory: true)
        let forkDir = rootDir.appendingPathComponent(fork.id.description, isDirectory: true)

        let resolved = try #require(try SessionSidecar.read(in: rootDir)?.profile)
        #expect(resolved.definitionName == Self.profile.name)
        #expect(resolved.standard == profile.standard.chosen)
        #expect(resolved.flash == profile.flash.chosen)
        #expect(resolved.embedding == profile.embedding.chosen)
        #expect(resolved.context == profile.standard.resolution.contextTokens)

        // A fork's own model/slot/context are already its own fields; the
        // run-wide profile facts are stated once, on the root.
        #expect(try SessionSidecar.read(in: forkDir)?.profile == nil)
    }

    // MARK: - Recording levels

    @Test("a writer built at RecordingLevel.off writes nothing, wherever it was built")
    func writerAtRecordingLevelOffWritesNothing() throws {
        let parent = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: parent) }
        let dir = parent.appendingPathComponent(ULID.generate().description, isDirectory: true)

        let writer = SessionSidecarWriter(
            slot: .standard,
            model: "org/std-a",
            context: 4_096,
            recordingLevel: .off,
            profile: nil
        )
        writer.write(instructions: nil, grammar: nil, forkedAtEntryCount: nil, to: dir)

        // The gate lives in the writer, not in whoever built it: `.off` means a
        // writer that writes nothing, so a durable root can always be handed one
        // (see ``DurableRecording``) instead of being paired with `nil` — the
        // pairing that records a tree ``TranscriptTree/load(under:)`` refuses.
        //
        // Asserting the directory never appears, rather than just that no
        // `session.json` is in it, is what makes this a real check: `write` is
        // what brings the session's directory into existence, so a gate that
        // ran too late would leave the directory behind.
        #expect(!FileManager.default.fileExists(atPath: dir.path))
    }

    @Test("RecordingLevel.off writes no sidecar at all")
    @MainActor
    func recordingLevelOffWritesNoSidecar() async throws {
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

        // Nothing at all is recorded — not a sidecar, and not a transcript
        // either. Asserting the whole router directory never appears is what
        // makes this a real check: `SessionSidecar.read` returning nil proves
        // little on its own, since it reports an absent directory and an absent
        // sidecar identically. It also pins the pairing `TranscriptTree` now
        // depends on — a transcript with no sidecar beside it is a load error,
        // so a level that writes no sidecar must write no transcript.
        let routerDir = recordingsDir.appendingPathComponent(router.id.description, isDirectory: true)
        #expect(!FileManager.default.fileExists(atPath: routerDir.path))
        _ = root
        _ = fork
    }

    @Test("RecordingLevel.metadataOnly still writes sidecars — only turn content is trimmed")
    @MainActor
    func metadataOnlyStillWritesSidecars() async throws {
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

        let rootDir =
            recordingsDir
            .appendingPathComponent(router.id.description, isDirectory: true)
            .appendingPathComponent(root.id.description, isDirectory: true)
        let forkDir = rootDir.appendingPathComponent(fork.id.description, isDirectory: true)

        #expect(try SessionSidecar.read(in: rootDir)?.recordingLevel == .metadataOnly)
        #expect(try SessionSidecar.read(in: forkDir)?.recordingLevel == .metadataOnly)
    }

    // MARK: - Best-effort write failure

    @Test("a session whose sidecar can never be written still forks and generates normally")
    @MainActor
    func sessionWithUnwritableSidecarStillForksAndGenerates() async throws {
        let cacheDir = Self.makeTempDir()
        // The recordings root itself is a regular file, so every write under
        // it — both the sidecar's and the transcript recorder's, since a
        // session's `recordingDirectory` nests under this same root — fails to
        // create its directory. Best-effort failure must never surface into
        // `fork()`/`respond()`, which must still succeed and return the model's
        // real output regardless.
        let recordingsDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "SessionSidecarTests-blocker-\(UUID().uuidString)", isDirectory: false)
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
        #expect(try await root.respond(to: "hello") == Self.cannedText)

        let fork = try await root.fork(workingDirectory: nil)
        #expect(try await fork.respond(to: "hi") == Self.cannedText)
    }

    // MARK: - Concurrent forks

    @Test("every one of many concurrent forks writes its own sidecar into its own directory")
    @MainActor
    func concurrentForksEachWriteExactlyOneSidecar() async throws {
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
                    try await root.fork(workingDirectory: nil).id
                }
            }
            var ids: [ULID] = []
            for try await id in group {
                ids.append(id)
            }
            return ids
        }

        let rootDir =
            recordingsDir
            .appendingPathComponent(router.id.description, isDirectory: true)
            .appendingPathComponent(root.id.description, isDirectory: true)
        #expect(Set(forkIds).count == forkCount)
        for id in forkIds {
            _ = try #require(try SessionSidecar.read(in: rootDir.appendingPathComponent(id.description)))
        }
    }

    @Test("racing writes at one directory: exactly one wins and the loser cannot clobber its bytes")
    func racingWritesAtOneDirectoryLeaveExactlyOneWinner() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Vended forks never actually race for a directory — each mints its own
        // ULID — so this drives the exclusive create directly, which is the
        // property the write-once guarantee rests on. A check-then-write would
        // let more than one of these through.
        let sessionDir = dir.appendingPathComponent(ULID.generate().description, isDirectory: true)
        let attempts = 16
        let succeeded = await withTaskGroup(of: Bool.self) { group in
            for attempt in 0..<attempts {
                group.addTask {
                    // Each writer records a different cut point, so the
                    // surviving bytes name their author.
                    (try? SessionSidecar.write(Self.sampleSidecar(forkedAtEntryCount: attempt), to: sessionDir)) != nil
                }
            }
            return await group.reduce(into: 0) { count, didWrite in count += didWrite ? 1 : 0 }
        }

        #expect(succeeded == 1)
        let survivor = try #require(try SessionSidecar.read(in: sessionDir))
        // Exactly one writer's bytes, whole — never a torn mix of two.
        let cutPoint = try #require(survivor.forkedAtEntryCount)
        #expect((0..<attempts).contains(cutPoint))
        #expect(survivor == Self.sampleSidecar(forkedAtEntryCount: cutPoint))
    }
}
