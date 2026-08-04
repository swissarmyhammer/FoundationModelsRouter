import Foundation
import FoundationModels
import Testing

@testable import FoundationModelsRouter

/// Exercises task 3y1tktw: the crash edge of run-outcome durability.
///
/// A journaled run with a non-terminal event (`.progress` or `.elicitation`)
/// in the effective recorded stream and no `.completed` for the same
/// `(tool, correlationID)` pair anywhere in that stream died with the
/// crashed process — its memory-only ``SessionMailbox`` is gone, so no
/// teardown sweep ever journaled a terminal event for it.
/// ``RoutedModel/restoreSessionTree(root:registry:tools:)`` closes that hole
/// at restore time: it manufactures exactly one terminal `.completed` event
/// with outcome ``OperationOutcome/lost`` per orphaned run and posts it to
/// the restored node's own fresh outbox, so the next turn's drain journals
/// it durably and the model learns the run died. (The orderly-shutdown case
/// is ``RoutedSessionActor/close()``'s mailbox sweep — see
/// ``SessionMailboxTests``; this suite covers only the crash edge.)
///
/// Also carries the default-registry regression: restoring a transcript that
/// contains recorded ``OperationEventSegment``s must succeed with the
/// default ``CustomSegmentRegistry/routerDefault`` (no
/// `unregisteredCustomSegmentType` throw, no caller setup).
///
/// Everything runs against stubs (pattern from
/// ``SessionTreeRestorationToolWiringTests``): no MLX, no network, no GPU.
@Suite("restoreSessionTree: orphaned journaled runs manufacture .lost terminals")
struct SessionTreeRestorationLostRunTests {
    // MARK: - Stub container

    private final class BasicLLMContainer: PlainTranscriptStubContainer {
        func makeSession(instructions: String?) -> any LanguageModelSessionBackend {
            StubSessionBackend(responseText: "stub response")
        }
    }

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
            .appendingPathComponent("SessionTreeRestorationLostRunTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Builds a router wired with the stubs and a durable recordings root.
    ///
    /// - Parameter id: The router id to construct with — pass the first
    ///   router's `id` to simulate a fresh process continuing the same
    ///   recording root.
    private static func makeRouter(
        id: ULID = .generate(),
        cacheDir: URL,
        recordingsDir: URL
    ) -> Router {
        Router(
            id: id,
            cacheDir: cacheDir,
            recordingsDir: recordingsDir,
            recorder: JSONLRecorder(directory: recordingsDir),
            probe: StubProbe(chip: "Apple Test", totalRAM: 64 << 30, recommendedMaxWorkingSetSize: 48 << 30),
            metadataSource: StubMetadataSource(raw: rawMetadata),
            loader: StubModelLoader(container: BasicLLMContainer(), dimension: stubDimension)
        )
    }

    /// Builds a canned ``OperationEvent``.
    private static func event(
        tool: String = "shell",
        op: String = "run command",
        correlationID: String,
        kind: OperationEventKind,
        detail: String,
        outcome: OperationOutcome? = nil,
        elicitation: ElicitationRequest? = nil
    ) -> OperationEvent {
        OperationEvent(
            tool: tool, op: op, correlationID: correlationID, kind: kind, detail: detail,
            outcome: outcome, elicitation: elicitation)
    }

    /// Builds the production elicitation shape ``ToolContext/elicit(_:)``
    /// posts: `kind: .elicitation`, an empty `detail`, and the question
    /// carried in the typed request's `message` — never in `detail`.
    private static func elicitationEvent(
        tool: String = "snippet",
        op: String = "elicit form",
        correlationID: String,
        message: String
    ) -> OperationEvent {
        event(
            tool: tool, op: op, correlationID: correlationID, kind: .elicitation, detail: "",
            elicitation: ElicitationRequest(
                message: message,
                elicitationId: ULID.generate(),
                requestedSchema: ElicitationRequestedSchema(
                    properties: ["pick": .singleSelect(ElicitationSingleSelectSchema(values: ["a", "b"]))]
                )
            )
        )
    }

    /// Records a root session under a fresh router, riding `journaled` into
    /// its single turn (each is drained from the outbox and journaled as an
    /// ``OperationEventSegment`` on the recorded `.prompt` entry), then
    /// restores that root under a second router sharing the same recording
    /// root — the crashed-process simulation: the first session's
    /// memory-only mailbox/outbox are simply gone.
    ///
    /// - Returns: The restored tree and the original root's id.
    private static func recordAndRestore(
        journaled: [OperationEvent],
        cacheDir: URL,
        recordingsDir: URL
    ) async throws -> (restored: RestoredSessionTree, rootId: ULID) {
        let router1 = makeRouter(cacheDir: cacheDir, recordingsDir: recordingsDir)
        let profile1 = try await router1.resolve(profile: profile, reporting: ResolutionProgress())
        let root = profile1.standard.makeSession()
        for event in journaled {
            await root.outbox.post(event)
        }
        _ = try await root.respond(to: "hello")

        let router2 = makeRouter(id: router1.id, cacheDir: cacheDir, recordingsDir: recordingsDir)
        let profile2 = try await router2.resolve(profile: profile, reporting: ResolutionProgress())
        let restored = try await profile2.standard.restoreSessionTree(root: root.id)
        return (restored, root.id)
    }

    // MARK: - Default-registry round trip (regression)

    @Test("a transcript carrying OperationEventSegments restores with the default registry — no unregisteredCustomSegmentType")
    @MainActor
    func defaultRegistryRestoresTranscriptWithEventSegments() async throws {
        let cacheDir = Self.makeTempDir()
        let recordingsDir = Self.makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: cacheDir)
            try? FileManager.default.removeItem(at: recordingsDir)
        }

