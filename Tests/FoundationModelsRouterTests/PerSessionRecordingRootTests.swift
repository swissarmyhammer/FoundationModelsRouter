import Foundation
import FoundationModels
import Testing

@testable import FoundationModelsRouter

/// Exercises task ke41yth: a per-session recording root override
/// (``RoutedModel/makeSession(instructions:workingDirectory:recordingRoot:tools:budget:compactionPrompt:agentSpawn:discoveryPriming:toolOutputProtection:repetitionDetection:)``)
/// and the omittable ``routerId`` path segment it unlocks.
///
/// A single resident model handle vends every session under one Router-level
/// ``Router/recordingsDir`` by default, nested by ``RoutedModel/routerId`` —
/// but an ACP-style host serving many concurrent sessions across different
/// project directories needs each session's transcript to land under a
/// *caller-chosen* root instead, with no opaque per-process routerId
/// directory in between. This suite locks in: the override writes a flat
/// `<root>/<sessionId>/` layout (including for a fork taken from that root,
/// nested one level deeper under it); omitting it reproduces today's nested
/// `<recordingsDir>/<routerId>/<sessionId>/` layout byte-for-byte; two
/// sessions from the same Router with different roots never leak into each
/// other; and
/// ``RoutedModel/restoreSessionTree(root:recordingRoot:instructions:tools:toolOutputProtection:isNoOpToolCall:userPresence:)``
/// round-trips both layouts, with the recording routerId still readable from
/// the restored flat session's `index.md` record.
///
/// Everything here runs against stubs — a stub ``ModelLoader``, a canned LLM
/// container backed by ``StubSessionBackend``, and a ``JSONLRecorder``
/// writing into temp directories — mirroring ``SessionTreeRestorationTests``'
/// scaffolding.
@Suite("Per-session recording root + omittable routerId segment")
struct PerSessionRecordingRootTests {
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
            "max_position_embeddings": 8192,
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
            .appendingPathComponent("PerSessionRecordingRootTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Builds a router wired with the stubs and a durable recordings root, so
    /// vended sessions nest their transcripts under it.
    ///
    /// - Parameter id: The router id to construct with — pass the first
    ///   router's `id` to simulate a fresh process continuing the same
    ///   recording root.
    private static func makeRouter(
        id: ULID = .generate(),
        cacheDir: URL,
        recordingsDir: URL,
        pool: ModelPool = ModelPool()
    ) -> Router {
        Router(
            id: id,
            cacheDir: cacheDir,
            recordingsDir: recordingsDir,
            recorder: JSONLRecorder(directory: recordingsDir),
            probe: StubProbe(
                chip: "Apple Test", totalRAM: 64 << 30, recommendedMaxWorkingSetSize: 48 << 30),
            metadataSource: StubMetadataSource(raw: rawMetadata),
            loader: StubModelLoader(dimension: stubDimension, text: cannedText),
            pool: pool
        )
    }

    // MARK: - Flat layout: recordingRoot omits the routerId segment

    /// A session vended with a recording root writes its folder, and its
    /// `index.md`, directly under that root, with no router id segment.
    @Test("makeSession(recordingRoot:) writes a flat <root>/<sessionId>/ layout with no routerId segment")
    @MainActor
    func recordingRootProducesFlatLayoutWithNoRouterIdSegment() async throws {
        let cacheDir = Self.makeTempDir()
        let recordingsDir = Self.makeTempDir()
        let customRoot = Self.makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: cacheDir)
            try? FileManager.default.removeItem(at: recordingsDir)
            try? FileManager.default.removeItem(at: customRoot)
        }

        let router = Self.makeRouter(cacheDir: cacheDir, recordingsDir: recordingsDir)
        let profile = try await router.resolve(profile: Self.profile, reporting: ResolutionProgress())

        let session = profile.standard.makeSession(recordingRoot: customRoot)
        defer { await session.close() }
        _ = try await session.respond(to: "hello")

