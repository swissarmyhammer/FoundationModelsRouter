import Foundation
import FoundationModels
import Testing

@testable import FoundationModelsRouter

/// Exercises task zcxnbst: restoring a whole session tree from disk by root
/// session id — ``RoutedModel/restoreSessionTree(root:registry:)`` — the
/// final piece of plan.md's "Transcript fidelity" section, "Reconstruction
/// end-to-end".
///
/// Everything here runs against stubs — a stub ``ModelLoader``, a canned LLM
/// container backed by ``StubSessionBackend``, and a ``JSONLRecorder``
/// writing into a temp directory — so the suite needs no network and no GPU.
/// A "fresh process" is simulated by resolving a *second*, independently
/// constructed ``Router``/``LanguageModelProfile`` pointed at the *same*
/// `id` and recordings directory as the first — mirroring how the gated
/// integration suite discards the original `Router` and every in-memory
/// session before restoring.
@Suite("Session tree restoration: restoreSessionTree(root:registry:)")
struct SessionTreeRestorationTests {
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

    /// A differently-resolving profile definition: its `.standard`/`.flash`
    /// slots pick different models than ``profile`` does, so resolving it
    /// simulates a "fresh process" whose resident model no longer matches
    /// what a recording was made against.
    private static let mismatchProfile = ProfileDefinition(
        name: "coding-mismatch",
        description: "a differently-resolving profile for the model-mismatch test",
        standard: ["org/std-b"],
        flash: ["org/flash-b"],
        embedding: ["org/emb-a"]
    )

    private static let stubDimension = 8
    private static let cannedText = "canned response"

    private static func makeTempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SessionTreeRestorationTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Builds a router wired with the stubs and a durable recordings root, so
    /// vended sessions nest their transcripts and index under it.
    ///
    /// - Parameter id: The router id to construct with — pass the first
    ///   router's `id` to simulate a fresh process continuing the same
    ///   recording root.
    private static func makeRouter(
        id: ULID = .generate(),
        cacheDir: URL,
        recordingsDir: URL,
        maxConcurrentForks: Int = 4
    ) -> Router {
        Router(
            id: id,
            maxConcurrentForks: maxConcurrentForks,
            cacheDir: cacheDir,
            recordingsDir: recordingsDir,
            recorder: JSONLRecorder(directory: recordingsDir),
            probe: StubProbe(chip: "Apple Test", totalRAM: 64 << 30, recommendedMaxWorkingSetSize: 48 << 30),
            metadataSource: StubMetadataSource(raw: rawMetadata),
            loader: StubModelLoader(dimension: stubDimension, text: cannedText)
        )
    }

    /// Reads every session index record under a router id's recording root.
    private func records(routerId: ULID, recordingsDir: URL) throws -> [SessionIndexRecord] {
        try SessionIndexWriter.read(
            under: recordingsDir.appendingPathComponent(routerId.description, isDirectory: true)
        )
    }

    // MARK: - Tree shape restoration

