import Foundation
import FoundationModels
import Testing

@testable import FoundationModelsRouter

/// Exercises task s61g2vb's per-session tool composition:
/// ``RoutedModel/makeSession(instructions:workingDirectory:tools:)`` wrapping
/// every tool in the session's own ``ElevatingTool`` layer — whose ambient
/// ``ToolContext`` posts the tool's events to the session's own
/// ``RoutedSession/outbox``, with **no explicit wiring call anywhere** in
/// these tests — and ``RoutedSessionActor/fork(workingDirectory:)``'s
/// fork-then-elevate composition (``ForkableTool/forked()`` then the child's
/// own elevation layer) building the child's tool list from the parent's
/// true originals.
///
/// Everything runs against stubs — no MLX, no network, no GPU. Real
/// `LanguageModelSession(tools:)` wiring lives in the live
/// ``MLXFoundationModelsContainer``/``MLXFoundationModelsSessionBackend``
/// (`Sources/FoundationModelsRouter/Resolution/LiveModelLoader.swift`),
/// exercised end to end only by the gated integration suite.
@Suite("makeSession(tools:): per-session composition + fork-then-elevate")
struct SessionOutboxToolWiringTests {
    // MARK: - Test tools

    @Generable
    struct FakeToolArguments {
        let value: String
    }

    /// A plain `Tool` with no `ForkableTool` conformance and no ambient
    /// posting at all — proves a mixed tool list works: this one just passes
    /// through into its own elevation wrapper untouched, both at
    /// construction and at fork.
    private struct PlainTool: Tool {
        let name = "plain"
        let description = "a tool with no event-emitting or forking capability"

        func call(arguments: FakeToolArguments) async throws -> String {
            "plain: \(arguments.value)"
        }
    }

    /// A manually opened gate a fixture tool blocks on until the test lets
    /// it finish (mirrors ``ElevatingToolTests``'s own gate).
    private actor ToolGate {
        private var isOpen = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func open() {
            isOpen = true
            for waiter in waiters {
                waiter.resume()
            }
            waiters.removeAll()
        }

        func waitUntilOpened() async {
            guard !isOpen else { return }
            await withCheckedContinuation { waiters.append($0) }
        }
    }

    /// Blocks on a ``ToolGate`` and supplies a per-call `waitSeconds` of `0`
    /// through ``ElevationParameterProviding``, so the composition-site
    /// ``ElevatingTool`` detaches it immediately — keeping the
    /// pending-envelope tests fast without touching the wrap-time
    /// ``ElevationConfiguration/defaultWaitSeconds``.
    private struct GatedZeroWaitTool: Tool, ElevationParameterProviding {
        let name = "gated-zero-wait"
        let description = "test-only slow tool that detaches immediately"
        let gate: ToolGate

        func call(arguments: FakeToolArguments) async throws -> String {
            await gate.waitUntilOpened()
            return "gated: \(arguments.value)"
        }

        func elevationClocks(
            from arguments: GeneratedContent
        ) -> (waitSeconds: TimeInterval?, timeout: TimeInterval?) {
            (0, nil)
        }
    }

    // MARK: - Stub container capturing the threaded tool list

    /// A ``LoadedLLMContainer`` that records the `tools` it was handed at
    /// session-construction time, so a test can assert the exact list
    /// ``RoutedModel/makeSession(instructions:workingDirectory:tools:)`` passed
    /// through reached the container/backend-construction boundary — the seam
    /// the live container threads into `LanguageModelSession(model:tools:instructions:)`.
    /// `@unchecked Sendable` invariant: `lastTools` is written once, synchronously,
    /// inside `makeSession(instructions:tools:)` — itself called synchronously
    /// (no `await` between call and the write) from `RoutedModel.makeSession`,
    /// which is not actor-isolated and so never hops off the calling thread. Every
    /// test that reads `lastTools` does so from the same `@MainActor` test method
    /// that made the (synchronous) `makeSession(tools:)` call, after it returns —
    /// so the write and every read happen on the same thread, never concurrently.
    /// No lock is needed for a field that is never actually accessed from more
    /// than one thread.
    private final class ToolCapturingLLMContainer: LoadedLLMContainer, @unchecked Sendable {
        private(set) var lastTools: [any Tool] = []

        /// The ``StubSessionBackend`` most recently vended by
        /// `makeSession(instructions:tools:)`, so a test can hold a reference
        /// to the *root* session's own backend and, after forking, inspect
        /// what ``RoutedSessionActor/fork(workingDirectory:)`` passed to its
        /// `makeFork(tools:)` (see ``StubSessionBackend/lastForkTools``) —
        /// without needing any test-only accessor onto the private `backend`
        /// a `RoutedSession`/`RoutedSessionActor` holds.
        private(set) var lastBackend: StubSessionBackend?

