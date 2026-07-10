import Foundation
import FoundationModels
import HuggingFace
import MLXHuggingFace
import MLXLMCommon
import Testing
import Tokenizers

@testable import FoundationModelsRouter

// MARK: - Gate

/// Reuses the same opt-in gating pattern as the rest of this target: unset
/// (the default, and on any CI/GPU-less box) this whole suite is skipped, so
/// `swift test` stays green without network or a GPU. Kept as its own
/// file-scoped constant rather than sharing another file's — Swift's
/// top-level `private` is file-scoped, not target-scoped.
private let sessionTreeRestorationIntegrationEnvVar = "FM_ROUTER_INTEGRATION_TESTS"

private var sessionTreeRestorationIntegrationEnabled: Bool {
    ProcessInfo.processInfo.environment[sessionTreeRestorationIntegrationEnvVar] != nil
}

/// The same deliberately tiny `mlx-community` generation model the rest of
/// this target's gated suites use.
private let sessionTreeRestorationTinyModel: ModelRef = "mlx-community/SmolLM-135M-Instruct-4bit"

// MARK: - Suite

/// The mandated end-to-end integration test for task zcxnbst — the FINAL task
/// in the "Transcript fidelity" effort (see plan.md's "Transcript fidelity"
/// section, "Reconstruction end-to-end"), proving the whole design works
/// against a real model:
///
/// 1. Start a router, make a root session, drive a real `respond(to:)` turn
///    carrying a memorable fact.
/// 2. Fork the root twice and fork one child again — a genuine branching,
///    3-level tree — driving a real turn on each fork.
/// 3. Assert, before any teardown, that each session's `transcript.jsonl` on
///    disk already contains its turn's entry events (sync-as-they-happen,
///    not only at teardown).
/// 4. Discard the router and every in-memory session (everything from step
///    1-3 lives inside ``driveOriginalTree(cacheDir:recordingsDir:)`` alone,
///    so it is all released when that call returns).
/// 5. Construct a **new** router over the same recordings directory — same
///    `id`, same `recordingsDir` — simulating a fresh process.
/// 6. Restore the whole tree, passing only the root session's id.
/// 7. Assert the restored tree matches: structure, each node's own recorded
///    turns (via the reconstructed effective entry counts, unchanged from
///    what step 3 observed), and an unchanged `sessions.jsonl`.
/// 8. Drive a **new** live turn on a restored node — the deepest one, the
///    grandfork — asking for the earlier fact, asserting the response
///    recalls it: the proof that `LanguageModelSession(transcript:)` seeded
///    from a reconstructed `Transcript` behaves indistinguishably from a
///    never-torn-down session.
///
/// Builds ``LanguageModelProfile``s directly over an already-loaded tiny
/// model's ``MLXFoundationModelsContainer`` (bypassing
/// `Router.resolve(_:reporting:)`, which would need real `.flash`/`.embedding`
/// downloads too) — the same technique
/// ``LanguageModelSessionBackendIntegrationTests`` and
/// ``TranscriptReconstructionIntegrationTests`` use — but drives every session
/// through the **real, public** vending surface
/// (`makeSession`/`fork`/`restoreSessionTree`), since this test's whole point
/// is proving that public surface end-to-end, not just its backend seam.
@Suite(
    "Gated real-model end-to-end coverage: restoreSessionTree(root:registry:) (task zcxnbst)",
    .serialized,
    .timeLimit(.minutes(20)),
    .enabled(if: sessionTreeRestorationIntegrationEnabled)
)
struct SessionTreeRestorationIntegrationTests {
    /// A minimal ``LoadedEmbeddingContainer`` stand-in for the unused
    /// `.embedding` slot the ``LanguageModelProfile`` this suite builds must
    /// still carry — never exercised here, only present to satisfy the type.
    private struct UnusedEmbeddingContainer: LoadedEmbeddingContainer {
        let dimension = 1
        func embed(texts: [String]) async throws -> [[Float]] { [] }
    }

    /// Loads the tiny model directly through a real ``LiveModelLoader`` and
    /// returns its concrete ``MLXFoundationModelsContainer``. Called once per
    /// simulated "process" — the second call models a fresh process reloading
    /// the same model from the Hub cache.
    private func makeContainer() async throws -> MLXFoundationModelsContainer {
        let loader = LiveModelLoader(
            downloader: #hubDownloader(),
            tokenizerLoader: #huggingFaceTokenizerLoader()
        )
        let loaded = try await loader.loadLLM(
            ref: sessionTreeRestorationTinyModel,
            slot: .standard,
            context: 512,
            reporting: { _ in }
        )
        return try #require(loaded as? MLXFoundationModelsContainer)
    }

