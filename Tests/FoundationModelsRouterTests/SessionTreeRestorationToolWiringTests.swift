import Foundation
import FoundationModels
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
/// per-node elevation wrapper — whose ambient ``ToolContext`` posts to that
/// node's own outbox — rather than sharing one event route tree-wide. Real
/// `LanguageModelSession(tools:)` wiring for a restored
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

    private struct PlainTool: Tool {
        let name = "plain"
        let description = "a tool with no event-emitting capability"

        func call(arguments: FakeToolArguments) async throws -> String {
            "plain: \(arguments.value)"
        }
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

        let emitter = AmbientEventPostingTool()
        let plain = PlainTool()
        _ = try await profile2.standard.restoreSessionTree(root: root.id, tools: [emitter, plain])

        #expect(container2.threadedToolsByCall.count == 1)
        let threaded = try #require(container2.threadedToolsByCall.first)
        #expect(threaded.count == 2)
        // Every String-output tool arrives wrapped in the elevation layer;
        // the shape assertion peels it to reach the threaded originals.
        let innerTools = threaded.compactMap(elevationWrapped)
        #expect(innerTools.contains { $0 is AmbientEventPostingTool })
        #expect(innerTools.contains { $0 is PlainTool })
    }

    @Test("the container receives the original tool wrapped in the restored root's own elevation layer")
    @MainActor
    func restoredRootWrapsTheOriginalToolInItsOwnElevationLayer() async throws {
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

        let emitter = AmbientEventPostingTool()
        let restored = try await profile2.standard.restoreSessionTree(root: root.id, tools: [emitter])

        // No per-tool copy step exists: the container receives the caller's
        // original instance inside the restored root's own elevation
        // wrapper, and calling that wrapper — the tool the model would
        // actually call — routes the ambient-context event to the restored
        // root's own outbox.
        guard
            let threadedElevated = container2.threadedToolsByCall.first?.first
                as? ElevatingTool<AmbientToolArguments>
        else {
            Issue.record("expected the container to receive an ElevatingTool over the ambient fixture")
            return
        }
        #expect(elevationWrapped(threadedElevated) as? AmbientEventPostingTool === emitter)

        _ = try await threadedElevated.call(arguments: AmbientToolArguments(value: "threaded-to-restored-backend"))
        let pending = await restored.root.outbox.pending()
        #expect(pending.events.map(\.event.detail) == ["threaded-to-restored-backend"])
    }

    @Test(
        "a non-String-output tool threaded to a restored root arrives in the node's own binding-only ContextBindingTool, posting to its outbox with its own identity"
    )
    @MainActor
    func restoredRootWrapsNonStringOutputToolInItsOwnBindingLayer() async throws {
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

        let emitter = AmbientNonStringOutputTool()
        let restored = try await profile2.standard.restoreSessionTree(root: root.id, tools: [emitter])

        // The container receives the caller's original instance inside the
        // restored root's own binding-only wrapper — the restore-site
        // counterpart of the root and fork sites' non-String composition —
        // and calling that wrapper routes the ambient event to the
        // restored root's own outbox under the tool's own identity and a
        // fresh per-call correlationID.
        guard
            let threadedBound = container2.threadedToolsByCall.first?.first
                as? ContextBindingTool<AmbientToolArguments, NonStringToolOutput>
        else {
            Issue.record("expected the container to receive a ContextBindingTool over the non-String fixture")
            return
        }
        #expect(elevationWrapped(threadedBound) as? AmbientNonStringOutputTool === emitter)

        let output = try await threadedBound.call(
            arguments: AmbientToolArguments(value: "threaded-to-restored-backend"))
        let events = await restored.root.outbox.pending().events.map(\.event)
        #expect(events.map(\.detail) == ["threaded-to-restored-backend"])
        #expect(events.map(\.tool) == [emitter.name])
        #expect(events.map(\.op) == [emitter.name])
        #expect(events.map(\.correlationID) == [output.text])
        #expect(output.text != "unbound")
    }

    @Test("each restored node in a tree gets its own fresh outbox with its own elevation wrapper — not shared tree-wide")
    @MainActor
    func eachRestoredNodeGetsItsOwnOutboxAndElevationWrapper() async throws {
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

        let emitter = AmbientEventPostingTool()
        let restored = try await profile2.standard.restoreSessionTree(root: root.id, tools: [emitter])
        let restoredFork = try #require(restored.children(of: root.id).first)

        #expect(restored.root.outbox !== restoredFork.outbox)

        guard
            let rootElevated = container2.threadedToolsByCall[0].first as? ElevatingTool<AmbientToolArguments>,
            let forkElevated = container2.threadedToolsByCall[1].first as? ElevatingTool<AmbientToolArguments>
        else {
            Issue.record("expected both restored nodes to receive their own ElevatingTool wrapper")
            return
        }
        // Both nodes share the caller's one original instance — the
        // per-node isolation is each node's own elevation wrapper, whose
        // ambient context posts to that node's own outbox.
        #expect(elevationWrapped(rootElevated) as? AmbientEventPostingTool === emitter)
        #expect(elevationWrapped(forkElevated) as? AmbientEventPostingTool === emitter)

        _ = try await rootElevated.call(arguments: AmbientToolArguments(value: "from-root"))
        _ = try await forkElevated.call(arguments: AmbientToolArguments(value: "from-fork"))

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

    @Test("forking a restored session builds its child's tools from the restore call's own originals, fork-then-elevate composed")
    @MainActor
    func forkOfRestoredSessionComposesItsOwnElevationLayerFromTheOriginals() async throws {
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

        let emitter = AmbientEventPostingTool()
        let restored = try await profile2.standard.restoreSessionTree(root: root.id, tools: [emitter])
        let child = try await restored.root.fork(workingDirectory: nil)

        guard let childActor = child as? RoutedSessionActor,
            let childElevated = childActor.tools.first as? ElevatingTool<AmbientToolArguments>
        else {
            Issue.record("expected the fork of a restored session to expose its own ElevatingTool wrapper")
            return
        }
        #expect(elevationWrapped(childElevated) as? AmbientEventPostingTool === emitter)

        _ = try await childElevated.call(arguments: AmbientToolArguments(value: "from-fork-of-restored"))
        let childPending = await child.outbox.pending()
        #expect(childPending.events.map(\.event.detail) == ["from-fork-of-restored"])

        // The restored root's own outbox is untouched by the fork's event.
        let rootPending = await restored.root.outbox.pending()
        #expect(rootPending.events.isEmpty)
    }

    // MARK: - Elevation layer: restore's own chain order (task ^k4nygqa)

    @Test("restore composes elevate only: elevation outermost, no fork, no capping; the original tool innermost")
    @MainActor
    func restoreComposesElevateOnly() async throws {
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

        let emitter = AmbientEventPostingTool()
        let restored = try await profile2.standard.restoreSessionTree(root: root.id, tools: [emitter])

        let threaded = try #require(container2.threadedToolsByCall.first?.first)
        // Restore applies no capping — deliberately: no budget travels
        // through restoration, and the pending envelope is tiny.
        #expect(!(threaded is TokenCappingTool<AmbientToolArguments>))
        guard let elevating = threaded as? ElevatingTool<AmbientToolArguments>,
            let inner = elevating.wrapped as? AmbientEventPostingTool
        else {
            Issue.record("expected elevate(tool) at the restore container boundary")
            return
        }
        #expect(inner === emitter)

        // Calling the composed wrapper routes the ambient-context event to
        // the restored root's own outbox.
        _ = try await elevating.call(arguments: AmbientToolArguments(value: "restore-chain-inner"))
        let pending = await restored.root.outbox.pending()
        #expect(pending.events.map(\.event.detail) == ["restore-chain-inner"])
    }
}
