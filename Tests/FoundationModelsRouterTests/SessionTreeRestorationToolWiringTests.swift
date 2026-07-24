import Foundation
import FoundationModels
import Operations
import Testing

@testable import FoundationModelsRouter

/// Exercises task jkdae4b: threading `[any FoundationModels.Tool]` through
/// ``RoutedModel/restoreSessionTree(root:registry:tools:)`` — the seam that
/// used to hardcode `tools: []` through ``LoadedLLMContainer/makeSession(transcript:)``,
/// leaving a restored session tree with no live tool-calling at all.
///
/// Mirrors ``SessionOutboxToolWiringTests``'s stub-based approach (no MLX, no
/// network, no GPU): a container that records the exact tool list threaded to
/// its `makeSession(transcript:tools:)` construction seam, so a test can
/// assert both that the caller's `tools:` argument reaches the container/
/// backend boundary for every restored node, and that each node gets its own
/// per-session instanced (sink-bound) copy rather than sharing one instance
/// tree-wide. Real `LanguageModelSession(tools:)` wiring for a restored
/// transcript lives in the live ``MLXFoundationModelsContainer``
/// (`Resolution/LiveModelLoader.swift`), exercised end to end only by the
/// gated integration suite.
@Suite("restoreSessionTree(root:registry:tools:): tools threaded to every restored node")
struct SessionTreeRestorationToolWiringTests {
    // MARK: - Test tools

    @Generable
    struct FakeToolArguments {
        let value: String
    }

    /// A real `FoundationModels.Tool` that also conforms to `EventEmittingTool`
    /// via a pure `connecting(_:)` — mirrors ``SessionOutboxToolWiringTests/FakeEmittingTool``.
    /// `@unchecked Sendable`: `sink` is immutable (`let`), so concurrent reads
    /// are safe even if `OperationEventSink` does not conform to `Sendable`.
    private final class FakeEmittingTool: Tool, EventEmittingTool, @unchecked Sendable {
        let name = "fake-emitter"
        let description = "test-only tool that posts events through its own sink"

        private let sink: (any OperationEventSink)?

        init(sink: (any OperationEventSink)? = nil) {
            self.sink = sink
        }

        /// Pure: returns a new instance wired to `sink`, never mutating
        /// `self` — the receiver (e.g. the caller's own original) keeps
        /// posting into the void forever.
        func connecting(_ sink: any OperationEventSink) -> any Tool {
            FakeEmittingTool(sink: sink)
        }

        func call(arguments: FakeToolArguments) async throws -> String {
            "handled: \(arguments.value)"
        }

        /// Posts `event` through this instance's own sink, or silently drops
        /// it if none is connected.
        func postEvent(_ event: OperationEvent) async {
            await sink?.post(event)
        }
    }

    private struct PlainTool: Tool {
        let name = "plain"
        let description = "a tool with no event-emitting capability"

        func call(arguments: FakeToolArguments) async throws -> String {
            "plain: \(arguments.value)"
        }
    }

    private static func event(correlationID: String = "c1", detail: String = "done") -> OperationEvent {
        OperationEvent(tool: "fake-emitter", op: "run thing", correlationID: correlationID, kind: .completed, detail: detail)
    }

    // MARK: - Stub container capturing the threaded tool list per restored node

    /// A ``LoadedLLMContainer`` that records the `tools` most recently passed
    /// to `makeSession(transcript:tools:)` — the seam
    /// ``RoutedModel/restoreSessionTree(root:registry:tools:)`` threads its
    /// own per-node instanced tool list through — plus every backend it has
    /// vended, keyed by call order, so a test can inspect each restored
    /// node's own threaded list rather than only the last one.
    private final class ToolCapturingRestoreContainer: LoadedLLMContainer, @unchecked Sendable {
        private(set) var threadedToolsByCall: [[any Tool]] = []
        private(set) var backendsByCall: [StubSessionBackend] = []

        func makeSession(instructions: String?) -> any LanguageModelSessionBackend {
            StubSessionBackend(instructions: instructions)
        }

        func makeSession(transcript: Transcript) -> any LanguageModelSessionBackend {
            StubSessionBackend(entries: Array(transcript))
        }

        func makeSession(transcript: Transcript, tools: [any Tool]) -> any LanguageModelSessionBackend {
            threadedToolsByCall.append(tools)
            let backend = StubSessionBackend(entries: Array(transcript))
            backendsByCall.append(backend)
            return backend
        }
    }

