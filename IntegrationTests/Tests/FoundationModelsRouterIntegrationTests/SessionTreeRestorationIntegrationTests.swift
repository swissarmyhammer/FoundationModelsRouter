import Foundation
import FoundationModels
import FoundationModelsRouterTestSupport
import Testing

@testable import FoundationModelsRouter
@testable import FoundationModelsRouterRealModelSupport

/// The real `mlx-community` model the fork-tree test drives, and deliberately
/// NOT ``RealModels/standard``.
///
/// ``RealModels/standard`` is `Muse-Glimmer-30B-4bit`, and it is what the
/// fork-tree test drove until task ^bpwfbyz. That test drives five turns and
/// no tool, and three of its turns are filler turns whose reply nothing reads.
/// The 30B writes a `<think>` block of 196 to 275 tokens before it answers a
/// filler prompt, so the three fillers were 74 of the test's 112 seconds, and
/// the test could not reach half of ``integrationTestBudgetMinutes`` on the
/// 30B. The suite doc states the measurements and what the change no longer
/// proves.
///
/// `Qwen2.5-3B-Instruct-4bit` writes no `<think>` block, and it is the subject
/// ``CompactionRoundTripIntegrationTests`` already recalls a planted fact
/// against, which is the property the fork-tree test's last step asserts.
private let sessionTreeForkTreeModel: ModelRef = "mlx-community/Qwen2.5-3B-Instruct-4bit"

/// The real `mlx-community` model the tool-calling test drives: the same
/// ``RealModels/standard`` the rest of this target's gated suites use for the
/// `.standard` slot.
///
/// Not ``sessionTreeForkTreeModel``, and that is measured. On 2026-08-21 the 3B
/// answered the tool-calling test's prompt with
/// `<tool_call>{{"name": "echo", "arguments": {"text": "ping"}}}`, which the
/// provider rejected as an incomplete tool-call payload, so that test keeps the
/// subject whose tool calling is dependable.
private let sessionTreeToolCallingModel: ModelRef = RealModels.standard

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
///    what step 3 observed), and an unchanged root `session.json`.
/// 8. Drive a **new** live turn on a restored node — the deepest one, the
///    grandfork — asking for the earlier fact, asserting the response
///    recalls it: the proof that `LanguageModelSession(transcript:)` seeded
///    from a reconstructed `Transcript` behaves indistinguishably from a
///    never-torn-down session.
///
/// Builds ``LanguageModelProfile``s directly over an already-loaded
/// model's ``MLXFoundationModelsContainer`` (bypassing
/// `Router.resolve(_:reporting:)`, which would need real `.flash`/`.embedding`
/// downloads too) — the same technique
/// ``LanguageModelSessionBackendIntegrationTests`` and
/// ``TranscriptReconstructionIntegrationTests`` use — but drives every session
/// through the **real, public** vending surface
/// (`makeSession`/`fork`/`restoreSessionTree`), since this test's whole point
/// is proving that public surface end-to-end, not just its backend seam.
///
/// ## What it NO LONGER proves (task ^bpwfbyz)
///
/// Until that task both tests drove ``RealModels/standard``, the 30B, and took
/// the provider's default sampling: temperature 0.6 out of MLX's clock-seeded,
/// process-global PRNG. The three runs of 2026-08-20 measured the fork-tree
/// test at 94.1, then 114.1, then 116.4 seconds, and the tool-calling test at
/// 54.4, then 61.7, then 58.5 seconds. The 116.4 was 97 percent of
/// ``integrationTestBudgetMinutes``, the dearest test of the whole target, and
/// a run alone decided the number: the 30B always writes a `<think>` block
/// before its answer, that block is a different length on every run of
/// identical code, and the box that measured it decodes near ten tokens a
/// second. Three changes bring the suite inside the budget, and each one is
/// stated on the constant that carries it:
///
/// - ``samplingMode`` pins argmax decoding on every container this suite
///   loads.
/// - ``sessionTreeForkTreeModel`` moves the fork-tree test onto a 3B model
///   that writes no `<think>` block. Measured in isolation on 2026-08-21 with
///   argmax decoding: on the 30B the fork-tree test took 112.4 seconds, 74 of
///   them the three filler turns (275, 208 and 196 tokens of `<think>` at 37.0,
///   19.2 and 18.4 seconds), beside a 16.0-second root turn, a 14.2-second
///   recall turn and two 3.5-second loads. A filler turn cut inside its
///   `<think>` block at 32 tokens took the test to 65.0 seconds, but the cut
///   transcript made the recall turn grow from 151 to 267 tokens and pushed the
///   tool-calling test's turn over the restored root past the two-minute
///   limit, so a cut filler is not a technique. With complete filler replies
///   the 30B's root turn, recall turn and two loads are 37 seconds before the
///   first filler, and no complete filler reply of the 30B is under 100 tokens,
///   so the test cannot reach half the budget on the 30B. On the 3B the same
///   test measures 3.0 seconds.
/// - ``sessionTreeToolCallingModel`` keeps the tool-calling test on the 30B,
///   because the 3B garbled its tool call. That test measured 51.6 seconds in
///   isolation with argmax decoding: a 25.7-second filler turn, an 18.5-second
///   two-round tool turn, and two loads.
///
/// What is no longer proven is:
///
/// - **The fork-tree round trip over the 30B's transcripts.** The fork-tree
///   test restores and continues a tree the 3B recorded. That tree holds no
///   `.reasoning` entry, because the 3B writes no `<think>` block, so this test
///   no longer shows a tree of reasoning entries surviving the trip to disk
///   and back. The tool-calling test still does: its root turn is a 30B turn
///   with a reasoning entry, and the restored root drives a live turn over it.
/// - **The standard model's recall through a restored tree.** That the 3B
///   recalls 42 three levels down says nothing about the 30B, and a fact this
///   subject lost might survive under the larger one.
///   ``CompactionRoundTripIntegrationTests`` records the same trade for its own
///   recall step.
/// - **The sampled path.** Both tests decode with argmax now, so a red run is
///   attributable to the change under test, and the behavior under the
///   provider's default sampling is not measured here.
///
/// Everything else is untouched: the five-turn tree, the sync-as-they-happen
/// check, the two routers, the restore by root id, every structural and
/// byte-level assertion, the live recall, and the tool-calling round trip are
/// exactly what they were.
///
/// A test the limit cancels is worse than a plain red result. The cancellation
/// lands mid-generation, and a cancellation on GPU work aborts the whole
/// process on a Metal assertion (fork card ^3axg80k), which takes every other
/// suite's results with it. See ``integrationTestBudgetMinutes`` for the whole
/// run table.
@Suite(
    "Gated real-model end-to-end coverage: restoreSessionTree(root:) (task zcxnbst)",
    .serialized,
    .timeLimit(.minutes(integrationTestBudgetMinutes)),
    .exclusiveRealModel
)
struct SessionTreeRestorationIntegrationTests {
    // MARK: - Test tool (task jkdae4b: tools threaded through restoreSessionTree)