        // A run that completed cleanly: the journaled segments exercise the
        // default-registry rebuild path without tripping any orphan logic.
        let (restored, rootId) = try await Self.recordAndRestore(
            journaled: [
                Self.event(correlationID: "run-1", kind: .progress, detail: "10%"),
                Self.event(correlationID: "run-1", kind: .completed, detail: "exit 0", outcome: .succeeded),
            ],
            cacheDir: cacheDir,
            recordingsDir: recordingsDir
        )

        #expect(restored.session(rootId) != nil)
    }

    // MARK: - Orphaned run -> manufactured .lost

    @Test("an orphaned .progress run manufactures exactly one .completed/.lost on the restored session's outbox")
    @MainActor
    func orphanedProgressRunManufacturesOneLostEvent() async throws {
        let cacheDir = Self.makeTempDir()
        let recordingsDir = Self.makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: cacheDir)
            try? FileManager.default.removeItem(at: recordingsDir)
        }

        let (restored, _) = try await Self.recordAndRestore(
            journaled: [Self.event(correlationID: "run-1", kind: .progress, detail: "812 lines so far")],
            cacheDir: cacheDir,
            recordingsDir: recordingsDir
        )

        let pending = await restored.root.outbox.pending()
        #expect(pending.events.count == 1)
        let manufactured = try #require(pending.events.first?.event)
        #expect(manufactured.kind == .completed)
        #expect(manufactured.outcome == .lost)
        #expect(manufactured.correlationID == "run-1")
        #expect(manufactured.tool == "shell")
        #expect(manufactured.op == "run command")
    }

    @Test("an orphaned .elicitation run manufactures a .completed/.lost carrying the question as its detail")
    @MainActor
    func orphanedElicitationRunManufacturesLostEvent() async throws {
        let cacheDir = Self.makeTempDir()
        let recordingsDir = Self.makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: cacheDir)
            try? FileManager.default.removeItem(at: recordingsDir)
        }

        // The production shape: the question rides `elicitation.message`,
        // `detail` is empty — the manufactured terminal must surface the
        // message, not an empty body.
        let (restored, _) = try await Self.recordAndRestore(
            journaled: [Self.elicitationEvent(correlationID: "ask-1", message: "Which account?")],
            cacheDir: cacheDir,
            recordingsDir: recordingsDir
        )

        let pending = await restored.root.outbox.pending()
        #expect(pending.events.count == 1)
        let manufactured = try #require(pending.events.first?.event)
        #expect(manufactured.kind == .completed)
        #expect(manufactured.outcome == .lost)
        #expect(manufactured.correlationID == "ask-1")
        #expect(manufactured.tool == "snippet")
        #expect(manufactured.op == "elicit form")
        #expect(manufactured.detail == "Which account?")
    }

    // MARK: - Completed run -> nothing manufactured

    @Test("a run whose .completed is journaled manufactures nothing on restore")
    @MainActor
    func completedRunManufacturesNothing() async throws {
        let cacheDir = Self.makeTempDir()
        let recordingsDir = Self.makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: cacheDir)
            try? FileManager.default.removeItem(at: recordingsDir)
        }

        let (restored, _) = try await Self.recordAndRestore(
            journaled: [
                Self.event(correlationID: "run-1", kind: .progress, detail: "10%"),
                Self.event(correlationID: "run-1", kind: .completed, detail: "exit 0", outcome: .succeeded),
            ],
            cacheDir: cacheDir,
            recordingsDir: recordingsDir
        )

        let pending = await restored.root.outbox.pending()
        #expect(pending.events.isEmpty)
    }

    // MARK: - Two orphaned runs -> two distinct .lost events

    @Test("two orphaned runs manufacture two .lost events with distinct correlationIDs")
    @MainActor
    func twoOrphanedRunsManufactureTwoLostEvents() async throws {
        let cacheDir = Self.makeTempDir()
        let recordingsDir = Self.makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: cacheDir)
            try? FileManager.default.removeItem(at: recordingsDir)
        }

        let (restored, _) = try await Self.recordAndRestore(
            journaled: [
                Self.event(correlationID: "run-1", kind: .progress, detail: "first run"),
                Self.event(correlationID: "run-2", kind: .progress, detail: "second run"),
            ],
            cacheDir: cacheDir,
            recordingsDir: recordingsDir
        )

        let pending = await restored.root.outbox.pending()
        let manufactured = pending.events.map(\.event)
        #expect(manufactured.count == 2)
        #expect(manufactured.allSatisfy { $0.kind == .completed && $0.outcome == .lost })
        #expect(Set(manufactured.map(\.correlationID)) == ["run-1", "run-2"])
    }

    // MARK: - Runs are keyed by (tool, correlationID), never correlationID alone

    @Test("one tool's .completed does not suppress another tool's orphan sharing the same correlationID")
    @MainActor
    func completedRunOfOneToolDoesNotSuppressAnotherToolsOrphan() async throws {
        let cacheDir = Self.makeTempDir()
        let recordingsDir = Self.makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: cacheDir)
            try? FileManager.default.removeItem(at: recordingsDir)
        }

        // Correlation ids are tool-assigned and opaque — two tools can both
        // use "3". The shell run completed; the snippet run is orphaned. The
        // manufactured .lost must exist and be attributed to the snippet
        // run, exactly the (tool, correlationID) identity SessionOutbox's
        // own coalescing uses.
        let (restored, _) = try await Self.recordAndRestore(
            journaled: [
                Self.event(tool: "shell", op: "run command", correlationID: "3", kind: .progress, detail: "running"),
                Self.event(
                    tool: "shell", op: "run command", correlationID: "3", kind: .completed,
                    detail: "exit 0", outcome: .succeeded),
                Self.event(tool: "snippet", op: "run snippet", correlationID: "3", kind: .progress, detail: "compiling"),
            ],
            cacheDir: cacheDir,
            recordingsDir: recordingsDir
        )

        let pending = await restored.root.outbox.pending()
        #expect(pending.events.count == 1)
        let manufactured = try #require(pending.events.first?.event)
        #expect(manufactured.outcome == .lost)
        #expect(manufactured.tool == "snippet")
        #expect(manufactured.op == "run snippet")
        #expect(manufactured.correlationID == "3")
    }

    // MARK: - Fork trees: the scan is per node, over that node's own effective view

    @Test("an ancestor's orphaned run manufactures one .lost on every restored node whose inherited prefix carries it")
    @MainActor
    func parentOrphanManufacturesLostOnParentAndFork() async throws {
        let cacheDir = Self.makeTempDir()
        let recordingsDir = Self.makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: cacheDir)
            try? FileManager.default.removeItem(at: recordingsDir)
        }

        let router1 = Self.makeRouter(cacheDir: cacheDir, recordingsDir: recordingsDir)
        let profile1 = try await router1.resolve(profile: Self.profile, reporting: ResolutionProgress())
        let root = profile1.standard.makeSession()
        await root.outbox.post(Self.event(correlationID: "run-1", kind: .progress, detail: "dangling"))
        _ = try await root.respond(to: "hello")
        let fork = try await root.fork(workingDirectory: nil)
        _ = try await fork.respond(to: "fork turn")

        let router2 = Self.makeRouter(id: router1.id, cacheDir: cacheDir, recordingsDir: recordingsDir)
        let profile2 = try await router2.resolve(profile: Self.profile, reporting: ResolutionProgress())
        let restored = try await profile2.standard.restoreSessionTree(root: root.id)
        let restoredFork = try #require(restored.children(of: root.id).first)

        // Per-node closure: the dangling .progress sits in both nodes'
        // effective streams (the fork inherits it in its parent prefix), so
        // each restored node's model gets its own .lost — one per node, on
        // that node's own outbox.
        let rootPending = await restored.root.outbox.pending()
        #expect(rootPending.events.map(\.event.outcome) == [.lost])
        let forkPending = await restoredFork.outbox.pending()
        #expect(forkPending.events.map(\.event.outcome) == [.lost])
        #expect(forkPending.events.first?.event.correlationID == "run-1")
    }

    @Test("a run completed by the parent after the fork cut point is .lost only from the fork's own view")
    @MainActor
    func runCompletedAfterForkCutIsLostOnlyFromForksView() async throws {
        let cacheDir = Self.makeTempDir()
        let recordingsDir = Self.makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: cacheDir)
            try? FileManager.default.removeItem(at: recordingsDir)
        }

        let router1 = Self.makeRouter(cacheDir: cacheDir, recordingsDir: recordingsDir)
        let profile1 = try await router1.resolve(profile: Self.profile, reporting: ResolutionProgress())
        let root = profile1.standard.makeSession()
        await root.outbox.post(Self.event(correlationID: "run-1", kind: .progress, detail: "running"))
        _ = try await root.respond(to: "hello")
        let fork = try await root.fork(workingDirectory: nil)
        _ = try await fork.respond(to: "fork turn")
        // The completion lands in the parent only after the fork's cut point
        // was fixed — it never enters the fork's inherited prefix.
        await root.outbox.post(
            Self.event(correlationID: "run-1", kind: .completed, detail: "exit 0", outcome: .succeeded))
        _ = try await root.respond(to: "parent turn two")

        let router2 = Self.makeRouter(id: router1.id, cacheDir: cacheDir, recordingsDir: recordingsDir)
        let profile2 = try await router2.resolve(profile: Self.profile, reporting: ResolutionProgress())
        let restored = try await profile2.standard.restoreSessionTree(root: root.id)
        let restoredFork = try #require(restored.children(of: root.id).first)

        // The parent's own view has the terminal — nothing manufactured. The
        // fork's view ends on the dangling .progress: from its conversation
        // the outcome genuinely is unknowable, so it gets a .lost.
        let rootPending = await restored.root.outbox.pending()
        #expect(rootPending.events.isEmpty)
        let forkPending = await restoredFork.outbox.pending()
        #expect(forkPending.events.map(\.event.outcome) == [.lost])
    }

    // MARK: - Manufactured detail is bounded like sweep()'s synthesized terminal

    @Test("a manufactured .lost detail is truncated to the trailing terminalDetailTailLimit characters")
    @MainActor
    func manufacturedDetailIsBoundedToTerminalDetailTailLimit() async throws {
        let cacheDir = Self.makeTempDir()
        let recordingsDir = Self.makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: cacheDir)
            try? FileManager.default.removeItem(at: recordingsDir)
        }

        // Progress details are journaled verbatim, so an orphaned run can
        // carry an arbitrarily large one; the manufactured terminal must
        // apply the same trailing-tail bound sweep()'s synthesized terminal
        // does, keeping the end of the output (what a reader acts on).
        let oversized = String(repeating: "x", count: SessionMailbox.terminalDetailTailLimit) + "TAIL-MARKER"
        let (restored, _) = try await Self.recordAndRestore(
            journaled: [Self.event(correlationID: "run-1", kind: .progress, detail: oversized)],
            cacheDir: cacheDir,
            recordingsDir: recordingsDir
        )

        let pending = await restored.root.outbox.pending()
        let manufactured = try #require(pending.events.first?.event)
        #expect(manufactured.outcome == .lost)
        #expect(manufactured.detail.count == SessionMailbox.terminalDetailTailLimit)
        #expect(manufactured.detail.hasSuffix("TAIL-MARKER"))
    }
}
