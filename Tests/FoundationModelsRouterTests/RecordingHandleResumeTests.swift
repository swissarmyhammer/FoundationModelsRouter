import Foundation
import FoundationModels
import Testing

@testable import FoundationModelsRouter

/// Exercises task qts4v0a: ``RoutedModel/makeLanguageModel(resuming:)``,
/// the overload that resumes a previously recorded session into a fresh
/// ``RecordingLanguageModel`` handle.
///
/// Unlike a plain ``RoutedModel/makeLanguageModel()`` handle (whose last-seen
/// transcript starts empty), a resumed handle primes last-seen with the
/// resumed session's own reconstructed ``FoundationModels/Transcript`` — so its
/// first diff records only genuinely new entries — and nests its own
/// directory under the resumed session's, the same
/// lineage semantics ``RoutedSessionActor/fork(workingDirectory:)`` already
/// establishes for ``RoutedSession``. Pairing the returned handle and
/// transcript into `LanguageModelSession(model:tools:transcript:)` is also how
/// a resumed session finally gets real tools — the container-based
/// `restoreSessionTree`/`fork` path hardcodes `tools: []`.
///
/// Everything runs against a stub `LanguageModel` conformer wrapping a stub
/// ``LoadedLLMContainer`` and a ``JSONLRecorder`` writing into a temp
/// directory, so the suite needs no network and no GPU, and lineage can be
/// verified by reloading a ``TranscriptTree`` straight off disk.
@Suite("Recording handle resume: makeLanguageModel(resuming:) lineage and priming")
struct RecordingHandleResumeTests {
    // MARK: - Stub underlying LanguageModel

    /// A configurable `LanguageModel` conformer standing in for the resident
    /// model ``RecordingLanguageModel`` wraps.
    ///
    /// Behavior is driven purely by what each call observes, not by any fixed
    /// per-instance script, so the same stub instance can serve a toolless
    /// turn before a resume and a tool-using turn after it: with no enabled
    /// tool definitions it replies with ``plainResponseText`` directly; with
    /// one or more enabled it emits a `.toolCalls` event naming the first
    /// tool until the transcript shows a `.toolOutput` entry, then replies
    /// with ``toolResponseText`` — mirroring how a real model's executor is
    /// invoked twice per tool-using turn.
    private struct StubUnderlyingModel: LanguageModel {
        let plainResponseText: String
        let toolResponseText: String

        var capabilities: LanguageModelCapabilities {
            LanguageModelCapabilities([.toolCalling])
        }

        var executorConfiguration: Executor.Configuration {
            Executor.Configuration(
                plainResponseText: plainResponseText, toolResponseText: toolResponseText)
        }

        struct Executor: LanguageModelExecutor {
            struct Configuration: Sendable, Hashable {
                let plainResponseText: String
                let toolResponseText: String
            }

            typealias Model = StubUnderlyingModel

            private let configuration: Configuration

            init(configuration: Configuration) throws {
                self.configuration = configuration
            }

            func respond(
                to request: LanguageModelExecutorGenerationRequest,
                model: StubUnderlyingModel,
                streamingInto channel: LanguageModelExecutorGenerationChannel
            ) async throws {
                guard let toolName = request.enabledToolDefinitions.first?.name else {
                    await channel.send(
                        .response(action: .appendText(configuration.plainResponseText, tokenCount: 1)))
                    return
                }

                let alreadyRanTool = request.transcript.contains { entry in
                    if case .toolOutput = entry { return true }
                    return false
                }
                guard alreadyRanTool else {
                    await channel.send(
                        .toolCalls(
                            action: .toolCall(
                                id: "call-1",
                                name: toolName,
                                action: .appendArguments(#"{"text":"hi"}"#, tokenCount: 1)
                            )
                        )
                    )
                    return
                }
                await channel.send(
                    .response(action: .appendText(configuration.toolResponseText, tokenCount: 1)))
            }
        }
    }

    // MARK: - Test tool

    @Generable
    struct UppercaseArguments {
        let text: String
    }

    /// A real `FoundationModels.Tool` conformer only ever attached to a
    /// resumed handle's session — never to the parent's — so a passing
    /// tool-using turn after resume proves resuming with a different tool set
    /// works.
    private struct UppercaseTool: Tool {
        let name = "uppercase"
        let description = "Uppercases text"

        func call(arguments: UppercaseArguments) async throws -> String {
            arguments.text.uppercased()
        }
    }

    // MARK: - Stub container

    private struct StubLanguageModelContainer: PlainTranscriptStubContainer {
        let model: StubUnderlyingModel