    /// Builds a real ``LanguageModelProfile`` directly over `container`,
    /// stamped with `id` (pass the first router's `id` to continue the same
    /// recording root) and `recordingsDir` — the same manual-harness
    /// technique this target's other gated suites use, so this suite reaches
    /// `Router.resolve(_:reporting:)`-adjacent behavior without downloading
    /// the `.flash`/`.embedding` slots too.
    private func buildProfile(
        id: ULID = .generate(),
        container: MLXFoundationModelsContainer,
        cacheDir: URL,
        recordingsDir: URL
    ) -> (router: Router, profile: LanguageModelProfile) {
        let recorder = JSONLRecorder(directory: recordingsDir)
        let router = Router(id: id, cacheDir: cacheDir, recordingsDir: recordingsDir, recorder: recorder)

        func noopResolution(_ slot: ModelSlot) -> SlotResolution {
            SlotResolution(slot: slot, remainingBudgetBytes: 0, chosen: sessionTreeRestorationTinyModel, considered: [])
        }
        let standard = RoutedLLM(
            slot: .standard,
            chosen: sessionTreeRestorationTinyModel,
            footprintBytes: 0,
            resolution: noopResolution(.standard),
            container: container,
            routerId: router.id,
            recorder: recorder,
            recordingsRoot: recordingsDir
        )
        let flash = RoutedLLM(
            slot: .flash,
            chosen: sessionTreeRestorationTinyModel,
            footprintBytes: 0,
            resolution: noopResolution(.flash),
            container: container,
            routerId: router.id,
            recorder: recorder,
            recordingsRoot: recordingsDir
        )
        let embedding = RoutedEmbedder(
            slot: .embedding,
            chosen: sessionTreeRestorationTinyModel,
            footprintBytes: 0,
            resolution: noopResolution(.embedding),
            container: UnusedEmbeddingContainer(),
            routerId: router.id,
            recorder: recorder,
            recordingsRoot: recordingsDir
        )
        let profile = LanguageModelProfile(
            definitionName: "test",
            standard: standard,
            flash: flash,
            embedding: embedding,
            router: router,
            residencyToken: .generate()
        )
        return (router, profile)
    }

    /// Decodes every event from a session directory's `transcript.jsonl`, or
    /// an empty array if the file does not exist yet.
    private static func recordedEvents(in directory: URL) throws -> [TranscriptEvent] {
        let fileURL = directory.appendingPathComponent("transcript.jsonl", isDirectory: false)
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let text = try String(contentsOf: fileURL, encoding: .utf8)
        let decoder = JSONDecoder()
        return try text.split(separator: "\n").filter { !$0.isEmpty }.map {
            try decoder.decode(TranscriptEvent.self, from: Data($0.utf8))
        }
    }

    /// The ids and observations ``driveOriginalTree(cacheDir:recordingsDir:)``
    /// hands back once every in-memory session it built has gone out of scope.
    private struct OriginalTree {
        let routerId: ULID
        let rootId: ULID
        let forkAId: ULID
        let forkBId: ULID
        let grandforkId: ULID
        /// `sessions.jsonl`'s raw bytes as of just before restoration.
        let sessionsIndexBytes: Data
        /// Each node's effective entry-kind event count as of just before
        /// restoration, via ``TranscriptTree`` — independent of any private
        /// actor state, so the post-restore comparison is a genuine
        /// disk-to-disk check.
        let effectiveEntryCounts: [ULID: Int]
    }