    @Test("restoring a 4-node tree by root id reproduces its shape and per-node effective entry counts")
    @MainActor
    func restoringReproducesTreeShapeAndEntryCounts() async throws {
        let cacheDir = Self.makeTempDir()
        let recordingsDir = Self.makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: cacheDir)
            try? FileManager.default.removeItem(at: recordingsDir)
        }

        let router1 = Self.makeRouter(cacheDir: cacheDir, recordingsDir: recordingsDir)
        let profile1 = try await router1.resolve(profile: Self.profile, reporting: ResolutionProgress())

        let root = profile1.standard.makeSession()
        _ = try await root.respond(to: "remember 42")
        let forkA = try await root.fork(workingDirectory: nil)
        _ = try await forkA.respond(to: "forkA turn")
        let forkB = try await root.fork(workingDirectory: nil)
        let grandfork = try await forkA.fork(workingDirectory: nil)
        _ = try await grandfork.respond(to: "grandfork turn")

        // "Tear down": nothing below reaches back into router1/profile1
        // except reading the ids already captured above — a fresh router
        // simulates a new process continuing the same recording root.

        let router2 = Self.makeRouter(id: router1.id, cacheDir: cacheDir, recordingsDir: recordingsDir)
        let profile2 = try await router2.resolve(profile: Self.profile, reporting: ResolutionProgress())

        let restored = try await profile2.standard.restoreSessionTree(root: root.id)

        #expect(restored.root.id == root.id)
        #expect(restored.root.parentId == nil)

        let childIds = Set(restored.children(of: root.id).map(\.id))
        #expect(childIds == [forkA.id, forkB.id])
        #expect(restored.children(of: forkA.id).map(\.id) == [grandfork.id])
        #expect(restored.children(of: forkB.id).isEmpty)

        // Per-node effective entry counts, verified independently through
        // `TranscriptTree` rather than any private actor state:
        // root: 1 turn (prompt+response) == 2.
        // forkA: root's 2 inherited + its own 1 turn == 4.
        // forkB: root's 2 inherited + no own turn == 2.
        // grandfork: forkA's 4 inherited + its own 1 turn == 6.
        let routerDirectory = recordingsDir.appendingPathComponent(router1.id.description, isDirectory: true)
        let tree = try TranscriptTree.load(under: routerDirectory)
        #expect(try tree.effectiveEntryEvents(forSession: root.id).count == 2)
        #expect(try tree.effectiveEntryEvents(forSession: forkA.id).count == 4)
        #expect(try tree.effectiveEntryEvents(forSession: forkB.id).count == 2)
        #expect(try tree.effectiveEntryEvents(forSession: grandfork.id).count == 6)

        // A new turn on a restored leaf that never generated before persists
        // only its own new delta: its transcript.jsonl did not exist at all
        // before restoration, so the restored session's persistedEntryCount
        // must have started at its reconstructed count (2, inherited from
        // root), not 0 — else this turn would re-persist the two inherited
        // entries on top of its own.
        let restoredForkB = try #require(restored.session(forkB.id))
        _ = try await restoredForkB.respond(to: "forkB's first turn, post-restore")

        let reloadedTree = try TranscriptTree.load(under: routerDirectory)
        #expect(try reloadedTree.effectiveEntryEvents(forSession: forkB.id).count == 4)
    }

    // MARK: - sessions.jsonl untouched by restoration

    @Test("restoreSessionTree writes zero new sessions.jsonl records; a later fork of a restored session appends exactly one")
    @MainActor
    func restorationAppendsNoIndexRecordsButLaterForkAppendsOne() async throws {
        let cacheDir = Self.makeTempDir()
        let recordingsDir = Self.makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: cacheDir)
            try? FileManager.default.removeItem(at: recordingsDir)
        }

        let router1 = Self.makeRouter(cacheDir: cacheDir, recordingsDir: recordingsDir)
        let profile1 = try await router1.resolve(profile: Self.profile, reporting: ResolutionProgress())

        let root = profile1.standard.makeSession()
        _ = try await root.respond(to: "hello")
        let fork = try await root.fork(workingDirectory: nil)
        _ = fork

        let indexFileURL = recordingsDir
            .appendingPathComponent(router1.id.description, isDirectory: true)
            .appendingPathComponent("sessions.jsonl", isDirectory: false)
        let bytesBeforeRestore = try Data(contentsOf: indexFileURL)

        let router2 = Self.makeRouter(id: router1.id, cacheDir: cacheDir, recordingsDir: recordingsDir)
        let profile2 = try await router2.resolve(profile: Self.profile, reporting: ResolutionProgress())
        let restored = try await profile2.standard.restoreSessionTree(root: root.id)

        let bytesAfterRestore = try Data(contentsOf: indexFileURL)
        #expect(bytesAfterRestore == bytesBeforeRestore)

        let recordsBeforeNewFork = try records(routerId: router1.id, recordingsDir: recordingsDir)
        #expect(recordsBeforeNewFork.count == 2)

        // A brand-new fork taken *from a restored session* appends normally,
        // exactly like any other fork.
        let newFork = try await restored.root.fork(workingDirectory: nil)

        let recordsAfterNewFork = try records(routerId: router1.id, recordingsDir: recordingsDir)
        #expect(recordsAfterNewFork.count == 3)
        #expect(recordsAfterNewFork.contains { $0.sessionId == newFork.id && $0.parentId == root.id })
    }

    // MARK: - Typed errors

    @Test("restoring by a non-root session id throws notARootSession")
    @MainActor
    func restoringNonRootIdThrowsNotARootSession() async throws {
        let cacheDir = Self.makeTempDir()
        let recordingsDir = Self.makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: cacheDir)
            try? FileManager.default.removeItem(at: recordingsDir)
        }

        let router1 = Self.makeRouter(cacheDir: cacheDir, recordingsDir: recordingsDir)
        let profile1 = try await router1.resolve(profile: Self.profile, reporting: ResolutionProgress())
        let root = profile1.standard.makeSession()
        let fork = try await root.fork(workingDirectory: nil)

        let router2 = Self.makeRouter(id: router1.id, cacheDir: cacheDir, recordingsDir: recordingsDir)
        let profile2 = try await router2.resolve(profile: Self.profile, reporting: ResolutionProgress())

        await #expect(throws: SessionTreeRestorationError.notARootSession(fork.id)) {
            _ = try await profile2.standard.restoreSessionTree(root: fork.id)
        }
    }

    @Test("restoring against a profile whose resident model differs from the recorded one throws modelMismatch")
    @MainActor
    func restoringAgainstMismatchedModelThrowsModelMismatch() async throws {
        let cacheDir = Self.makeTempDir()
        let recordingsDir = Self.makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: cacheDir)
            try? FileManager.default.removeItem(at: recordingsDir)
        }

        let router1 = Self.makeRouter(cacheDir: cacheDir, recordingsDir: recordingsDir)
        let profile1 = try await router1.resolve(profile: Self.profile, reporting: ResolutionProgress())
        let root = profile1.standard.makeSession()
        _ = try await root.respond(to: "hello")

        // A second router resolved against a *different* profile definition —
        // its `.standard` slot resolves to a different model than the one
        // `root` was recorded against.
        let router2 = Self.makeRouter(id: router1.id, cacheDir: cacheDir, recordingsDir: recordingsDir)
        let profile2 = try await router2.resolve(profile: Self.mismatchProfile, reporting: ResolutionProgress())

        await #expect(
            throws: SessionTreeRestorationError.modelMismatch(
                session: root.id,
                slot: .standard,
                recorded: "org/std-a",
                resident: "org/std-b"
            )
        ) {
            _ = try await profile2.standard.restoreSessionTree(root: root.id)
        }
    }

    @Test("a session index record recorded against a non-generation slot throws slotNotInProfile")
    @MainActor
    func recordedEmbeddingSlotThrowsSlotNotInProfile() async throws {
        let cacheDir = Self.makeTempDir()
        let recordingsDir = Self.makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: cacheDir)
            try? FileManager.default.removeItem(at: recordingsDir)
        }

        let router1 = Self.makeRouter(cacheDir: cacheDir, recordingsDir: recordingsDir)
        let profile1 = try await router1.resolve(profile: Self.profile, reporting: ResolutionProgress())

        // Fabricate a root session's index record directly, bypassing the
        // normal makeSession/fork vending paths, with a slot no generation
        // handle exists for.
        let fabricatedId = ULID.generate()
        let writer = SessionIndexWriter(
            directory: recordingsDir.appendingPathComponent(router1.id.description, isDirectory: true)
        )
        await writer.append(
            SessionIndexRecord(
                sessionId: fabricatedId,
                parentId: nil,
                path: fabricatedId.description,
                forkedAtEntryCount: 0,
                slot: .embedding,
                model: "org/emb-a",
                instructions: nil,
                grammar: nil,
                createdAt: Date()
            )
        )

        let router2 = Self.makeRouter(id: router1.id, cacheDir: cacheDir, recordingsDir: recordingsDir)
        let profile2 = try await router2.resolve(profile: Self.profile, reporting: ResolutionProgress())

        await #expect(throws: SessionTreeRestorationError.slotNotInProfile(session: fabricatedId, slot: .embedding)) {
            _ = try await profile2.standard.restoreSessionTree(root: fabricatedId)
        }

        _ = profile1
    }

    // MARK: - Guided session restoration

    @Test("a restored guided session's next turn runs through the guided path with its recorded grammar")
    @MainActor
    func restoredGuidedSessionUsesRecordedGrammar() async throws {
        let cacheDir = Self.makeTempDir()
        let recordingsDir = Self.makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: cacheDir)
            try? FileManager.default.removeItem(at: recordingsDir)
        }

        let router1 = Self.makeRouter(cacheDir: cacheDir, recordingsDir: recordingsDir)
        let profile1 = try await router1.resolve(profile: Self.profile, reporting: ResolutionProgress())

        let grammarSource = #"{"type":"object"}"#
        let root = profile1.standard.makeGuidedSession(grammar: .jsonSchema(grammarSource))

        let router2 = Self.makeRouter(id: router1.id, cacheDir: cacheDir, recordingsDir: recordingsDir)
        let profile2 = try await router2.resolve(profile: Self.profile, reporting: ResolutionProgress())
        let restored = try await profile2.standard.restoreSessionTree(root: root.id)

        #expect(restored.root.grammar == .jsonSchema(grammarSource))

        // Driving a turn goes through the guided path — StubSessionBackend's
        // guided `respond` runs the real (GPU-free) xgrammar-subset
        // validation and, on success, the chokepoint records the grammar
        // onto the turn's events.
        _ = try await restored.root.respond(to: "produce an object")

        let recordingDirectory = recordingsDir
            .appendingPathComponent(router1.id.description, isDirectory: true)
            .appendingPathComponent(root.id.description, isDirectory: true)
        let fileURL = recordingDirectory.appendingPathComponent("transcript.jsonl", isDirectory: false)
        let text = try String(contentsOf: fileURL, encoding: .utf8)
        let decoder = JSONDecoder()
        let events = try text.split(separator: "\n").map { try decoder.decode(TranscriptEvent.self, from: Data($0.utf8)) }
        #expect(events.contains { $0.grammar == grammarSource })
    }

    /// Documents and locks in a known, deliberate restoration limitation (see
    /// ``RoutedModel/restoreSessionTree(root:registry:)``'s doc comment,
    /// "Known limitation: the `.ebnf` grammar case"): `SessionIndexRecord.grammar`
    /// persists only the grammar's `source` string, not which `Grammar` case
    /// it came from, so a session originally guided by `.ebnf(_:)` restores
    /// under the `.jsonSchema` case instead — its source text is preserved,
    /// but its case is not. This is a stub-only observation (the live MLX
    /// backend already unconditionally rejects `.ebnf` regardless of
    /// restoration, so this never regresses real generation).
    @Test("a restored session originally guided by .ebnf reconstructs its grammar as .jsonSchema, preserving only the source text")
    @MainActor
    func restoredEbnfGrammarReconstructsAsJSONSchema() async throws {
        let cacheDir = Self.makeTempDir()
        let recordingsDir = Self.makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: cacheDir)
            try? FileManager.default.removeItem(at: recordingsDir)
        }

        let router1 = Self.makeRouter(cacheDir: cacheDir, recordingsDir: recordingsDir)
        let profile1 = try await router1.resolve(profile: Self.profile, reporting: ResolutionProgress())

        let ebnfSource = #"root ::= "yes" | "no""#
        let root = profile1.standard.makeGuidedSession(grammar: .ebnf(ebnfSource))
        #expect(root.grammar == .ebnf(ebnfSource))

        let router2 = Self.makeRouter(id: router1.id, cacheDir: cacheDir, recordingsDir: recordingsDir)
        let profile2 = try await router2.resolve(profile: Self.profile, reporting: ResolutionProgress())
        let restored = try await profile2.standard.restoreSessionTree(root: root.id)

        #expect(restored.root.grammar == .jsonSchema(ebnfSource))
        #expect(restored.root.grammar != .ebnf(ebnfSource))
    }
}
