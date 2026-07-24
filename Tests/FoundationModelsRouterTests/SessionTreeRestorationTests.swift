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
            probe: StubProbe(
                chip: "Apple Test", totalRAM: 64 << 30, recommendedMaxWorkingSetSize: 48 << 30),
            metadataSource: StubMetadataSource(raw: rawMetadata),
            loader: StubModelLoader(dimension: stubDimension, text: cannedText)
        )
    }

    /// A router id's recording root.
    private func routerDirectory(routerId: ULID, recordingsDir: URL) -> URL {
        recordingsDir.appendingPathComponent(routerId.description, isDirectory: true)
    }

    /// The id of every session recorded under a router id's recording root.
    private func recordedSessionIds(routerId: ULID, recordingsDir: URL) throws -> Set<ULID> {
        let tree = try TranscriptTree.load(
            under: routerDirectory(routerId: routerId, recordingsDir: recordingsDir))
        func ids(_ node: SessionNode) -> [ULID] { [node.id] + node.children.flatMap(ids) }
        return Set(tree.roots.flatMap(ids))
    }

    // MARK: - Checkpoint-aware restore fixtures

    /// Builds a stamped `.response`-kind event carrying real `tokensIn`/
    /// `tokensOut` — the shape a genuine turn's diffed close takes, needed to
    /// exercise ``TranscriptTree/restoredUsageState(in:)``'s "newest stamp
    /// after the checkpoint" precedence tier.
    private static func stampedResponseEvent(
        seq: Int,
        sessionId: ULID,
        routerId: ULID,
        entryId: String,
        tokensIn: Int,
        tokensOut: Int
    ) -> TranscriptEvent {
        TranscriptEvent(
            routerId: routerId,
            sessionId: sessionId,
            seq: seq,
            ts: Date(timeIntervalSince1970: TimeInterval(seq)),
            kind: .response,
            tokensIn: tokensIn,
            tokensOut: tokensOut,
            entry: TranscriptEntryPayload(
                entryId: entryId,
                segments: [.text(id: "\(entryId)-text", content: "reply")],
                assetIds: []
            )
        )
    }

    // MARK: - Tree shape restoration

    @Test(
        "restoring a 4-node tree by root id reproduces its shape and per-node effective entry counts")
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
        let routerDirectory = recordingsDir.appendingPathComponent(
            router1.id.description, isDirectory: true)
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

    // MARK: - Durable working directory survives restoration (harness plan §7, task 6j4bven)

    @Test(
        "a session vended with an overridden working directory restores to that same directory, not its recording directory"
    )
    @MainActor
    func restoredSessionReassemblesItsRecordedWorkingDirectoryOverride() async throws {
        let cacheDir = Self.makeTempDir()
        let recordingsDir = Self.makeTempDir()
        let overrideDir = Self.makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: cacheDir)
            try? FileManager.default.removeItem(at: recordingsDir)
            try? FileManager.default.removeItem(at: overrideDir)
        }

        let router1 = Self.makeRouter(cacheDir: cacheDir, recordingsDir: recordingsDir)
        let profile1 = try await router1.resolve(profile: Self.profile, reporting: ResolutionProgress())

        let root = profile1.standard.makeSession(workingDirectory: overrideDir)
        _ = try await root.respond(to: "hello")
        #expect(root.workingDirectory == overrideDir)
        // The recording directory is never the override: this is exercising a
        // genuine divergence, not one that happens to coincide.
        #expect(root.recordingDirectory != overrideDir)

        let router2 = Self.makeRouter(id: router1.id, cacheDir: cacheDir, recordingsDir: recordingsDir)
        let profile2 = try await router2.resolve(profile: Self.profile, reporting: ResolutionProgress())
        let restored = try await profile2.standard.restoreSessionTree(root: root.id)

        // Restoration reassembles the recorded override, not the (also
        // restored, separately-verified-elsewhere) recording directory a
        // caller never asked to run against.
        #expect(restored.root.workingDirectory == overrideDir)
        #expect(restored.root.id == root.id)
    }

    // MARK: - Sidecars untouched by restoration

    @Test("restoreSessionTree writes no sidecar of its own; a later fork of a restored session writes exactly one")
    @MainActor
    func restorationWritesNoSidecarButLaterForkWritesOne() async throws {
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

        // A sidecar is write-once, so restoring a session must not touch the
        // one already sitting in its directory — byte-for-byte.
        let rootSidecarURL = routerDirectory(routerId: router1.id, recordingsDir: recordingsDir)
            .appendingPathComponent(root.id.description, isDirectory: true)
            .appendingPathComponent("session.json", isDirectory: false)
        let bytesBeforeRestore = try Data(contentsOf: rootSidecarURL)

        let router2 = Self.makeRouter(id: router1.id, cacheDir: cacheDir, recordingsDir: recordingsDir)
        let profile2 = try await router2.resolve(profile: Self.profile, reporting: ResolutionProgress())
        let restored = try await profile2.standard.restoreSessionTree(root: root.id)

        #expect(try Data(contentsOf: rootSidecarURL) == bytesBeforeRestore)
        #expect(
            try recordedSessionIds(routerId: router1.id, recordingsDir: recordingsDir) == [
                root.id, fork.id,
            ])

        // A brand-new fork taken *from a restored session* writes its own
        // sidecar normally, exactly like any other fork.
        let newFork = try await restored.root.fork(workingDirectory: nil)

        #expect(
            try recordedSessionIds(routerId: router1.id, recordingsDir: recordingsDir)
                == [root.id, fork.id, newFork.id]
        )
        let newForkNode = try #require(
            try TranscriptTree.load(
                under: routerDirectory(routerId: router1.id, recordingsDir: recordingsDir)
            )
            .session(newFork.id)
        )
        #expect(newForkNode.parentId == root.id)
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
        let profile2 = try await router2.resolve(
            profile: Self.mismatchProfile, reporting: ResolutionProgress())

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

    @Test("a session sidecar recorded against a non-generation slot throws slotNotInProfile")
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

        // Fabricate a root session's directory and sidecar directly,
        // bypassing the normal makeSession/fork vending paths, with a slot no
        // generation handle exists for.
        let fabricatedId = ULID.generate()
        let fabricatedDirectory = routerDirectory(routerId: router1.id, recordingsDir: recordingsDir)
            .appendingPathComponent(fabricatedId.description, isDirectory: true)
        try SessionSidecar.write(
            SessionSidecar(
                slot: .embedding,
                model: "org/emb-a",
                context: 4_096,
                instructions: nil,
                grammar: nil,
                recordingLevel: .full,
                forkedAtEntryCount: nil,
                profile: nil,
                workingDirectory: fabricatedDirectory
            ),
            to: fabricatedDirectory
        )

        let router2 = Self.makeRouter(id: router1.id, cacheDir: cacheDir, recordingsDir: recordingsDir)
        let profile2 = try await router2.resolve(profile: Self.profile, reporting: ResolutionProgress())

        await #expect(
            throws: SessionTreeRestorationError.slotNotInProfile(session: fabricatedId, slot: .embedding)
        ) {
            _ = try await profile2.standard.restoreSessionTree(root: fabricatedId)
        }

        _ = profile1
    }

    // MARK: - Guided session restoration

    @Test(
        "a restored guided session's next turn runs through the guided path with its recorded grammar")
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
    /// "Known limitation: the `.ebnf` grammar case"): `SessionSidecar.grammar`
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

    // MARK: - Checkpoint-aware restore: restores a compacted, under-budget session

    @Test(
        "restoreSessionTree restores a compacted, under-budget session with unchanged id; its sidecar carries the compaction count and its restored fill reflects the checkpoint's own tokensAfter"
    )
    @MainActor
    func restoringACompactedSessionYieldsCheckpointedWindowAndCompactionCount() async throws {
        let cacheDir = Self.makeTempDir()
        let recordingsDir = Self.makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: cacheDir)
            try? FileManager.default.removeItem(at: recordingsDir)
        }

        let router1 = Self.makeRouter(cacheDir: cacheDir, recordingsDir: recordingsDir)
        let profile1 = try await router1.resolve(profile: Self.profile, reporting: ResolutionProgress())

        let root = profile1.standard.makeSession()
        _ = try await root.respond(to: "turn 1")
        _ = try await root.respond(to: "turn 2")

        // Learn the real, SDK-assigned entry ids for turn 1 (to be folded
        // away) and turn 2 (the surviving tail), then fabricate and append a
        // compaction checkpoint referencing them directly onto the session's
        // own transcript.jsonl — the exact shape `RoutedSession.compact(prompt:budget:)`
        // itself appends, without driving the whole pipeline through a stub.
        let routerDir = routerDirectory(routerId: router1.id, recordingsDir: recordingsDir)
        let treeBeforeCheckpoint = try TranscriptTree.load(under: routerDir)
        let rawEvents = try treeBeforeCheckpoint.events(forSession: root.id)
        let prompts = rawEvents.filter { $0.kind == .prompt }
        let responses = rawEvents.filter { $0.kind == .response }
        let turn1PromptId = try #require(prompts.first?.entry?.entryId)
        let turn1ResponseId = try #require(responses.first?.entry?.entryId)
        let turn2PromptId = try #require(prompts.last?.entry?.entryId)
        let turn2ResponseId = try #require(responses.last?.entry?.entryId)
        let sessionContext = try #require(treeBeforeCheckpoint.session(root.id)?.sidecar.context)

        let checkpointEvent = try TranscriptFixtures.compactionCheckpointEvent(
            seq: rawEvents.count,
            sessionId: root.id,
            routerId: router1.id,
            entryId: "checkpoint-1",
            content: CompactionSegment.Content(
                liveWindowEntryIds: ["checkpoint-1", turn2PromptId, turn2ResponseId],
                foldedEntryIds: [turn1PromptId, turn1ResponseId],
                tokensBefore: 1_000,
                tokensAfter: 321,
                stagesApplied: ["Summarization"],
                promptName: "default"
            )
        )
        let transcriptURL = routerDir
            .appendingPathComponent(root.id.description, isDirectory: true)
            .appendingPathComponent("transcript.jsonl", isDirectory: false)
        let existing = try String(contentsOf: transcriptURL, encoding: .utf8)
        let checkpointLine = String(data: try JSONEncoder().encode(checkpointEvent), encoding: .utf8)!
        try (existing + checkpointLine + "\n").write(to: transcriptURL, atomically: true, encoding: .utf8)

        // "Tear down" and restore under a fresh process.
        let router2 = Self.makeRouter(id: router1.id, cacheDir: cacheDir, recordingsDir: recordingsDir)
        let profile2 = try await router2.resolve(profile: Self.profile, reporting: ResolutionProgress())
        let restored = try await profile2.standard.restoreSessionTree(root: root.id)

        #expect(restored.root.id == root.id)

        let reloadedTree = try TranscriptTree.load(under: routerDir)
        let restoredWindow = try reloadedTree.effectiveTranscript(forSession: root.id)
        #expect(Array(restoredWindow).map(\.id) == ["checkpoint-1", turn2PromptId, turn2ResponseId])
        #expect(reloadedTree.session(root.id)?.sidecar.compactionCount == 1)

        // Under budget: the checkpoint is the newest thing (no turn ran
        // after it before restore), so restored fill reports its own
        // `tokensAfter` — never the full pre-fold size.
        let fill = await restored.root.contextFill
        #expect(fill == Double(321) / Double(sessionContext))
    }

    // MARK: - Checkpoint-aware restored fill precedence

    @Test("restoredUsageState: a stamped response after the newest checkpoint wins over the checkpoint's own tokensAfter")
    func restoredUsageStatePrefersStampAfterCheckpoint() throws {
        let sessionId = ULID.generate()
        let routerId = ULID.generate()
        let checkpointEvent = try TranscriptFixtures.compactionCheckpointEvent(
            seq: 0,
            sessionId: sessionId,
            routerId: routerId,
            entryId: "checkpoint-1",
            content: CompactionSegment.Content(
                liveWindowEntryIds: ["checkpoint-1"],
                foldedEntryIds: [],
                tokensBefore: 1_000,
                tokensAfter: 300,
                stagesApplied: ["Summarization"],
                promptName: "default"
            )
        )
        let stampedEvent = Self.stampedResponseEvent(
            seq: 1, sessionId: sessionId, routerId: routerId, entryId: "post-response-1",
            tokensIn: 50, tokensOut: 20
        )

        let state = TranscriptTree.restoredUsageState(in: [checkpointEvent, stampedEvent])
        #expect(state == .measured(input: 50, output: 20))
    }

    @Test("restoredUsageState: a checkpoint with no stamped response after it falls back to the checkpoint's own tokensAfter")
    func restoredUsageStateFallsBackToCheckpointTokensAfter() throws {
        let sessionId = ULID.generate()
        let routerId = ULID.generate()
        let checkpointEvent = try TranscriptFixtures.compactionCheckpointEvent(
            seq: 0,
            sessionId: sessionId,
            routerId: routerId,
            entryId: "checkpoint-1",
            content: CompactionSegment.Content(
                liveWindowEntryIds: ["checkpoint-1"],
                foldedEntryIds: [],
                tokensBefore: 1_000,
                tokensAfter: 300,
                stagesApplied: ["Summarization"],
                promptName: "default"
            )
        )

        let state = TranscriptTree.restoredUsageState(in: [checkpointEvent])
        #expect(state == .measured(input: 300, output: 0))
    }

    @Test("restoredUsageState: no checkpoint at all falls back to the newest stamped response anywhere, else unknown")
    func restoredUsageStateWithNoCheckpointFallsBackToPlainNewestStampOrUnknown() throws {
        let sessionId = ULID.generate()
        let routerId = ULID.generate()
        let stampedEvent = Self.stampedResponseEvent(
            seq: 0, sessionId: sessionId, routerId: routerId, entryId: "response-1",
            tokensIn: 10, tokensOut: 5
        )

        #expect(TranscriptTree.restoredUsageState(in: [stampedEvent]) == .measured(input: 10, output: 5))
        #expect(TranscriptTree.restoredUsageState(in: []) == .unknown)
    }

    @Test("restoredUsageState: a stamped response recorded before the checkpoint is ignored — only a stamp strictly after it, or its own tokensAfter, ever governs")
    func restoredUsageStateIgnoresStampBeforeCheckpoint() throws {
        let sessionId = ULID.generate()
        let routerId = ULID.generate()
        // Deliberately implausible usage (999/999) on the pre-checkpoint
        // stamp: if the "strictly after" boundary in `restoredUsageState`
        // ever regressed to include the checkpoint's own index or anything
        // before it, this value would leak through and the assertion below
        // would fail.
        let olderStampedEvent = Self.stampedResponseEvent(
            seq: 0, sessionId: sessionId, routerId: routerId, entryId: "pre-response-1",
            tokensIn: 999, tokensOut: 999
        )
        let checkpointEvent = try TranscriptFixtures.compactionCheckpointEvent(
            seq: 1,
            sessionId: sessionId,
            routerId: routerId,
            entryId: "checkpoint-1",
            content: CompactionSegment.Content(
                liveWindowEntryIds: ["checkpoint-1"],
                foldedEntryIds: ["pre-response-1"],
                tokensBefore: 1_000,
                tokensAfter: 300,
                stagesApplied: ["Summarization"],
                promptName: "default"
            )
        )

        let state = TranscriptTree.restoredUsageState(in: [olderStampedEvent, checkpointEvent])
        #expect(state == .measured(input: 300, output: 0))
    }

    @Test("restoredUsageState: the after-checkpoint slice starts strictly at checkpoint.index + 1, excluding the checkpoint event's own position")
    func restoredUsageStateAfterSliceExcludesCheckpointsOwnIndex() throws {
        // A real compaction checkpoint never carries a `tokensIn`/`tokensOut`
        // stamp of its own — `RoutedSessionActor.compact(prompt:budget:)`
        // appends its diff partials with no usage stamped on them (see
        // `RoutedSession.swift`) — so this event is synthetic: it
        // deliberately carries both a `CompactionSegment` *and* a stamp, the
        // only way to make the exact array-slice boundary
        // (`events[(checkpoint.index + 1)...]`, not `events[checkpoint.index...]`)
        // observable rather than merely documented. If that boundary ever
        // regressed to include the checkpoint's own index, `newestStampedUsage`
        // would find this event's stamp (111/222) instead of falling back to
        // its `tokensAfter` (300).
        let sessionId = ULID.generate()
        let routerId = ULID.generate()
        let content = CompactionSegment.Content(
            liveWindowEntryIds: ["checkpoint-1"],
            foldedEntryIds: [],
            tokensBefore: 1_000,
            tokensAfter: 300,
            stagesApplied: ["Summarization"],
            promptName: "default"
        )
        let contentJSON = String(data: try JSONEncoder().encode(content), encoding: .utf8)!
        let checkpointEventWithOwnStamp = TranscriptEvent(
            routerId: routerId,
            sessionId: sessionId,
            seq: 0,
            ts: Date(timeIntervalSince1970: 0),
            kind: .response,
            text: "summary",
            tokensIn: 111,
            tokensOut: 222,
            entry: TranscriptEntryPayload(
                entryId: "checkpoint-1",
                segments: [
                    .text(id: "checkpoint-1-text", content: "summary"),
                    .custom(
                        id: "checkpoint-1-segment",
                        typeDiscriminator: CompactionSegment.typeDiscriminator,
                        contentJSON: contentJSON,
                        description: nil
                    ),
                ],
                assetIds: []
            )
        )

        let state = TranscriptTree.restoredUsageState(in: [checkpointEventWithOwnStamp])
        #expect(state == .measured(input: 300, output: 0))
    }
}
