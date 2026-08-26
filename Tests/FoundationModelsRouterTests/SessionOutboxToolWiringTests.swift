import Foundation
import FoundationModels
import Testing

@testable import FoundationModelsRouter

/// Exercises task s61g2vb's per-session tool composition:
/// ``RoutedModel/makeSession(instructions:workingDirectory:recordingRoot:tools:budget:compactionPrompt:summarization:agentSpawn:discoveryPriming:)`` wrapping
/// every String-output tool in the session's own ``RunToCompletionTool`` (or
/// ``BackgroundTool``) layer and
/// every non-String-output tool in the binding-only ``ContextBindingTool``
/// (task ^6htgvw2) — either way the ambient ``ToolContext`` posts the tool's
/// events to the session's own ``RoutedSession/outbox``, with **no explicit
/// wiring call anywhere** in these tests — and
/// ``RoutedSessionActor/fork(workingDirectory:)``'s fork-then-detach
/// composition (``ForkableTool/forked()`` then the child's own detachment
/// layer) building the child's tool list from the parent's true originals.
///
/// Everything runs against stubs — no MLX, no network, no GPU. Real
/// `LanguageModelSession(tools:)` wiring lives in the live
/// ``MLXFoundationModelsContainer``/``MLXFoundationModelsSessionBackend``
/// (`Sources/FoundationModelsRouter/Resolution/LiveModelLoader.swift`),
/// exercised end to end only by the gated integration suite.
@Suite("makeSession(tools:): per-session composition + fork-then-detach")
struct SessionOutboxToolWiringTests {
    // MARK: - Test tools

    @Generable
    struct FakeToolArguments {
        let value: String
    }

    /// A plain `Tool` with no `ForkableTool` conformance and no ambient
    /// posting at all — proves a mixed tool list works: this one just passes
    /// through into its own detachment wrapper untouched, both at
    /// construction and at fork.
    private struct PlainTool: Tool {
        let name = "plain"
        let description = "a tool with no event-emitting or forking capability"

        func call(arguments: FakeToolArguments) async throws -> String {
            "plain: \(arguments.value)"
        }
    }

    /// Blocks on a ``RunLatch`` and declares background for itself through
    /// ``DetachmentParameterProviding``, so the composition-site
    /// ``BackgroundTool`` hands each call back as a pending envelope at once
    /// and the pending-envelope tests wait on no wall clock.
    private struct GatedBackgroundTool: Tool, DetachmentParameterProviding {
        let name = "gated-background"
        let description = "test-only slow tool that declares background"
        let gate: RunLatch

        var detachmentMount: DetachConfiguration? {
            DetachConfiguration(mode: .background, timeout: nil)
        }

        func call(arguments: FakeToolArguments) async throws -> String {
            await gate.waitUntilOpen()
            return "gated: \(arguments.value)"
        }
    }

    // MARK: - Stub container capturing the threaded tool list

    /// A ``LoadedLLMContainer`` that records the `tools` it was handed at
    /// session-construction time, so a test can assert the exact list
    /// ``RoutedModel/makeSession(instructions:workingDirectory:recordingRoot:tools:budget:compactionPrompt:summarization:agentSpawn:discoveryPriming:)`` passed
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

        /// The turn-scope binding's `completionToken` observed at each
        /// `respond` entry — what a composed tool's own per-call
        /// `correlationID` must differ from.
        private(set) var observedTurnTokens: [String?] = []

        init(tools: [any Tool]) {
            self.tools = tools
        }

        func respond(to prompt: String, maxTokens: Int?) async throws -> String {
            observedTurnTokens.append(ToolContext.current?.completionToken)
            if let detached = tools.first as? BackgroundTool<FakeToolArguments> {
                toolCallStarted = true
                let rendered = try await detached.call(arguments: FakeToolArguments(value: prompt))
                renderedToolOutputs.append(rendered)
            }
            // The non-String counterpart: invokes the binding-only wrapper
            // from inside the turn — under the turn-scope ambient binding —
            // recording the output's text (the per-call token the tool
            // observed) for the shadowing assertions.
            if let bound = tools.first
                as? ContextBindingTool<AmbientToolArguments, NonStringToolOutput>
            {
                toolCallStarted = true
                let output = try await bound.call(
                    arguments: AmbientToolArguments(value: Self.nonStringInvocationDetail))
                renderedToolOutputs.append(output.text)
            }
            return try await inner.respond(to: prompt, maxTokens: maxTokens)
        }