    // MARK: - Stubs

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
            .appendingPathComponent("SessionTreeRestorationToolWiringTests-\(UUID().uuidString)", isDirectory: true)
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
        container: any LoadedLLMContainer,
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
            loader: StubModelLoader(container: container, dimension: stubDimension)
        )
    }

    // MARK: - Tools threaded to the container/backend boundary

    @Test("restoreSessionTree(tools:) threads the exact tool list to the container's makeSession(transcript:tools:)")
    @MainActor
    func restoredRootThreadsToolsToContainer() async throws {
        let cacheDir = Self.makeTempDir()
        let recordingsDir = Self.makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: cacheDir)
            try? FileManager.default.removeItem(at: recordingsDir)
        }

        let container1 = ToolCapturingRestoreContainer()
        let router1 = Self.makeRouter(container: container1, cacheDir: cacheDir, recordingsDir: recordingsDir)
        let profile1 = try await router1.resolve(profile: Self.profile, reporting: ResolutionProgress())
        let root = profile1.standard.makeSession()
        _ = try await root.respond(to: "hello")

        let container2 = ToolCapturingRestoreContainer()
        let router2 = Self.makeRouter(
            id: router1.id, container: container2, cacheDir: cacheDir, recordingsDir: recordingsDir)
        let profile2 = try await router2.resolve(profile: Self.profile, reporting: ResolutionProgress())

        let emitter = FakeEmittingTool()
        let plain = PlainTool()
        _ = try await profile2.standard.restoreSessionTree(root: root.id, tools: [emitter, plain])

        #expect(container2.threadedToolsByCall.count == 1)
        let threaded = try #require(container2.threadedToolsByCall.first)
        #expect(threaded.count == 2)
        #expect(threaded.contains { $0 is FakeEmittingTool })
        #expect(threaded.contains { $0 is PlainTool })
    }

    @Test("the container receives a distinct, sink-bound copy of an emitting tool for a restored root — not the original")
    @MainActor
    func restoredRootReceivesDistinctSinkBoundCopy() async throws {
        let cacheDir = Self.makeTempDir()
        let recordingsDir = Self.makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: cacheDir)
            try? FileManager.default.removeItem(at: recordingsDir)
        }

        let container1 = ToolCapturingRestoreContainer()
        let router1 = Self.makeRouter(container: container1, cacheDir: cacheDir, recordingsDir: recordingsDir)
        let profile1 = try await router1.resolve(profile: Self.profile, reporting: ResolutionProgress())
        let root = profile1.standard.makeSession()
        _ = try await root.respond(to: "hello")

        let container2 = ToolCapturingRestoreContainer()
        let router2 = Self.makeRouter(
            id: router1.id, container: container2, cacheDir: cacheDir, recordingsDir: recordingsDir)
        let profile2 = try await router2.resolve(profile: Self.profile, reporting: ResolutionProgress())

        let emitter = FakeEmittingTool()
        let restored = try await profile2.standard.restoreSessionTree(root: root.id, tools: [emitter])

        guard let instancedEmitter = container2.threadedToolsByCall.first?.first as? FakeEmittingTool else {
            Issue.record("expected the container to receive a FakeEmittingTool")
            return
        }
        #expect(instancedEmitter !== emitter)

        // Posting through the container-threaded copy reaches the restored
        // root's own outbox — proving it really is the sink-bound instance
        // wired at restore time, not a disconnected passthrough.
        await instancedEmitter.postEvent(Self.event(detail: "threaded-to-restored-backend"))
        let pending = await restored.root.outbox.pending()
        #expect(pending.events.map(\.event.detail) == ["threaded-to-restored-backend"])

        // The original, never instanced, still posts into the void.
        await emitter.postEvent(Self.event(detail: "never reaches anything"))
        let pendingAfter = await restored.root.outbox.pending()
        #expect(pendingAfter.events.map(\.event.detail) == ["threaded-to-restored-backend"])
    }

    @Test("each restored node in a tree gets its own fresh outbox with its own instanced tool copy — not shared tree-wide")
    @MainActor
    func eachRestoredNodeGetsItsOwnOutboxAndToolInstance() async throws {
        let cacheDir = Self.makeTempDir()
        let recordingsDir = Self.makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: cacheDir)
            try? FileManager.default.removeItem(at: recordingsDir)
        }

        let container1 = ToolCapturingRestoreContainer()
        let router1 = Self.makeRouter(container: container1, cacheDir: cacheDir, recordingsDir: recordingsDir)
        let profile1 = try await router1.resolve(profile: Self.profile, reporting: ResolutionProgress())
        let root = profile1.standard.makeSession()
        _ = try await root.respond(to: "hello")
        let fork = try await root.fork(workingDirectory: nil)
        _ = try await fork.respond(to: "fork turn")

        let container2 = ToolCapturingRestoreContainer()
        let router2 = Self.makeRouter(
            id: router1.id, container: container2, cacheDir: cacheDir, recordingsDir: recordingsDir)
        let profile2 = try await router2.resolve(profile: Self.profile, reporting: ResolutionProgress())

        let emitter = FakeEmittingTool()
        let restored = try await profile2.standard.restoreSessionTree(root: root.id, tools: [emitter])
        let restoredFork = try #require(restored.children(of: root.id).first)

        #expect(restored.root.outbox !== restoredFork.outbox)

        guard let rootInstancedEmitter = container2.threadedToolsByCall[0].first as? FakeEmittingTool,
            let forkInstancedEmitter = container2.threadedToolsByCall[1].first as? FakeEmittingTool
        else {
            Issue.record("expected both restored nodes to receive an instanced FakeEmittingTool")
            return
        }
        #expect(rootInstancedEmitter !== forkInstancedEmitter)

        await rootInstancedEmitter.postEvent(Self.event(correlationID: "root", detail: "from-root"))
        await forkInstancedEmitter.postEvent(Self.event(correlationID: "fork", detail: "from-fork"))

        let rootPending = await restored.root.outbox.pending()
        let forkPending = await restoredFork.outbox.pending()
        #expect(rootPending.events.map(\.event.detail) == ["from-root"])
        #expect(forkPending.events.map(\.event.detail) == ["from-fork"])
    }

    @Test("a session with no tools argument restores with an empty, unconnected outbox")
    @MainActor
    func restoringWithNoToolsHasEmptyOutbox() async throws {
        let cacheDir = Self.makeTempDir()
        let recordingsDir = Self.makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: cacheDir)
            try? FileManager.default.removeItem(at: recordingsDir)
        }

        let container1 = ToolCapturingRestoreContainer()
        let router1 = Self.makeRouter(container: container1, cacheDir: cacheDir, recordingsDir: recordingsDir)
        let profile1 = try await router1.resolve(profile: Self.profile, reporting: ResolutionProgress())
        let root = profile1.standard.makeSession()
        _ = try await root.respond(to: "hello")

        let container2 = ToolCapturingRestoreContainer()
        let router2 = Self.makeRouter(
            id: router1.id, container: container2, cacheDir: cacheDir, recordingsDir: recordingsDir)
        let profile2 = try await router2.resolve(profile: Self.profile, reporting: ResolutionProgress())

        let restored = try await profile2.standard.restoreSessionTree(root: root.id)

        #expect(container2.threadedToolsByCall.first?.isEmpty == true)
        let pending = await restored.root.outbox.pending()
        #expect(pending.events.isEmpty)
        #expect(pending.prompts.isEmpty)
    }

    // MARK: - Forking a restored session still works with the threaded originals

    @Test("forking a restored session builds its child's tools from the restore call's own originals, fork-then-connect composed")
    @MainActor
    func forkOfRestoredSessionUsesOriginalsForForkThenConnect() async throws {
        let cacheDir = Self.makeTempDir()
        let recordingsDir = Self.makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: cacheDir)
            try? FileManager.default.removeItem(at: recordingsDir)
        }

        let container1 = ToolCapturingRestoreContainer()
        let router1 = Self.makeRouter(container: container1, cacheDir: cacheDir, recordingsDir: recordingsDir)
        let profile1 = try await router1.resolve(profile: Self.profile, reporting: ResolutionProgress())
        let root = profile1.standard.makeSession()
        _ = try await root.respond(to: "hello")

        let container2 = ToolCapturingRestoreContainer()
        let router2 = Self.makeRouter(
            id: router1.id, container: container2, cacheDir: cacheDir, recordingsDir: recordingsDir)
        let profile2 = try await router2.resolve(profile: Self.profile, reporting: ResolutionProgress())

        let emitter = FakeEmittingTool()
        let restored = try await profile2.standard.restoreSessionTree(root: root.id, tools: [emitter])
        let child = try await restored.root.fork(workingDirectory: nil)

        guard let childActor = child as? RoutedSessionActor,
            let childInstance = childActor.tools.first as? FakeEmittingTool
        else {
            Issue.record("expected the fork of a restored session to expose its own instanced FakeEmittingTool")
            return
        }

        await childInstance.postEvent(Self.event(detail: "from-fork-of-restored"))
        let childPending = await child.outbox.pending()
        #expect(childPending.events.map(\.event.detail) == ["from-fork-of-restored"])

        // The restored root's own outbox is untouched by the fork's event.
        let rootPending = await restored.root.outbox.pending()
        #expect(rootPending.events.isEmpty)
    }
}
