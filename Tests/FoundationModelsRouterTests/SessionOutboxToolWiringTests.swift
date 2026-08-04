import Foundation
import FoundationModels
import Testing

@testable import FoundationModelsRouter

/// Exercises task s61g2vb's per-session tool capabilities:
/// ``RoutedModel/makeSession(instructions:workingDirectory:tools:)`` pure
/// per-session instancing (``EventEmittingTool/connecting(_:)``) with **no
/// explicit wiring call anywhere** in these tests, and
/// ``RoutedSessionActor/fork(workingDirectory:)``'s fork-then-connect
/// composition (``ForkableTool/forked()`` then ``EventEmittingTool/connecting(_:)``)
/// building the child's tool list from the parent's true originals.
///
/// Everything runs against stubs — no MLX, no network, no GPU. Real
/// `LanguageModelSession(tools:)` wiring lives in the live
/// ``MLXFoundationModelsContainer``/``MLXFoundationModelsSessionBackend``
/// (`Sources/FoundationModelsRouter/Resolution/LiveModelLoader.swift`),
/// exercised end to end only by the gated integration suite.
@Suite("makeSession(tools:): per-session instancing + fork-then-connect")
struct SessionOutboxToolWiringTests {
    // MARK: - Test tools

    @Generable
    struct FakeToolArguments {
        let value: String
    }

    /// A real `FoundationModels.Tool` that also conforms to `EventEmittingTool`
    /// via a pure `connecting(_:)` — a host discovers it by conformance cast
    /// and wires it during construction, mirroring how a real fused
    /// `OperationTool<Context: EventEmittingContext>` gets its conformance.
    /// `postEvent(_:)` is the test-only stand-in for what a real tool's
    /// `execute(in:)` would do: post through whichever sink this particular
    /// instance was instanced with (or into the void if none), never a
    /// mutable slot that could be reconnected later.
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

    /// A `Tool` that both emits and forks, so a host applies `forked()` first
    /// and `connecting(_:)` second — the composition order
    /// ``ForkableTool``'s doc comment pins. `generation` proves `forked()`
    /// is actually invoked (incremented on every fork) rather than the
    /// original being shared unchanged.
    /// `@unchecked Sendable`: `sink` is immutable (`let`), so concurrent reads
    /// are safe even if `OperationEventSink` does not conform to `Sendable`.
    private final class ForkableEmittingTool: Tool, EventEmittingTool, ForkableTool, @unchecked Sendable {
        let name = "forkable-emitter"
        let description = "test-only tool that forks into a new generation and can emit"
        let generation: Int

        private let sink: (any OperationEventSink)?

        init(generation: Int = 0, sink: (any OperationEventSink)? = nil) {
            self.generation = generation
            self.sink = sink
        }

        func connecting(_ sink: any OperationEventSink) -> any Tool {
            ForkableEmittingTool(generation: generation, sink: sink)
        }

        /// Derives a child session's instance, marking it with the next
        /// generation while sharing whatever sink the receiver had (fork
        /// runs before connect, per the composition order).
        func forked() -> any Tool {
            ForkableEmittingTool(generation: generation + 1, sink: sink)
        }

        func call(arguments: FakeToolArguments) async throws -> String {
            "handled: \(arguments.value)"
        }

        func postEvent(_ event: OperationEvent) async {
            await sink?.post(event)
        }
    }

    /// A plain `Tool` with no `EventEmittingTool`/`ForkableTool` conformance
    /// at all — proves a mixed tool list works: this one just passes through
    /// untouched, both at construction and at fork.
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

    /// Peels the elevation layer every composition site wraps around a
    /// String-output tool, returning the inner (connected) tool — or `nil`
    /// when `tool` is not the expected ``ElevatingTool``.
    private static func elevationWrapped(_ tool: (any Tool)?) -> (any Tool)? {
        (tool as? ElevatingTool<FakeToolArguments>)?.wrapped
    }