    /// Steps 1-4: builds a fresh profile, drives a root turn carrying a
    /// memorable fact plus a genuine branching 3-level fork tree (root ->
    /// forkA, forkB; forkA -> grandfork), each with its own live turn,
    /// asserts every session's `transcript.jsonl` already reflects its turn
    /// before this function returns, and returns only plain data — every
    /// `Router`/`LanguageModelProfile`/`RoutedSession` this function built
    /// goes out of scope with it, simulating discarding the router and every
    /// in-memory session.
    private func driveOriginalTree(cacheDir: URL, recordingsDir: URL) async throws -> OriginalTree {
        let container = try await makeContainer()
        let (router, profile) = buildProfile(container: container, cacheDir: cacheDir, recordingsDir: recordingsDir)

        let root = profile.standard.makeSession(instructions: "You are a terse, literal assistant.")
        _ = try await root.respond(
            to: "My favorite number is 42. Remember it. Reply with just \"OK\".",
            maxTokens: 64
        )

        let forkA = try await root.fork(workingDirectory: nil)
        _ = try await forkA.respond(to: "Say hi in one word.", maxTokens: 32)
        let forkB = try await root.fork(workingDirectory: nil)
        _ = try await forkB.respond(to: "Say hi in one word.", maxTokens: 32)
        let grandfork = try await forkA.fork(workingDirectory: nil)
        _ = try await grandfork.respond(to: "Say hi in one word.", maxTokens: 32)

        // Step 3: sync-as-they-happen — every session's transcript.jsonl
        // already contains its own turn's entry events, before any teardown.
        for session in [root, forkA, forkB, grandfork] {
            let events = try Self.recordedEvents(in: session.recordingDirectory)
            let entryKinds: Set<TranscriptEvent.Kind> = [.instructions, .prompt, .toolCalls, .toolOutput, .response, .reasoning]
            #expect(events.contains { entryKinds.contains($0.kind) })
        }

        let routerDirectory = recordingsDir.appendingPathComponent(router.id.description, isDirectory: true)
        let tree = try TranscriptTree.load(under: routerDirectory)
        let effectiveEntryCounts = try [root.id, forkA.id, forkB.id, grandfork.id].reduce(into: [ULID: Int]()) { acc, id in
            acc[id] = try tree.effectiveEntryEvents(forSession: id).count
        }

        let indexFileURL = routerDirectory.appendingPathComponent("sessions.jsonl", isDirectory: false)
        let sessionsIndexBytes = try Data(contentsOf: indexFileURL)

        return OriginalTree(
            routerId: router.id,
            rootId: root.id,
            forkAId: forkA.id,
            forkBId: forkB.id,
            grandforkId: grandfork.id,
            sessionsIndexBytes: sessionsIndexBytes,
            effectiveEntryCounts: effectiveEntryCounts
        )
    }

    @Test("a whole fork tree recorded, torn down, and restored by root id in a fresh Router matches on disk and recalls prior context live")
    func restoresWholeTreeAcrossSimulatedProcessBoundary() async throws {
        let cacheDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SessionTreeRestorationIntegrationTests-cache-\(UUID().uuidString)", isDirectory: true)
        let recordingsDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SessionTreeRestorationIntegrationTests-recordings-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: cacheDir)
            try? FileManager.default.removeItem(at: recordingsDir)
        }

        // Steps 1-4: record the original tree, then discard everything that
        // built it — only plain ids/bytes/counts survive.
        let original = try await driveOriginalTree(cacheDir: cacheDir, recordingsDir: recordingsDir)

        // Step 5: a brand-new Router/profile over the same recordings
        // directory and the same router id — a fresh process continuing the
        // same recording root, with a freshly (re-)loaded model container.
        let container2 = try await makeContainer()
        let (_, profile2) = buildProfile(
            id: original.routerId,
            container: container2,
            cacheDir: cacheDir,
            recordingsDir: recordingsDir
        )

        // Step 6: restore, passing only the root session's id.
        let restored = try await profile2.standard.restoreSessionTree(root: original.rootId)

        // Step 7: structure matches.
        #expect(restored.root.id == original.rootId)
        #expect(restored.root.parentId == nil)
        let childIds = Set(restored.children(of: original.rootId).map(\.id))
        #expect(childIds == [original.forkAId, original.forkBId])
        #expect(restored.children(of: original.forkAId).map(\.id) == [original.grandforkId])
        #expect(restored.children(of: original.forkBId).isEmpty)

        // Each node's own recorded turns are unchanged from what was
        // observed on disk before restoration.
        let routerDirectory = recordingsDir.appendingPathComponent(original.routerId.description, isDirectory: true)
        let reloadedTree = try TranscriptTree.load(under: routerDirectory)
        for id in [original.rootId, original.forkAId, original.forkBId, original.grandforkId] {
            let count = try reloadedTree.effectiveEntryEvents(forSession: id).count
            #expect(count == original.effectiveEntryCounts[id])
        }

        // sessions.jsonl is byte-identical: restoration wrote nothing to it.
        let indexFileURL = routerDirectory.appendingPathComponent("sessions.jsonl", isDirectory: false)
        let sessionsIndexBytesAfterRestore = try Data(contentsOf: indexFileURL)
        #expect(sessionsIndexBytesAfterRestore == original.sessionsIndexBytes)

        // Step 8: the fidelity payoff. A brand-new live turn on the deepest
        // restored node (three levels down from the root that was told the
        // fact) recalls it — proof the `LanguageModelSession(transcript:)`
        // seed behaves indistinguishably from a never-torn-down session.
        let restoredGrandfork = try #require(restored.session(original.grandforkId))
        let reply = try await restoredGrandfork.respond(
            to: "What is my favorite number? Answer with just the number, digits only.",
            maxTokens: 32
        )
        #expect(reply.contains("42"))
    }
}
