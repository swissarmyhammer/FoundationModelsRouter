import Foundation
import FoundationModels
import FoundationModelsRouterTestSupport
import Testing

@testable import FoundationModelsExtras
@testable import FoundationModelsRouter

/// Exercises task jkdae4b: threading `[any FoundationModels.Tool]` through
/// ``RoutedModel/restoreSessionTree(root:recordingRoot:instructions:tools:toolOutputProtection:isNoOpToolCall:userPresence:hookSessionKey:)``
/// — the seam that used to hardcode `tools: []` through
/// ``LoadedLLMContainer/makeSession(transcript:)``, leaving a restored
/// session tree with no live tool-calling at all.
///
/// Mirrors `SessionOutboxToolWiringTests`'s stub-based approach (no MLX, no
/// network, no GPU): a container that records the exact tool list threaded to
/// its `makeSession(transcript:tools:)` construction seam, so a test can
/// assert both that the caller's `tools:` argument reaches the container/
/// backend boundary for every restored node, and that each node gets its own
/// per-node mount wrapper — whose ambient ``ToolContext`` posts to that
/// node's own outbox — rather than sharing one event route tree-wide. Real
/// `LanguageModelSession(tools:)` wiring for a restored
/// transcript lives in the live ``MLXFoundationModelsContainer``
/// (`Resolution/LiveModelLoader.swift`), exercised end to end only by the
/// gated integration suite.
@Suite("restoreSessionTree(root:tools:): tools threaded to every restored node")
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
    /// ``RoutedModel/restoreSessionTree(root:recordingRoot:instructions:tools:toolOutputProtection:isNoOpToolCall:userPresence:hookSessionKey:)``
    /// threads its own per-node instanced tool list through — plus every
    /// backend it has vended, keyed by call order, so a test can inspect each
    /// restored node's own threaded list rather than only the last one.
    ///
    /// `@unchecked Sendable` is safe here without synchronization:
    /// `threadedToolsByCall` and `backendsByCall` are appended to only
    /// synchronously inside `makeSession(transcript:tools:)` — called from
    /// the `restoreSessionTree` call a `@MainActor` test awaits — and read
    /// only after that call returns to the same test method, so no two
    /// tasks ever touch the mutable state concurrently.
    private final class ToolCapturingRestoreContainer: LoadedLLMContainer, @unchecked Sendable {
        /// The scripted counter of this container: one token per `Character`.
        let tokenCounter: any TokenCounter = CharacterTokenCounter()

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
    /// - Parameters:
    ///   - id: The router id to construct with — pass the first router's
    ///     `id` to simulate a fresh process continuing the same recording
    ///     root.
    ///   - pool: The resident-model pool. Defaults to a fresh pool, so
    ///     parallel suites never share residents.
    private static func makeRouter(
        id: ULID = .generate(),
        container: any LoadedLLMContainer,
        cacheDir: URL,
        recordingsDir: URL,
        pool: ModelPool = ModelPool()
    ) -> Router {
        Router(
            id: id,
            cacheDir: cacheDir,
            recordingsDir: recordingsDir,
            recorder: JSONLRecorder(directory: recordingsDir),
            probe: StubProbe(chip: "Apple Test", totalRAM: 64 << 30, recommendedMaxWorkingSetSize: 48 << 30),
            metadataSource: StubMetadataSource(raw: rawMetadata),
            loader: StubModelLoader(container: container, dimension: stubDimension),
            pool: pool
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
        defer { await root.close() }
        _ = try await root.respond(to: "hello")

        let container2 = ToolCapturingRestoreContainer()
        let router2 = Self.makeRouter(
            id: router1.id, container: container2, cacheDir: cacheDir, recordingsDir: recordingsDir)
        let profile2 = try await router2.resolve(profile: Self.profile, reporting: ResolutionProgress())

        let emitter = AmbientEventPostingTool()
        let plain = PlainTool()
        let restored = try await profile2.standard.restoreSessionTree(root: root.id, tools: [emitter, plain])
        defer { await restored.root.close() }

        #expect(container2.threadedToolsByCall.count == 1)
        let threaded = try #require(container2.threadedToolsByCall.first)
        #expect(threaded.count == 2)
        // Every String-output tool arrives wrapped in the mount layer;
        // the shape assertion peels it to reach the threaded originals.
        let innerTools = threaded.compactMap(mountWrapped)
        #expect(innerTools.contains { $0 is AmbientEventPostingTool })
        #expect(innerTools.contains { $0 is PlainTool })
    }

    @Test("the container receives the original tool wrapped in the restored root's own mount layer")
    @MainActor
    func restoredRootWrapsTheOriginalToolInItsOwnMountLayer() async throws {
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
        defer { await root.close() }
        _ = try await root.respond(to: "hello")

        let container2 = ToolCapturingRestoreContainer()
        let router2 = Self.makeRouter(
            id: router1.id, container: container2, cacheDir: cacheDir, recordingsDir: recordingsDir)
        let profile2 = try await router2.resolve(profile: Self.profile, reporting: ResolutionProgress())

        let emitter = AmbientEventPostingTool()
        let restored = try await profile2.standard.restoreSessionTree(root: root.id, tools: [emitter])
        defer { await restored.root.close() }

        // No per-tool copy step exists: the container receives the caller's
        // original instance inside the restored root's own mount
        // wrapper, and calling that wrapper — the tool the model would
        // actually call — routes the ambient-context event to the restored
        // root's own outbox.
        guard
            let threadedMounted = failureDeliveryPeeled(container2.threadedToolsByCall.first?.first)
                as? RunToCompletionRunner<AmbientToolArguments>
        else {
            Issue.record("expected the container to receive a RunToCompletionRunner over the ambient fixture")
            return
        }
        #expect(mountWrapped(threadedMounted) as? AmbientEventPostingTool === emitter)

        _ = try await threadedMounted.call(arguments: AmbientToolArguments(value: "threaded-to-restored-backend"))
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
        defer { await root.close() }
        _ = try await root.respond(to: "hello")

        let container2 = ToolCapturingRestoreContainer()
        let router2 = Self.makeRouter(
            id: router1.id, container: container2, cacheDir: cacheDir, recordingsDir: recordingsDir)
        let profile2 = try await router2.resolve(profile: Self.profile, reporting: ResolutionProgress())

        let emitter = AmbientNonStringOutputTool()
        let restored = try await profile2.standard.restoreSessionTree(root: root.id, tools: [emitter])
        defer { await restored.root.close() }

        // The container receives the caller's original instance inside the
        // restored root's own binding-only wrapper — the restore-site
        // counterpart of the root site's non-String composition —
        // and calling that wrapper routes the ambient event to the
        // restored root's own outbox under the tool's own identity and a
        // fresh per-call correlationID.
        guard
            let threadedBound = failureDeliveryPeeled(container2.threadedToolsByCall.first?.first)
                as? ContextBindingTool<AmbientToolArguments, NonStringToolOutput>
        else {
            Issue.record("expected the container to receive a ContextBindingTool over the non-String fixture")
            return
        }
        #expect(mountWrapped(threadedBound) as? AmbientNonStringOutputTool === emitter)

        let output = try await threadedBound.call(
            arguments: AmbientToolArguments(value: "threaded-to-restored-backend"))
        let events = await restored.root.outbox.pending().events.map(\.event)
        #expect(events.map(\.detail) == ["threaded-to-restored-backend"])
        #expect(events.map(\.tool) == [emitter.name])
        #expect(events.map(\.op) == [emitter.name])
        #expect(events.map(\.correlationID) == [output.text])
        #expect(output.text != "unbound")
    }

    // MARK: - A recorded fork tree: each node gets its own wiring

    /// Records a root session that answers once, and a recorded fork of it
    /// that answers once (``RecordedForkFixtures``), through a router over
    /// `container`. Both sessions close before this returns.
    ///
    /// - Parameters:
    ///   - container: The container of the recording router.
    ///   - cacheDir: The disposable cache directory.
    ///   - recordingsDir: The durable recordings root.
    /// - Returns: The id of the recording router, the id of the root and the
    ///   id of the fork.
    /// - Throws: What the resolve, an answer or the write of the fork throws.
    private static func recordRootWithFork(
        container: any LoadedLLMContainer, cacheDir: URL, recordingsDir: URL
    ) async throws -> (routerId: ULID, rootId: ULID, forkId: ULID) {
        let router = makeRouter(container: container, cacheDir: cacheDir, recordingsDir: recordingsDir)
        let profile = try await router.resolve(profile: Self.profile, reporting: ResolutionProgress())
        let root = profile.standard.makeSession()
        let donor = profile.standard.makeSession()
        do {
            _ = try await root.respond(to: "hello")
            _ = try await donor.respond(to: "fork answer")
        } catch {
            await donor.close()
            await root.close()
            throw error
        }
        await donor.close()
        await root.close()
        let cut = try RecordedForkFixtures.cut(
            atEndOf: root.id,
            under: RouterTestFixtures.routerDirectory(routerId: router.id, recordingsDir: recordingsDir))
        try RecordedForkFixtures.nest(donor: donor.recordingDirectory, under: root.recordingDirectory, cut: cut)
        return (router.id, root.id, donor.id)
    }

    /// The production change that makes this test fail: a restore that
    /// shares one outbox or one mount wrapper across the nodes of a tree.
    @Test("each restored node of a recorded fork tree gets its own fresh outbox with its own mount wrapper")
    @MainActor
    func eachRestoredNodeGetsItsOwnOutboxAndMountWrapper() async throws {
        let cacheDir = Self.makeTempDir()
        let recordingsDir = Self.makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: cacheDir)
            try? FileManager.default.removeItem(at: recordingsDir)
        }
        let recorded = try await Self.recordRootWithFork(
            container: ToolCapturingRestoreContainer(), cacheDir: cacheDir, recordingsDir: recordingsDir)

        let container2 = ToolCapturingRestoreContainer()
        let router2 = Self.makeRouter(
            id: recorded.routerId, container: container2, cacheDir: cacheDir, recordingsDir: recordingsDir)
        let profile2 = try await router2.resolve(profile: Self.profile, reporting: ResolutionProgress())
        let emitter = AmbientEventPostingTool()
        let restored = try await profile2.standard.restoreSessionTree(root: recorded.rootId, tools: [emitter])
        defer { await SessionFixtureLifecycle.close(restored) }
        let restoredFork = try #require(restored.session(recorded.forkId))

        #expect(restored.root.outbox !== restoredFork.outbox)
        // The restore walks the root first, then its fork.
        try #require(container2.threadedToolsByCall.count == 2)
        let rootMounted = try #require(
            failureDeliveryPeeled(container2.threadedToolsByCall[0].first) as? RunToCompletionRunner<AmbientToolArguments>)
        let forkMounted = try #require(
            failureDeliveryPeeled(container2.threadedToolsByCall[1].first) as? RunToCompletionRunner<AmbientToolArguments>)
        // Both nodes share the one original instance of the caller. The
        // isolation is the own mount wrapper of each node, whose ambient
        // context posts to the own outbox of that node.
        #expect(mountWrapped(rootMounted) as? AmbientEventPostingTool === emitter)
        #expect(mountWrapped(forkMounted) as? AmbientEventPostingTool === emitter)

        _ = try await rootMounted.call(arguments: AmbientToolArguments(value: "from-root"))
        _ = try await forkMounted.call(arguments: AmbientToolArguments(value: "from-fork"))

        #expect(await restored.root.outbox.pending().events.map(\.event.detail) == ["from-root"])
        #expect(await restoredFork.outbox.pending().events.map(\.event.detail) == ["from-fork"])
    }

    /// The production change that makes this test fail: a restore that
    /// shares one binding wrapper across the nodes of a tree, or one token
    /// across their calls.
    @Test(
        "each restored node of a recorded fork tree gets its own ContextBindingTool for a non-String-output tool, posting to its own outbox under its own call's correlationID"
    )
    @MainActor
    func eachRestoredNodeGetsItsOwnOutboxAndBindingWrapperForNonStringOutput() async throws {
        let cacheDir = Self.makeTempDir()
        let recordingsDir = Self.makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: cacheDir)
            try? FileManager.default.removeItem(at: recordingsDir)
        }
        let recorded = try await Self.recordRootWithFork(
            container: ToolCapturingRestoreContainer(), cacheDir: cacheDir, recordingsDir: recordingsDir)

        let container2 = ToolCapturingRestoreContainer()
        let router2 = Self.makeRouter(
            id: recorded.routerId, container: container2, cacheDir: cacheDir, recordingsDir: recordingsDir)
        let profile2 = try await router2.resolve(profile: Self.profile, reporting: ResolutionProgress())
        let emitter = AmbientNonStringOutputTool()
        let restored = try await profile2.standard.restoreSessionTree(root: recorded.rootId, tools: [emitter])
        defer { await SessionFixtureLifecycle.close(restored) }
        let restoredFork = try #require(restored.session(recorded.forkId))

        #expect(restored.root.outbox !== restoredFork.outbox)
        try #require(container2.threadedToolsByCall.count == 2)
        let rootBound = try #require(
            failureDeliveryPeeled(container2.threadedToolsByCall[0].first)
                as? ContextBindingTool<AmbientToolArguments, NonStringToolOutput>)
        let forkBound = try #require(
            failureDeliveryPeeled(container2.threadedToolsByCall[1].first)
                as? ContextBindingTool<AmbientToolArguments, NonStringToolOutput>)
        #expect(mountWrapped(rootBound) as? AmbientNonStringOutputTool === emitter)
        #expect(mountWrapped(forkBound) as? AmbientNonStringOutputTool === emitter)

        let rootOutput = try await rootBound.call(arguments: AmbientToolArguments(value: "from-root"))
        let forkOutput = try await forkBound.call(arguments: AmbientToolArguments(value: "from-fork"))

        let rootEvents = await restored.root.outbox.pending().events.map(\.event)
        let forkEvents = await restoredFork.outbox.pending().events.map(\.event)
        #expect(rootEvents.map(\.detail) == ["from-root"])
        #expect(forkEvents.map(\.detail) == ["from-fork"])
        #expect(rootEvents.map(\.tool) == [emitter.name])
        #expect(forkEvents.map(\.tool) == [emitter.name])
        // The event of each node holds the new token of its own call as its
        // correlationID, never the token of the other node.
        #expect(rootEvents.map(\.correlationID) == [rootOutput.text])
        #expect(forkEvents.map(\.correlationID) == [forkOutput.text])
        #expect(rootOutput.text != forkOutput.text)
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
        defer { await root.close() }
        _ = try await root.respond(to: "hello")

        let container2 = ToolCapturingRestoreContainer()
        let router2 = Self.makeRouter(
            id: router1.id, container: container2, cacheDir: cacheDir, recordingsDir: recordingsDir)
        let profile2 = try await router2.resolve(profile: Self.profile, reporting: ResolutionProgress())

        let restored = try await profile2.standard.restoreSessionTree(root: root.id)
        defer { await restored.root.close() }

        #expect(container2.threadedToolsByCall.first?.isEmpty == true)
        let pending = await restored.root.outbox.pending()
        #expect(pending.events.isEmpty)
        #expect(restored.root.outbox.queue.pending.isEmpty)
    }

    // MARK: - Mount layer: restore's own chain order (task ^k4nygqa)

    @Test("restore composes mount only: mount layer outermost, no capping; the original tool innermost")
    @MainActor
    func restoreComposesMountOnly() async throws {
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
        defer { await root.close() }
        _ = try await root.respond(to: "hello")

        let container2 = ToolCapturingRestoreContainer()
        let router2 = Self.makeRouter(
            id: router1.id, container: container2, cacheDir: cacheDir, recordingsDir: recordingsDir)
        let profile2 = try await router2.resolve(profile: Self.profile, reporting: ResolutionProgress())

        let emitter = AmbientEventPostingTool()
        let restored = try await profile2.standard.restoreSessionTree(root: root.id, tools: [emitter])
        defer { await restored.root.close() }

        let threaded = try #require(failureDeliveryPeeled(container2.threadedToolsByCall.first?.first))
        // Restore applies no capping — deliberately: no budget travels
        // through restoration, and the pending envelope is tiny.
        #expect(!(threaded is TokenCappingTool<AmbientToolArguments>))
        guard let mounting = threaded as? RunToCompletionRunner<AmbientToolArguments>,
            let inner = mounting.wrapped as? AmbientEventPostingTool
        else {
            Issue.record("expected mount(tool) at the restore container boundary")
            return
        }
        #expect(inner === emitter)

        // Calling the composed wrapper routes the ambient-context event to
        // the restored root's own outbox.
        _ = try await mounting.call(arguments: AmbientToolArguments(value: "restore-chain-inner"))
        let pending = await restored.root.outbox.pending()
        #expect(pending.events.map(\.event.detail) == ["restore-chain-inner"])
    }

    @Test(
        "restore composes bind only for a non-String-output tool: no capping; the original tool innermost"
    )
    @MainActor
    func restoreComposesBindOnlyForNonStringOutput() async throws {
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
        defer { await root.close() }
        _ = try await root.respond(to: "hello")

        let container2 = ToolCapturingRestoreContainer()
        let router2 = Self.makeRouter(
            id: router1.id, container: container2, cacheDir: cacheDir, recordingsDir: recordingsDir)
        let profile2 = try await router2.resolve(profile: Self.profile, reporting: ResolutionProgress())

        let emitter = AmbientNonStringOutputTool()
        let restored = try await profile2.standard.restoreSessionTree(root: root.id, tools: [emitter])
        defer { await restored.root.close() }

        let threaded = try #require(failureDeliveryPeeled(container2.threadedToolsByCall.first?.first))
        // Restore applies no capping — no budget travels through
        // restoration, and capping is String-only anyway — so the chain is
        // bind(tool), consistent with the makeSession site's non-String
        // composition.
        // The no-cap check below is type-guaranteed for a non-String
        // output (``TokenCappingTool`` wraps only `Tool<Arguments, String>`)
        // — it documents the shape; the load-bearing chain proof is
        // `wrapped` being the original instance directly.
        #expect(!(threaded is TokenCappingTool<AmbientToolArguments>))
        guard
            let bound = threaded as? ContextBindingTool<AmbientToolArguments, NonStringToolOutput>,
            let inner = bound.wrapped as? AmbientNonStringOutputTool
        else {
            Issue.record("expected bind(tool) at the restore container boundary")
            return
        }
        #expect(inner === emitter)

        // Calling the composed wrapper routes the ambient-context event to
        // the restored root's own outbox.
        _ = try await bound.call(arguments: AmbientToolArguments(value: "restore-bind-inner"))
        let pending = await restored.root.outbox.pending()
        #expect(pending.events.map(\.event.detail) == ["restore-bind-inner"])
    }
}
