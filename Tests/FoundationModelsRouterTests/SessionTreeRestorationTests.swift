import Foundation
import FoundationModels
import FoundationModelsExtras
import Testing

@testable import FoundationModelsRouter

/// Exercises task zcxnbst: restoring a whole session tree from disk by root
/// session id —
/// ``RoutedModel/restoreSessionTree(root:recordingRoot:instructions:tools:toolOutputProtection:isNoOpToolCall:userPresence:hookSessionKey:)``
/// — the final piece of plan.md's "Transcript fidelity" section,
/// "Reconstruction end-to-end".
///
/// Everything here runs against stubs — a stub ``ModelLoader``, a canned LLM
/// container backed by ``StubSessionBackend``, and a ``JSONLRecorder``
/// writing into a temp directory — so the suite needs no network and no GPU.
/// A "fresh process" is simulated by resolving a *second*, independently
/// constructed ``Router``/``LanguageModelProfile`` pointed at the *same*
/// `id` and recordings directory as the first — mirroring how the gated
/// integration suite discards the original `Router` and every in-memory
/// session before restoring.
@Suite("Session tree restoration: restoreSessionTree(root:)")
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

    /// Builds a router wired with the stubs and a durable recordings root, so
    /// vended sessions nest their transcripts and index under it.
    ///
    /// - Parameters:
    ///   - id: The router id to construct with — pass the first router's `id`
    ///     to simulate a fresh process continuing the same recording root.
    ///   - cacheDir: The disposable cache directory.
    ///   - recordingsDir: The durable recordings root.
    ///   - recorder: The recorder to construct with. A recording root admits
    ///     one live writer, so a continuation router that must *write* while
    ///     the first router is still alive in this process has to share the
    ///     first writer's recorder; `nil` (the default) makes a fresh one.
    ///   - pool: The resident-model pool. Defaults to a fresh pool, so parallel suites never share residents.
    private static func makeRouter(
        id: ULID = .generate(),
        cacheDir: URL,
        recordingsDir: URL,
        recorder: JSONLRecorder? = nil,
        pool: ModelPool = ModelPool()
    ) -> Router {
        Router(
            id: id,
            cacheDir: cacheDir,
            recordingsDir: recordingsDir,
            recorder: recorder ?? JSONLRecorder(directory: recordingsDir),
            probe: StubProbe(
                chip: "Apple Test", totalRAM: 64 << 30, recommendedMaxWorkingSetSize: 48 << 30),
            metadataSource: StubMetadataSource(raw: rawMetadata),
            loader: StubModelLoader(dimension: stubDimension, text: cannedText),
            pool: pool
        )
    }

    /// The id of every session recorded under a router id's recording root.
    private func recordedSessionIds(routerId: ULID, recordingsDir: URL) throws -> Set<ULID> {
        let tree = try TranscriptTree.load(
            under: RouterTestFixtures.routerDirectory(routerId: routerId, recordingsDir: recordingsDir))
        func ids(_ node: SessionNode) -> [ULID] { [node.id] + node.children.flatMap(ids) }
        return Set(tree.roots.flatMap(ids))
    }

    // MARK: - Checkpoint-aware restore fixtures

    /// Builds a stamped `.response`-kind event carrying real `tokensIn`/
    /// `tokensOut` — the shape a genuine submission's diffed close takes, needed to
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

    // MARK: - Durable working directory survives restoration (task 6j4bven)

    @Test(
        "a session vended with an overridden working directory restores to that same directory, not its recording directory"
    )
    @MainActor
    func restoredSessionReassemblesItsRecordedWorkingDirectoryOverride() async throws {
        let cacheDir = RouterTestFixtures.makeTempDir(prefix: "SessionTreeRestorationTests")
        let recordingsDir = RouterTestFixtures.makeTempDir(prefix: "SessionTreeRestorationTests")
        let overrideDir = RouterTestFixtures.makeTempDir(prefix: "SessionTreeRestorationTests")
        defer {
            try? FileManager.default.removeItem(at: cacheDir)
            try? FileManager.default.removeItem(at: recordingsDir)
            try? FileManager.default.removeItem(at: overrideDir)
        }

        let router1 = Self.makeRouter(cacheDir: cacheDir, recordingsDir: recordingsDir)
        let profile1 = try await router1.resolve(profile: Self.profile, reporting: ResolutionProgress())

        let root = profile1.standard.makeSession(workingDirectory: overrideDir)
        defer { await root.close() }
        _ = try await root.respond(to: "hello")
        #expect(root.workingDirectory == overrideDir)
        // The recording directory is never the override: this is exercising a
        // genuine divergence, not one that happens to coincide.
        #expect(root.recordingDirectory != overrideDir)

        let router2 = Self.makeRouter(id: router1.id, cacheDir: cacheDir, recordingsDir: recordingsDir)
        let profile2 = try await router2.resolve(profile: Self.profile, reporting: ResolutionProgress())
        let restored = try await profile2.standard.restoreSessionTree(root: root.id)
        defer { await restored.root.close() }

        // Restoration reassembles the recorded override, not the (also
        // restored, separately-verified-elsewhere) recording directory a
        // caller never asked to run against.
        #expect(restored.root.workingDirectory == overrideDir)
        #expect(restored.root.id == root.id)
    }

    // MARK: - Index files untouched by restoration

    /// A restore does not rewrite the root's `index.md`.
    @Test("restoreSessionTree does not rewrite the root's index.md")
    @MainActor
    func restorationLeavesTheIndex() async throws {
        let cacheDir = RouterTestFixtures.makeTempDir(prefix: "SessionTreeRestorationTests")
        let recordingsDir = RouterTestFixtures.makeTempDir(prefix: "SessionTreeRestorationTests")
        defer {
            try? FileManager.default.removeItem(at: cacheDir)
            try? FileManager.default.removeItem(at: recordingsDir)
        }

        let router1 = Self.makeRouter(cacheDir: cacheDir, recordingsDir: recordingsDir)
        let profile1 = try await router1.resolve(profile: Self.profile, reporting: ResolutionProgress())

        let root = profile1.standard.makeSession()
        defer { await root.close() }
        _ = try await root.respond(to: "hello")

        // Restoring a session must not rewrite the index.md already sitting
        // in its directory — byte-for-byte.
        let rootIndexURL = RouterTestFixtures.indexURL(
            of: root.id, routerId: router1.id, recordingsDir: recordingsDir)
        let bytesBeforeRestore = try Data(contentsOf: rootIndexURL)

        let router2 = Self.makeRouter(id: router1.id, cacheDir: cacheDir, recordingsDir: recordingsDir)
        let profile2 = try await router2.resolve(profile: Self.profile, reporting: ResolutionProgress())
        let restored = try await profile2.standard.restoreSessionTree(root: root.id)
        defer { await restored.root.close() }

        #expect(try Data(contentsOf: rootIndexURL) == bytesBeforeRestore)
        #expect(try recordedSessionIds(routerId: router1.id, recordingsDir: recordingsDir) == [root.id])
    }

    // MARK: - Typed errors

    /// A root whose `index.md` record names a schema version newer than this
    /// reader fails the restore with the typed newer-router error.
    @Test("restoring a tree whose index.md carries a future schema version throws the typed newer-router error")
    @MainActor
    func restoringAFutureVersionIndexThrowsTheTypedError() async throws {
        let cacheDir = RouterTestFixtures.makeTempDir(prefix: "SessionTreeRestorationTests")
        let recordingsDir = RouterTestFixtures.makeTempDir(prefix: "SessionTreeRestorationTests")
        defer {
            try? FileManager.default.removeItem(at: cacheDir)
            try? FileManager.default.removeItem(at: recordingsDir)
        }

        let router1 = Self.makeRouter(cacheDir: cacheDir, recordingsDir: recordingsDir)
        let profile1 = try await router1.resolve(profile: Self.profile, reporting: ResolutionProgress())
        let root = profile1.standard.makeSession()
        defer { await root.close() }
        _ = try await root.respond(to: "hello")

        // Restamp the recorded root index.md with a version this reader does
        // not know — the fabricated future-version recording of the
        // acceptance criteria.
        let futureVersion = RecordingSchemaVersion.current + 1
        try RouterTestFixtures.rewriteIndex(
            in: RouterTestFixtures.sessionDirectory(of: root.id, routerId: router1.id, recordingsDir: recordingsDir)
        ) { $0.schemaVersion = futureVersion }

        let router2 = Self.makeRouter(id: router1.id, cacheDir: cacheDir, recordingsDir: recordingsDir)
        let profile2 = try await router2.resolve(profile: Self.profile, reporting: ResolutionProgress())

        await #expect(throws: RecordingSchemaVersionError.self) {
            // A restore that does not throw fails the test; its root closes.
            try await profile2.standard.restoreSessionTree(root: root.id).root.close()
        }
    }

    @Test("restoring against a profile whose resident model differs from the recorded one throws modelMismatch")
    @MainActor
    func restoringAgainstMismatchedModelThrowsModelMismatch() async throws {
        let cacheDir = RouterTestFixtures.makeTempDir(prefix: "SessionTreeRestorationTests")
        let recordingsDir = RouterTestFixtures.makeTempDir(prefix: "SessionTreeRestorationTests")
        defer {
            try? FileManager.default.removeItem(at: cacheDir)
            try? FileManager.default.removeItem(at: recordingsDir)
        }

        let router1 = Self.makeRouter(cacheDir: cacheDir, recordingsDir: recordingsDir)
        let profile1 = try await router1.resolve(profile: Self.profile, reporting: ResolutionProgress())
        let root = profile1.standard.makeSession()
        defer { await root.close() }
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
            // A restore that does not throw fails the test; its root closes.
            try await profile2.standard.restoreSessionTree(root: root.id).root.close()
        }
    }

    /// The working context, in tokens, of the fabricated embedding-slot
    /// record of ``recordedEmbeddingSlotThrowsSlotNotInProfile()``.
    private static let fabricatedEmbeddingContext = 4_096

    /// A record against a slot no generation handle serves fails the
    /// restore with `slotNotInProfile`.
    @Test("a session index.md recorded against a non-generation slot throws slotNotInProfile")
    @MainActor
    func recordedEmbeddingSlotThrowsSlotNotInProfile() async throws {
        let cacheDir = RouterTestFixtures.makeTempDir(prefix: "SessionTreeRestorationTests")
        let recordingsDir = RouterTestFixtures.makeTempDir(prefix: "SessionTreeRestorationTests")
        defer {
            try? FileManager.default.removeItem(at: cacheDir)
            try? FileManager.default.removeItem(at: recordingsDir)
        }

        let router1 = Self.makeRouter(cacheDir: cacheDir, recordingsDir: recordingsDir)
        let profile1 = try await router1.resolve(profile: Self.profile, reporting: ResolutionProgress())

        // Fabricate a root session's directory and index.md directly,
        // bypassing the normal makeSession vending path, with a slot no
        // generation handle exists for.
        let fabricatedId = ULID.generate()
        let fabricatedDirectory = RouterTestFixtures.routerDirectory(routerId: router1.id, recordingsDir: recordingsDir)
            .appendingPathComponent(fabricatedId.description, isDirectory: true)
        try SessionRecordFixtures.write(
            SessionRecord(
                sessionId: fabricatedId,
                workingDirectory: fabricatedDirectory,
                updatedAt: Date(),
                slot: .embedding,
                model: "org/emb-a",
                context: Self.fabricatedEmbeddingContext,
                recordingLevel: .full,
                routerId: router1.id
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
        "a restored guided session's next answer runs through the guided path with its recorded grammar")
    @MainActor
    func restoredGuidedSessionUsesRecordedGrammar() async throws {
        let cacheDir = RouterTestFixtures.makeTempDir(prefix: "SessionTreeRestorationTests")
        let recordingsDir = RouterTestFixtures.makeTempDir(prefix: "SessionTreeRestorationTests")
        defer {
            try? FileManager.default.removeItem(at: cacheDir)
            try? FileManager.default.removeItem(at: recordingsDir)
        }

        let router1 = Self.makeRouter(cacheDir: cacheDir, recordingsDir: recordingsDir)
        let profile1 = try await router1.resolve(profile: Self.profile, reporting: ResolutionProgress())

        let grammarSource = #"{"type":"object"}"#
        let root = profile1.standard.makeGuidedSession(grammar: .jsonSchema(grammarSource))
        defer { await root.close() }

        let router2 = Self.makeRouter(id: router1.id, cacheDir: cacheDir, recordingsDir: recordingsDir)
        let profile2 = try await router2.resolve(profile: Self.profile, reporting: ResolutionProgress())
        let restored = try await profile2.standard.restoreSessionTree(root: root.id)
        defer { await restored.root.close() }

        #expect(restored.root.grammar == .jsonSchema(grammarSource))

        // Driving an answer goes through the guided path — StubSessionBackend's
        // guided `respond` runs the real (GPU-free) xgrammar-subset
        // validation and, on success, the chokepoint records the grammar
        // onto the events of the submission.
        _ = try await restored.root.respond(to: "produce an object")

        let recordingDirectory = recordingsDir
            .appendingPathComponent(router1.id.description, isDirectory: true)
            .appendingPathComponent(root.id.description, isDirectory: true)
        let fileURL = recordingDirectory.appendingPathComponent("transcript.jsonl", isDirectory: false)
        let events = try JSONLFile(url: fileURL).records(as: TranscriptEvent.self)
        #expect(events.contains { $0.grammar == grammarSource })
    }

    /// Documents and locks in a known, deliberate restoration limitation (see
    /// ``RoutedModel/restoreSessionTree(root:recordingRoot:instructions:tools:toolOutputProtection:isNoOpToolCall:userPresence:hookSessionKey:)``'s
    /// doc comment, "Known limitation: the `.ebnf` grammar case"):
    /// `SessionRecord.grammar`
    /// persists only the grammar's `source` string, not which `Grammar` case
    /// it came from, so a session originally guided by `.ebnf(_:)` restores
    /// under the `.jsonSchema` case instead — its source text is preserved,
    /// but its case is not. This is a stub-only observation (the live MLX
    /// backend already unconditionally rejects `.ebnf` regardless of
    /// restoration, so this never regresses real generation).
    @Test("a restored session originally guided by .ebnf reconstructs its grammar as .jsonSchema, preserving only the source text")
    @MainActor
    func restoredEbnfGrammarReconstructsAsJSONSchema() async throws {
        let cacheDir = RouterTestFixtures.makeTempDir(prefix: "SessionTreeRestorationTests")
        let recordingsDir = RouterTestFixtures.makeTempDir(prefix: "SessionTreeRestorationTests")
        defer {
            try? FileManager.default.removeItem(at: cacheDir)
            try? FileManager.default.removeItem(at: recordingsDir)
        }

        let router1 = Self.makeRouter(cacheDir: cacheDir, recordingsDir: recordingsDir)
        let profile1 = try await router1.resolve(profile: Self.profile, reporting: ResolutionProgress())

        let ebnfSource = #"root ::= "yes" | "no""#
        let root = profile1.standard.makeGuidedSession(grammar: .ebnf(ebnfSource))
        defer { await root.close() }
        #expect(root.grammar == .ebnf(ebnfSource))

        let router2 = Self.makeRouter(id: router1.id, cacheDir: cacheDir, recordingsDir: recordingsDir)
        let profile2 = try await router2.resolve(profile: Self.profile, reporting: ResolutionProgress())
        let restored = try await profile2.standard.restoreSessionTree(root: root.id)
        defer { await restored.root.close() }

        #expect(restored.root.grammar == .jsonSchema(ebnfSource))
        #expect(restored.root.grammar != .ebnf(ebnfSource))
    }

    // MARK: - Checkpoint-aware restore: restores a compacted, under-budget session

    /// The `tokensBefore` of the fabricated checkpoint of
    /// ``restoringACompactedSessionYieldsCheckpointedWindow()``.
    private static let fabricatedCheckpointTokensBefore = 1_000

    /// The `tokensAfter` of the fabricated checkpoint of
    /// ``restoringACompactedSessionYieldsCheckpointedWindow()``:
    /// the fill that the restored session reports.
    private static let fabricatedCheckpointTokensAfter = 321

    /// A compacted, under-budget session restores with its id, its window
    /// starts at the checkpoint, and its fill is the checkpoint's own
    /// `tokensAfter`. The checkpoint is appended to the transcript by hand,
    /// so no live session counts it in the record; the live count has its
    /// own test in ``SessionIndexRecordingTests``.
    @Test(
        "restoreSessionTree restores a compacted, under-budget session with unchanged id; its restored fill reflects the checkpoint's own tokensAfter"
    )
    @MainActor
    func restoringACompactedSessionYieldsCheckpointedWindow() async throws {
        let cacheDir = RouterTestFixtures.makeTempDir(prefix: "SessionTreeRestorationTests")
        let recordingsDir = RouterTestFixtures.makeTempDir(prefix: "SessionTreeRestorationTests")
        defer {
            try? FileManager.default.removeItem(at: cacheDir)
            try? FileManager.default.removeItem(at: recordingsDir)
        }

        let router1 = Self.makeRouter(cacheDir: cacheDir, recordingsDir: recordingsDir)
        let profile1 = try await router1.resolve(profile: Self.profile, reporting: ResolutionProgress())

        let root = profile1.standard.makeSession()
        defer { await root.close() }
        _ = try await root.respond(to: "message 1")
        _ = try await root.respond(to: "message 2")

        // Learn the real, SDK-assigned entry ids for answer 1 (to be compacted
        // away) and answer 2 (the surviving tail), then fabricate and append a
        // compaction checkpoint referencing them directly onto the session's
        // own transcript.jsonl — the exact shape `RoutedSession.compact(prompt:budget:)`
        // itself appends, without driving the whole pipeline through a stub.
        let routerDir = RouterTestFixtures.routerDirectory(routerId: router1.id, recordingsDir: recordingsDir)
        let treeBeforeCheckpoint = try TranscriptTree.load(under: routerDir)
        let rawEvents = try treeBeforeCheckpoint.events(forSession: root.id)
        let prompts = rawEvents.filter { $0.kind == .prompt }
        let responses = rawEvents.filter { $0.kind == .response }
        let answer1PromptId = try #require(prompts.first?.entry?.entryId)
        let answer1ResponseId = try #require(responses.first?.entry?.entryId)
        let answer2PromptId = try #require(prompts.last?.entry?.entryId)
        let answer2ResponseId = try #require(responses.last?.entry?.entryId)
        let sessionContext = try #require(treeBeforeCheckpoint.session(root.id)?.record.context)

        let checkpointEvent = try TranscriptFixtures.compactionCheckpointEvent(
            seq: rawEvents.count,
            sessionId: root.id,
            routerId: router1.id,
            entryId: "checkpoint-1",
            content: CompactionSegment.Content(
                liveWindowEntryIds: ["checkpoint-1", answer2PromptId, answer2ResponseId],
                compactedEntryIds: [answer1PromptId, answer1ResponseId],
                tokensBefore: Self.fabricatedCheckpointTokensBefore,
                tokensAfter: Self.fabricatedCheckpointTokensAfter,
                stagesApplied: ["Summarization"],
                promptName: "default"
            )
        )
        let transcriptURL = routerDir
            .appendingPathComponent(root.id.description, isDirectory: true)
            .appendingPathComponent("transcript.jsonl", isDirectory: false)
        try JSONLFile(url: transcriptURL).append(checkpointEvent)

        // "Tear down" and restore under a fresh process.
        let router2 = Self.makeRouter(id: router1.id, cacheDir: cacheDir, recordingsDir: recordingsDir)
        let profile2 = try await router2.resolve(profile: Self.profile, reporting: ResolutionProgress())
        let restored = try await profile2.standard.restoreSessionTree(root: root.id)
        defer { await restored.root.close() }

        #expect(restored.root.id == root.id)

        let reloadedTree = try TranscriptTree.load(under: routerDir)
        let restoredWindow = try reloadedTree.effectiveTranscript(forSession: root.id)
        #expect(Array(restoredWindow).map(\.id) == ["checkpoint-1", answer2PromptId, answer2ResponseId])

        // Under budget: the checkpoint is the newest thing (no answer ran
        // after it before restore), so restored fill reports its own
        // `tokensAfter` — never the full pre-compaction size.
        let fill = await restored.root.contextFill
        #expect(fill == Double(Self.fabricatedCheckpointTokensAfter) / Double(sessionContext))
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
                compactedEntryIds: [],
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
                compactedEntryIds: [],
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
                compactedEntryIds: ["pre-response-1"],
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
        // stamp of its own — the compaction handler
        // `RoutedSessionActor.performCompaction(_:_:)` appends its diff
        // partials with no usage stamped on them (see
        // `RoutedSessionActorCompaction.swift`) — so this event is synthetic: it
        // deliberately carries both a `CompactionSegment` *and* a stamp, the
        // only way to make the exact array-slice boundary
        // (`events[(checkpoint.index + 1)...]`, not `events[checkpoint.index...]`)
        // observable rather than merely documented. If that boundary ever
        // regressed to include the checkpoint's own index, the stamp reader
        // would find this event's stamp (111/222) instead of falling back to
        // its `tokensAfter` (300).
        let sessionId = ULID.generate()
        let routerId = ULID.generate()
        let content = CompactionSegment.Content(
            liveWindowEntryIds: ["checkpoint-1"],
            compactedEntryIds: [],
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
                    .structure(
                        id: "checkpoint-1-segment",
                        schemaName: CompactionSegment.schemaName,
                        contentJSON: contentJSON
                    ),
                ],
                assetIds: []
            )
        )

        let state = TranscriptTree.restoredUsageState(in: [checkpointEventWithOwnStamp])
        #expect(state == .measured(input: 300, output: 0))
    }

    // MARK: - Configuration envelope re-application (task ^ne5g9jn)

    @Test(
        "a session saved with a budget, prompt, and priming restores with that same configuration applied to every node"
    )
    @MainActor
    func restoredTreeReappliesRecordedConfiguration() async throws {
        let cacheDir = RouterTestFixtures.makeTempDir(prefix: "SessionTreeRestorationTests")
        let recordingsDir = RouterTestFixtures.makeTempDir(prefix: "SessionTreeRestorationTests")
        defer {
            try? FileManager.default.removeItem(at: cacheDir)
            try? FileManager.default.removeItem(at: recordingsDir)
        }

        let router1 = Self.makeRouter(cacheDir: cacheDir, recordingsDir: recordingsDir)
        let profile1 = try await router1.resolve(profile: Self.profile, reporting: ResolutionProgress())

        let budget = TokenBudget(limit: 100_000, toolOutputLimit: 512)
        let prompt = CompactionPrompt(name: "custom", text: "Condense the conversation.")
        let priming = DiscoveryPriming(tool: "ambient-emitter", queryProperty: "value")
        let root = profile1.standard.makeSession(
            tools: [AmbientEventPostingTool()],
            budget: budget,
            compactionPrompt: prompt,
            discoveryPriming: priming
        )
        defer { await root.close() }
        _ = try await root.respond(to: "hello")

        let router2 = Self.makeRouter(id: router1.id, cacheDir: cacheDir, recordingsDir: recordingsDir)
        let profile2 = try await router2.resolve(profile: Self.profile, reporting: ResolutionProgress())
        let restored = try await profile2.standard.restoreSessionTree(
            root: root.id, tools: [AmbientEventPostingTool()])
        defer { await restored.root.close() }

        let restoredRoot = try #require(restored.root as? RoutedSessionActor)
        #expect(restoredRoot.autoCompactionBudget == budget)
        #expect(restoredRoot.autoCompactionPrompt == prompt)
        #expect(restoredRoot.discoveryPriming == priming)

        // Every recorded tool name matched a supplied tool, so nothing is
        // reported missing.
        #expect(restored.configurationReport.missingTools.isEmpty)
        #expect(restored.configurationReport.isComplete)
    }

    @Test("the restore result names every recorded tool the caller did not supply")
    @MainActor
    func restoreReportsRecordedToolsTheCallerDidNotSupply() async throws {
        let cacheDir = RouterTestFixtures.makeTempDir(prefix: "SessionTreeRestorationTests")
        let recordingsDir = RouterTestFixtures.makeTempDir(prefix: "SessionTreeRestorationTests")
        defer {
            try? FileManager.default.removeItem(at: cacheDir)
            try? FileManager.default.removeItem(at: recordingsDir)
        }

        let router1 = Self.makeRouter(cacheDir: cacheDir, recordingsDir: recordingsDir)
        let profile1 = try await router1.resolve(profile: Self.profile, reporting: ResolutionProgress())

        let root = profile1.standard.makeSession(tools: [AmbientEventPostingTool()])
        defer { await root.close() }
        _ = try await root.respond(to: "hello")

        let router2 = Self.makeRouter(id: router1.id, cacheDir: cacheDir, recordingsDir: recordingsDir)
        let profile2 = try await router2.resolve(profile: Self.profile, reporting: ResolutionProgress())
        // Deliberately restored with no tools at all: the recorded name has
        // no supplied instance to match, and the report must say so.
        let restored = try await profile2.standard.restoreSessionTree(root: root.id)
        defer { await restored.root.close() }

        #expect(
            restored.configurationReport.missingTools == [
                SessionConfigurationRestorationReport.MissingTool(
                    session: root.id, toolName: "ambient-emitter")
            ])
        #expect(!restored.configurationReport.isComplete)
    }

    /// Makes a root session with `configuration`, and restores the tree on a
    /// second router with the same id. Expects that the restored root keeps
    /// `expected`.
    ///
    /// After its checks, also when a step throws, it closes each session that
    /// it made: the root and the restored root.
    ///
    /// - Parameters:
    ///   - expected: The value of the setting that the restored root must keep.
    ///   - configuration: The configuration of the root session.
    ///   - setting: Reads the setting from a session.
    ///   - sourceLocation: The location that each failed expectation reports.
    /// - Throws: What the resolve, the answer or the restore throws, or a
    ///   failed `#require` when a session is not a ``RoutedSessionActor``.
    @MainActor
    private static func expectRestoreKeeps<Setting: Equatable>(
        _ expected: Setting,
        madeWith configuration: SessionConfiguration,
        readBy setting: (RoutedSessionActor) -> Setting,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        let cacheDir = RouterTestFixtures.makeTempDir(prefix: "SessionTreeRestorationTests")
        let recordingsDir = RouterTestFixtures.makeTempDir(prefix: "SessionTreeRestorationTests")
        defer {
            try? FileManager.default.removeItem(at: cacheDir)
            try? FileManager.default.removeItem(at: recordingsDir)
        }

        let router1 = makeRouter(cacheDir: cacheDir, recordingsDir: recordingsDir)
        let profile1 = try await router1.resolve(profile: profile, reporting: ResolutionProgress())

        let root = profile1.standard.makeSession(configuration: configuration)
        defer { await root.close() }
        _ = try await root.respond(to: "hello")

        let router2 = makeRouter(id: router1.id, cacheDir: cacheDir, recordingsDir: recordingsDir)
        let profile2 = try await router2.resolve(profile: profile, reporting: ResolutionProgress())
        let restored = try await profile2.standard.restoreSessionTree(root: root.id)
        defer { await restored.root.close() }

        let restoredRoot = try #require(restored.root as? RoutedSessionActor, sourceLocation: sourceLocation)
        #expect(setting(restoredRoot) == expected, sourceLocation: sourceLocation)
    }

    @Test("a session made with a repetition detection keeps it after a restore (task ^1hcwaqy)")
    @MainActor
    func restoredTreeReappliesRecordedRepetitionDetection() async throws {
        let detection = RepetitionDetection(isEnabled: false, windowTokens: 512, minimumLineLength: 8, recoveriesPerAnswer: 1)
        try await Self.expectRestoreKeeps(
            detection,
            madeWith: SessionConfiguration(repetitionDetection: detection),
            readBy: \.repetitionDetection)
    }

    @Test("a session made with a mail-only answer limit keeps it after a restore (task ^9bxas0w)")
    @MainActor
    func restoredTreeReappliesRecordedMailOnlyAnswerLimit() async throws {
        // A value that is not the default, so the restore cannot pass by
        // falling back to the default.
        let limit = SessionConfiguration.defaultMailOnlyAnswerLimit + 1
        try await Self.expectRestoreKeeps(
            limit,
            madeWith: SessionConfiguration(mailOnlyAnswerLimit: limit),
            readBy: \.mailOnlyAnswerLimit)
    }

    @Test("a session made with a settle period keeps it after a restore")
    @MainActor
    func restoredTreeReappliesRecordedInlineSettleGrace() async throws {
        // A value that is not the default, so the restore cannot pass by
        // falling back to the default.
        let grace = ToolMount.defaultInlineSettleGrace / 4
        try await Self.expectRestoreKeeps(
            grace,
            madeWith: SessionConfiguration(inlineSettleGrace: grace),
            readBy: \.inlineSettleGrace)
    }

    /// The production change that makes this test fail: a record that does
    /// not hold the user presence, or a restore that does not give it to
    /// the run plane. The restored session is then interactive.
    @Test("a headless session keeps its user presence after a restore (task ^0hps8jg)")
    @MainActor
    func restoredTreeReappliesRecordedUserPresence() async throws {
        // Not the default, so the restore cannot pass by falling back to the
        // default.
        try await Self.expectRestoreKeeps(
            UserPresence.headless,
            madeWith: SessionConfiguration(userPresence: .headless),
            readBy: \.runPlane.userPresence)
    }

    /// The production change that makes this test fail: a restore that
    /// reads a missing or an unknown recorded user presence as headless, or
    /// that fails on it.
    @Test(
        "an index.md with no user presence, or with a value this version does not know, restores an interactive session (task ^0hps8jg)",
        arguments: [nil, "elsewhere"] as [String?])
    @MainActor
    func missingOrUnknownRecordedUserPresenceRestoresInteractive(recorded: String?) async throws {
        let cacheDir = RouterTestFixtures.makeTempDir(prefix: "SessionTreeRestorationTests")
        let recordingsDir = RouterTestFixtures.makeTempDir(prefix: "SessionTreeRestorationTests")
        defer {
            try? FileManager.default.removeItem(at: cacheDir)
            try? FileManager.default.removeItem(at: recordingsDir)
        }

        let router1 = Self.makeRouter(cacheDir: cacheDir, recordingsDir: recordingsDir)
        let profile1 = try await router1.resolve(profile: Self.profile, reporting: ResolutionProgress())
        let root = profile1.standard.makeSession(configuration: SessionConfiguration(userPresence: .headless))
        defer { await root.close() }
        _ = try await root.respond(to: "hello")

        // A headless session, so a restore that ignores the edit gives a
        // headless session and the test fails.
        try Self.rewriteRecordedUserPresence(
            recorded,
            inSessionDirectory: RouterTestFixtures.sessionDirectory(
                of: root.id, routerId: router1.id, recordingsDir: recordingsDir))

        let router2 = Self.makeRouter(id: router1.id, cacheDir: cacheDir, recordingsDir: recordingsDir)
        let profile2 = try await router2.resolve(profile: Self.profile, reporting: ResolutionProgress())
        let restored = try await profile2.standard.restoreSessionTree(root: root.id)
        defer { await restored.root.close() }

        let restoredRoot = try #require(restored.root as? RoutedSessionActor)
        #expect(restoredRoot.runPlane.userPresence == .interactive)
    }

    // MARK: - User presence given to a restore (task ^58gn0mt)

    /// Makes a root session with `recorded` as its user presence, and
    /// restores the tree on a second router with the same id. The restore
    /// gives `override` as its user presence.
    ///
    /// After its reads, also when a step throws, it closes each session that
    /// it made: the root and the restored root.
    ///
    /// - Parameters:
    ///   - recorded: The user presence that the record holds.
    ///   - override: The user presence that the restore gets, or `nil`.
    /// - Returns: The user presence of the run plane of the restored root.
    /// - Throws: What the resolve, the answer or the restore throws, or a
    ///   failed `#require` when a session is not a ``RoutedSessionActor``.
    @MainActor
    private static func restoredUserPresence(
        recorded: UserPresence, override: UserPresence?
    ) async throws -> UserPresence {
        let cacheDir = RouterTestFixtures.makeTempDir(prefix: "SessionTreeRestorationTests")
        let recordingsDir = RouterTestFixtures.makeTempDir(prefix: "SessionTreeRestorationTests")
        defer {
            try? FileManager.default.removeItem(at: cacheDir)
            try? FileManager.default.removeItem(at: recordingsDir)
        }

        let router1 = makeRouter(cacheDir: cacheDir, recordingsDir: recordingsDir)
        let profile1 = try await router1.resolve(profile: profile, reporting: ResolutionProgress())
        let root = profile1.standard.makeSession(configuration: SessionConfiguration(userPresence: recorded))
        defer { await root.close() }
        _ = try await root.respond(to: "hello")

        let router2 = makeRouter(id: router1.id, cacheDir: cacheDir, recordingsDir: recordingsDir)
        let profile2 = try await router2.resolve(profile: profile, reporting: ResolutionProgress())
        let restored = try await profile2.standard.restoreSessionTree(root: root.id, userPresence: override)
        defer { await restored.root.close() }

        let restoredRoot = try #require(restored.root as? RoutedSessionActor)
        return restoredRoot.runPlane.userPresence
    }

    /// The production change that makes this test fail: a restore that does
    /// not give its user presence to the run plane of each node. The restored
    /// session is then interactive, as the record holds.
    @Test("a restore with a headless user presence makes a recorded interactive root headless")
    @MainActor
    func restoreWithHeadlessOverridesRecordedInteractive() async throws {
        let presence = try await Self.restoredUserPresence(recorded: .interactive, override: .headless)

        #expect(presence == .headless)
    }

    /// The production change that makes this test fail: a restore that does
    /// not give its user presence to the run plane of each node. The restored
    /// session is then headless, as the record holds.
    @Test("a restore with an interactive user presence makes a recorded headless root interactive")
    @MainActor
    func restoreWithInteractiveOverridesRecordedHeadless() async throws {
        let presence = try await Self.restoredUserPresence(recorded: .headless, override: .interactive)

        #expect(presence == .interactive)
    }

    /// The production change that makes this test fail: a restore that reads
    /// `nil` as interactive. The recorded headless session then restores
    /// interactive.
    @Test("a restore with no user presence keeps the recorded user presence of the root")
    @MainActor
    func restoreWithNoUserPresenceKeepsRecordedValue() async throws {
        let presence = try await Self.restoredUserPresence(recorded: .headless, override: nil)

        #expect(presence == .headless)
    }

    /// The production change that makes this test fail: a public restore that
    /// does not send its user presence to the tree restore.
    @Test("restoreSession gives its user presence to the restored session")
    @MainActor
    func restoreSessionGivesItsUserPresence() async throws {
        let cacheDir = RouterTestFixtures.makeTempDir(prefix: "SessionTreeRestorationTests")
        let recordingsDir = RouterTestFixtures.makeTempDir(prefix: "SessionTreeRestorationTests")
        defer {
            try? FileManager.default.removeItem(at: cacheDir)
            try? FileManager.default.removeItem(at: recordingsDir)
        }

        let router1 = Self.makeRouter(cacheDir: cacheDir, recordingsDir: recordingsDir)
        let profile1 = try await router1.resolve(profile: Self.profile, reporting: ResolutionProgress())
        let root = profile1.standard.makeSession()
        defer { await root.close() }
        _ = try await root.respond(to: "hello")

        let router2 = Self.makeRouter(id: router1.id, cacheDir: cacheDir, recordingsDir: recordingsDir)
        let profile2 = try await router2.resolve(profile: Self.profile, reporting: ResolutionProgress())
        let restored = try await profile2.standard.restoreSession(id: root.id, userPresence: .headless)
        defer { await restored.session.close() }

        let restoredRoot = try #require(restored.session as? RoutedSessionActor)
        #expect(restoredRoot.runPlane.userPresence == .headless)
    }

    /// The line of the configuration envelope in the `index.md` of a
    /// headless session: the key of the user presence and the name of
    /// ``UserPresence/headless``.
    private static let headlessUserPresenceLine = "userPresence: headless"

    /// Rewrites the user presence that the `index.md` of a headless session
    /// holds, in the YAML text itself: a name this version does not know
    /// cannot go through the typed record.
    ///
    /// - Parameters:
    ///   - recorded: The name to store, or `nil` to remove the key.
    ///   - sessionDirectory: The directory of the session. Its `index.md`
    ///     must hold ``headlessUserPresenceLine``.
    /// - Throws: What the read or the write throws, or a failed `#require`
    ///   when the file holds no ``headlessUserPresenceLine``.
    private static func rewriteRecordedUserPresence(_ recorded: String?, inSessionDirectory sessionDirectory: URL) throws {
        let indexURL = RouterTestFixtures.indexURL(inSessionDirectory: sessionDirectory)
        let text = try String(contentsOf: indexURL, encoding: .utf8)
        let lines = text.components(separatedBy: "\n")
        let presenceIndex = try #require(
            lines.firstIndex { $0.trimmingCharacters(in: .whitespaces) == headlessUserPresenceLine })
        var rewritten = lines
        if let recorded {
            rewritten[presenceIndex] = lines[presenceIndex].replacingOccurrences(of: "headless", with: recorded)
        } else {
            rewritten.remove(at: presenceIndex)
        }
        try rewritten.joined(separator: "\n").write(to: indexURL, atomically: true, encoding: .utf8)
    }

    // MARK: - Decided restore losses (task ^xky3j8w)

    /// A recorded spawn context stays readable from the restored tree's
    /// record; the restore re-applies nothing, since a live session holds no
    /// such state.
    @Test(
        "a recorded agent-spawn context survives a restore on disk: restore re-applies nothing because a live session holds no such state"
    )
    @MainActor
    func recordedAgentSpawnStaysReadableFromTheRestoredTreesRecord() async throws {
        let cacheDir = RouterTestFixtures.makeTempDir(prefix: "SessionTreeRestorationTests")
        let recordingsDir = RouterTestFixtures.makeTempDir(prefix: "SessionTreeRestorationTests")
        defer {
            try? FileManager.default.removeItem(at: cacheDir)
            try? FileManager.default.removeItem(at: recordingsDir)
        }

        let router1 = Self.makeRouter(cacheDir: cacheDir, recordingsDir: recordingsDir)
        let profile1 = try await router1.resolve(profile: Self.profile, reporting: ResolutionProgress())

        let spawn = SessionRecord.AgentSpawn(
            parentSessionId: ULID.generate(), parentToolCallId: "call-1")
        let root = profile1.standard.makeSession(agentSpawn: spawn)
        defer { await root.close() }
        _ = try await root.respond(to: "hello")

        let router2 = Self.makeRouter(id: router1.id, cacheDir: cacheDir, recordingsDir: recordingsDir)
        let profile2 = try await router2.resolve(profile: Self.profile, reporting: ResolutionProgress())
        let restored = try await profile2.standard.restoreSessionTree(root: root.id)
        defer { await restored.root.close() }
        #expect(restored.root.id == root.id)

        // The spawn context is write-once creation metadata: neither
        // `RoutedSessionActor` nor `RoutedSession` retains it as live state,
        // so there is nothing for a restore to re-apply — the recorded fact
        // stays on disk and stays readable from the loaded tree (both the
        // record's own field and the configuration envelope carry it).
        let tree = try TranscriptTree.load(
            under: RouterTestFixtures.routerDirectory(routerId: router1.id, recordingsDir: recordingsDir))
        let record = try #require(tree.session(root.id)?.record)
        #expect(record.agentSpawn == spawn)
        #expect(record.configuration?.agentSpawn == spawn)
    }

    /// How many tokens the rewritten recorded context of
    /// ``restoreReportsARecordedContextTheLiveResolutionNoLongerMatches()``
    /// adds to the resolved one, so the two no longer match.
    private static let recordedContextSkew = 1_024

    /// A recorded context that the live resolution does not match is
    /// reported for its session, and never adopted.
    @Test(
        "a recorded context the live resolution no longer matches is reported per session in contextMismatches, never silently adopted"
    )
    @MainActor
    func restoreReportsARecordedContextTheLiveResolutionNoLongerMatches() async throws {
        let cacheDir = RouterTestFixtures.makeTempDir(prefix: "SessionTreeRestorationTests")
        let recordingsDir = RouterTestFixtures.makeTempDir(prefix: "SessionTreeRestorationTests")
        defer {
            try? FileManager.default.removeItem(at: cacheDir)
            try? FileManager.default.removeItem(at: recordingsDir)
        }

        let router1 = Self.makeRouter(cacheDir: cacheDir, recordingsDir: recordingsDir)
        let profile1 = try await router1.resolve(profile: Self.profile, reporting: ResolutionProgress())
        let root = profile1.standard.makeSession()
        defer { await root.close() }
        _ = try await root.respond(to: "hello")

        let router2 = Self.makeRouter(id: router1.id, cacheDir: cacheDir, recordingsDir: recordingsDir)
        let profile2 = try await router2.resolve(profile: Self.profile, reporting: ResolutionProgress())

        // Recorded and live contexts match: nothing to report.
        let matching = try await profile2.standard.restoreSessionTree(root: root.id)
        defer { await matching.root.close() }
        #expect(matching.contextMismatches.isEmpty)

        // Rewrite the recorded context to a figure the live resolution does
        // not match — the on-disk stand-in for a recording made on a machine
        // whose window search settled on a different window.
        let rootDirectory = RouterTestFixtures.sessionDirectory(
            of: root.id, routerId: router1.id, recordingsDir: recordingsDir)
        let resolvedContext = try #require(try SessionIndexFile.read(in: rootDirectory)).context
        let recordedContext = resolvedContext + Self.recordedContextSkew
        try RouterTestFixtures.rewriteIndex(in: rootDirectory) { $0.context = recordedContext }

        let restored = try await profile2.standard.restoreSessionTree(root: root.id)
        defer { await restored.root.close() }
        #expect(
            restored.contextMismatches == [
                RestoredSession.ContextMismatch(
                    session: root.id, recorded: recordedContext, resolved: resolvedContext)
            ])
    }

    /// Builds an entry-kind event whose `.structure` segment carries content
    /// that is not JSON — the fabricated corruption
    /// `corruptStructuredSegmentFailsRestoreLoudly` appends to a recorded
    /// transcript.
    private static func corruptStructuredSegmentEvent(
        seq: Int,
        sessionId: ULID,
        routerId: ULID,
        kind: TranscriptEvent.Kind,
        schemaName: String
    ) -> TranscriptEvent {
        TranscriptEvent(
            routerId: routerId,
            sessionId: sessionId,
            seq: seq,
            ts: Date(timeIntervalSince1970: TimeInterval(seq)),
            kind: kind,
            text: "corrupt",
            entry: TranscriptEntryPayload(
                entryId: "corrupt-1",
                segments: [
                    .text(id: "corrupt-1-text", content: "corrupt"),
                    .structure(
                        id: "corrupt-1-segment",
                        schemaName: schemaName,
                        contentJSON: "{ not json"
                    ),
                ],
                assetIds: []
            )
        )
    }

    @Test(
        "a corrupt structured segment fails the restore loudly with entryReconstructionFailed naming the session and seq — never a silent partial restore",
        arguments: [
            (CompactionSegment.schemaName, TranscriptEvent.Kind.response),
            (OperationEventSegment.schemaName, TranscriptEvent.Kind.prompt),
        ]
    )
    @MainActor
    func corruptStructuredSegmentFailsRestoreLoudly(
        schemaName: String, kind: TranscriptEvent.Kind
    ) async throws {
        let cacheDir = RouterTestFixtures.makeTempDir(prefix: "SessionTreeRestorationTests")
        let recordingsDir = RouterTestFixtures.makeTempDir(prefix: "SessionTreeRestorationTests")
        defer {
            try? FileManager.default.removeItem(at: cacheDir)
            try? FileManager.default.removeItem(at: recordingsDir)
        }

        let router1 = Self.makeRouter(cacheDir: cacheDir, recordingsDir: recordingsDir)
        let profile1 = try await router1.resolve(profile: Self.profile, reporting: ResolutionProgress())
        let root = profile1.standard.makeSession()
        defer { await root.close() }
        _ = try await root.respond(to: "hello")

        let routerDir = RouterTestFixtures.routerDirectory(routerId: router1.id, recordingsDir: recordingsDir)
        let recordedEvents = try TranscriptTree.load(under: routerDir).events(forSession: root.id)
        let corruptSeq = recordedEvents.count
        let corruptEvent = Self.corruptStructuredSegmentEvent(
            seq: corruptSeq,
            sessionId: root.id,
            routerId: router1.id,
            kind: kind,
            schemaName: schemaName
        )
        let transcriptURL = routerDir
            .appendingPathComponent(root.id.description, isDirectory: true)
            .appendingPathComponent("transcript.jsonl", isDirectory: false)
        try JSONLFile(url: transcriptURL).append(corruptEvent)

        let router2 = Self.makeRouter(id: router1.id, cacheDir: cacheDir, recordingsDir: recordingsDir)
        let profile2 = try await router2.resolve(profile: Self.profile, reporting: ResolutionProgress())
        do {
            // A restore that does not throw fails the test; its root closes.
            try await profile2.standard.restoreSessionTree(root: root.id).root.close()
            Issue.record("restoring a corrupt \(schemaName) segment must throw, not restore silently")
        } catch let error as TranscriptReconstructionError {
            guard case .entryReconstructionFailed(let session, let seq, _) = error else {
                Issue.record("expected entryReconstructionFailed, got \(error)")
                return
            }
            #expect(session == root.id)
            #expect(seq == corruptSeq)
        }
    }
}
