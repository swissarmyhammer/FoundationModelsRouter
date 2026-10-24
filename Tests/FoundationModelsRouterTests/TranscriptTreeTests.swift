import Foundation
import FoundationModels
import Testing

@testable import FoundationModelsRouter

/// Exercises `TranscriptTree`: the queryable read-side of the session
/// hierarchy — fetch any session's transcript directly by its `ULID`, and
/// inspect the tree as data, no caller-side directory walking (see plan.md's
/// "Transcript fidelity" section, "Retrieval & the fork hierarchy as
/// first-class data").
///
/// Everything runs against stubs — a stub `ModelLoader`, a canned LLM
/// container backed by `StubSessionBackend`, and a `JSONLRecorder` writing
/// into a temp directory — so the suite needs no network and no GPU, mirroring
/// ``SessionIndexTests``' scaffolding.
@Suite("TranscriptTree: session-id lookup and hierarchy-aware retrieval")
struct TranscriptTreeTests {
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

    private static let configJSON = Data("""
        {
            "num_hidden_layers": 2,
            "max_position_embeddings": 8192,
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

    /// A fresh temp directory, named by its canonical path.
    ///
    /// macOS reaches the temporary directory through a symlink (`/var` →
    /// `/private/var`), and ``TranscriptTree`` reports discovered session
    /// directories as its `FileManager` enumeration spells them — canonically,
    /// with that symlink resolved. Canonicalizing here means a directory this
    /// suite builds and one the tree reports back are the same `URL`, so the
    /// assertions below compare like with like. (`resolvingSymlinksInPath()`
    /// is not enough: it leaves `/var` alone.)
    private static func makeTempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TranscriptTreeTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let canonical = try? dir.resourceValues(forKeys: [.canonicalPathKey]).canonicalPath else {
            return dir
        }
        return URL(fileURLWithPath: canonical, isDirectory: true)
    }

    /// Builds a router wired with the stubs, an explicit recorder, and a
    /// durable recordings root, so vended sessions nest their transcripts —
    /// and the `index.md` of each session — under it.
    private static func makeRouter(
        recorder: any TranscriptRecorder,
        cacheDir: URL,
        recordingsDir: URL,
        pool: ModelPool = ModelPool()
    ) -> Router {
        Router(
            cacheDir: cacheDir,
            recordingsDir: recordingsDir,
            recorder: recorder,
            recordingLevel: .full,
            probe: StubProbe(
                chip: "Apple Test", totalRAM: 64 << 30, recommendedMaxWorkingSetSize: 48 << 30),
            metadataSource: StubMetadataSource(raw: rawMetadata),
            loader: StubModelLoader(dimension: stubDimension, text: cannedText),
            pool: pool
        )
    }

    // MARK: - Effective entries of a root

    @Test("effectiveEntryEvents for a root is just its own entry-kind events")
    @MainActor
    func effectiveEntryEventsForRootIsItsOwnEntries() async throws {
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
        defer { await root.close() }
        _ = try await root.respond(to: "root-message-1")

        let tree = try TranscriptTree.load(
            under: RouterTestFixtures.routerDirectory(routerId: router.id, recordingsDir: recordingsDir))
        let effective = try tree.effectiveEntryEvents(forSession: root.id)
        #expect(effective.map(\.kind) == [.prompt, .response])
        #expect(effective.first?.text == "root-message-1")
    }

    // MARK: - An unreadable index.md fails loudly

    /// An `index.md` that holds no frontmatter holds no record, so the load
    /// fails with `indexUnreadable` naming its directory.
    @Test(
        "a session directory holding an undecodable index.md throws indexUnreadable naming it")
    @MainActor
    func undecodableIndexThrowsNamingItsDirectory() async throws {
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
        defer { await root.close() }
        _ = try await root.respond(to: "root-message-1")

        let routerDir = RouterTestFixtures.routerDirectory(routerId: router.id, recordingsDir: recordingsDir)
        let rootDirectory = RouterTestFixtures.sessionDirectory(
            of: root.id, routerId: router.id, recordingsDir: recordingsDir)
        let indexURL = RouterTestFixtures.indexURL(inSessionDirectory: rootDirectory)
        try FileManager.default.removeItem(at: indexURL)
        try Data("{ truncated".utf8).write(to: indexURL)

        #expect(throws: TranscriptTreeError.indexUnreadable(directory: rootDirectory)) {
            _ = try TranscriptTree.load(under: routerDir)
        }
    }

    /// A record stamped with a schema version newer than this reader fails
    /// the load with the typed newer-router error, not `indexUnreadable`.
    @Test(
        "an index.md stamped with a future schema version fails the load with the typed newer-router error, not indexUnreadable"
    )
    @MainActor
    func futureVersionIndexFailsTheLoadWithTheTypedError() async throws {
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
        defer { await root.close() }
        _ = try await root.respond(to: "root-message-1")

        // Restamp the recorded index.md with a version this reader does not
        // know, the way a recording written by a newer router would carry it.
        let routerDir = RouterTestFixtures.routerDirectory(routerId: router.id, recordingsDir: recordingsDir)
        let rootDirectory = RouterTestFixtures.sessionDirectory(
            of: root.id, routerId: router.id, recordingsDir: recordingsDir)
        let futureVersion = RecordingSchemaVersion.current + 1
        try RouterTestFixtures.rewriteIndex(in: rootDirectory) { $0.schemaVersion = futureVersion }

        // The frontmatter decodes fine and names a newer version: that is not
        // corruption, so the load must surface the version refusal typed,
        // never merged into `indexUnreadable`.
        #expect(
            throws: RecordingSchemaVersionError.recordingFromNewerRouter(
                directory: rootDirectory,
                version: futureVersion,
                supported: RecordingSchemaVersion.current
            )
        ) {
            _ = try TranscriptTree.load(under: routerDir)
        }
    }

    /// A transcript with no `index.md` beside it cannot be placed in the
    /// tree, so the load fails with `indexMissing` instead of skipping it.
    @Test("a transcript.jsonl with no index.md beside it throws indexMissing rather than being skipped")
    func transcriptWithNoIndexThrows() throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let sessionDirectory = dir.appendingPathComponent(
            ULID.generate().description, isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
        try Data().write(
            to: sessionDirectory.appendingPathComponent("transcript.jsonl", isDirectory: false))

        #expect(throws: TranscriptTreeError.indexMissing(directory: sessionDirectory)) {
            _ = try TranscriptTree.load(under: dir)
        }
    }

    /// An `index.md` in a folder whose name is not a session id names no
    /// session, so the load fails with `sessionDirectoryNotIdentified`.
    @Test(
        "an index.md in a directory not named for a session id throws sessionDirectoryNotIdentified")
    func indexInANonSessionDirectoryThrows() throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // A session's id comes from its directory's name, so an index.md
        // somewhere else names no session at all.
        let notASessionDirectory = dir.appendingPathComponent("scratch", isDirectory: true)
        try SessionRecordFixtures.writePlaceholder(in: notASessionDirectory)

        #expect(
            throws: TranscriptTreeError.sessionDirectoryNotIdentified(directory: notASessionDirectory)
        ) {
            _ = try TranscriptTree.load(under: dir)
        }
    }

    // MARK: - Two directories claiming one session id

    /// Two folders that carry one session id fail the load with
    /// `duplicateSessionId` naming both, instead of trapping.
    @Test("two session directories sharing one session id throw duplicateSessionId naming both, rather than trapping")
    func duplicateSessionIdAcrossDirectoriesThrows() throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // One session's directory copied under another — the shape an rsync or
        // a hand-pasted tree produces. The filesystem cannot stop it (the two
        // live at different depths), and every malformed-tree condition this
        // loader meets must be a typed error naming the directories, never a
        // trap.
        let rootId = ULID.generate()
        let duplicatedId = ULID.generate()
        let rootDirectory = dir.appendingPathComponent(rootId.description, isDirectory: true)
        let first = dir.appendingPathComponent(duplicatedId.description, isDirectory: true)
        let second = rootDirectory.appendingPathComponent(duplicatedId.description, isDirectory: true)
        try SessionRecordFixtures.writePlaceholder(in: rootDirectory)
        try SessionRecordFixtures.writePlaceholder(in: first)
        try SessionRecordFixtures.writePlaceholder(in: second, forkedAtEntryCount: 0)

        #expect(
            throws: TranscriptTreeError.duplicateSessionId(
                id: duplicatedId,
                directories: [first, second].sorted { $0.path < $1.path }
            )
        ) {
            _ = try TranscriptTree.load(under: dir)
        }
    }

    // MARK: - A recorded fork whose record holds no cut point

    /// A nested session whose record holds no fork cut cannot say how much
    /// of its parent it inherits, so `effectiveEntryEvents` throws
    /// `forkCutPointMissing`.
    @Test("effectiveEntryEvents throws forkCutPointMissing for a nested session whose index.md has no forkedAtEntryCount")
    func effectiveEntryEventsThrowsWhenANestedSessionRecordsNoCutPoint() throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let rootId = ULID.generate()
        let childId = ULID.generate()
        let rootDirectory = dir.appendingPathComponent(rootId.description, isDirectory: true)
        let childDirectory = rootDirectory.appendingPathComponent(
            childId.description, isDirectory: true)
        try SessionRecordFixtures.writePlaceholder(in: rootDirectory)
        // Nested under a parent, so it inherits — yet records no cut point
        // saying how much. Only a hand-built tree can be in this state.
        try SessionRecordFixtures.writePlaceholder(in: childDirectory)

        let tree = try TranscriptTree.load(under: dir)
        #expect(try #require(tree.session(childId)).parentId == rootId)
        #expect(
            throws: TranscriptTreeError.forkCutPointMissing(session: childId, directory: childDirectory)
        ) {
            _ = try tree.effectiveEntryEvents(forSession: childId)
        }
    }

    // MARK: - session/embedding exclusion from effectiveEntryEvents

    @Test("session meta and embedding events never appear in effectiveEntryEvents")
    @MainActor
    func sessionAndEmbeddingEventsExcludedFromEffectiveEntries() async throws {
        let cacheDir = Self.makeTempDir()
        let recordingsDir = Self.makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: cacheDir)
            try? FileManager.default.removeItem(at: recordingsDir)
        }

        let recorder = JSONLRecorder(directory: recordingsDir)
        let router = Self.makeRouter(
            recorder: recorder, cacheDir: cacheDir, recordingsDir: recordingsDir)
        let profile = try await router.resolve(profile: Self.profile, reporting: ResolutionProgress())

        let root = profile.standard.makeSession()
        defer { await root.close() }
        _ = try await root.respond(to: "root-message-1")

        let routerDir = RouterTestFixtures.routerDirectory(routerId: router.id, recordingsDir: recordingsDir)
        let tree = try TranscriptTree.load(under: routerDir)
        let rootDirectory = try #require(tree.session(root.id)).directory

        // Directly inject a router-only `.embedding` event into the root
        // session's own transcript.jsonl — real embeddings never land inside
        // a session's directory (they record to the router's own top-level
        // file), so this exercises the entry-kind filter in isolation from
        // what the live router actually produces.
        await recorder.append(
            TranscriptEvent.Partial(
                routerId: router.id,
                sessionId: root.id,
                parentId: nil,
                slot: .embedding,
                model: "org/emb-a",
                kind: .embedding,
                text: "embedded text"
            ),
            to: rootDirectory
        )

        let rawEvents = try tree.events(forSession: root.id)
        #expect(rawEvents.contains { $0.kind == .session })
        #expect(rawEvents.contains { $0.kind == .embedding })

        let effective = try tree.effectiveEntryEvents(forSession: root.id)
        #expect(!effective.contains { $0.kind == .session })
        #expect(!effective.contains { $0.kind == .embedding })
        #expect(effective.map(\.kind) == [.prompt, .response])
    }
}