        func makeSession(instructions: String?) -> any LanguageModelSessionBackend {
            let backend = StubSessionBackend()
            lastBackend = backend
            return backend
        }

        func makeSession(instructions: String?, tools: [any Tool]) -> any LanguageModelSessionBackend {
            lastTools = tools
            let backend = StubSessionBackend()
            lastBackend = backend
            return backend
        }

        func makeSession(transcript: Transcript) -> any LanguageModelSessionBackend {
            StubSessionBackend(entries: Array(transcript))
        }
    }

    /// A backend that invokes the session's first composed tool from inside
    /// `respond` — standing in for the SDK runtime invoking a tool
    /// mid-generation, so a test can cancel the turn while that tool call
    /// is in flight.
    ///
    /// `@unchecked Sendable` on the same terms as ``StubSessionBackend``:
    /// the owning session drives one backend method at a time, and tests
    /// read the captures only after the driving turn settled.
    private final class ToolInvokingBackend: LanguageModelSessionBackend, @unchecked Sendable {
        private let inner = StubSessionBackend()

        /// The composed tool list this backend was constructed with.
        private let tools: [any Tool]

        /// Flips just before the first composed tool is invoked, so a test
        /// can wait for the call to be in flight before cancelling.
        private(set) var toolCallStarted = false

        /// Every rendered output the invoked tool returned, in call order.
        private(set) var renderedToolOutputs: [String] = []

        init(tools: [any Tool]) {
            self.tools = tools
        }

        func respond(to prompt: String, maxTokens: Int?) async throws -> String {
            if let elevated = tools.first as? ElevatingTool<FakeToolArguments> {
                toolCallStarted = true
                let rendered = try await elevated.call(arguments: FakeToolArguments(value: prompt))
                renderedToolOutputs.append(rendered)
            }
            return try await inner.respond(to: prompt, maxTokens: maxTokens)
        }

        func streamResponse(to prompt: String, maxTokens: Int?) -> AsyncThrowingStream<String, Error> {
            inner.streamResponse(to: prompt, maxTokens: maxTokens)
        }

        func respond(to prompt: String, following grammar: Grammar, maxTokens: Int?) async throws -> String {
            try await inner.respond(to: prompt, following: grammar, maxTokens: maxTokens)
        }

        func makeFork() -> any LanguageModelSessionBackend {
            inner.makeFork()
        }

        func makeFork(tools: [any Tool]) -> any LanguageModelSessionBackend {
            inner.makeFork(tools: tools)
        }

        func replacingTranscript(_ transcript: Transcript) -> any LanguageModelSessionBackend {
            inner.replacingTranscript(transcript)
        }

        func transcriptEntries() -> [Transcript.Entry] {
            inner.transcriptEntries()
        }

        func usageTokenCounts() -> (input: Int, output: Int)? {
            inner.usageTokenCounts()
        }
    }

    /// Vends one retained ``ToolInvokingBackend`` per session, handing it
    /// the composed tool list makeSession threaded through.
    /// `@unchecked Sendable` invariant: `lastBackend` is written once,
    /// synchronously, inside `makeSession(instructions:tools:)` — itself
    /// called synchronously from `RoutedModel.makeSession` on the vending
    /// thread — and read only by the `@MainActor` test method after that
    /// vend returns, so the write and every read happen on the same
    /// thread, never concurrently (the same invariant
    /// ``ToolCapturingLLMContainer`` documents).
    private final class ToolInvokingLLMContainer: LoadedLLMContainer, @unchecked Sendable {
        private(set) var lastBackend: ToolInvokingBackend?

        func makeSession(instructions: String?) -> any LanguageModelSessionBackend {
            makeSession(instructions: instructions, tools: [])
        }

        func makeSession(instructions: String?, tools: [any Tool]) -> any LanguageModelSessionBackend {
            let backend = ToolInvokingBackend(tools: tools)
            lastBackend = backend
            return backend
        }