    /// The scripted tool argument schema the turn's prompt reliably drives —
    /// mirrors ``RecordingHandleIntegrationTests/EchoArguments``.
    @Generable
    struct EchoArguments {
        let text: String
    }

    /// A real `FoundationModels.Tool` conformer, so the SDK's own machinery
    /// invokes it once it observes a `.toolCalls` entry naming it — mirrors
    /// ``RecordingHandleIntegrationTests/EchoTool``.
    private struct EchoTool: FoundationModels.Tool {
        let name = "echo"
        let description = "Echoes the given text back verbatim."

        func call(arguments: EchoArguments) async throws -> String {
            "echoed: \(arguments.text)"
        }
    }


    /// This suite's own ``RealModelHarness`` call: the same real
    /// ``LanguageModelProfile`` build every other gated suite of this target
    /// uses, over an already-loaded container, so this suite reaches
    /// `Router.resolve(_:reporting:)`-adjacent behavior without downloading the
    /// `.flash`/`.embedding` slots too.
    ///
    /// A wrapper rather than four spelled-out calls, because this suite's
    /// context is the same at each of its four sites and only the model, the
    /// container and the router id move.
    ///
    /// - Parameters:
    ///   - model: The model reference to stamp every slot with — the one
    ///     `container` was loaded from.
    ///   - container: The model that is already loaded and resident.
    ///   - cacheDir: The directory the router caches under.
    ///   - recordingsDir: The directory the router records under.
    ///   - routerId: The id to stamp the router with. Pass the FIRST router's id
    ///     to continue the same recording root; a fresh one starts a new root.
    /// - Returns: The profile to vend sessions from.
    private static func makeProfile(
        model: ModelRef,
        container: MLXFoundationModelsContainer,
        cacheDir: URL,
        recordingsDir: URL,
        routerId: ULID = .generate()
    ) -> LanguageModelProfile {
        RealModelHarness.make(
            model: model,
            // The window this suite's own hand-built profile resolved at before
            // it moved onto the harness: it stated no `contextTokens` at all, so
            // every slot took `SlotResolution`'s own default. Stated explicitly
            // here, because the harness has no default of its own to inherit.
            context: ProfileDefinition.defaultContext,
            container: container,
            cacheDir: cacheDir,
            recordingsDir: recordingsDir,
            routerId: routerId
        )
    }