    private static func event(correlationID: String = "c1", detail: String = "done") -> OperationEvent {
        OperationEvent(tool: "fake-emitter", op: "run thing", correlationID: correlationID, kind: .completed, detail: detail)
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

    private static func makeTempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SessionOutboxToolWiringTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func makeRouter(container: any LoadedLLMContainer, cacheDir: URL) -> Router {
        Router(
            cacheDir: cacheDir,
            recorder: InMemoryRecorder(),
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

        let emitter = FakeEmittingTool()
        let plain = PlainTool()
        _ = profile.standard.makeSession(tools: [emitter, plain])

        #expect(container.lastTools.count == 2)
        // Every String-output tool arrives wrapped in the elevation layer;
        // the shape assertion peels it to reach the threaded originals.
        let innerTools = container.lastTools.compactMap(Self.elevationWrapped)
        #expect(innerTools.contains { $0 is FakeEmittingTool })
        #expect(innerTools.contains { $0 is PlainTool })
    }

    @Test("the container receives a distinct, sink-bound copy of an emitting tool — not the original instance")
    @MainActor
    func toolsThreadedToContainerAreDistinctSinkBoundCopies() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let container = ToolCapturingLLMContainer()
        let router = Self.makeRouter(container: container, cacheDir: dir)
        let profile = try await router.resolve(profile: Self.profile, reporting: ResolutionProgress())

        let emitter = FakeEmittingTool()
        let session = profile.standard.makeSession(tools: [emitter])

        guard let instancedEmitter = Self.elevationWrapped(container.lastTools.first) as? FakeEmittingTool else {
            Issue.record("expected the container to receive a FakeEmittingTool")
            return
        }
        #expect(instancedEmitter !== emitter)

        // Posting through the container-threaded copy — the one the model
        // would actually call — reaches this session's own outbox, proving
        // it really is the sink-bound instance, not a disconnected passthrough.
        await instancedEmitter.postEvent(Self.event(detail: "threaded-to-backend"))
        let pending = await session.outbox.pending()
        #expect(pending.events.map(\.event.detail) == ["threaded-to-backend"])

        // The original, never instanced, still posts into the void — the
        // outbox gains nothing further beyond the one event already posted
        // through the container-threaded copy above.
        await emitter.postEvent(Self.event(detail: "never reaches anything"))
        let pendingAfter = await session.outbox.pending()
        #expect(pendingAfter.events.map(\.event.detail) == ["threaded-to-backend"])
    }

    // MARK: - Auto-connect: no explicit wiring call anywhere

    @Test("a fake emitting tool passed in tools: delivers events with no explicit wiring call anywhere")
    @MainActor
    func emittingToolAutoConnectsToSessionOutbox() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let container = ToolCapturingLLMContainer()
        let router = Self.makeRouter(container: container, cacheDir: dir)
        let profile = try await router.resolve(profile: Self.profile, reporting: ResolutionProgress())

        let emitter = FakeEmittingTool()
        let session = profile.standard.makeSession(tools: [emitter])

        // No call to `connecting(...)` appears anywhere in this test —
        // `makeSession(tools:)` itself must have wired it during construction.
        guard let instancedEmitter = Self.elevationWrapped(container.lastTools.first) as? FakeEmittingTool else {
            Issue.record("expected the container to receive a FakeEmittingTool")
            return
        }
        await instancedEmitter.postEvent(Self.event(detail: "auto-connected"))

        let pending = await session.outbox.pending()
        #expect(pending.events.map(\.event.detail) == ["auto-connected"])
    }

    @Test("a mixed tool list passes the non-emitting tool through untouched")
    @MainActor
    func mixedToolListPassesPlainToolThroughUntouched() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let container = ToolCapturingLLMContainer()
        let router = Self.makeRouter(container: container, cacheDir: dir)
        let profile = try await router.resolve(profile: Self.profile, reporting: ResolutionProgress())

        let emitter = FakeEmittingTool()
        let plain = PlainTool()
        let session = profile.standard.makeSession(tools: [plain, emitter])

        let mixedInnerTools = container.lastTools.compactMap(Self.elevationWrapped)
        guard let instancedEmitter = mixedInnerTools.first(where: { $0 is FakeEmittingTool }) as? FakeEmittingTool,
            let instancedPlain = mixedInnerTools.first(where: { $0 is PlainTool }) as? PlainTool
        else {
            Issue.record("expected both a FakeEmittingTool and a PlainTool in the threaded list")
            return
        }