        func makeSession(transcript: Transcript) -> any LanguageModelSessionBackend {
            StubSessionBackend(entries: Array(transcript))
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

    /// The budget the capping-layer tests vend sessions with: an ample
    /// context limit and a deliberately tiny `toolOutputLimit`, so the cap
    /// layer is present and easy to trip.
    private static let budgetWithSmallToolOutputCap = TokenBudget(limit: 4096, toolOutputLimit: 5)

    /// How long a test waits for a parked run to settle before giving up —
    /// generous, because the gate is opened first and the wait only has to
    /// observe an already-finishing run.
    private static let mailboxWaitTimeoutSeconds: Double = 30

    private static func makeTempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SessionOutboxToolWiringTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func makeRouter(
        container: any LoadedLLMContainer, cacheDir: URL, recorder: any TranscriptRecorder = InMemoryRecorder()
    ) -> Router {
        Router(
            cacheDir: cacheDir,
            recorder: recorder,
            probe: StubProbe(chip: "Apple Test", totalRAM: 64 << 30, recommendedMaxWorkingSetSize: 48 << 30),
            metadataSource: StubMetadataSource(raw: rawMetadata),
            loader: StubModelLoader(container: container, dimension: stubDimension)
        )
    }

    // MARK: - Tools threaded to the container/backend boundary

    @Test("makeSession(tools:) threads the exact tool list shape to the container/backend construction boundary")
    @MainActor
    func toolsAreThreadedToContainer() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let container = ToolCapturingLLMContainer()
        let router = Self.makeRouter(container: container, cacheDir: dir)
        let profile = try await router.resolve(profile: Self.profile, reporting: ResolutionProgress())

        let emitter = AmbientEventPostingTool()
        let plain = PlainTool()
        _ = profile.standard.makeSession(tools: [emitter, plain])

        #expect(container.lastTools.count == 2)
        // Every String-output tool arrives wrapped in the elevation layer;
        // the shape assertion peels it to reach the threaded originals.
        let innerTools = container.lastTools.compactMap(elevationWrapped)
        #expect(innerTools.contains { $0 is AmbientEventPostingTool })
        #expect(innerTools.contains { $0 is PlainTool })
    }

    @Test("the container receives the original tool instance itself, wrapped in the session's own elevation layer")
    @MainActor
    func toolsThreadedToContainerWrapTheOriginalInstance() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let container = ToolCapturingLLMContainer()
        let router = Self.makeRouter(container: container, cacheDir: dir)
        let profile = try await router.resolve(profile: Self.profile, reporting: ResolutionProgress())

        let emitter = AmbientEventPostingTool()
        _ = profile.standard.makeSession(tools: [emitter])

        // No per-tool copy step exists anymore: the composition wraps the
        // very same instance the caller passed, and per-session event
        // routing lives entirely in the elevation wrapper's ambient
        // `ToolContext`.
        guard let inner = elevationWrapped(container.lastTools.first) as? AmbientEventPostingTool else {
            Issue.record("expected the container to receive an elevated AmbientEventPostingTool")
            return
        }
        #expect(inner === emitter)
    }

    // MARK: - Ambient event route: no explicit wiring call anywhere

    @Test("a tool's ambient-context post reaches the session's own outbox with no explicit wiring call anywhere")
    @MainActor
    func ambientContextRoutesToolEventsToSessionOutbox() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let container = ToolCapturingLLMContainer()
        let router = Self.makeRouter(container: container, cacheDir: dir)
        let profile = try await router.resolve(profile: Self.profile, reporting: ResolutionProgress())

        let emitter = AmbientEventPostingTool()
        let session = profile.standard.makeSession(tools: [emitter])

        // No wiring call appears anywhere in this test — the elevation
        // layer `makeSession(tools:)` composed binds the ambient
        // `ToolContext` (carrying this session's own outbox) around the
        // call, so the tool's post lands there.
        guard let elevated = container.lastTools.first as? ElevatingTool<AmbientToolArguments> else {
            Issue.record("expected the container to receive an ElevatingTool over the ambient fixture")
            return
        }
        _ = try await elevated.call(arguments: AmbientToolArguments(value: "auto-routed"))