        /// The event detail the backend's non-String invocation posts — a
        /// fixed marker, deliberately not the composed prompt, so a test can
        /// match it exactly without depending on prompt composition.
        static let nonStringInvocationDetail = "invoked-inside-respond"

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

    /// How long a test waits for a background run to settle before giving up —
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
        // Every String-output tool arrives wrapped in the detachment layer;
        // the shape assertion peels it to reach the threaded originals.
        let innerTools = container.lastTools.compactMap(detachmentWrapped)
        #expect(innerTools.contains { $0 is AmbientEventPostingTool })
        #expect(innerTools.contains { $0 is PlainTool })
    }

    @Test("the container receives the original tool instance itself, wrapped in the session's own detachment layer")
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
        // routing lives entirely in the detachment wrapper's ambient
        // `ToolContext`.
        guard let inner = detachmentWrapped(container.lastTools.first) as? AmbientEventPostingTool else {
            Issue.record("expected the container to receive a detached AmbientEventPostingTool")
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

        // No wiring call appears anywhere in this test — the detachment
        // layer `makeSession(tools:)` composed binds the ambient
        // `ToolContext` (carrying this session's own outbox) around the
        // call, so the tool's post lands there.
        guard let detached = container.lastTools.first as? RunToCompletionTool<AmbientToolArguments> else {
            Issue.record("expected the container to receive a RunToCompletionTool over the ambient fixture")
            return
        }
        _ = try await detached.call(arguments: AmbientToolArguments(value: "auto-routed"))

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

        let mixedInnerTools = container.lastTools.compactMap(detachmentWrapped)
        guard
            let instancedPlain = mixedInnerTools.first(where: { $0 is PlainTool }) as? PlainTool,
            let ambientDetached = container.lastTools.first(where: {
                detachmentWrapped($0) is AmbientEventPostingTool
            }) as? RunToCompletionTool<AmbientToolArguments>
        else {
            Issue.record("expected both an AmbientEventPostingTool and a PlainTool in the threaded list")
            return
        }

        // The ambient tool's events still route to this session's own
        // outbox despite sharing the list with a plain tool.
        _ = try await ambientDetached.call(arguments: AmbientToolArguments(value: "still works"))
        let pending = await session.outbox.pending()
        #expect(pending.events.map(\.event.detail) == ["still works"])

        let output = try await instancedPlain.call(arguments: FakeToolArguments(value: "x"))
        #expect(output == "plain: x")
    }

    @Test(
        "a non-String-output tool composed through makeSession(tools:) posts ambient events under its own identity to the session's own outbox"
    )
    @MainActor
    func nonStringOutputToolAmbientRouteThroughMakeSession() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let container = ToolCapturingLLMContainer()
        let router = Self.makeRouter(container: container, cacheDir: dir)
        let profile = try await router.resolve(profile: Self.profile, reporting: ResolutionProgress())

        let emitter = AmbientNonStringOutputTool()
        let session = profile.standard.makeSession(tools: [emitter])

        // The composed, model-facing tool is the binding-only wrapper —
        // never the bare original: the pending envelope has no String wire
        // form to ride on this tool, but per-tool identity and per-call
        // correlation still bind around every call.
        guard
            let bound = container.lastTools.first
                as? ContextBindingTool<AmbientToolArguments, NonStringToolOutput>
        else {
            Issue.record("expected the container to receive a ContextBindingTool over the non-String fixture")
            return
        }
        let first = try await bound.call(arguments: AmbientToolArguments(value: "first"))
        let second = try await bound.call(arguments: AmbientToolArguments(value: "second"))

        let events = await session.outbox.pending().events.map(\.event)
        #expect(events.map(\.detail) == ["first", "second"])
        #expect(events.map(\.tool) == [emitter.name, emitter.name])
        #expect(events.map(\.op) == [emitter.name, emitter.name])
        // Each call minted its own completionToken — the correlationID the
        // tool's own ambient posts carried, run scope, never turn scope.
        #expect(events.map(\.correlationID) == [first.text, second.text])
        #expect(first.text != second.text)
    }

    @Test(
        "inside a real respond turn, a non-String-output tool's per-call binding shadows the turn-scope binding: its posts carry its own identity and token, never session/respond or the turn's token"
    )
    @MainActor
    func nonStringToolPerCallBindingShadowsTurnScopeBindingInsideRespond() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let container = ToolInvokingLLMContainer()
        let router = Self.makeRouter(container: container, cacheDir: dir)
        let profile = try await router.resolve(profile: Self.profile, reporting: ResolutionProgress())

        let emitter = AmbientNonStringOutputTool()
        let session = profile.standard.makeSession(tools: [emitter])

        _ = try await session.respond(to: "drive the non-String tool")

        let backend = try #require(container.lastBackend)
        #expect(backend.toolCallStarted)
        let perCallToken = try #require(backend.renderedToolOutputs.first)
        let turnToken = try #require(backend.observedTurnTokens.first ?? nil)

        // The tool ran under a live turn-scope binding, and its own
        // per-call binding shadowed it: the posted event carries the
        // tool's identity and its call's own freshly minted token — never
        // the turn binding's "session"/"respond" stamps or the turn's
        // completionToken (the exact fallback this task removes).
        let events = await session.outbox.pending().events.map(\.event)
        #expect(events.map(\.detail) == [ToolInvokingBackend.nonStringInvocationDetail])
        #expect(events.map(\.tool) == [emitter.name])
        #expect(events.map(\.op) == [emitter.name])
        #expect(events.map(\.correlationID) == [perCallToken])
        #expect(perCallToken != turnToken)
        #expect(perCallToken != "unbound")
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

    // MARK: - Fork behavior: fresh-per-session outbox, fork-then-detach tool composition

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
            let parentDetached = parentActor.tools.first as? RunToCompletionTool<AmbientToolArguments>,
            let childDetached = childActor.tools.first as? RunToCompletionTool<AmbientToolArguments>
        else {
            Issue.record("expected both the parent and the fork to expose their own RunToCompletionTool wrapper")
            return
        }
        // Both sessions share the very same underlying tool instance —
        // per-session isolation lives entirely in each session's own
        // detachment wrapper and the ambient context it binds per call.
        #expect(detachmentWrapped(parentDetached) as? AmbientEventPostingTool === emitter)
        #expect(detachmentWrapped(childDetached) as? AmbientEventPostingTool === emitter)

        // Concurrently call through each session's own composed wrapper —
        // event delivery must never migrate between the two outboxes.
        async let parentCall = parentDetached.call(arguments: AmbientToolArguments(value: "from-parent"))
        async let childCall = childDetached.call(arguments: AmbientToolArguments(value: "from-child"))
        _ = try await (parentCall, childCall)

        let parentPending = await session.outbox.pending()
        let childPending = await child.outbox.pending()
        #expect(parentPending.events.map(\.event.detail) == ["from-parent"])
        #expect(childPending.events.map(\.event.detail) == ["from-child"])
    }

    @Test(
        "a non-String-output tool forked into a child gets the child's own ContextBindingTool, posting to the fork's outbox with its own identity"
    )
    @MainActor
    func forkComposedNonStringOutputToolPostsToForkOutbox() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let container = ToolCapturingLLMContainer()
        let router = Self.makeRouter(container: container, cacheDir: dir)
        let profile = try await router.resolve(profile: Self.profile, reporting: ResolutionProgress())

        let emitter = AmbientNonStringOutputTool()
        let session = profile.standard.makeSession(tools: [emitter])
        let child = try await session.fork(workingDirectory: nil)

        guard let parentActor = session as? RoutedSessionActor,
            let childActor = child as? RoutedSessionActor,
            let parentBound = parentActor.tools.first
                as? ContextBindingTool<AmbientToolArguments, NonStringToolOutput>,
            let childBound = childActor.tools.first
                as? ContextBindingTool<AmbientToolArguments, NonStringToolOutput>
        else {
            Issue.record("expected both the parent and the fork to expose their own ContextBindingTool wrapper")
            return
        }
        // Both sessions share the very same underlying tool instance —
        // per-session isolation lives entirely in each session's own
        // binding wrapper and the ambient context it binds per call.
        #expect(detachmentWrapped(parentBound) as? AmbientNonStringOutputTool === emitter)
        #expect(detachmentWrapped(childBound) as? AmbientNonStringOutputTool === emitter)

        let parentOutput = try await parentBound.call(arguments: AmbientToolArguments(value: "from-parent"))
        let childOutput = try await childBound.call(arguments: AmbientToolArguments(value: "from-child"))

        // Each session's composed wrapper posts to that session's own
        // outbox — never the other's — with the tool's own identity and
        // that call's own freshly minted correlationID.
        let parentEvents = await session.outbox.pending().events.map(\.event)
        let childEvents = await child.outbox.pending().events.map(\.event)
        #expect(parentEvents.map(\.detail) == ["from-parent"])
        #expect(childEvents.map(\.detail) == ["from-child"])
        #expect(parentEvents.map(\.tool) == [emitter.name])
        #expect(childEvents.map(\.tool) == [emitter.name])
        #expect(parentEvents.map(\.correlationID) == [parentOutput.text])
        #expect(childEvents.map(\.correlationID) == [childOutput.text])
        #expect(parentOutput.text != childOutput.text)
    }

    @Test(
        "after fork, the parent's and the fork's non-String-output binding wrappers post concurrently to their own outboxes, each call under its own fresh token"
    )
    @MainActor
    func parentAndForkNonStringOutputToolsPostToTheirOwnOutboxesConcurrently() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let container = ToolCapturingLLMContainer()
        let router = Self.makeRouter(container: container, cacheDir: dir)
        let profile = try await router.resolve(profile: Self.profile, reporting: ResolutionProgress())

        let emitter = AmbientNonStringOutputTool()
        let session = profile.standard.makeSession(tools: [emitter])
        let child = try await session.fork(workingDirectory: nil)

        guard let parentActor = session as? RoutedSessionActor,
            let childActor = child as? RoutedSessionActor,
            let parentBound = parentActor.tools.first
                as? ContextBindingTool<AmbientToolArguments, NonStringToolOutput>,
            let childBound = childActor.tools.first
                as? ContextBindingTool<AmbientToolArguments, NonStringToolOutput>
        else {
            Issue.record("expected both the parent and the fork to expose their own ContextBindingTool wrapper")
            return
        }
        // Both sessions share the very same underlying tool instance —
        // per-session isolation lives entirely in each session's own
        // binding wrapper and the ambient context it binds per call.
        #expect(detachmentWrapped(parentBound) as? AmbientNonStringOutputTool === emitter)
        #expect(detachmentWrapped(childBound) as? AmbientNonStringOutputTool === emitter)

        // Concurrently call through each session's own binding wrapper —
        // event delivery must never migrate between the two outboxes, and
        // each concurrent call must run under its own freshly minted token.
        async let parentCall = parentBound.call(arguments: AmbientToolArguments(value: "from-parent"))
        async let childCall = childBound.call(arguments: AmbientToolArguments(value: "from-child"))
        let (parentOutput, childOutput) = try await (parentCall, childCall)

        let parentEvents = await session.outbox.pending().events.map(\.event)
        let childEvents = await child.outbox.pending().events.map(\.event)
        #expect(parentEvents.map(\.detail) == ["from-parent"])
        #expect(childEvents.map(\.detail) == ["from-child"])
        #expect(parentEvents.map(\.tool) == [emitter.name])
        #expect(childEvents.map(\.tool) == [emitter.name])
        // Each event's correlationID is exactly its own call's token — the
        // concurrent bindings never bled into each other.
        #expect(parentEvents.map(\.correlationID) == [parentOutput.text])
        #expect(childEvents.map(\.correlationID) == [childOutput.text])
        #expect(parentOutput.text != childOutput.text)
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
            let capturedDetached = parentActor.tools.first as? RunToCompletionTool<AmbientToolArguments>
        else {
            Issue.record("expected the parent session to expose its own RunToCompletionTool wrapper")
            return
        }

        // Stands in for a detached task that captured the composed tool at
        // operation start, before any fork happened.
        let child = try await session.fork(workingDirectory: nil)

        _ = try await capturedDetached.call(arguments: AmbientToolArguments(value: "captured-before-fork"))
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

        let parentInnerTools = parentActor.tools.compactMap(detachmentWrapped)
        let childInnerTools = childActor.tools.compactMap(detachmentWrapped)
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

        // Calling the forked tool through the child's own detachment wrapper
        // posts to the child's own outbox.
        guard
            let childForkableDetached = childActor.tools.first(where: {
                detachmentWrapped($0) is ForkableAmbientTool
            }) as? RunToCompletionTool<AmbientToolArguments>
        else {
            Issue.record("expected the child's tool list to hold the forked tool's own RunToCompletionTool")
            return
        }
        _ = try await childForkableDetached.call(arguments: AmbientToolArguments(value: "from-forked-tool"))
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
        "fork threads the child's fork-then-detach composed tools into the backend's makeFork(tools:) — the model-facing session, not just the actor's own bookkeeping list"
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
        // child's fork-then-detach composed tool list is what actually
        // reached the model-facing backend construction seam, not just the
        // fork's own actor-level bookkeeping array.
        #expect(rootBackend.lastForkTools.count == 1)
        guard let forkedDetachedAtBackend = rootBackend.lastForkTools.first as? RunToCompletionTool<AmbientToolArguments>
        else {
            Issue.record("expected the backend's makeFork(tools:) to have received the child's RunToCompletionTool")
            return
        }
        #expect(detachmentWrapped(forkedDetachedAtBackend) as? AmbientEventPostingTool === emitter)

        // Calling through the exact wrapper the backend received posts to
        // the child's own outbox — confirming it is genuinely the
        // child-composed wrapper, not a passthrough of the parent's.
        _ = try await forkedDetachedAtBackend.call(
            arguments: AmbientToolArguments(value: "from-backend-threaded-tool"))
        let childPending = await child.outbox.pending()
        #expect(childPending.events.map(\.event.detail) == ["from-backend-threaded-tool"])
        let parentPending = await session.outbox.pending()
        #expect(parentPending.events.isEmpty)
    }

    // MARK: - Detachment layer: per-site chain order (task ^k4nygqa)

    @Test("makeSession composes detach → cap: capping outermost, detachment inside it, the original tool innermost")
    @MainActor
    func makeSessionComposesDetachCap() async throws {
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
            let detaching = capping.wrapped as? RunToCompletionTool<AmbientToolArguments>,
            let inner = detaching.wrapped as? AmbientEventPostingTool
        else {
            Issue.record("expected cap(detach(tool)) at the container boundary")
            return
        }
        #expect(inner === emitter)

        // Calling through the full chain still routes the tool's
        // ambient-context event to this session's own outbox.
        _ = try await capping.call(arguments: AmbientToolArguments(value: "chain-inner"))
        let pending = await session.outbox.pending()
        #expect(pending.events.map(\.event.detail) == ["chain-inner"])
    }

    @Test("makeSession without a budget composes detach only: detachment outermost, no capping layer")
    @MainActor
    func makeSessionWithoutBudgetComposesDetachOnly() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let container = ToolCapturingLLMContainer()
        let router = Self.makeRouter(container: container, cacheDir: dir)
        let profile = try await router.resolve(profile: Self.profile, reporting: ResolutionProgress())

        let emitter = AmbientEventPostingTool()
        let session = profile.standard.makeSession(tools: [emitter])

        #expect(!(container.lastTools.first is TokenCappingTool<AmbientToolArguments>))
        guard let detaching = container.lastTools.first as? RunToCompletionTool<AmbientToolArguments>,
            let inner = detaching.wrapped as? AmbientEventPostingTool
        else {
            Issue.record("expected detach(tool) at the container boundary")
            return
        }
        #expect(inner === emitter)

        _ = try await detaching.call(arguments: AmbientToolArguments(value: "uncapped-chain-inner"))
        let pending = await session.outbox.pending()
        #expect(pending.events.map(\.event.detail) == ["uncapped-chain-inner"])
    }

    @Test("fork composes fork → detach → cap: capping outermost, detachment inside, the forked instance innermost")
    @MainActor
    func forkComposesForkDetachCap() async throws {
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
            let detaching = capping.wrapped as? RunToCompletionTool<AmbientToolArguments>,
            let forkedInner = detaching.wrapped as? ForkableAmbientTool
        else {
            Issue.record("expected cap(detach(forked(tool))) in the fork's tool list")
            return
        }
        // `forked()` ran before the child's detachment wrapped it: the
        // innermost instance is the next generation.
        #expect(forkedInner.generation == 1)
        _ = try await capping.call(arguments: AmbientToolArguments(value: "fork-chain-inner"))
        let childPending = await child.outbox.pending()
        #expect(childPending.events.map(\.event.detail) == ["fork-chain-inner"])
    }

    @Test("fork without a budget composes fork → detach: detachment outermost, no capping layer")
    @MainActor
    func forkWithoutBudgetComposesForkDetachOnly() async throws {
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
        guard let detaching = childActor.tools.first as? RunToCompletionTool<AmbientToolArguments>,
            let forkedInner = detaching.wrapped as? ForkableAmbientTool
        else {
            Issue.record("expected detach(forked(tool)) in the fork's tool list")
            return
        }
        // `forked()` ran before the child's detachment wrapped it: the
        // innermost instance is the next generation — the same fork →
        // detach order as the with-budget case, just with no cap layer
        // anywhere in the chain.
        #expect(forkedInner.generation == 1)
        _ = try await detaching.call(arguments: AmbientToolArguments(value: "uncapped-fork-chain-inner"))
        let childPending = await child.outbox.pending()
        #expect(childPending.events.map(\.event.detail) == ["uncapped-fork-chain-inner"])
    }

    /// Shared body of the with-/without-budget makeSession bind-only pins:
    /// composes a session over ``AmbientNonStringOutputTool`` under `budget`
    /// and asserts the container-boundary chain is bind(tool) — never capped
    /// — with the ambient event routed to the session's own outbox.
    ///
    /// - Parameters:
    ///   - budget: The session budget to compose under, or `nil` for none.
    ///   - detail: The event detail the asserted post carries.
    @MainActor
    private func assertMakeSessionComposesBindOnlyForNonStringOutput(
        budget: TokenBudget?, detail: String
    ) async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let container = ToolCapturingLLMContainer()
        let router = Self.makeRouter(container: container, cacheDir: dir)
        let profile = try await router.resolve(profile: Self.profile, reporting: ResolutionProgress())

        let emitter = AmbientNonStringOutputTool()
        let session = profile.standard.makeSession(tools: [emitter], budget: budget)

        // Capping requires a String output to truncate, so at every budget
        // level the chain for a non-String-output tool is bind(tool) —
        // never cap(bind(tool)) (see ``ToolDetachment/sessionMounted``).
        // The no-cap check below is type-guaranteed for a non-String
        // output (``TokenCappingTool`` wraps only `Tool<Arguments, String>`)
        // — it documents the shape; the load-bearing chain proof is
        // `wrapped` being the original instance directly.
        #expect(!(container.lastTools.first is TokenCappingTool<AmbientToolArguments>))
        guard
            let bound = container.lastTools.first
                as? ContextBindingTool<AmbientToolArguments, NonStringToolOutput>,
            let inner = bound.wrapped as? AmbientNonStringOutputTool
        else {
            Issue.record("expected bind(tool) at the container boundary")
            return
        }
        #expect(inner === emitter)

        _ = try await bound.call(arguments: AmbientToolArguments(value: detail))
        let pending = await session.outbox.pending()
        #expect(pending.events.map(\.event.detail) == [detail])
    }

    @Test(
        "makeSession with a budget composes a non-String-output tool as bind only: no cap layer exists for output capping cannot truncate"
    )
    @MainActor
    func makeSessionWithBudgetComposesBindOnlyForNonStringOutput() async throws {
        try await assertMakeSessionComposesBindOnlyForNonStringOutput(
            budget: Self.budgetWithSmallToolOutputCap, detail: "budgeted-bind-inner")
    }

    /// Shared body of the with-/without-budget fork bind-only pins: forks a
    /// session over ``AmbientNonStringOutputTool`` composed under `budget`
    /// and asserts the child's chain is bind(tool) — never capped, the very
    /// same shared instance innermost — with the ambient event routed to the
    /// child's own outbox and the parent's left untouched.
    ///
    /// - Parameters:
    ///   - budget: The session budget to compose under, or `nil` for none.
    ///   - detail: The event detail the asserted post carries.
    @MainActor
    private func assertForkComposesBindOnlyForNonStringOutput(
        budget: TokenBudget?, detail: String
    ) async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let container = ToolCapturingLLMContainer()
        let router = Self.makeRouter(container: container, cacheDir: dir)
        let profile = try await router.resolve(profile: Self.profile, reporting: ResolutionProgress())

        let emitter = AmbientNonStringOutputTool()
        let session = profile.standard.makeSession(tools: [emitter], budget: budget)
        let child = try await session.fork(workingDirectory: nil)

        guard let childActor = child as? RoutedSessionActor else {
            Issue.record("expected the fork to be a RoutedSessionActor")
            return
        }
        // The same bind-only chain as the root site at every budget level:
        // capping has no String output to truncate, and the fixture is not
        // ForkableTool, so the very same instance passes through shared
        // into the child's own binding layer.
        // The no-cap check below is type-guaranteed for a non-String
        // output (``TokenCappingTool`` wraps only `Tool<Arguments, String>`)
        // — it documents the shape; the load-bearing chain proof is
        // `wrapped` being the original instance directly.
        #expect(!(childActor.tools.first is TokenCappingTool<AmbientToolArguments>))
        guard
            let childBound = childActor.tools.first
                as? ContextBindingTool<AmbientToolArguments, NonStringToolOutput>,
            let childInner = childBound.wrapped as? AmbientNonStringOutputTool
        else {
            Issue.record("expected bind(tool) in the fork's tool list")
            return
        }
        #expect(childInner === emitter)

        _ = try await childBound.call(arguments: AmbientToolArguments(value: detail))
        let childPending = await child.outbox.pending()
        #expect(childPending.events.map(\.event.detail) == [detail])
        let parentPending = await session.outbox.pending()
        #expect(parentPending.events.isEmpty)
    }

    @Test(
        "fork with a budget composes a non-String-output tool as bind only in the child: shared instance innermost, no cap layer"
    )
    @MainActor
    func forkWithBudgetComposesBindOnlyForNonStringOutput() async throws {
        try await assertForkComposesBindOnlyForNonStringOutput(
            budget: Self.budgetWithSmallToolOutputCap, detail: "budgeted-fork-bind-inner")
    }

    @Test(
        "makeSession without a budget composes a non-String-output tool as bind only: the same bind(tool) chain as the with-budget case"
    )
    @MainActor
    func makeSessionWithoutBudgetComposesBindOnlyForNonStringOutput() async throws {
        try await assertMakeSessionComposesBindOnlyForNonStringOutput(
            budget: nil, detail: "uncapped-bind-inner")
    }

    @Test(
        "fork without a budget composes a non-String-output tool as bind only in the child: shared instance innermost, no cap layer"
    )
    @MainActor
    func forkWithoutBudgetComposesBindOnlyForNonStringOutput() async throws {
        try await assertForkComposesBindOnlyForNonStringOutput(
            budget: nil, detail: "uncapped-fork-bind-inner")
    }

    // MARK: - Detachment behavior through a session's composed tool list

    @Test(
        "a slow detached tool returns the pending envelope, and its later .completed rides the next turn's preamble and lands as a durable OperationEventSegment"
    )
    @MainActor
    func detachedSlowToolCompletionRidesNextTurn() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let container = ToolCapturingLLMContainer()
        let recorder = InMemoryRecorder()
        let router = Self.makeRouter(container: container, cacheDir: dir, recorder: recorder)
        let profile = try await router.resolve(profile: Self.profile, reporting: ResolutionProgress())

        let gate = RunLatch()
        let session = profile.standard.makeSession(tools: [GatedBackgroundTool(gate: gate)])
        let backend = try #require(container.lastBackend)
        guard let detached = container.lastTools.first as? BackgroundTool<FakeToolArguments> else {
            Issue.record("expected the composed tool list to hold a BackgroundTool")
            return
        }

        // The tool declared background, so the model-facing call returns
        // the pending envelope on the wire at once.
        let rendered = try await detached.call(arguments: FakeToolArguments(value: "slow"))
        let envelope = try JSONDecoder().decode(PendingRunEnvelope.self, from: Data(rendered.utf8))
        #expect(envelope.pending)

        // Let the background run finish; its synthesized `.completed` funnels
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
            guard case .structure(_, let schemaName, let contentJSON) = segment,
                schemaName == OperationEventSegment.schemaName
            else { return nil }
            return try? JSONDecoder().decode(OperationEvent.self, from: Data(contentJSON.utf8))
        }
        #expect(journaled.contains { $0.kind == .completed && $0.correlationID == envelope.completionToken })
    }

    @Test("a fork's tracked detached run lives in the fork's own mailbox; the parent's mailbox is untouched")
    @MainActor
    func forkBackgroundRunLivesInForkMailbox() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let container = ToolCapturingLLMContainer()
        let router = Self.makeRouter(container: container, cacheDir: dir)
        let profile = try await router.resolve(profile: Self.profile, reporting: ResolutionProgress())

        let gate = RunLatch()
        let session = profile.standard.makeSession(tools: [GatedBackgroundTool(gate: gate)])
        let child = try await session.fork(workingDirectory: nil)

        guard let childActor = child as? RoutedSessionActor,
            let childDetached = childActor.tools.first as? BackgroundTool<FakeToolArguments>
        else {
            Issue.record("expected the fork's composed tool list to hold a BackgroundTool")
            return
        }

        let rendered = try await childDetached.call(arguments: FakeToolArguments(value: "forked"))
        let envelope = try JSONDecoder().decode(PendingRunEnvelope.self, from: Data(rendered.utf8))
        #expect(envelope.pending)

        let childTokens = await child.mailbox.backgroundRuns().map(\.completionToken)
        #expect(childTokens == [envelope.completionToken])
        let parentRuns = await session.mailbox.backgroundRuns()
        #expect(parentRuns.isEmpty)

        // Settle the background run so no detached work outlives the test.
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

        let gate = RunLatch()
        // toolOutputLimit 5 is far below the envelope's own estimated size:
        // real tool output at this cap is truncated, but the envelope —
        // control-plane data whose completionToken the model must keep —
        // must pass through untouched.
        let session = profile.standard.makeSession(
            tools: [GatedBackgroundTool(gate: gate)],
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
        // Byte-for-byte what the detachment layer rendered: the capping
        // decorator still recognizes the envelope's wire form, so neither the
        // completionToken nor the next-step instruction it carries is
        // truncated away.
        #expect(rendered == PendingRunEnvelope(completionToken: envelope.completionToken).rendered)
        #expect(PendingRunEnvelope.isRendered(text: rendered))

        // Settle the background run so no detached work outlives the test.
        await gate.open()
        _ = await session.mailbox.wait(completionToken: envelope.completionToken, seconds: Self.mailboxWaitTimeoutSeconds)
    }

    @Test(
        "cancelling a turn detaches an in-flight detached tool call: it is backgrounded in the session's mailbox and later settles normally, never dying with the turn"
    )
    @MainActor
    func cancellingATurnBackgroundsInFlightDetachedToolCall() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let container = ToolInvokingLLMContainer()
        let router = Self.makeRouter(container: container, cacheDir: dir)
        let profile = try await router.resolve(profile: Self.profile, reporting: ResolutionProgress())

        let gate = RunLatch()
        let session = profile.standard.makeSession(tools: [GatedBackgroundTool(gate: gate)])
        let backend = try #require(container.lastBackend)

        // Drive a turn whose backend invokes the composed detached tool,
        // then cancel the turn while that tool call is in flight. (The
        // tool declared background, so the call is handed back as a token
        // with or without the cancel — what this pins is what cancellation
        // does NOT do: kill the background run.)
        let turn = Task { try await session.respond(to: "cancel me") }
        for _ in 0..<600 {
            if backend.toolCallStarted { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(backend.toolCallStarted)
        await session.cancelCurrentTurn()

        // The run was tracked in this session's mailbox, and it is still running
        // with the turn cancelled. Read the run plane here, while the work is
        // still in flight: `respond(to:)` drains the run plane before it
        // returns (task ^nmpejc5), so a read after the call would say nothing
        // about what the cancellation did.
        #expect(
            await BoundedWait.conditionReached("the tool's run tracked on the session") {
                await !session.mailbox.backgroundRuns().isEmpty
            })
        let trackedTokens = await session.mailbox.backgroundRuns().map(\.completionToken)

        // The background run outlived the cancelled turn un-cancelled: opening
        // the gate lets it settle as a normal success — and lets the turn's
        // own caller finish.
        await gate.open()
        _ = try? await turn.value

        // The tool call answered with the pending envelope, not a
        // CancellationError, and that envelope's token is the run that was
        // tracked.
        let rendered = try #require(backend.renderedToolOutputs.first)
        let envelope = try JSONDecoder().decode(PendingRunEnvelope.self, from: Data(rendered.utf8))
        #expect(envelope.pending)
        #expect(trackedTokens == [envelope.completionToken])

        let settled = await session.mailbox.wait(completionToken: envelope.completionToken, seconds: Self.mailboxWaitTimeoutSeconds)
        guard case .settled(let terminal) = settled else {
            Issue.record("expected the background run to settle after the gate opened, got \(settled)")
            return
        }
        #expect(terminal.outcome == .succeeded)
        #expect(terminal.detail == "gated: cancel me")
    }
}
