import Foundation
import FoundationModels
import Testing

@testable import FoundationModelsRouter

/// Exercises `TranscriptTree`: the queryable read-side of the fork hierarchy —
/// fetch any session's transcript directly by its `ULID`, and inspect the tree
/// as data, no caller-side directory walking (see plan.md's "Transcript
/// fidelity" section, "Retrieval & the fork hierarchy as first-class data").
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
            .appendingPathComponent("TranscriptTreeTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Builds a router wired with the stubs, an explicit recorder, and a
    /// durable recordings root, so vended sessions nest their transcripts —
    /// and the session index — under it.
    private static func makeRouter(
        recorder: any TranscriptRecorder,
        cacheDir: URL,
        recordingsDir: URL
    ) -> Router {
        Router(
            maxConcurrentForks: 4,
            cacheDir: cacheDir,
            recordingsDir: recordingsDir,
            recorder: recorder,
            recordingLevel: .full,
            probe: StubProbe(chip: "Apple Test", totalRAM: 64 << 30, recommendedMaxWorkingSetSize: 48 << 30),
            metadataSource: StubMetadataSource(raw: rawMetadata),
            loader: StubModelLoader(dimension: stubDimension, text: cannedText)
        )
    }

    /// This router's recording root — `recordings/<routerId>/` — the same
    /// directory ``TranscriptTree/load(under:)`` reads.
    private func routerDirectory(router: Router, recordingsDir: URL) -> URL {
        recordingsDir.appendingPathComponent(router.id.description, isDirectory: true)
    }

    // MARK: - Reusable branching-tree fixture

    /// Builds a 3-level branching tree on disk: a root session, two of its
    /// forks (`forkA`, `forkB`), and one of forkA's own forks (`grandfork`) —
    /// the shape the later restore task's mandated integration test also
    /// needs, so this is written to be reusable beyond this suite.
    ///
    /// Each session generates the requested number of turns *before* any of
    /// its own children fork from it (so a child's `forkedAtEntryCount`
    /// baseline lands exactly where the turn plan intends), then the
    /// requested number *after* — exercising "an ancestor keeps generating
    /// after a child forks from it" without disturbing the already-taken
    /// fork's baseline. Every turn's prompt is a distinct, greppable string
    /// (`"<session>-turn-<n>"`) so a test can identify exactly which turns
    /// survived a truncation.
    ///
    /// - Parameters:
    ///   - profile: The resolved profile to vend sessions from.
    ///   - rootTurnsBeforeForks: Turns `root` takes before `forkA`/`forkB` fork.
    ///   - rootTurnsAfterForks: Turns `root` takes after forking, invisible to
    ///     both forks' effective transcripts.
    ///   - forkATurnsBeforeGrandfork: Turns `forkA` takes before `grandfork`
    ///     forks from it.
    ///   - forkATurnsAfterGrandfork: Turns `forkA` takes after `grandfork`
    ///     forks, invisible to `grandfork`'s effective transcript.
    ///   - forkBTurns: Turns `forkB` takes (`forkB` has no children).
    ///   - grandforkTurns: Turns `grandfork` takes.
    /// - Returns: The four vended sessions.
    private static func buildBranchingTree(
        profile: LanguageModelProfile,
        rootTurnsBeforeForks: Int = 1,
        rootTurnsAfterForks: Int = 0,
        forkATurnsBeforeGrandfork: Int = 1,
        forkATurnsAfterGrandfork: Int = 0,
        forkBTurns: Int = 1,
        grandforkTurns: Int = 1
    ) async throws -> (root: RoutedSession, forkA: RoutedSession, forkB: RoutedSession, grandfork: RoutedSession) {
        let root = profile.standard.makeSession()
        if rootTurnsBeforeForks > 0 {
            for turn in 1...rootTurnsBeforeForks {
                _ = try await root.respond(to: "root-turn-\(turn)")
            }
        }

        let forkA = try await root.fork(workingDirectory: nil)
        let forkB = try await root.fork(workingDirectory: nil)

        if rootTurnsAfterForks > 0 {
            for turn in 1...rootTurnsAfterForks {
                _ = try await root.respond(to: "root-turn-\(rootTurnsBeforeForks + turn)")
            }
        }

        if forkATurnsBeforeGrandfork > 0 {
            for turn in 1...forkATurnsBeforeGrandfork {
                _ = try await forkA.respond(to: "forkA-turn-\(turn)")
            }
        }

        let grandfork = try await forkA.fork(workingDirectory: nil)

        if forkATurnsAfterGrandfork > 0 {
            for turn in 1...forkATurnsAfterGrandfork {
                _ = try await forkA.respond(to: "forkA-turn-\(forkATurnsBeforeGrandfork + turn)")
            }
        }

        if forkBTurns > 0 {
            for turn in 1...forkBTurns {
                _ = try await forkB.respond(to: "forkB-turn-\(turn)")
            }
        }

        if grandforkTurns > 0 {
            for turn in 1...grandforkTurns {
                _ = try await grandfork.respond(to: "grandfork-turn-\(turn)")
            }
        }

        return (root, forkA, forkB, grandfork)
    }

    // MARK: - Lookup by ULID

    @Test("looks up every session in a branching tree by id alone, with no directory path")
    @MainActor
    func looksUpEverySessionByIdAlone() async throws {
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
        let (root, forkA, forkB, grandfork) = try await Self.buildBranchingTree(profile: profile)

        let tree = try TranscriptTree.load(under: routerDirectory(router: router, recordingsDir: recordingsDir))

        #expect(tree.session(root.id)?.id == root.id)
        #expect(tree.session(forkA.id)?.id == forkA.id)
        #expect(tree.session(forkB.id)?.id == forkB.id)
        #expect(tree.session(grandfork.id)?.id == grandfork.id)
        #expect(tree.session(.generate()) == nil)
    }

    // MARK: - Tree shape and children ordering

    @Test("the tree's roots, children, and parent links match the index")
    @MainActor
    func treeShapeMatchesIndex() async throws {
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
        let (root, forkA, forkB, grandfork) = try await Self.buildBranchingTree(profile: profile)

        let tree = try TranscriptTree.load(under: routerDirectory(router: router, recordingsDir: recordingsDir))

        #expect(tree.roots.map(\.id) == [root.id])
        let rootNode = try #require(tree.roots.first)
        #expect(rootNode.parentId == nil)

        // Children are ordered by ULID (creation order) — assert the *set*
        // matches, then assert the returned order already equals the
        // id-sorted order, so the test does not itself assume forkA was
        // necessarily created before forkB in wall-clock terms.
        let rootChildren = tree.children(of: root.id)
        #expect(Set(rootChildren.map(\.id)) == Set([forkA.id, forkB.id]))
        #expect(rootChildren.map(\.id) == rootChildren.map(\.id).sorted())

        let forkANode = try #require(tree.session(forkA.id))
        #expect(forkANode.parentId == root.id)
        #expect(forkANode.children.map(\.id) == [grandfork.id])

        let forkBNode = try #require(tree.session(forkB.id))
        #expect(forkBNode.parentId == root.id)
        #expect(forkBNode.children.isEmpty)

        let grandforkNode = try #require(tree.session(grandfork.id))
        #expect(grandforkNode.parentId == forkA.id)
        #expect(grandforkNode.children.isEmpty)
        #expect(tree.children(of: grandfork.id).isEmpty)
    }

    // MARK: - events(forSession:) is that session's own delta only

    @Test("events(forSession:) decodes only that session's own transcript.jsonl")
    @MainActor
    func eventsForSessionIsOwnDeltaOnly() async throws {
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
        let (root, forkA, _, grandfork) = try await Self.buildBranchingTree(profile: profile)

        let tree = try TranscriptTree.load(under: routerDirectory(router: router, recordingsDir: recordingsDir))

        let forkAEvents = try tree.events(forSession: forkA.id)
        // forkA's own file: one session-meta line, plus one prompt/response
        // pair for its single turn — never root's or grandfork's entries.
        #expect(forkAEvents.map(\.kind) == [.session, .prompt, .response])
        #expect(forkAEvents.first { $0.kind == .prompt }?.text == "forkA-turn-1")
        #expect(!forkAEvents.contains { $0.text == "root-turn-1" })
        #expect(!forkAEvents.contains { $0.text == "grandfork-turn-1" })

        let rootEvents = try tree.events(forSession: root.id)
        #expect(rootEvents.map(\.kind) == [.session, .prompt, .response])

        _ = grandfork
    }

    // MARK: - Effective entries: grandfork cut correctly, ancestors keep generating

    @Test("effectiveEntryEvents for a grandfork is root-up-to-fork1 + child-up-to-fork2 + grandfork's own, even when ancestors kept generating after the forks")
    @MainActor
    func effectiveEntryEventsCutsCorrectlyForGrandfork() async throws {
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
        // root takes a second turn *after* forkA/forkB fork; forkA takes a
        // second turn *after* grandfork forks — both must be invisible to
        // grandfork's effective transcript.
        let (root, forkA, _, grandfork) = try await Self.buildBranchingTree(
            profile: profile,
            rootTurnsBeforeForks: 1,
            rootTurnsAfterForks: 1,
            forkATurnsBeforeGrandfork: 1,
            forkATurnsAfterGrandfork: 1,
            forkBTurns: 0,
            grandforkTurns: 1
        )

        let tree = try TranscriptTree.load(under: routerDirectory(router: router, recordingsDir: recordingsDir))

        // Uninstructed turns: one prompt + one response entry each, so
        // forkA's baseline is 2 (root's one prior turn) and grandfork's
        // baseline is 4 (root's 2 inherited + forkA's own 1 turn == 2 more).
        let forkANode = try #require(tree.session(forkA.id))
        #expect(forkANode.forkedAtEntryCount == 2)
        let grandforkNode = try #require(tree.session(grandfork.id))
        #expect(grandforkNode.forkedAtEntryCount == 4)

        let effective = try tree.effectiveEntryEvents(forSession: grandfork.id)

        let prompts = effective.filter { $0.kind == .prompt }.map(\.text)
        #expect(prompts == ["root-turn-1", "forkA-turn-1", "grandfork-turn-1"])
        #expect(effective.map(\.kind) == [.prompt, .response, .prompt, .response, .prompt, .response])
        // Never the router-only session meta, and never the turns that
        // happened after either fork point.
        #expect(!effective.contains { $0.kind == .session })
        #expect(!effective.contains { $0.text == "root-turn-2" })
        #expect(!effective.contains { $0.text == "forkA-turn-2" })

        _ = root
    }

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
        let (root, _, _, _) = try await Self.buildBranchingTree(profile: profile)

        let tree = try TranscriptTree.load(under: routerDirectory(router: router, recordingsDir: recordingsDir))
        let effective = try tree.effectiveEntryEvents(forSession: root.id)
        #expect(effective.map(\.kind) == [.prompt, .response])
        #expect(effective.first?.text == "root-turn-1")
    }

    // MARK: - Duplicated sessionId handling

    @Test("a duplicated sessionId in sessions.jsonl still yields exactly one SessionNode, using the first record's fields")
    func duplicatedSessionIdYieldsOneNode() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let writer = SessionIndexWriter(directory: dir)
        let sessionId = ULID.generate()
        let first = SessionIndexRecord(
            sessionId: sessionId,
            parentId: nil,
            path: "first-path",
            forkedAtEntryCount: 0,
            slot: .standard,
            model: "org/model-a",
            instructions: nil,
            grammar: nil,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let duplicate = SessionIndexRecord(
            sessionId: sessionId,
            parentId: nil,
            path: "second-path",
            forkedAtEntryCount: 5,
            slot: .standard,
            model: "org/model-b",
            instructions: nil,
            grammar: nil,
            createdAt: Date(timeIntervalSince1970: 1_700_000_500)
        )
        await writer.append(first)
        await writer.append(duplicate)

        let tree = try TranscriptTree.load(under: dir)
        #expect(tree.roots.count == 1)
        let node = try #require(tree.session(sessionId))
        #expect(node.forkedAtEntryCount == 0)
        #expect(node.directory == dir.appendingPathComponent("first-path", isDirectory: true))
        #expect(node.children.isEmpty)
    }

    // MARK: - Index-less fallback

    @Test("with no sessions.jsonl, the fallback reproduces the tree shape and per-session events; effectiveEntryEvents on a fork throws")
    @MainActor
    func fallbackReproducesTreeShapeAndThrowsForForks() async throws {
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
        let (root, forkA, forkB, grandfork) = try await Self.buildBranchingTree(profile: profile)

        let routerDir = routerDirectory(router: router, recordingsDir: recordingsDir)

        // Sanity: the index-backed tree has the shape we expect before we
        // remove the index.
        let indexedTree = try TranscriptTree.load(under: routerDir)
        #expect(indexedTree.roots.map(\.id) == [root.id])

        let indexFileURL = routerDir.appendingPathComponent("sessions.jsonl", isDirectory: false)
        try FileManager.default.removeItem(at: indexFileURL)

        let fallbackTree = try TranscriptTree.load(under: routerDir)

        #expect(fallbackTree.roots.map(\.id) == [root.id])
        #expect(Set(fallbackTree.children(of: root.id).map(\.id)) == Set([forkA.id, forkB.id]))
        #expect(fallbackTree.children(of: forkA.id).map(\.id) == [grandfork.id])

        // Per-session events still decode correctly without the index.
        let forkAEvents = try fallbackTree.events(forSession: forkA.id)
        #expect(forkAEvents.map(\.kind) == [.session, .prompt, .response])
        #expect(forkAEvents.first { $0.kind == .prompt }?.text == "forkA-turn-1")

        // forkedAtEntryCount is unknown in fallback mode, so a fork's
        // effective transcript cannot be reconstructed.
        #expect(fallbackTree.session(forkA.id)?.forkedAtEntryCount == nil)
        #expect(throws: TranscriptTreeError.forkedAtEntryCountUnknown(forkA.id)) {
            _ = try fallbackTree.effectiveEntryEvents(forSession: forkA.id)
        }
        #expect(throws: TranscriptTreeError.forkedAtEntryCountUnknown(grandfork.id)) {
            _ = try fallbackTree.effectiveEntryEvents(forSession: grandfork.id)
        }

        // A root has no parent to truncate, so it is unaffected by the
        // missing baseline even in fallback mode.
        let rootEffective = try fallbackTree.effectiveEntryEvents(forSession: root.id)
        #expect(rootEffective.map(\.kind) == [.prompt, .response])
    }

    // MARK: - Fallback surfaces sessions whose own parent never generated

    @Test("the fallback surfaces a fork whose own root never generated (no transcript.jsonl for the root), rather than silently dropping it")
    @MainActor
    func fallbackSurfacesForkWhoseRootNeverGenerated() async throws {
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

        // root never calls respond(), so it never writes a session-meta line
        // and therefore never gets a transcript.jsonl at all — only the fork
        // (which does generate) leaves any on-disk trace of itself.
        let root = profile.standard.makeSession()
        let fork = try await root.fork(workingDirectory: nil)
        _ = try await fork.respond(to: "fork-turn-1")

        let routerDir = routerDirectory(router: router, recordingsDir: recordingsDir)
        let indexFileURL = routerDir.appendingPathComponent("sessions.jsonl", isDirectory: false)
        try FileManager.default.removeItem(at: indexFileURL)

        let fallbackTree = try TranscriptTree.load(under: routerDir)

        // root left no discoverable trace at all — that is an accepted
        // fallback limitation — but the fork must still surface, promoted to
        // a root of the loaded (partial) tree, not silently dropped along
        // with its own subtree.
        #expect(fallbackTree.session(root.id) == nil)
        let forkNode = try #require(fallbackTree.session(fork.id))
        #expect(fallbackTree.roots.map(\.id) == [fork.id])
        // The node still honestly reports the parent it was forked from, even
        // though that parent is unresolvable in this loaded tree.
        #expect(forkNode.parentId == root.id)

        let forkEvents = try fallbackTree.events(forSession: fork.id)
        #expect(forkEvents.first { $0.kind == .prompt }?.text == "fork-turn-1")

        // fork claims a parent (root.id) that cannot be resolved in this
        // loaded tree, so its effective transcript cannot be honestly
        // reconstructed — this must fail loudly, never silently return just
        // fork's own turns as if that were its whole conversation.
        #expect(throws: TranscriptTreeError.parentUnresolvable(fork.id)) {
            _ = try fallbackTree.effectiveEntryEvents(forSession: fork.id)
        }
    }

    // MARK: - Orphan with a known forkedAtEntryCount still fails loudly

    @Test("effectiveEntryEvents throws parentUnresolvable for an index-loaded node whose parent record is missing, even though its own forkedAtEntryCount is known")
    func effectiveEntryEventsThrowsForOrphanWithKnownForkedAtEntryCount() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let writer = SessionIndexWriter(directory: dir)
        let missingParentId = ULID.generate()
        let orphanId = ULID.generate()
        // Only the child's own record is written — as if the parent's own
        // index line was dropped by SessionIndexWriter's best-effort
        // log-and-drop failure policy, while the child's own line wrote
        // fine. `missingParentId` never appears as a record in this index.
        let orphanRecord = SessionIndexRecord(
            sessionId: orphanId,
            parentId: missingParentId,
            path: "orphan-path",
            forkedAtEntryCount: 2,
            slot: .standard,
            model: "org/model-a",
            instructions: nil,
            grammar: nil,
            createdAt: Date()
        )
        await writer.append(orphanRecord)

        let tree = try TranscriptTree.load(under: dir)
        let node = try #require(tree.session(orphanId))
        #expect(node.parentId == missingParentId)
        #expect(node.forkedAtEntryCount == 2)
        // Promoted to a root of the loaded (partial) tree since its parent
        // is unresolvable.
        #expect(tree.roots.map(\.id) == [orphanId])

        // A real, known cut point exists, but the ancestor data it would
        // truncate is gone — that is a stronger reason to fail than "unknown
        // count", not a reason to silently return partial data.
        #expect(throws: TranscriptTreeError.parentUnresolvable(orphanId)) {
            _ = try tree.effectiveEntryEvents(forSession: orphanId)
        }
    }

    // MARK: - A present-but-empty sessions.jsonl still triggers the fallback

    @Test("a present but empty sessions.jsonl (e.g. a partial write failure) still falls back to enumerating transcript.jsonl")
    @MainActor
    func emptyIndexFileStillTriggersFallback() async throws {
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
        let (root, forkA, forkB, grandfork) = try await Self.buildBranchingTree(profile: profile)

        let routerDir = routerDirectory(router: router, recordingsDir: recordingsDir)
        let indexFileURL = routerDir.appendingPathComponent("sessions.jsonl", isDirectory: false)
        // Simulate a dropped write that still left the file present (created,
        // but its line never successfully appended) — the file exists but
        // decodes to zero records, distinct from the file being missing
        // entirely.
        try Data().write(to: indexFileURL)

        let fallbackTree = try TranscriptTree.load(under: routerDir)

        #expect(fallbackTree.roots.map(\.id) == [root.id])
        #expect(Set(fallbackTree.children(of: root.id).map(\.id)) == Set([forkA.id, forkB.id]))
        #expect(fallbackTree.children(of: forkA.id).map(\.id) == [grandfork.id])
        // Recovered via the fallback, so the cut point is unknown, just like
        // the missing-file fallback case.
        #expect(fallbackTree.session(forkA.id)?.forkedAtEntryCount == nil)
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
        let router = Self.makeRouter(recorder: recorder, cacheDir: cacheDir, recordingsDir: recordingsDir)
        let profile = try await router.resolve(profile: Self.profile, reporting: ResolutionProgress())

        let root = profile.standard.makeSession()
        _ = try await root.respond(to: "root-turn-1")

        let routerDir = routerDirectory(router: router, recordingsDir: recordingsDir)
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