        // The plain tool has no connect surface at all; the emitter still
        // auto-connects despite sharing the list with a non-emitting tool.
        await instancedEmitter.postEvent(Self.event(detail: "still works"))
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

    // MARK: - Fork behavior: fresh-per-session outbox, fork-then-connect tool composition

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
        "after fork, the parent's own instance keeps posting to the parent's outbox and the fork's own instance posts to the fork's outbox — concurrently"
    )
    @MainActor
    func parentAndForkInstancesPostToTheirOwnOutboxesConcurrently() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let container = ToolCapturingLLMContainer()
        let router = Self.makeRouter(container: container, cacheDir: dir)
        let profile = try await router.resolve(profile: Self.profile, reporting: ResolutionProgress())

        let emitter = FakeEmittingTool()
        let session = profile.standard.makeSession(tools: [emitter])
        let child = try await session.fork(workingDirectory: nil)

        guard let parentActor = session as? RoutedSessionActor,
            let childActor = child as? RoutedSessionActor,
            let parentInstance = Self.elevationWrapped(parentActor.tools.first) as? FakeEmittingTool,
            let childInstance = Self.elevationWrapped(childActor.tools.first) as? FakeEmittingTool
        else {
            Issue.record("expected both the parent and the fork to expose their own instanced FakeEmittingTool")
            return
        }
        #expect(parentInstance !== childInstance)

        // Concurrently post from each session's own instance — this is
        // exactly the scenario the old mutation-based design failed: one
        // shared instance, one sink, so forking silently re-homed the
        // parent's own future events to the fork.
        async let parentPost: Void = parentInstance.postEvent(
            Self.event(correlationID: "parent", detail: "from-parent"))
        async let childPost: Void = childInstance.postEvent(
            Self.event(correlationID: "child", detail: "from-child"))
        _ = await (parentPost, childPost)

        let parentPending = await session.outbox.pending()
        let childPending = await child.outbox.pending()
        #expect(parentPending.events.map(\.event.detail) == ["from-parent"])
        #expect(childPending.events.map(\.event.detail) == ["from-child"])
    }

    @Test("a sink captured before the fork keeps posting to the parent after forking")
    @MainActor
    func sinkCapturedBeforeForkKeepsPostingToParentAfterFork() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let container = ToolCapturingLLMContainer()
        let router = Self.makeRouter(container: container, cacheDir: dir)
        let profile = try await router.resolve(profile: Self.profile, reporting: ResolutionProgress())

        let emitter = FakeEmittingTool()
        let session = profile.standard.makeSession(tools: [emitter])

        guard let parentActor = session as? RoutedSessionActor,
            let capturedInstance = Self.elevationWrapped(parentActor.tools.first) as? FakeEmittingTool
        else {
            Issue.record("expected the parent session to expose its own instanced FakeEmittingTool")
            return
        }

        // Stands in for a detached task that captured its sink at operation
        // start, before any fork happened.
        _ = try await session.fork(workingDirectory: nil)

        await capturedInstance.postEvent(Self.event(detail: "captured-before-fork"))
        let parentPending = await session.outbox.pending()
        #expect(parentPending.events.map(\.event.detail) == ["captured-before-fork"])
    }

    @Test(
        "at fork, a ForkableTool fixture's forked() is invoked and its result lands in the child's tool list; a plain tool passes through shared"
    )
    @MainActor
    func forkAppliesForkedThenConnectsAndSharesPlainToolsUnchanged() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let container = ToolCapturingLLMContainer()
        let router = Self.makeRouter(container: container, cacheDir: dir)
        let profile = try await router.resolve(profile: Self.profile, reporting: ResolutionProgress())

        let forkable = ForkableEmittingTool()
        let plain = PlainTool()
        let session = profile.standard.makeSession(tools: [forkable, plain])
        let child = try await session.fork(workingDirectory: nil)

        guard let parentActor = session as? RoutedSessionActor,
            let childActor = child as? RoutedSessionActor
        else {
            Issue.record("expected both sessions to be RoutedSessionActor")
            return
        }

        let parentInnerTools = parentActor.tools.compactMap(Self.elevationWrapped)
        let childInnerTools = childActor.tools.compactMap(Self.elevationWrapped)
        guard let parentForkable = parentInnerTools.first(where: { $0 is ForkableEmittingTool }) as? ForkableEmittingTool,
            let childForkable = childInnerTools.first(where: { $0 is ForkableEmittingTool }) as? ForkableEmittingTool
        else {
            Issue.record("expected both sessions to expose a ForkableEmittingTool")
            return
        }
        // The parent's own instance is untouched; the child's is the result
        // of `forked()` — a distinct, incremented-generation instance, not
        // the original passed to `makeSession(tools:)`.
        #expect(parentForkable.generation == 0)
        #expect(childForkable.generation == 1)
        #expect(childForkable !== forkable)

        // The forked-then-connected copy posts to the child's own outbox.
        await childForkable.postEvent(Self.event(detail: "from-forked-tool"))
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
        "fork threads the child's fork-then-connect composed tools into the backend's makeFork(tools:) — the model-facing session, not just the actor's own bookkeeping list"
    )
    @MainActor
    func forkThreadsChildToolsIntoBackendMakeFork() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let container = ToolCapturingLLMContainer()
        let router = Self.makeRouter(container: container, cacheDir: dir)
        let profile = try await router.resolve(profile: Self.profile, reporting: ResolutionProgress())

        let emitter = FakeEmittingTool()
        let session = profile.standard.makeSession(tools: [emitter])
        guard let rootBackend = container.lastBackend else {
            Issue.record("expected the container to have vended a StubSessionBackend for the root session")
            return
        }

        let child = try await session.fork(workingDirectory: nil)

        guard let childActor = child as? RoutedSessionActor,
            let childInstance = Self.elevationWrapped(childActor.tools.first) as? FakeEmittingTool
        else {
            Issue.record("expected the fork to expose its own instanced FakeEmittingTool")
            return
        }

        // `rootBackend` is the actual backend `RoutedSessionActor.fork()` calls
        // `makeFork(tools:)` on — asserting on `lastForkTools` here proves the
        // child's fork-then-connect composed tool list (`childActor.tools`)
        // is what actually reached the model-facing backend construction
        // seam, not just the fork's own actor-level bookkeeping array.
        #expect(rootBackend.lastForkTools.count == 1)
        guard let forkedToolAtBackend = Self.elevationWrapped(rootBackend.lastForkTools.first) as? FakeEmittingTool else {
            Issue.record("expected the backend's makeFork(tools:) to have received a FakeEmittingTool")
            return
        }
        #expect(forkedToolAtBackend === childInstance)

        // Posting through the exact instance the backend received reaches
        // the child's own outbox — confirming it is genuinely the
        // child-connected copy, not a disconnected passthrough of the parent's.
        await forkedToolAtBackend.postEvent(Self.event(detail: "from-backend-threaded-tool"))
        let childPending = await child.outbox.pending()
        #expect(childPending.events.map(\.event.detail) == ["from-backend-threaded-tool"])
    }

    // MARK: - Elevation layer: per-site chain order (task ^k4nygqa)

    @Test("makeSession composes connect → elevate → cap: capping outermost, elevation inside it, the sink-bound instance innermost")
    @MainActor
    func makeSessionComposesConnectElevateCap() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let container = ToolCapturingLLMContainer()
        let router = Self.makeRouter(container: container, cacheDir: dir)
        let profile = try await router.resolve(profile: Self.profile, reporting: ResolutionProgress())

        let emitter = FakeEmittingTool()
        let session = profile.standard.makeSession(
            tools: [emitter],
            budget: TokenBudget(limit: 4096, toolOutputLimit: 5)
        )

        guard let capping = container.lastTools.first as? TokenCappingTool<FakeToolArguments>,
            let elevating = capping.wrapped as? ElevatingTool<FakeToolArguments>,
            let connected = elevating.wrapped as? FakeEmittingTool
        else {
            Issue.record("expected cap(elevate(connect(tool))) at the container boundary")
            return
        }
        #expect(connected !== emitter)

        // The innermost instance is the session-connected copy: posting
        // through it reaches this session's own outbox.
        await connected.postEvent(Self.event(detail: "chain-inner"))
        let pending = await session.outbox.pending()
        #expect(pending.events.map(\.event.detail) == ["chain-inner"])
    }

    @Test("makeSession without a budget composes connect → elevate: elevation outermost, no capping layer")
    @MainActor
    func makeSessionWithoutBudgetComposesConnectElevate() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let container = ToolCapturingLLMContainer()
        let router = Self.makeRouter(container: container, cacheDir: dir)
        let profile = try await router.resolve(profile: Self.profile, reporting: ResolutionProgress())

        let emitter = FakeEmittingTool()
        let session = profile.standard.makeSession(tools: [emitter])

        #expect(!(container.lastTools.first is TokenCappingTool<FakeToolArguments>))
        guard let elevating = container.lastTools.first as? ElevatingTool<FakeToolArguments>,
            let connected = elevating.wrapped as? FakeEmittingTool
        else {
            Issue.record("expected elevate(connect(tool)) at the container boundary")
            return
        }
        #expect(connected !== emitter)

        await connected.postEvent(Self.event(detail: "uncapped-chain-inner"))
        let pending = await session.outbox.pending()
        #expect(pending.events.map(\.event.detail) == ["uncapped-chain-inner"])
    }

    @Test("fork composes fork → connect → elevate → cap: capping outermost, elevation inside, the forked-then-connected instance innermost")
    @MainActor
    func forkComposesForkConnectElevateCap() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let container = ToolCapturingLLMContainer()
        let router = Self.makeRouter(container: container, cacheDir: dir)
        let profile = try await router.resolve(profile: Self.profile, reporting: ResolutionProgress())

        let forkable = ForkableEmittingTool()
        let session = profile.standard.makeSession(
            tools: [forkable],
            budget: TokenBudget(limit: 4096, toolOutputLimit: 5)
        )
        let child = try await session.fork(workingDirectory: nil)

        guard let childActor = child as? RoutedSessionActor,
            let capping = childActor.tools.first as? TokenCappingTool<FakeToolArguments>,
            let elevating = capping.wrapped as? ElevatingTool<FakeToolArguments>,
            let forkedConnected = elevating.wrapped as? ForkableEmittingTool
        else {
            Issue.record("expected cap(elevate(connect(forked(tool)))) in the fork's tool list")
            return
        }
        // `forked()` ran before `connecting(_:)`: the innermost instance is
        // the next generation, wired to the child's own outbox.
        #expect(forkedConnected.generation == 1)
        await forkedConnected.postEvent(Self.event(detail: "fork-chain-inner"))
        let childPending = await child.outbox.pending()
        #expect(childPending.events.map(\.event.detail) == ["fork-chain-inner"])
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
        let router = Router(
            cacheDir: dir,
            recorder: recorder,
            probe: StubProbe(chip: "Apple Test", totalRAM: 64 << 30, recommendedMaxWorkingSetSize: 48 << 30),
            metadataSource: StubMetadataSource(raw: Self.rawMetadata),
            loader: StubModelLoader(container: container, dimension: Self.stubDimension)
        )
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
        _ = await session.mailbox.wait(completionToken: envelope.completionToken, seconds: 30)
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
        _ = await child.mailbox.wait(completionToken: envelope.completionToken, seconds: 30)
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
            budget: TokenBudget(limit: 4096, toolOutputLimit: 5)
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
        _ = await session.mailbox.wait(completionToken: envelope.completionToken, seconds: 30)
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
        let settled = await session.mailbox.wait(completionToken: envelope.completionToken, seconds: 30)
        guard case .settled(let terminal) = settled else {
            Issue.record("expected the parked run to settle after the gate opened, got \(settled)")
            return
        }
        #expect(terminal.outcome == .succeeded)
        #expect(terminal.detail == "gated: cancel me")
    }
}