    /// The decoding every container this suite loads is pinned to.
    ///
    /// Argmax. The provider default samples at temperature `0.6` from MLX's
    /// process-global PRNG, which seeds itself from the clock, so the length of
    /// the `<think>` block the 30B writes before each answer, and the wall
    /// clock with it, differed on every run of identical code. Argmax decoding
    /// consumes no randomness at all, which is what lets a red run here be
    /// attributed to the change under test, and what lets the wall clock be
    /// measured against the budget rather than against the run.
    private static let samplingMode: GenerationOptions.SamplingMode = .greedy

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

    /// A root session's own sidecar file, under a router's recording root.
    ///
    /// - Parameters:
    ///   - routerDirectory: The router's recording root.
    ///   - rootId: The root session's span id, which names its directory.
    /// - Returns: The URL of that session's `session.json`.
    private static func rootSidecarURL(routerDirectory: URL, rootId: ULID) -> URL {
        routerDirectory
            .appendingPathComponent(rootId.description, isDirectory: true)
            .appendingPathComponent("session.json", isDirectory: false)
    }

    /// The ids and observations ``driveOriginalTree(cacheDir:recordingsDir:)``
    /// hands back once every in-memory session it built has gone out of scope.
    private struct OriginalTree {
        let routerId: ULID
        let rootId: ULID
        let forkAId: ULID
        let forkBId: ULID
        let grandforkId: ULID
        /// The root session's write-once `session.json` bytes as of just
        /// before restoration.
        let rootSidecarBytes: Data
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
        let container = try await RealModelContainer.load(
            ref: sessionTreeForkTreeModel, samplingMode: Self.samplingMode)
        let profile = Self.makeProfile(
            model: sessionTreeForkTreeModel, container: container, cacheDir: cacheDir, recordingsDir: recordingsDir)
        // The router's own id, read off the handle it stamped. The harness
        // returns no `Router`, because this is the only fact this suite needs of
        // one and every handle already carries it.
        let routerId = profile.standard.routerId

        let root = profile.standard.makeSession(instructions: "You are a terse, literal assistant.")
        _ = try await root.respond(
            to: "My favorite number is 42. Remember it. Reply with just \"OK\".",
            maxTokens: GatedRealModelBudget.responseTokenCeiling
        )

        let forkA = try await root.fork(workingDirectory: nil)
        _ = try await forkA.respond(to: "Say hi in one word.", maxTokens: GatedRealModelBudget.responseTokenCeiling)
        let forkB = try await root.fork(workingDirectory: nil)
        _ = try await forkB.respond(to: "Say hi in one word.", maxTokens: GatedRealModelBudget.responseTokenCeiling)
        let grandfork = try await forkA.fork(workingDirectory: nil)
        _ = try await grandfork.respond(to: "Say hi in one word.", maxTokens: GatedRealModelBudget.responseTokenCeiling)

        // Step 3: sync-as-they-happen — every session's transcript.jsonl
        // already contains its own turn's entry events, before any teardown.
        for session in [root, forkA, forkB, grandfork] {
            let events = try Self.recordedEvents(in: session.recordingDirectory)
            let entryKinds: Set<TranscriptEvent.Kind> = [.instructions, .prompt, .toolCalls, .toolOutput, .response, .reasoning]
            #expect(events.contains { entryKinds.contains($0.kind) })
        }

        let routerDirectory = recordingsDir.appendingPathComponent(routerId.description, isDirectory: true)
        let tree = try TranscriptTree.load(under: routerDirectory)
        let effectiveEntryCounts = try [root.id, forkA.id, forkB.id, grandfork.id].reduce(into: [ULID: Int]()) { acc, id in
            acc[id] = try tree.effectiveEntryEvents(forSession: id).count
        }

        let rootSidecarBytes = try Data(contentsOf: Self.rootSidecarURL(routerDirectory: routerDirectory, rootId: root.id))

        await container.model.evict()

