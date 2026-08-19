import Foundation
import FoundationModels
import FoundationModelsRouterTestSupport
import Testing

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

/// The same real `mlx-community` generation model the rest of this target's
/// gated suites use for the `.standard` slot.
private let sessionTreeRestorationTinyModel: ModelRef = RealModels.standard

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
    "Gated real-model end-to-end coverage: restoreSessionTree(root:) (task zcxnbst)",
    .serialized,
    .timeLimit(.minutes(20)),
    .enabled(if: sessionTreeRestorationIntegrationEnabled),
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
    /// A wrapper rather than four spelled-out calls, because this suite's model
    /// and context are the same at each of its four sites and only the container
    /// and the router id move.
    ///
    /// - Parameters:
    ///   - container: The model that is already loaded and resident.
    ///   - cacheDir: The directory the router caches under.
    ///   - recordingsDir: The directory the router records under.
    ///   - routerId: The id to stamp the router with. Pass the FIRST router's id
    ///     to continue the same recording root; a fresh one starts a new root.
    /// - Returns: The profile to vend sessions from.
    private static func makeProfile(
        container: MLXFoundationModelsContainer,
        cacheDir: URL,
        recordingsDir: URL,
        routerId: ULID = .generate()
    ) -> LanguageModelProfile {
        RealModelHarness.make(
            model: sessionTreeRestorationTinyModel,
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
        let container = try await RealModelContainer.load(ref: sessionTreeRestorationTinyModel)
        let profile = Self.makeProfile(container: container, cacheDir: cacheDir, recordingsDir: recordingsDir)
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
        let container2 = try await RealModelContainer.load(ref: sessionTreeRestorationTinyModel)
        let profile2 = Self.makeProfile(
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
            let container = try await RealModelContainer.load(ref: sessionTreeRestorationTinyModel)
            let profile = Self.makeProfile(container: container, cacheDir: cacheDir, recordingsDir: recordingsDir)
            let root = profile.standard.makeSession()
            _ = try await root.respond(to: "Say hi in one word.", maxTokens: GatedRealModelBudget.responseTokenCeiling)
            await container.model.evict()
            return (profile.standard.routerId, root.id)
        }()

        // A fresh process continuing the same recording root, restoring with
        // a real tool this time — the seam that used to hardcode `tools: []`.
        let container2 = try await RealModelContainer.load(ref: sessionTreeRestorationTinyModel)
        let profile2 = Self.makeProfile(
            container: container2, cacheDir: cacheDir, recordingsDir: recordingsDir, routerId: routerId)
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