        let pending = await session.outbox.pending()
        #expect(pending.events.map(\.event.detail) == ["auto-routed"])
    }

    @Test("a mixed tool list passes the plain tool through untouched")
    @MainActor
    func mixedToolListPassesPlainToolThroughUntouched() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let container = ToolCapturingLLMContainer()
        let router = Self.makeRouter(container: container, cacheDir: dir)
        let profile = try await router.resolve(profile: Self.profile, reporting: ResolutionProgress())

        let emitter = AmbientEventPostingTool()
        let plain = PlainTool()
        let session = profile.standard.makeSession(tools: [plain, emitter])

        let mixedInnerTools = container.lastTools.compactMap(elevationWrapped)
        guard
            let instancedPlain = mixedInnerTools.first(where: { $0 is PlainTool }) as? PlainTool,
            let ambientElevated = container.lastTools.first(where: {
                elevationWrapped($0) is AmbientEventPostingTool
            }) as? ElevatingTool<AmbientToolArguments>
        else {
            Issue.record("expected both an AmbientEventPostingTool and a PlainTool in the threaded list")
            return
        }

        // The ambient tool's events still route to this session's own
        // outbox despite sharing the list with a plain tool.
        _ = try await ambientElevated.call(arguments: AmbientToolArguments(value: "still works"))
        let pending = await session.outbox.pending()
        #expect(pending.events.map(\.event.detail) == ["still works"])

        let output = try await instancedPlain.call(arguments: FakeToolArguments(value: "x"))
        #expect(output == "plain: x")
    }

    @Test("a session with no tools has an empty, unconnected outbox")
    @MainActor
    func sessionWithNoToolsHasEmptyOutbox() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let container = ToolCapturingLLMContainer()
        let router = Self.makeRouter(container: container, cacheDir: dir)
        let profile = try await router.resolve(profile: Self.profile, reporting: ResolutionProgress())

        let session = profile.standard.makeSession()
        let pending = await session.outbox.pending()
        #expect(pending.events.isEmpty)
        #expect(pending.prompts.isEmpty)
    }

    // MARK: - Fork behavior: fresh-per-session outbox, fork-then-elevate tool composition

    @Test("a fork gets its own fresh SessionOutbox, distinct from its parent's")
    @MainActor
    func forkGetsFreshOutbox() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let container = ToolCapturingLLMContainer()
        let router = Self.makeRouter(container: container, cacheDir: dir)
        let profile = try await router.resolve(profile: Self.profile, reporting: ResolutionProgress())

        let session = profile.standard.makeSession()
        let child = try await session.fork(workingDirectory: nil)

        #expect(session.outbox !== child.outbox)
    }

    @Test(
        "after fork, the parent's composed tool posts to the parent's outbox and the fork's to the fork's — concurrently, over one shared underlying instance"
    )
    @MainActor
    func parentAndForkComposedToolsPostToTheirOwnOutboxesConcurrently() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let container = ToolCapturingLLMContainer()
        let router = Self.makeRouter(container: container, cacheDir: dir)
        let profile = try await router.resolve(profile: Self.profile, reporting: ResolutionProgress())

        let emitter = AmbientEventPostingTool()
        let session = profile.standard.makeSession(tools: [emitter])
        let child = try await session.fork(workingDirectory: nil)

        guard let parentActor = session as? RoutedSessionActor,
            let childActor = child as? RoutedSessionActor,
            let parentElevated = parentActor.tools.first as? ElevatingTool<AmbientToolArguments>,
            let childElevated = childActor.tools.first as? ElevatingTool<AmbientToolArguments>
        else {
            Issue.record("expected both the parent and the fork to expose their own ElevatingTool wrapper")
            return
        }
        // Both sessions share the very same underlying tool instance —
        // per-session isolation lives entirely in each session's own
        // elevation wrapper and the ambient context it binds per call.
        #expect(elevationWrapped(parentElevated) as? AmbientEventPostingTool === emitter)
        #expect(elevationWrapped(childElevated) as? AmbientEventPostingTool === emitter)

        // Concurrently call through each session's own composed wrapper —
        // event delivery must never migrate between the two outboxes.
        async let parentCall = parentElevated.call(arguments: AmbientToolArguments(value: "from-parent"))
        async let childCall = childElevated.call(arguments: AmbientToolArguments(value: "from-child"))
        _ = try await (parentCall, childCall)

        let parentPending = await session.outbox.pending()
        let childPending = await child.outbox.pending()
        #expect(parentPending.events.map(\.event.detail) == ["from-parent"])
        #expect(childPending.events.map(\.event.detail) == ["from-child"])
    }

    @Test("a composed tool captured before the fork keeps posting to the parent after forking")
    @MainActor
    func composedToolCapturedBeforeForkKeepsPostingToParentAfterFork() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let container = ToolCapturingLLMContainer()
        let router = Self.makeRouter(container: container, cacheDir: dir)
        let profile = try await router.resolve(profile: Self.profile, reporting: ResolutionProgress())

        let emitter = AmbientEventPostingTool()
        let session = profile.standard.makeSession(tools: [emitter])

        guard let parentActor = session as? RoutedSessionActor,
            let capturedElevated = parentActor.tools.first as? ElevatingTool<AmbientToolArguments>
        else {
            Issue.record("expected the parent session to expose its own ElevatingTool wrapper")
            return
        }

        // Stands in for a detached task that captured the composed tool at
        // operation start, before any fork happened.
        let child = try await session.fork(workingDirectory: nil)

        _ = try await capturedElevated.call(arguments: AmbientToolArguments(value: "captured-before-fork"))
        let parentPending = await session.outbox.pending()
        #expect(parentPending.events.map(\.event.detail) == ["captured-before-fork"])
        let childPending = await child.outbox.pending()
        #expect(childPending.events.isEmpty)
    }

    @Test(
        "at fork, a ForkableTool fixture's forked() is invoked and its result lands in the child's tool list; a plain tool passes through shared"
    )
    @MainActor
    func forkAppliesForkedAndSharesPlainToolsUnchanged() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let container = ToolCapturingLLMContainer()
        let router = Self.makeRouter(container: container, cacheDir: dir)
        let profile = try await router.resolve(profile: Self.profile, reporting: ResolutionProgress())

        let forkable = ForkableAmbientTool()
        let plain = PlainTool()
        let session = profile.standard.makeSession(tools: [forkable, plain])
        let child = try await session.fork(workingDirectory: nil)

        guard let parentActor = session as? RoutedSessionActor,
            let childActor = child as? RoutedSessionActor
        else {
            Issue.record("expected both sessions to be RoutedSessionActor")
            return
        }

        let parentInnerTools = parentActor.tools.compactMap(elevationWrapped)
        let childInnerTools = childActor.tools.compactMap(elevationWrapped)
        guard let parentForkable = parentInnerTools.first(where: { $0 is ForkableAmbientTool }) as? ForkableAmbientTool,
            let childForkable = childInnerTools.first(where: { $0 is ForkableAmbientTool }) as? ForkableAmbientTool
        else {
            Issue.record("expected both sessions to expose a ForkableAmbientTool")
            return
        }
        // The parent's own instance is untouched; the child's is the result
        // of `forked()` — a distinct, incremented-generation instance, not
        // the original passed to `makeSession(tools:)`.
        #expect(parentForkable.generation == 0)
        #expect(childForkable.generation == 1)
        #expect(childForkable !== forkable)

        // Calling the forked tool through the child's own elevation wrapper
        // posts to the child's own outbox.
        guard
            let childForkableElevated = childActor.tools.first(where: {
                elevationWrapped($0) is ForkableAmbientTool
            }) as? ElevatingTool<AmbientToolArguments>
        else {
            Issue.record("expected the child's tool list to hold the forked tool's own ElevatingTool")
            return
        }
        _ = try await childForkableElevated.call(arguments: AmbientToolArguments(value: "from-forked-tool"))
        let childPending = await child.outbox.pending()
        #expect(childPending.events.map(\.event.detail) == ["from-forked-tool"])

        // The plain tool has no `ForkableTool` conformance at all — it passes
        // through shared, unchanged, into the child's tool list.
        guard let childPlain = childInnerTools.first(where: { $0 is PlainTool }) as? PlainTool else {
            Issue.record("expected the plain tool to pass through into the child's tool list")
            return
        }
        let output = try await childPlain.call(arguments: FakeToolArguments(value: "y"))
        #expect(output == "plain: y")
    }

    @Test(
        "fork threads the child's fork-then-elevate composed tools into the backend's makeFork(tools:) — the model-facing session, not just the actor's own bookkeeping list"
    )
    @MainActor
    func forkThreadsChildToolsIntoBackendMakeFork() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let container = ToolCapturingLLMContainer()
        let router = Self.makeRouter(container: container, cacheDir: dir)
        let profile = try await router.resolve(profile: Self.profile, reporting: ResolutionProgress())

        let emitter = AmbientEventPostingTool()
        let session = profile.standard.makeSession(tools: [emitter])
        guard let rootBackend = container.lastBackend else {
            Issue.record("expected the container to have vended a StubSessionBackend for the root session")
            return
        }

        let child = try await session.fork(workingDirectory: nil)

        // `rootBackend` is the actual backend `RoutedSessionActor.fork()` calls
        // `makeFork(tools:)` on — asserting on `lastForkTools` here proves the
        // child's fork-then-elevate composed tool list is what actually
        // reached the model-facing backend construction seam, not just the
        // fork's own actor-level bookkeeping array.
        #expect(rootBackend.lastForkTools.count == 1)
        guard let forkedElevatedAtBackend = rootBackend.lastForkTools.first as? ElevatingTool<AmbientToolArguments>
        else {
            Issue.record("expected the backend's makeFork(tools:) to have received the child's ElevatingTool")
            return
        }
        #expect(elevationWrapped(forkedElevatedAtBackend) as? AmbientEventPostingTool === emitter)

        // Calling through the exact wrapper the backend received posts to
        // the child's own outbox — confirming it is genuinely the
        // child-composed wrapper, not a passthrough of the parent's.
        _ = try await forkedElevatedAtBackend.call(
            arguments: AmbientToolArguments(value: "from-backend-threaded-tool"))
        let childPending = await child.outbox.pending()
        #expect(childPending.events.map(\.event.detail) == ["from-backend-threaded-tool"])
        let parentPending = await session.outbox.pending()
        #expect(parentPending.events.isEmpty)
    }

    // MARK: - Elevation layer: per-site chain order (task ^k4nygqa)

    @Test("makeSession composes elevate → cap: capping outermost, elevation inside it, the original tool innermost")
    @MainActor
    func makeSessionComposesElevateCap() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let container = ToolCapturingLLMContainer()
        let router = Self.makeRouter(container: container, cacheDir: dir)
        let profile = try await router.resolve(profile: Self.profile, reporting: ResolutionProgress())

        let emitter = AmbientEventPostingTool()
        let session = profile.standard.makeSession(
            tools: [emitter],
            budget: Self.budgetWithSmallToolOutputCap
        )

        guard let capping = container.lastTools.first as? TokenCappingTool<AmbientToolArguments>,
            let elevating = capping.wrapped as? ElevatingTool<AmbientToolArguments>,
            let inner = elevating.wrapped as? AmbientEventPostingTool
        else {
            Issue.record("expected cap(elevate(tool)) at the container boundary")
            return
        }
        #expect(inner === emitter)

        // Calling through the full chain still routes the tool's
        // ambient-context event to this session's own outbox.
        _ = try await capping.call(arguments: AmbientToolArguments(value: "chain-inner"))
        let pending = await session.outbox.pending()
        #expect(pending.events.map(\.event.detail) == ["chain-inner"])
    }

    @Test("makeSession without a budget composes elevate only: elevation outermost, no capping layer")
    @MainActor
    func makeSessionWithoutBudgetComposesElevateOnly() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let container = ToolCapturingLLMContainer()
        let router = Self.makeRouter(container: container, cacheDir: dir)
        let profile = try await router.resolve(profile: Self.profile, reporting: ResolutionProgress())

        let emitter = AmbientEventPostingTool()
        let session = profile.standard.makeSession(tools: [emitter])

        #expect(!(container.lastTools.first is TokenCappingTool<AmbientToolArguments>))
        guard let elevating = container.lastTools.first as? ElevatingTool<AmbientToolArguments>,
            let inner = elevating.wrapped as? AmbientEventPostingTool
        else {
            Issue.record("expected elevate(tool) at the container boundary")
            return
        }
        #expect(inner === emitter)

        _ = try await elevating.call(arguments: AmbientToolArguments(value: "uncapped-chain-inner"))
        let pending = await session.outbox.pending()
        #expect(pending.events.map(\.event.detail) == ["uncapped-chain-inner"])
    }

    @Test("fork composes fork → elevate → cap: capping outermost, elevation inside, the forked instance innermost")
    @MainActor
    func forkComposesForkElevateCap() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let container = ToolCapturingLLMContainer()
        let router = Self.makeRouter(container: container, cacheDir: dir)
        let profile = try await router.resolve(profile: Self.profile, reporting: ResolutionProgress())

        let forkable = ForkableAmbientTool()
        let session = profile.standard.makeSession(
            tools: [forkable],
            budget: Self.budgetWithSmallToolOutputCap
        )
        let child = try await session.fork(workingDirectory: nil)

        guard let childActor = child as? RoutedSessionActor,
            let capping = childActor.tools.first as? TokenCappingTool<AmbientToolArguments>,
            let elevating = capping.wrapped as? ElevatingTool<AmbientToolArguments>,
            let forkedInner = elevating.wrapped as? ForkableAmbientTool
        else {
            Issue.record("expected cap(elevate(forked(tool))) in the fork's tool list")
            return
        }
        // `forked()` ran before the child's elevation wrapped it: the
        // innermost instance is the next generation.
        #expect(forkedInner.generation == 1)
        _ = try await capping.call(arguments: AmbientToolArguments(value: "fork-chain-inner"))
        let childPending = await child.outbox.pending()
        #expect(childPending.events.map(\.event.detail) == ["fork-chain-inner"])
    }

    @Test("fork without a budget composes fork → elevate: elevation outermost, no capping layer")
    @MainActor
    func forkWithoutBudgetComposesForkElevateOnly() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let container = ToolCapturingLLMContainer()
        let router = Self.makeRouter(container: container, cacheDir: dir)
        let profile = try await router.resolve(profile: Self.profile, reporting: ResolutionProgress())

        let forkable = ForkableAmbientTool()
        let session = profile.standard.makeSession(tools: [forkable])
        let child = try await session.fork(workingDirectory: nil)

        guard let childActor = child as? RoutedSessionActor else {
            Issue.record("expected the fork to be a RoutedSessionActor")
            return
        }
        #expect(!(childActor.tools.first is TokenCappingTool<AmbientToolArguments>))
        guard let elevating = childActor.tools.first as? ElevatingTool<AmbientToolArguments>,
            let forkedInner = elevating.wrapped as? ForkableAmbientTool
        else {
            Issue.record("expected elevate(forked(tool)) in the fork's tool list")
            return
        }
        // `forked()` ran before the child's elevation wrapped it: the
        // innermost instance is the next generation — the same fork →
        // elevate order as the with-budget case, just with no cap layer
        // anywhere in the chain.
        #expect(forkedInner.generation == 1)
        _ = try await elevating.call(arguments: AmbientToolArguments(value: "uncapped-fork-chain-inner"))
        let childPending = await child.outbox.pending()
        #expect(childPending.events.map(\.event.detail) == ["uncapped-fork-chain-inner"])
    }

    // MARK: - Elevation behavior through a session's composed tool list

    @Test(
        "a slow elevated tool returns the pending envelope, and its later .completed rides the next turn's preamble and lands as a durable OperationEventSegment"
    )
    @MainActor
    func elevatedSlowToolCompletionRidesNextTurn() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let container = ToolCapturingLLMContainer()
        let recorder = InMemoryRecorder()
        let router = Self.makeRouter(container: container, cacheDir: dir, recorder: recorder)
        let profile = try await router.resolve(profile: Self.profile, reporting: ResolutionProgress())

        let gate = ToolGate()
        let session = profile.standard.makeSession(tools: [GatedZeroWaitTool(gate: gate)])
        let backend = try #require(container.lastBackend)
        guard let elevated = container.lastTools.first as? ElevatingTool<FakeToolArguments> else {
            Issue.record("expected the composed tool list to hold an ElevatingTool")
            return
        }

        // The model-facing call detaches immediately (per-call waitSeconds
        // 0) and returns the pending envelope on the wire.
        let rendered = try await elevated.call(arguments: FakeToolArguments(value: "slow"))
        let envelope = try JSONDecoder().decode(PendingRunEnvelope.self, from: Data(rendered.utf8))
        #expect(envelope.pending)

        // Let the parked run finish; its synthesized `.completed` funnels
        // into this session's own outbox.
        await gate.open()
        _ = await session.mailbox.wait(completionToken: envelope.completionToken, seconds: Self.mailboxWaitTimeoutSeconds)
        var pendingEvents: [OperationEvent] = []
        for _ in 0..<600 {
            pendingEvents = await session.outbox.pending().events.map(\.event)
            if pendingEvents.contains(where: { $0.kind == .completed }) { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let completed = try #require(pendingEvents.first { $0.kind == .completed })
        #expect(completed.correlationID == envelope.completionToken)
        #expect(completed.detail == "gated: slow")

        // The next turn drains it: the composed prompt the backend receives
        // carries the preamble line, and the recorded `.prompt` entry
        // carries the same event as a durable OperationEventSegment.
        _ = try await session.respond(to: "follow-up")
        let expectedLine = OperationEventSegment.renderedLine(for: completed)
        let composed = try #require(backend.receivedPrompts.last)
        #expect(composed.contains(expectedLine))
        #expect(composed.hasSuffix("\n\nfollow-up"))

        let events = await recorder.events
        let promptEvent = try #require(events.last { $0.kind == .prompt })
        let journaled = (promptEvent.entry?.segments ?? []).compactMap { segment -> OperationEvent? in
            guard case .custom(_, let discriminator, let contentJSON, _) = segment,
                discriminator == OperationEventSegment.typeDiscriminator
            else { return nil }
            return try? JSONDecoder().decode(OperationEvent.self, from: Data(contentJSON.utf8))
        }
        #expect(journaled.contains { $0.kind == .completed && $0.correlationID == envelope.completionToken })
    }

    @Test("a fork's parked elevated run lives in the fork's own mailbox; the parent's mailbox is untouched")
    @MainActor
    func forkParkedRunLivesInForkMailbox() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let container = ToolCapturingLLMContainer()
        let router = Self.makeRouter(container: container, cacheDir: dir)
        let profile = try await router.resolve(profile: Self.profile, reporting: ResolutionProgress())

        let gate = ToolGate()
        let session = profile.standard.makeSession(tools: [GatedZeroWaitTool(gate: gate)])
        let child = try await session.fork(workingDirectory: nil)

        guard let childActor = child as? RoutedSessionActor,
            let childElevated = childActor.tools.first as? ElevatingTool<FakeToolArguments>
        else {
            Issue.record("expected the fork's composed tool list to hold an ElevatingTool")
            return
        }

        let rendered = try await childElevated.call(arguments: FakeToolArguments(value: "forked"))
        let envelope = try JSONDecoder().decode(PendingRunEnvelope.self, from: Data(rendered.utf8))
        #expect(envelope.pending)

        let childParked = await child.mailbox.status().map(\.completionToken)
        #expect(childParked == [envelope.completionToken])
        let parentParked = await session.mailbox.status()
        #expect(parentParked.isEmpty)

        // Settle the parked run so no detached work outlives the test.
        await gate.open()
        _ = await child.mailbox.wait(completionToken: envelope.completionToken, seconds: Self.mailboxWaitTimeoutSeconds)
    }

    @Test("a pending envelope survives the outer capping layer intact, even under a cap smaller than the envelope itself")
    @MainActor
    func pendingEnvelopeSurvivesCappingLayer() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let container = ToolCapturingLLMContainer()
        let router = Self.makeRouter(container: container, cacheDir: dir)
        let profile = try await router.resolve(profile: Self.profile, reporting: ResolutionProgress())

        let gate = ToolGate()
        // toolOutputLimit 5 is far below the envelope's own estimated size:
        // real tool output at this cap is truncated, but the envelope —
        // control-plane data whose completionToken the model must keep —
        // must pass through untouched.
        let session = profile.standard.makeSession(
            tools: [GatedZeroWaitTool(gate: gate)],
            budget: Self.budgetWithSmallToolOutputCap
        )

        guard let capping = container.lastTools.first as? TokenCappingTool<FakeToolArguments> else {
            Issue.record("expected the composed tool list to hold a TokenCappingTool outermost")
            return
        }
        let rendered = try await capping.call(arguments: FakeToolArguments(value: "capped-slow"))
        let envelope = try JSONDecoder().decode(PendingRunEnvelope.self, from: Data(rendered.utf8))
        #expect(envelope.pending)
        #expect(ULID(envelope.completionToken) != nil)

        // Settle the parked run so no detached work outlives the test.
        await gate.open()
        _ = await session.mailbox.wait(completionToken: envelope.completionToken, seconds: Self.mailboxWaitTimeoutSeconds)
    }

    @Test(
        "cancelling a turn detaches an in-flight elevated tool call: it parks in the session's mailbox and later settles normally, never dying with the turn"
    )
    @MainActor
    func cancellingATurnParksInFlightElevatedToolCall() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let container = ToolInvokingLLMContainer()
        let router = Self.makeRouter(container: container, cacheDir: dir)
        let profile = try await router.resolve(profile: Self.profile, reporting: ResolutionProgress())

        let gate = ToolGate()
        let session = profile.standard.makeSession(tools: [GatedZeroWaitTool(gate: gate)])
        let backend = try #require(container.lastBackend)

        // Drive a turn whose backend invokes the composed elevated tool,
        // then cancel the turn while that tool call is in flight. (The
        // per-call waitSeconds of 0 means the call detaches with or
        // without the cancel — what this pins is what cancellation does
        // NOT do: kill the parked run.)
        let turn = Task { try await session.respond(to: "cancel me") }
        for _ in 0..<600 {
            if backend.toolCallStarted { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(backend.toolCallStarted)
        await session.cancelCurrentTurn()
        _ = try? await turn.value

        // The tool call answered with the pending envelope, not a
        // CancellationError, and the run parked in this session's mailbox.
        let rendered = try #require(backend.renderedToolOutputs.first)
        let envelope = try JSONDecoder().decode(PendingRunEnvelope.self, from: Data(rendered.utf8))
        #expect(envelope.pending)
        let parked = await session.mailbox.status().map(\.completionToken)
        #expect(parked == [envelope.completionToken])

        // The parked run outlived the cancelled turn un-cancelled: opening
        // the gate lets it settle as a normal success.
        await gate.open()
        let settled = await session.mailbox.wait(completionToken: envelope.completionToken, seconds: Self.mailboxWaitTimeoutSeconds)
        guard case .settled(let terminal) = settled else {
            Issue.record("expected the parked run to settle after the gate opened, got \(settled)")
            return
        }
        #expect(terminal.outcome == .succeeded)
        #expect(terminal.detail == "gated: cancel me")
    }
}