        return OriginalTree(
            routerId: routerId,
            rootId: root.id,
            forkAId: forkA.id,
            forkBId: forkB.id,
            grandforkId: grandfork.id,
            rootSidecarBytes: rootSidecarBytes,
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
        let container2 = try await RealModelContainer.load(
            ref: sessionTreeForkTreeModel, samplingMode: Self.samplingMode)
        let profile2 = Self.makeProfile(
            model: sessionTreeForkTreeModel,
            container: container2,
            cacheDir: cacheDir,
            recordingsDir: recordingsDir,
            routerId: original.routerId
        )

        // Step 6: restore, passing only the root session's id.
        let restored = try await profile2.standard.restoreSessionTree(root: original.rootId)

        // Step 7: structure matches.
        #expect(restored.root.id == original.rootId)
        // The restored tree continues the FIRST router's recording root, which
        // is the whole reason `RealModelHarness.make` takes a `routerId`.
        #expect(restored.root.routerId == original.routerId)
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

        // The root's sidecar is byte-identical: it is write-once, and
        // restoration only ever reads it.
        let rootSidecarBytesAfterRestore = try Data(
            contentsOf: Self.rootSidecarURL(routerDirectory: routerDirectory, rootId: original.rootId)
        )
        #expect(rootSidecarBytesAfterRestore == original.rootSidecarBytes)

        // Step 8: the fidelity payoff. A brand-new live turn on the deepest
        // restored node (three levels down from the root that was told the
        // fact) recalls it — proof the `LanguageModelSession(transcript:)`
        // seed behaves indistinguishably from a never-torn-down session.
        let restoredGrandfork = try #require(restored.session(original.grandforkId))
        let reply = try await restoredGrandfork.respond(
            to: "What is my favorite number? Answer with just the number, digits only.",
            maxTokens: GatedRealModelBudget.responseTokenCeiling
        )
        #expect(reply.contains("42"))

        await container2.model.evict()
    }

    // MARK: - Tools threaded through restoration (task jkdae4b)

    /// Task jkdae4b: proves ``RoutedModel/restoreSessionTree(root:recordingRoot:tools:)``
    /// gives a restored session real, live tool-calling — not the fixed
    /// `tools: []` a restore used to hardcode all the way down through
    /// ``LoadedLLMContainer/makeSession(transcript:)``. A root session is
    /// recorded with no tools, torn down, then restored in a fresh `Router`
    /// with a real ``EchoTool`` passed via `tools:`; a new turn instructing
    /// the model to call it is recorded with `.toolCalls`/`.toolOutput`
    /// entries and a response reflecting the tool's own output — proof the
    /// restored `LanguageModelSession` was actually built with the tool
    /// threaded to it, not silently ignoring it.
    @Test("restoreSessionTree(tools:) gives a restored session real tool-calling: a new turn on the restored root calls the echo tool")
    func restoredSessionCallsThreadedTool() async throws {
        let cacheDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SessionTreeRestorationIntegrationTests-tools-cache-\(UUID().uuidString)", isDirectory: true)
        let recordingsDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SessionTreeRestorationIntegrationTests-tools-recordings-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: cacheDir)
            try? FileManager.default.removeItem(at: recordingsDir)
        }

        // Record a root session with no tools at all, then discard everything
        // that built it, mirroring `driveOriginalTree`'s teardown discipline.
        let (routerId, rootId): (ULID, ULID) = try await {
            let container = try await RealModelContainer.load(
                ref: sessionTreeToolCallingModel, samplingMode: Self.samplingMode)
            let profile = Self.makeProfile(
                model: sessionTreeToolCallingModel, container: container, cacheDir: cacheDir,
                recordingsDir: recordingsDir)
            let root = profile.standard.makeSession()
            _ = try await root.respond(to: "Say hi in one word.", maxTokens: GatedRealModelBudget.responseTokenCeiling)
            await container.model.evict()
            return (profile.standard.routerId, root.id)
        }()

        // A fresh process continuing the same recording root, restoring with
        // a real tool this time — the seam that used to hardcode `tools: []`.
        let container2 = try await RealModelContainer.load(
            ref: sessionTreeToolCallingModel, samplingMode: Self.samplingMode)
        let profile2 = Self.makeProfile(
            model: sessionTreeToolCallingModel, container: container2, cacheDir: cacheDir,
            recordingsDir: recordingsDir, routerId: routerId)
        let restored = try await profile2.standard.restoreSessionTree(root: rootId, tools: [EchoTool()])
        // The same invariant the tree-restoration test above asserts: this
        // profile continues the first router's recording root.
        #expect(restored.root.routerId == routerId)

        let reply = try await restored.root.respond(
            to: "Call the echo tool with the text 'ping', then report its result.",
            maxTokens: GatedRealModelBudget.responseTokenCeiling
        )
        #expect(!reply.isEmpty)

        let routerDirectory = recordingsDir.appendingPathComponent(routerId.description, isDirectory: true)
        let events = try Self.recordedEvents(in: routerDirectory.appendingPathComponent(rootId.description, isDirectory: true))
        #expect(events.contains { $0.kind == .toolCalls })
        #expect(events.contains { $0.kind == .toolOutput })

        await container2.model.evict()
    }
}