        func makeSession(instructions: String?) -> any LanguageModelSessionBackend {
            StubSessionBackend()
        }

        var languageModel: any LanguageModel { model }
    }

    // MARK: - Stubs (probe, embedder, metadata, loader)

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

    /// A ``ModelLoader`` that returns the given ``LoadedLLMContainer`` for
    /// every generation slot. No download, no GPU.
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

    private static func makeTempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("RecordingHandleResumeTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Builds a router wired with `container` for every generation slot, an
    /// explicit recorder, and a durable recordings root (so a resumed handle
    /// has an on-disk `session.json`/`transcript.jsonl` tree to load).
    private static func makeRouter(
        container: any LoadedLLMContainer,
        recorder: any TranscriptRecorder,
        cacheDir: URL,
        recordingsDir: URL
    ) -> Router {
        Router(
            cacheDir: cacheDir,
            recordingsDir: recordingsDir,
            recorder: recorder,
            probe: StubProbe(
                chip: "Apple Test", totalRAM: 64 << 30, recommendedMaxWorkingSetSize: 48 << 30),
            metadataSource: StubMetadataSource(raw: rawMetadata),
            loader: StubModelLoader(container: container, dimension: stubDimension)
        )
    }

    // MARK: - Child transcript holds only post-resume events, with correct lineage

    @Test("resuming primes lastSeen: the child's own transcript.jsonl holds only post-resume events, with correct parent lineage")
    @MainActor
    func resumeRecordsOnlyNewEventsWithCorrectLineage() async throws {
        let cacheDir = Self.makeTempDir()
        let recordingsDir = Self.makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: cacheDir)
            try? FileManager.default.removeItem(at: recordingsDir)
        }

        let model = StubUnderlyingModel(plainResponseText: "reply", toolResponseText: "tool reply")
        let router = Self.makeRouter(
            container: StubLanguageModelContainer(model: model),
            recorder: JSONLRecorder(directory: recordingsDir),
            cacheDir: cacheDir,
            recordingsDir: recordingsDir
        )
        let profile = try await router.resolve(profile: Self.profile, reporting: ResolutionProgress())

        // Record N entries via the parent handle.
        let parentHandle = profile.standard.makeLanguageModel()
        let parentSession = LanguageModelSession(
            model: parentHandle, tools: [], instructions: "be terse")
        _ = try await parentSession.respond(to: "hi there")
        await parentHandle.sync(parentSession.transcript)
        let parentEntryCount = parentSession.transcript.count  // instructions, prompt, response == 3

        // Resume from the parent's session id and continue one turn.
        let (childHandle, restored) = try profile.standard.makeLanguageModel(
            resuming: parentHandle.state.sessionId)
        #expect(restored.count == parentEntryCount)

        let childSession = LanguageModelSession(model: childHandle, tools: [], transcript: restored)
        _ = try await childSession.respond(to: "continue please")
        await childHandle.sync(childSession.transcript)

        let routerDirectory = recordingsDir.appendingPathComponent(
            router.id.description, isDirectory: true)
        let tree = try TranscriptTree.load(under: routerDirectory)

        // The child's OWN transcript.jsonl contains only post-resume events —
        // never the whole restored history re-recorded into a fresh directory.
        let childOwnEvents = try tree.events(forSession: childHandle.state.sessionId)
        #expect(childOwnEvents.map(\.kind) == [.session, .prompt, .response])
        #expect(childOwnEvents.contains { $0.kind == .prompt && $0.text == "continue please" })

        // The parent's own transcript.jsonl is untouched.
        let parentOwnEvents = try tree.events(forSession: parentHandle.state.sessionId)
        #expect(parentOwnEvents.map(\.kind) == [.session, .instructions, .prompt, .response])

        // Lineage: the child's directory nests under the parent's, and its own
        // sidecar records the fork point.
        let childNode = try #require(tree.session(childHandle.state.sessionId))
        #expect(childNode.parentId == parentHandle.state.sessionId)
        #expect(childNode.sidecar.forkedAtEntryCount == parentEntryCount)
    }

    // MARK: - Different tool set