        let expectedDirectory = customRoot.appendingPathComponent(session.id.description, isDirectory: true)
        #expect(session.recordingDirectory == expectedDirectory)
        #expect(
            FileManager.default.fileExists(
                atPath: RouterTestFixtures.indexURL(inSessionDirectory: expectedDirectory).path))
        // No routerId directory anywhere under the custom root.
        #expect(
            !FileManager.default.fileExists(
                atPath: customRoot.appendingPathComponent(router.id.description).path))
    }

    /// A fork of a flat-layout root nests under the root's folder, with no
    /// router id segment, and writes its own `index.md` there.
    @Test("a fork of a flat-layout root session nests under it with no routerId segment, and lands its own index.md")
    @MainActor
    func forkOfFlatLayoutRootNestsWithNoRouterIdSegment() async throws {
        let cacheDir = Self.makeTempDir()
        let recordingsDir = Self.makeTempDir()
        let customRoot = Self.makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: cacheDir)
            try? FileManager.default.removeItem(at: recordingsDir)
            try? FileManager.default.removeItem(at: customRoot)
        }

        let router = Self.makeRouter(cacheDir: cacheDir, recordingsDir: recordingsDir)
        let profile = try await router.resolve(profile: Self.profile, reporting: ResolutionProgress())

        let root = profile.standard.makeSession(recordingRoot: customRoot)
        defer { await root.close() }
        _ = try await root.respond(to: "hello")
        let fork = try await root.fork(workingDirectory: nil)
        defer { await fork.close() }

        // The fork nests directly under the flat root's own directory —
        // still no routerId segment anywhere in the path.
        let expectedForkDirectory = customRoot
            .appendingPathComponent(root.id.description, isDirectory: true)
            .appendingPathComponent(fork.id.description, isDirectory: true)
        #expect(fork.recordingDirectory == expectedForkDirectory)
        #expect(
            FileManager.default.fileExists(
                atPath: RouterTestFixtures.indexURL(inSessionDirectory: expectedForkDirectory).path))

        // The whole tree is still reachable by loading the custom root
        // directly (the flat, no-routerId-segment layout).
        let tree = try TranscriptTree.load(under: customRoot)
        #expect(tree.children(of: root.id).map(\.id) == [fork.id])
    }

    @Test("omitting recordingRoot reproduces today's nested <recordingsDir>/<routerId>/<sessionId>/ layout byte-for-byte")
    @MainActor
    func omittingRecordingRootReproducesDefaultNestedLayout() async throws {
        let cacheDir = Self.makeTempDir()
        let recordingsDir = Self.makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: cacheDir)
            try? FileManager.default.removeItem(at: recordingsDir)
        }

        let router = Self.makeRouter(cacheDir: cacheDir, recordingsDir: recordingsDir)
        let profile = try await router.resolve(profile: Self.profile, reporting: ResolutionProgress())

        let session = profile.standard.makeSession()
        defer { await session.close() }

        let expectedDirectory = recordingsDir
            .appendingPathComponent(router.id.description, isDirectory: true)
            .appendingPathComponent(session.id.description, isDirectory: true)
        #expect(session.recordingDirectory == expectedDirectory)
    }

    @Test("two sessions from the same Router given different recordingRoots write to those roots with no leakage")
    @MainActor
    func differentRecordingRootsDoNotLeakIntoEachOther() async throws {
        let cacheDir = Self.makeTempDir()
        let recordingsDir = Self.makeTempDir()
        let rootA = Self.makeTempDir()
        let rootB = Self.makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: cacheDir)
            try? FileManager.default.removeItem(at: recordingsDir)
            try? FileManager.default.removeItem(at: rootA)
            try? FileManager.default.removeItem(at: rootB)
        }

        let router = Self.makeRouter(cacheDir: cacheDir, recordingsDir: recordingsDir)
        let profile = try await router.resolve(profile: Self.profile, reporting: ResolutionProgress())

        let sessionA = profile.standard.makeSession(recordingRoot: rootA)
        defer { await sessionA.close() }
        _ = try await sessionA.respond(to: "session A answer")
        let sessionB = profile.standard.makeSession(recordingRoot: rootB)
        defer { await sessionB.close() }
        _ = try await sessionB.respond(to: "session B answer")

        func childDirectoryNames(of directory: URL) throws -> Set<String> {
            Set(
                try FileManager.default.contentsOfDirectory(atPath: directory.path)
            )
        }

        // Each root holds only its one session folder: no index file is
        // written beside it (ROUTER-3).
        #expect(try childDirectoryNames(of: rootA) == [sessionA.id.description])
        #expect(try childDirectoryNames(of: rootB) == [sessionB.id.description])
    }

    // MARK: - Restoration round-trips both layouts

    /// A flat-layout session restores, and its `index.md` record still
    /// names the router id of the router that recorded it.
    @Test("a session written with no routerId segment restores correctly, and its routerId is still readable from metadata")
    @MainActor
    func flatLayoutSessionRestoresWithRouterIdReadableFromMetadata() async throws {
        let cacheDir = Self.makeTempDir()
        let recordingsDir = Self.makeTempDir()
        let customRoot = Self.makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: cacheDir)
            try? FileManager.default.removeItem(at: recordingsDir)
            try? FileManager.default.removeItem(at: customRoot)
        }

        let router1 = Self.makeRouter(cacheDir: cacheDir, recordingsDir: recordingsDir)
        let profile1 = try await router1.resolve(profile: Self.profile, reporting: ResolutionProgress())

        let root = profile1.standard.makeSession(recordingRoot: customRoot)
        defer { await root.close() }
        _ = try await root.respond(to: "remember the flat layout")

        // "Tear down" and restore under a fresh process continuing the same
        // router id, exactly as ``SessionTreeRestorationTests`` simulates.
        let router2 = Self.makeRouter(id: router1.id, cacheDir: cacheDir, recordingsDir: recordingsDir)
        let profile2 = try await router2.resolve(profile: Self.profile, reporting: ResolutionProgress())

        let restored = try await profile2.standard.restoreSessionTree(
            root: root.id, recordingRoot: customRoot)
        defer { await restored.root.close() }

        #expect(restored.root.id == root.id)
        #expect(restored.root.parentId == nil)

        let sessionDirectory = customRoot.appendingPathComponent(root.id.description, isDirectory: true)
        let record = try #require(try SessionIndexFile.read(in: sessionDirectory))
        #expect(record.routerId == router1.id)
    }

    @Test("an existing nested-layout recording still restores after the recordingRoot change")
    @MainActor
    func existingNestedLayoutRecordingStillRestores() async throws {
        let cacheDir = Self.makeTempDir()
        let recordingsDir = Self.makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: cacheDir)
            try? FileManager.default.removeItem(at: recordingsDir)
        }

        let router1 = Self.makeRouter(cacheDir: cacheDir, recordingsDir: recordingsDir)
        let profile1 = try await router1.resolve(profile: Self.profile, reporting: ResolutionProgress())

        // No recordingRoot: the existing nested <recordingsDir>/<routerId>/<sessionId>/ layout.
        let root = profile1.standard.makeSession()
        defer { await root.close() }
        _ = try await root.respond(to: "remember the nested layout")

        let router2 = Self.makeRouter(id: router1.id, cacheDir: cacheDir, recordingsDir: recordingsDir)
        let profile2 = try await router2.resolve(profile: Self.profile, reporting: ResolutionProgress())

        let restored = try await profile2.standard.restoreSessionTree(root: root.id)
        defer { await restored.root.close() }

        #expect(restored.root.id == root.id)
        #expect(restored.root.parentId == nil)
    }
}