    @Test("resuming with a different tool set drives a tool-using turn over the resumed transcript")
    @MainActor
    func resumingWithDifferentToolSetWorks() async throws {
        let cacheDir = Self.makeTempDir()
        let recordingsDir = Self.makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: cacheDir)
            try? FileManager.default.removeItem(at: recordingsDir)
        }

        let model = StubUnderlyingModel(plainResponseText: "reply", toolResponseText: "final answer")
        let router = Self.makeRouter(
            container: StubLanguageModelContainer(model: model),
            recorder: JSONLRecorder(directory: recordingsDir),
            cacheDir: cacheDir,
            recordingsDir: recordingsDir
        )
        let profile = try await router.resolve(profile: Self.profile, reporting: ResolutionProgress())

        // The parent handle never sees any tools.
        let parentHandle = profile.standard.makeLanguageModel()
        let parentSession = LanguageModelSession(
            model: parentHandle, tools: [], instructions: "be terse")
        _ = try await parentSession.respond(to: "hi there")
        await parentHandle.sync(parentSession.transcript)

        // Resume with a fresh tool the parent never had.
        let (childHandle, restored) = try profile.standard.makeLanguageModel(
            resuming: parentHandle.state.sessionId)
        let childSession = LanguageModelSession(
            model: childHandle, tools: [UppercaseTool()], transcript: restored)
        let response = try await childSession.respond(to: "please uppercase hi")
        #expect(response.content == "final answer")
        await childHandle.sync(childSession.transcript)

        let routerDirectory = recordingsDir.appendingPathComponent(
            router.id.description, isDirectory: true)
        let tree = try TranscriptTree.load(under: routerDirectory)
        let childOwnEvents = try tree.events(forSession: childHandle.state.sessionId)
        #expect(childOwnEvents.map(\.kind) == [.session, .prompt, .toolCalls, .toolOutput, .response])
    }

    // MARK: - Reconstruction over parent plus child

    @Test("TranscriptTree reconstruction over parent plus child yields the full conversation")
    @MainActor
    func reconstructionOverParentAndChildYieldsFullConversation() async throws {
        let cacheDir = Self.makeTempDir()
        let recordingsDir = Self.makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: cacheDir)
            try? FileManager.default.removeItem(at: recordingsDir)
        }

        let model = StubUnderlyingModel(plainResponseText: "reply", toolResponseText: "tool reply")
        let router = Self.makeRouter(
            container: StubLanguageModelContainer(model: model),
            recorder: JSONLRecorder(directory: recordingsDir),
            cacheDir: cacheDir,
            recordingsDir: recordingsDir
        )
        let profile = try await router.resolve(profile: Self.profile, reporting: ResolutionProgress())

        let parentHandle = profile.standard.makeLanguageModel()
        let parentSession = LanguageModelSession(
            model: parentHandle, tools: [], instructions: "be terse")
        _ = try await parentSession.respond(to: "first prompt")
        await parentHandle.sync(parentSession.transcript)

        let (childHandle, restored) = try profile.standard.makeLanguageModel(
            resuming: parentHandle.state.sessionId)
        let childSession = LanguageModelSession(model: childHandle, tools: [], transcript: restored)
        _ = try await childSession.respond(to: "second prompt")
        await childHandle.sync(childSession.transcript)

        // The parent keeps generating AFTER the resume point. This must never
        // leak into the child's effective conversation: `forkedAtEntryCount`
        // pins the cut point to the parent's entry count AT RESUME TIME, not
        // however much the parent has grown to by the time of reconstruction
        // — the same invariant `RoutedSessionActor.fork`'s own
        // `forkedAtEntryCount` establishes. Without this step, an inflated
        // `forkedAtEntryCount` (an overcount) would be indistinguishable from
        // the correct value, since `Array.prefix(_:)` silently clamps to
        // however much history actually exists.
        _ = try await parentSession.respond(to: "parent continues after resume")
        await parentHandle.sync(parentSession.transcript)

        let routerDirectory = recordingsDir.appendingPathComponent(
            router.id.description, isDirectory: true)
        let tree = try TranscriptTree.load(under: routerDirectory)
        let fullConversation = try tree.effectiveEntryEvents(forSession: childHandle.state.sessionId)

        #expect(
            fullConversation.map(\.kind) == [.instructions, .prompt, .response, .prompt, .response])
        #expect(
            fullConversation.map(\.text) == [
                "be terse", "first prompt", "reply", "second prompt", "reply",
            ])
        #expect(!fullConversation.contains { $0.text == "parent continues after resume" })

        // MergedTranscript sees every recorded event across both sessions
        // (parent's 6, after its extra post-resume turn, + child's 3), unlike
        // the tree's truncated/entry-kind-only view — a second, independent
        // confirmation that nothing was lost or duplicated across the resume
        // boundary.
        let merged = try MergedTranscript.merged(under: routerDirectory)
        #expect(merged.count == 9)
    }

    // MARK: - Resume after a fold: cut in append-only history coordinates (task ^bw2gts3)

    /// Enough driven turns that ``TurnTruncation`` (default recency window
    /// `defaultKeepRecentTurns`) has old turns to fold away.
    private static let foldWarmupTurnCount = 6

    /// A long-ish canned response, repeated across every turn, so six turns'
    /// worth of transcript carries a real byte-size estimate and the
    /// deterministic-fold budget derivation has room to sit strictly between
    /// the recency-window floor and the full pre-fold estimate.
    private static let foldableCannedText = String(
        repeating: "The quick brown fox jumps over the lazy dog. ", count: 12)

    /// Drives `count` sequential turns on `session` (prompts `"turn 0"`,
    /// `"turn 1"`, …), syncing `handle` after each so every turn-final
    /// response is recorded — the bare-handle counterpart of the shared
    /// `driveTurns(_:on:)` fixture, which drives a ``RoutedSession``.
    ///
    /// - Parameters:
    ///   - count: How many turns to drive.
    ///   - session: The session to drive them on.
    ///   - handle: The recording handle to sync after each turn.
    /// - Throws: Whatever `respond(to:)` throws.
    @MainActor
    private static func driveTurns(
        _ count: Int, on session: LanguageModelSession, syncing handle: RecordingLanguageModel
    ) async throws {
        for index in 0..<count {
            _ = try await session.respond(to: "turn \(index)")
            await handle.sync(session.transcript)
        }
    }

    /// The entry ids of `sessionId`'s own recorded entry events, in order —
    /// what the resumed handle itself appended after its cut.
    ///
    /// - Parameters:
    ///   - tree: The loaded recording tree to read from.
    ///   - sessionId: The session whose own recorded entries to list.
    /// - Returns: The entry ids, in recorded order.
    /// - Throws: Whatever ``TranscriptTree/events(forSession:)`` throws.
    private static func ownRecordedEntryIds(in tree: TranscriptTree, sessionId: ULID) throws -> [String] {
        try tree.events(forSession: sessionId).compactMap { $0.entry?.entryId }
    }

    @Test("resuming a compacted session records its cut in append-only history coordinates, so reconstruction restores the fold's live window plus the handle's own entries")
    @MainActor
    func resumingACompactedSessionCutsInAppendOnlyHistoryCoordinates() async throws {
        let cacheDir = Self.makeTempDir()
        let recordingsDir = Self.makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: cacheDir)
            try? FileManager.default.removeItem(at: recordingsDir)
        }

        let model = StubUnderlyingModel(
            plainResponseText: Self.foldableCannedText, toolResponseText: "tool reply")
        let router = Self.makeRouter(
            container: StubLanguageModelContainer(model: model),
            recorder: JSONLRecorder(directory: recordingsDir),
            cacheDir: cacheDir,
            recordingsDir: recordingsDir
        )
        let profile = try await router.resolve(profile: Self.profile, reporting: ResolutionProgress())

        // The parent handle records six turns, then folds deterministically:
        // the derived budget's target sits where TurnTruncation alone lands
        // under it, so no model-assisted summarization runs.
        let parentHandle = profile.standard.makeLanguageModel()
        let parentSession = LanguageModelSession(
            model: parentHandle, tools: [], instructions: "be terse")
        try await Self.driveTurns(Self.foldWarmupTurnCount, on: parentSession, syncing: parentHandle)

        let preFoldEntries = Array(parentSession.transcript)
        let (folded, result) = try await Compactor.compact(
            Transcript(entries: preFoldEntries),
            budget: deterministicFoldBudget(for: preFoldEntries)
        )
        #expect(!result.stagesApplied.isEmpty)
        _ = await parentHandle.noteCompaction(folded, result: result)

        // The resume cut in the recorded history's own append-only
        // coordinates: the raw effective entry-event count, boundary entry
        // included — strictly larger than the checkpoint-filtered restore
        // view a compacted session yields.
        let routerDirectory = RouterTestFixtures.routerDirectory(
            routerId: router.id, recordingsDir: recordingsDir)
        let entryEventCountAtResume = try TranscriptTree.load(under: routerDirectory)
            .effectiveEntryEvents(forSession: parentHandle.state.sessionId).count

        let (childHandle, restored) = try profile.standard.makeLanguageModel(
            resuming: parentHandle.state.sessionId)
        #expect(restored.count < entryEventCountAtResume)

        let childSession = LanguageModelSession(model: childHandle, tools: [], transcript: restored)
        _ = try await childSession.respond(to: "continue please")
        await childHandle.sync(childSession.transcript)

        let tree = try TranscriptTree.load(under: routerDirectory)

        // The fold's checkpoint governs the handle's restore: it sits inside
        // the inherited span, before the cut. A cut taken from the restore
        // view's count instead selects the oldest pre-fold span, which
        // carries no checkpoint at all.
        let checkpoint = try #require(
            TranscriptTree.newestCompactionCheckpoint(
                in: tree.effectiveEntryEvents(forSession: childHandle.state.sessionId)))

        // Entry-for-entry: the checkpoint's live window plus the handle's own
        // recorded entries — and nothing the fold discarded comes back.
        let childOwnIds = try Self.ownRecordedEntryIds(in: tree, sessionId: childHandle.state.sessionId)
        #expect(!childOwnIds.isEmpty)
        let restoredChildIds = try tree.effectiveTranscript(
            forSession: childHandle.state.sessionId
        ).map(\.id)
        #expect(restoredChildIds == checkpoint.content.liveWindowEntryIds + childOwnIds)
        #expect(Set(checkpoint.content.foldedEntryIds).isDisjoint(with: restoredChildIds))

        // The handle's sidecar records the cut in history coordinates
        // alongside the legacy positional baseline (the restore view's count,
        // which stays the handle's own diff baseline).
        let childNode = try #require(tree.session(childHandle.state.sessionId))
        #expect(childNode.sidecar.forkedAtHistoryOrdinal == entryEventCountAtResume)
        #expect(childNode.sidecar.forkedAtEntryCount == restored.count)
    }

    @Test("a resume-handle sidecar with no forkedAtHistoryOrdinal key (an old recording) still restores through forkedAtEntryCount")
    @MainActor
    func oldResumeRecordingWithoutHistoryOrdinalRestoresThroughTheLegacyCutField() async throws {
        let cacheDir = Self.makeTempDir()
        let recordingsDir = Self.makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: cacheDir)
            try? FileManager.default.removeItem(at: recordingsDir)
        }

        let model = StubUnderlyingModel(plainResponseText: "reply", toolResponseText: "tool reply")
        let router = Self.makeRouter(
            container: StubLanguageModelContainer(model: model),
            recorder: JSONLRecorder(directory: recordingsDir),
            cacheDir: cacheDir,
            recordingsDir: recordingsDir
        )
        let profile = try await router.resolve(profile: Self.profile, reporting: ResolutionProgress())

        // An unfolded parent: for a recording with no fold before the resume,
        // the legacy positional count and the history-coordinate cut agree,
        // which is exactly why old recordings keep restoring correctly.
        let parentHandle = profile.standard.makeLanguageModel()
        let parentSession = LanguageModelSession(
            model: parentHandle, tools: [], instructions: "be terse")
        _ = try await parentSession.respond(to: "remember 42")
        await parentHandle.sync(parentSession.transcript)

        let (childHandle, restored) = try profile.standard.makeLanguageModel(
            resuming: parentHandle.state.sessionId)
        let childSession = LanguageModelSession(model: childHandle, tools: [], transcript: restored)
        _ = try await childSession.respond(to: "continue please")
        await childHandle.sync(childSession.transcript)

        // Rewrite the handle's sidecar without the new key, simulating a
        // recording written before the field existed.
        let routerDirectory = RouterTestFixtures.routerDirectory(
            routerId: router.id, recordingsDir: recordingsDir)
        let treeBefore = try TranscriptTree.load(under: routerDirectory)
        let childNodeBefore = try #require(treeBefore.session(childHandle.state.sessionId))
        let sidecarURL = childNodeBefore.directory
            .appendingPathComponent(sessionSidecarFileName, isDirectory: false)
        var json = try #require(
            try JSONSerialization.jsonObject(with: Data(contentsOf: sidecarURL)) as? [String: Any])
        json.removeValue(forKey: "forkedAtHistoryOrdinal")
        try JSONSerialization.data(withJSONObject: json).write(to: sidecarURL)

        // The legacy field alone still yields the whole effective
        // conversation: the parent's entries at resume time plus the handle's
        // own entries.
        let tree = try TranscriptTree.load(under: routerDirectory)
        let expectedIds =
            try tree.effectiveTranscript(forSession: parentHandle.state.sessionId).map(\.id)
            + Self.ownRecordedEntryIds(in: tree, sessionId: childHandle.state.sessionId)
        #expect(
            try tree.effectiveTranscript(forSession: childHandle.state.sessionId).map(\.id)
                == expectedIds)
    }
}
