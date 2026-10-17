import Foundation
import FoundationModels
import FoundationModelsRouterTestSupport
import Synchronization
import Testing

@testable import FoundationModelsExtras
@testable import FoundationModelsRouter

/// Exercises task s61g2vb's per-session tool composition:
/// ``RoutedModel/makeSession(instructions:workingDirectory:recordingRoot:tools:budget:compactionPrompt:agentSpawn:discoveryPriming:toolOutputProtection:repetitionDetection:)`` wrapping
/// every String-output tool in the session's own ``RunToCompletionRunner`` (or
/// ``BackgroundToolRunner``) layer and
/// every non-String-output tool in the binding-only ``ContextBindingTool``
/// (task ^6htgvw2) — either way the ambient ``ToolContext`` posts the tool's
/// events to the session's own ``RoutedSession/outbox``, with **no explicit
/// wiring call anywhere** in these tests — and
/// ``RoutedSessionActor/fork(workingDirectory:)``'s fork-then-mount
/// composition (``ForkableTool/forked()`` then the child's own mount
/// layer) building the child's tool list from the parent's true originals.
///
/// Everything runs against stubs — no MLX, no network, no GPU. Real
/// `LanguageModelSession(tools:)` wiring lives in the live
/// ``MLXFoundationModelsContainer``/``MLXFoundationModelsSessionBackend``
/// (`Sources/FoundationModelsRouter/Resolution/LiveModelLoader.swift`),
/// exercised end to end only by the gated integration suite.
@Suite("makeSession(tools:): per-session composition + fork-then-mount")
struct SessionOutboxToolWiringTests {
    // MARK: - Test tools

    @Generable
    struct FakeToolArguments {
        let value: String
    }

    /// A plain `Tool` with no `ForkableTool` conformance and no ambient
    /// posting at all — proves a mixed tool list works: this one just passes
    /// through into its own mount wrapper untouched, both at
    /// construction and at fork.
    private struct PlainTool: Tool {
        let name = "plain"
        let description = "a tool with no event-emitting or forking capability"

        func call(arguments: FakeToolArguments) async throws -> String {
            "plain: \(arguments.value)"
        }
    }

    /// Blocks on a ``RunLatch`` and declares background for itself through
    /// ``BackgroundTool``, so the composition-site
    /// ``BackgroundToolRunner`` hands each call back as a pending envelope at once
    /// and the pending-envelope tests wait on no wall clock.
    private struct GatedBackgroundToolRunner: Tool, BackgroundTool {
        let name = "gated-background"
        let description = "test-only slow tool that declares background"
        let gate: RunLatch

        var mount: ToolMount? {
            ToolMount(mode: .background, timeout: nil)
        }

        /// No wait: each call answers with its pending envelope at once.
        var inlineSettleGrace: TimeInterval { 0 }

        func call(arguments: FakeToolArguments) async throws -> String {
            await gate.waitUntilOpen()
            return "gated: \(arguments.value)"
        }
    }

    /// Thrown by a fixture tool that finds no ambient ``ToolContext`` bound
    /// around its call.
    private struct ToolContextMissing: Error {}

    /// Posts one progress report through the ambient ``ToolContext``, opens
    /// its `reported` latch, then holds on its gate until a test opens it.
    private struct ProgressReportingBackgroundToolRunner: Tool, BackgroundTool {
        /// The progress detail the tool reports.
        static let progressDetail = "halfway through"

        let name = "progress-background"
        let description = "test-only background tool that reports progress"
        let gate: RunLatch

        /// Opened after the post of the progress report returned. The post
        /// returns only after the sink of the session staged the report and
        /// the run plane recorded its detail.
        let reported: RunLatch

        var mount: ToolMount? {
            ToolMount(mode: .background, timeout: nil)
        }

        /// No wait: each call answers with its pending envelope at once.
        var inlineSettleGrace: TimeInterval { 0 }

        func call(arguments: BackgroundFixtureArguments) async throws -> String {
            guard let context = ToolContext.current else { throw ToolContextMissing() }
            await context.progress(Self.progressDetail)
            await reported.open()
            await gate.waitUntilOpen()
            return "progress done"
        }
    }

    /// Raises one form elicitation through the ambient ``ToolContext`` and
    /// answers with the action the user chose.
    private struct ElicitingBackgroundToolRunner: Tool, BackgroundTool {
        /// The question the tool asks.
        static let question = "Which account?"

        let name = "eliciting-background"
        let description = "test-only background tool that elicits"
        let elicitationId: ULID

        var mount: ToolMount? {
            ToolMount(mode: .background, timeout: nil)
        }

        /// No wait: each call answers with its pending envelope at once.
        var inlineSettleGrace: TimeInterval { 0 }

        func call(arguments: BackgroundFixtureArguments) async throws -> String {
            guard let context = ToolContext.current else { throw ToolContextMissing() }
            let request = ElicitationRequest(
                message: Self.question, elicitationId: elicitationId,
                requestedSchema: ElicitationRequestedSchema(properties: [:]))
            let answer = try await context.elicit(request)
            return "answered: \(answer.action.rawValue)"
        }
    }

    // MARK: - Stub container capturing the threaded tool list

    /// A ``LoadedLLMContainer`` that records the `tools` it was handed at
    /// session-construction time, so a test can assert the exact list
    /// ``RoutedModel/makeSession(instructions:workingDirectory:recordingRoot:tools:budget:compactionPrompt:agentSpawn:discoveryPriming:toolOutputProtection:repetitionDetection:)`` passed
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
        /// The scripted counter of this container: one token per `Character`.
        let tokenCounter: any TokenCounter = CharacterTokenCounter()

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
    /// its first `respond` — standing in for the SDK runtime invoking a tool
    /// mid-generation, so a test can cancel the answer while that tool call
    /// is in flight.
    ///
    /// It invokes the tool in its first `respond` only. The terminal of a
    /// background run is mail, and the pump of the session delivers it in a
    /// submission of its own (task ^3qx0mpt): a backend that started a new
    /// run in each submission would start deliveries with no end. Every
    /// capture is behind one `Mutex`, because a test reads the captures while
    /// such a delivery can run.
    private final class ToolInvokingBackend: LanguageModelSessionBackend {
        /// The fields a call writes and a test reads.
        private struct Captures {
            /// See ``ToolInvokingBackend/toolCallStarted``.
            var toolCallStarted = false

            /// See ``ToolInvokingBackend/toolCallReturned``.
            var toolCallReturned = false

            /// See ``ToolInvokingBackend/renderedToolOutputs``.
            var renderedToolOutputs: [String] = []

            /// See ``ToolInvokingBackend/observedSubmissionTokens``.
            var observedSubmissionTokens: [String?] = []
        }

        private let inner = StubSessionBackend()

        /// The composed tool list this backend was constructed with.
        private let tools: [any Tool]

        /// The one lock the captures are behind.
        private let captures = Mutex(Captures())

        /// The signal of each change of the captures, sent after the change.
        /// A test waits on it for a capture with no clock.
        let changes = ChangeSignal()

        /// The latch that the first `respond` waits on after the first
        /// composed tool returns, or `nil` for no wait. While the latch is
        /// closed, the answer is in flight, so a test can stop the answer at
        /// that point.
        private let answerHold: RunLatch?

        /// Flips just before the first composed tool is invoked, so a test
        /// can wait for the call to be in flight before cancelling.
        var toolCallStarted: Bool { captures.withLock { $0.toolCallStarted } }

        /// Flips after the first composed tool returns, before the first
        /// `respond` waits on ``answerHold``.
        var toolCallReturned: Bool { captures.withLock { $0.toolCallReturned } }

        /// Every rendered output the invoked tool returned, in call order.
        var renderedToolOutputs: [String] { captures.withLock { $0.renderedToolOutputs } }

        /// The submission-scope binding's `completionToken` observed at each
        /// `respond` entry — what a composed tool's own per-call
        /// `correlationID` must differ from.
        var observedSubmissionTokens: [String?] { captures.withLock { $0.observedSubmissionTokens } }

        /// Makes a backend that invokes the first tool of `tools`.
        ///
        /// - Parameters:
        ///   - tools: The composed tool list of the session.
        ///   - answerHold: The latch that the first `respond` waits on after
        ///     the tool returns, or `nil` for no wait.
        init(tools: [any Tool], answerHold: RunLatch? = nil) {
            self.tools = tools
            self.answerHold = answerHold
        }

        func respond(to prompt: String, maxTokens: Int?) async throws -> String {
            let isFirstCall = capture { captures in
                captures.observedSubmissionTokens.append(ToolContext.current?.completionToken)
                return captures.observedSubmissionTokens.count == 1
            }
            if isFirstCall {
                try await invokeFirstTool(prompt: prompt)
                capture { $0.toolCallReturned = true }
                await answerHold?.waitUntilOpen()
            }
            return try await inner.respond(to: prompt, maxTokens: maxTokens)
        }

        /// Changes the captures under their lock, and then signals
        /// ``changes``.
        ///
        /// - Parameter change: The change of the captures.
        /// - Returns: What `change` returns.
        @discardableResult
        private func capture<Value>(_ change: (inout Captures) -> Value) -> Value {
            defer { changes.signal() }
            return captures.withLock { change(&$0) }
        }

        /// Invokes the first composed tool, and records what it rendered.
        ///
        /// - Parameter prompt: The prompt of the call, which a background
        ///   tool receives as its argument.
        /// - Throws: What the tool throws.
        private func invokeFirstTool(prompt: String) async throws {
            if let mounted = failureDeliveryPeeled(tools.first) as? BackgroundToolRunner<FakeToolArguments> {
                capture { $0.toolCallStarted = true }
                let rendered = try await mounted.call(arguments: FakeToolArguments(value: prompt))
                capture { $0.renderedToolOutputs.append(rendered) }
            }
            // The non-String counterpart: invokes the binding-only wrapper
            // from inside the submission — under the submission-scope ambient binding —
            // recording the output's text (the per-call token the tool
            // observed) for the shadowing assertions.
            if let bound = failureDeliveryPeeled(tools.first)
                as? ContextBindingTool<AmbientToolArguments, NonStringToolOutput>
            {
                capture { $0.toolCallStarted = true }
                let output = try await bound.call(
                    arguments: AmbientToolArguments(value: Self.nonStringInvocationDetail))
                capture { $0.renderedToolOutputs.append(output.text) }
            }
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
        /// The scripted counter of this container: one token per `Character`.
        let tokenCounter: any TokenCounter = CharacterTokenCounter()

        private(set) var lastBackend: ToolInvokingBackend?

        /// The latch that each vended backend gives to
        /// ``ToolInvokingBackend/init(tools:answerHold:)``, or `nil` for no
        /// wait.
        private let answerHold: RunLatch?

        /// Makes a container.
        ///
        /// - Parameter answerHold: The latch that the first `respond` of each
        ///   vended backend waits on after its tool returns, or `nil` for no
        ///   wait.
        init(answerHold: RunLatch? = nil) {
            self.answerHold = answerHold
        }

        func makeSession(instructions: String?) -> any LanguageModelSessionBackend {
            makeSession(instructions: instructions, tools: [])
        }

        func makeSession(instructions: String?, tools: [any Tool]) -> any LanguageModelSessionBackend {
            let backend = ToolInvokingBackend(tools: tools, answerHold: answerHold)
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

    /// The budget the capping-layer tests vend sessions with: an ample
    /// context limit and a deliberately tiny `toolOutputLimit`, so the cap
    /// layer is present and easy to trip.
    private static let budgetWithSmallToolOutputCap = TokenBudget(limit: 4096, toolOutputLimit: 5)

    private static func makeTempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SessionOutboxToolWiringTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func makeRouter(
        container: any LoadedLLMContainer, cacheDir: URL, recorder: any TranscriptRecorder = InMemoryRecorder(),
        pool: ModelPool = ModelPool()
    ) -> Router {
        Router(
            cacheDir: cacheDir,
            recorder: recorder,
            probe: StubProbe(chip: "Apple Test", totalRAM: 64 << 30, recommendedMaxWorkingSetSize: 48 << 30),
            metadataSource: StubMetadataSource(raw: rawMetadata),
            loader: StubModelLoader(container: container, dimension: stubDimension),
            pool: pool
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
        // Every String-output tool arrives wrapped in the mount layer;
        // the shape assertion peels it to reach the threaded originals.
        let innerTools = container.lastTools.compactMap(mountWrapped)
        #expect(innerTools.contains { $0 is AmbientEventPostingTool })
        #expect(innerTools.contains { $0 is PlainTool })
    }

    @Test("the container receives the original tool instance itself, wrapped in the session's own mount layer")
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
        // routing lives entirely in the mount wrapper's ambient
        // `ToolContext`.
        let inner = try #require(mountWrapped(container.lastTools.first) as? AmbientEventPostingTool)
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

        // No wiring call appears anywhere in this test — the mount
        // layer `makeSession(tools:)` composed binds the ambient
        // `ToolContext` (carrying this session's own outbox) around the
        // call, so the tool's post lands there.
        let mounted = try #require(
            failureDeliveryPeeled(container.lastTools.first) as? RunToCompletionRunner<AmbientToolArguments>)
        _ = try await mounted.call(arguments: AmbientToolArguments(value: "auto-routed"))

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

        let mixedInnerTools = container.lastTools.compactMap(mountWrapped)
        let instancedPlain = try #require(mixedInnerTools.first(where: { $0 is PlainTool }) as? PlainTool)
        let ambientMounted = try #require(
            failureDeliveryPeeled(container.lastTools.first(where: {
                mountWrapped($0) is AmbientEventPostingTool
            })) as? RunToCompletionRunner<AmbientToolArguments>)

        // The ambient tool's events still route to this session's own
        // outbox despite sharing the list with a plain tool.
        _ = try await ambientMounted.call(arguments: AmbientToolArguments(value: "still works"))
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
        let bound = try #require(
            failureDeliveryPeeled(container.lastTools.first)
                as? ContextBindingTool<AmbientToolArguments, NonStringToolOutput>)
        let first = try await bound.call(arguments: AmbientToolArguments(value: "first"))
        let second = try await bound.call(arguments: AmbientToolArguments(value: "second"))

        let events = await session.outbox.pending().events.map(\.event)
        #expect(events.map(\.detail) == ["first", "second"])
        #expect(events.map(\.tool) == [emitter.name, emitter.name])
        #expect(events.map(\.op) == [emitter.name, emitter.name])
        // Each call minted its own completionToken — the correlationID the
        // tool's own ambient posts carried, run scope, never submission scope.
        #expect(events.map(\.correlationID) == [first.text, second.text])
        #expect(first.text != second.text)
    }

    @Test(
        "inside a real respond submission, a non-String-output tool's per-call binding shadows the submission-scope binding: its posts carry its own identity and token, never session/respond or the submission's token"
    )
    @MainActor
    func nonStringToolPerCallBindingShadowsSubmissionScopeBindingInsideRespond() async throws {
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
        let submissionToken = try #require(backend.observedSubmissionTokens.first ?? nil)

        // The tool ran under a live submission-scope binding, and its own
        // per-call binding shadowed it: the posted event carries the
        // tool's identity and its call's own freshly minted token — never
        // the submission binding's "session"/"respond" stamps or the submission's
        // completionToken (the exact fallback this task removes).
        let events = await session.outbox.pending().events.map(\.event)
        #expect(events.map(\.detail) == [ToolInvokingBackend.nonStringInvocationDetail])
        #expect(events.map(\.tool) == [emitter.name])
        #expect(events.map(\.op) == [emitter.name])
        #expect(events.map(\.correlationID) == [perCallToken])
        #expect(perCallToken != submissionToken)
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
        #expect(session.outbox.queue.pending.isEmpty)
    }

    // MARK: - Fork behavior: fresh-per-session outbox, fork-then-mount tool composition

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

        let parentActor = try #require(session as? RoutedSessionActor)
        let childActor = try #require(child as? RoutedSessionActor)
        let parentMounted = try #require(
            failureDeliveryPeeled(parentActor.tools.first) as? RunToCompletionRunner<AmbientToolArguments>)
        let childMounted = try #require(
            failureDeliveryPeeled(childActor.tools.first) as? RunToCompletionRunner<AmbientToolArguments>)
        // Both sessions share the very same underlying tool instance —
        // per-session isolation lives entirely in each session's own
        // mount wrapper and the ambient context it binds per call.
        #expect(mountWrapped(parentMounted) as? AmbientEventPostingTool === emitter)
        #expect(mountWrapped(childMounted) as? AmbientEventPostingTool === emitter)

        // Concurrently call through each session's own composed wrapper —
        // event delivery must never migrate between the two outboxes.
        async let parentCall = parentMounted.call(arguments: AmbientToolArguments(value: "from-parent"))
        async let childCall = childMounted.call(arguments: AmbientToolArguments(value: "from-child"))
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

        let (parentBound, childBound) = try Self.boundPair(of: session, and: child)
        // Both sessions share the very same underlying tool instance —
        // per-session isolation lives entirely in each session's own
        // binding wrapper and the ambient context it binds per call.
        #expect(mountWrapped(parentBound) as? AmbientNonStringOutputTool === emitter)
        #expect(mountWrapped(childBound) as? AmbientNonStringOutputTool === emitter)

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

        let (parentBound, childBound) = try Self.boundPair(of: session, and: child)
        // Both sessions share the very same underlying tool instance —
        // per-session isolation lives entirely in each session's own
        // binding wrapper and the ambient context it binds per call.
        #expect(mountWrapped(parentBound) as? AmbientNonStringOutputTool === emitter)
        #expect(mountWrapped(childBound) as? AmbientNonStringOutputTool === emitter)

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

    /// The binding-only wrapper of the first tool of the parent and of the
    /// fork, the shape that both fork tests over
    /// ``AmbientNonStringOutputTool`` read.
    ///
    /// - Parameters:
    ///   - parent: The parent session.
    ///   - child: The fork of `parent`.
    /// - Returns: The wrapper of the parent and the wrapper of the fork.
    /// - Throws: When a session is not a ``RoutedSessionActor``, or when its
    ///   first tool is not a ``ContextBindingTool``.
    private static func boundPair(
        of parent: any RoutedSession, and child: any RoutedSession
    ) throws -> (
        parent: ContextBindingTool<AmbientToolArguments, NonStringToolOutput>,
        child: ContextBindingTool<AmbientToolArguments, NonStringToolOutput>
    ) {
        let parentActor = try #require(parent as? RoutedSessionActor)
        let childActor = try #require(child as? RoutedSessionActor)
        let parentBound = try #require(
            failureDeliveryPeeled(parentActor.tools.first)
                as? ContextBindingTool<AmbientToolArguments, NonStringToolOutput>)
        let childBound = try #require(
            failureDeliveryPeeled(childActor.tools.first)
                as? ContextBindingTool<AmbientToolArguments, NonStringToolOutput>)
        return (parentBound, childBound)
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

        let parentActor = try #require(session as? RoutedSessionActor)
        let capturedMounted = try #require(
            failureDeliveryPeeled(parentActor.tools.first) as? RunToCompletionRunner<AmbientToolArguments>)

        // Stands in for a background task that captured the composed tool at
        // operation start, before any fork happened.
        let child = try await session.fork(workingDirectory: nil)

        _ = try await capturedMounted.call(arguments: AmbientToolArguments(value: "captured-before-fork"))
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

        let parentActor = try #require(session as? RoutedSessionActor)
        let childActor = try #require(child as? RoutedSessionActor)

        let parentInnerTools = parentActor.tools.compactMap(mountWrapped)
        let childInnerTools = childActor.tools.compactMap(mountWrapped)
        let parentForkable = try #require(
            parentInnerTools.first(where: { $0 is ForkableAmbientTool }) as? ForkableAmbientTool)
        let childForkable = try #require(
            childInnerTools.first(where: { $0 is ForkableAmbientTool }) as? ForkableAmbientTool)
        // The parent's own instance is untouched; the child's is the result
        // of `forked()` — a distinct, incremented-generation instance, not
        // the original passed to `makeSession(tools:)`.
        #expect(parentForkable.generation == 0)
        #expect(childForkable.generation == 1)
        #expect(childForkable !== forkable)

        // Calling the forked tool through the child's own mount wrapper
        // posts to the child's own outbox.
        let childForkableMounted = try #require(
            failureDeliveryPeeled(childActor.tools.first(where: {
                mountWrapped($0) is ForkableAmbientTool
            })) as? RunToCompletionRunner<AmbientToolArguments>)
        _ = try await childForkableMounted.call(arguments: AmbientToolArguments(value: "from-forked-tool"))
        let childPending = await child.outbox.pending()
        #expect(childPending.events.map(\.event.detail) == ["from-forked-tool"])

        // The plain tool has no `ForkableTool` conformance at all — it passes
        // through shared, unchanged, into the child's tool list.
        let childPlain = try #require(childInnerTools.first(where: { $0 is PlainTool }) as? PlainTool)
        let output = try await childPlain.call(arguments: FakeToolArguments(value: "y"))
        #expect(output == "plain: y")
    }

    @Test(
        "fork threads the child's fork-then-mount composed tools into the backend's makeFork(tools:) — the model-facing session, not just the actor's own bookkeeping list"
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
        let rootBackend = try #require(container.lastBackend)

        let child = try await session.fork(workingDirectory: nil)

        // `rootBackend` is the actual backend `RoutedSessionActor.fork()` calls
        // `makeFork(tools:)` on — asserting on `lastForkTools` here proves the
        // child's fork-then-mount composed tool list is what actually
        // reached the model-facing backend construction seam, not just the
        // fork's own actor-level bookkeeping array.
        #expect(rootBackend.lastForkTools.count == 1)
        let forkedMountedAtBackend = try #require(
            failureDeliveryPeeled(rootBackend.lastForkTools.first) as? RunToCompletionRunner<AmbientToolArguments>)
        #expect(mountWrapped(forkedMountedAtBackend) as? AmbientEventPostingTool === emitter)

        // Calling through the exact wrapper the backend received posts to
        // the child's own outbox — confirming it is genuinely the
        // child-composed wrapper, not a passthrough of the parent's.
        _ = try await forkedMountedAtBackend.call(
            arguments: AmbientToolArguments(value: "from-backend-threaded-tool"))
        let childPending = await child.outbox.pending()
        #expect(childPending.events.map(\.event.detail) == ["from-backend-threaded-tool"])
        let parentPending = await session.outbox.pending()
        #expect(parentPending.events.isEmpty)
    }

    // MARK: - Mount layer: per-site chain order (task ^k4nygqa)

    @Test("makeSession composes mount → cap: capping outermost, mount layer inside it, the original tool innermost")
    @MainActor
    func makeSessionComposesMountCap() async throws {
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

        let capping = try #require(
            failureDeliveryPeeled(container.lastTools.first) as? TokenCappingTool<AmbientToolArguments>)
        let mounting = try #require(capping.wrapped as? RunToCompletionRunner<AmbientToolArguments>)
        let inner = try #require(mounting.wrapped as? AmbientEventPostingTool)
        #expect(inner === emitter)

        // Calling through the full chain still routes the tool's
        // ambient-context event to this session's own outbox.
        _ = try await capping.call(arguments: AmbientToolArguments(value: "chain-inner"))
        let pending = await session.outbox.pending()
        #expect(pending.events.map(\.event.detail) == ["chain-inner"])
    }

    @Test("makeSession without a budget composes mount only: mount layer outermost, no capping layer")
    @MainActor
    func makeSessionWithoutBudgetComposesMountOnly() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let container = ToolCapturingLLMContainer()
        let router = Self.makeRouter(container: container, cacheDir: dir)
        let profile = try await router.resolve(profile: Self.profile, reporting: ResolutionProgress())

        let emitter = AmbientEventPostingTool()
        let session = profile.standard.makeSession(tools: [emitter])

        #expect(!(failureDeliveryPeeled(container.lastTools.first) is TokenCappingTool<AmbientToolArguments>))
        let mounting = try #require(
            failureDeliveryPeeled(container.lastTools.first) as? RunToCompletionRunner<AmbientToolArguments>)
        let inner = try #require(mounting.wrapped as? AmbientEventPostingTool)
        #expect(inner === emitter)

        _ = try await mounting.call(arguments: AmbientToolArguments(value: "uncapped-chain-inner"))
        let pending = await session.outbox.pending()
        #expect(pending.events.map(\.event.detail) == ["uncapped-chain-inner"])
    }

    @Test("fork composes fork → mount → cap: capping outermost, mount layer inside, the forked instance innermost")
    @MainActor
    func forkComposesForkMountCap() async throws {
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

        let childActor = try #require(child as? RoutedSessionActor)
        let capping = try #require(
            failureDeliveryPeeled(childActor.tools.first) as? TokenCappingTool<AmbientToolArguments>)
        let mounting = try #require(capping.wrapped as? RunToCompletionRunner<AmbientToolArguments>)
        let forkedInner = try #require(mounting.wrapped as? ForkableAmbientTool)
        // `forked()` ran before the child's mount layer wrapped it: the
        // innermost instance is the next generation.
        #expect(forkedInner.generation == 1)
        _ = try await capping.call(arguments: AmbientToolArguments(value: "fork-chain-inner"))
        let childPending = await child.outbox.pending()
        #expect(childPending.events.map(\.event.detail) == ["fork-chain-inner"])
    }

    @Test("fork without a budget composes fork → mount: mount layer outermost, no capping layer")
    @MainActor
    func forkWithoutBudgetComposesForkMountOnly() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let container = ToolCapturingLLMContainer()
        let router = Self.makeRouter(container: container, cacheDir: dir)
        let profile = try await router.resolve(profile: Self.profile, reporting: ResolutionProgress())

        let forkable = ForkableAmbientTool()
        let session = profile.standard.makeSession(tools: [forkable])
        let child = try await session.fork(workingDirectory: nil)

        let childActor = try #require(child as? RoutedSessionActor)
        #expect(!(failureDeliveryPeeled(childActor.tools.first) is TokenCappingTool<AmbientToolArguments>))
        let mounting = try #require(
            failureDeliveryPeeled(childActor.tools.first) as? RunToCompletionRunner<AmbientToolArguments>)
        let forkedInner = try #require(mounting.wrapped as? ForkableAmbientTool)
        // `forked()` ran before the child's mount layer wrapped it: the
        // innermost instance is the next generation — the same fork →
        // mount order as the with-budget case, just with no cap layer
        // anywhere in the chain.
        #expect(forkedInner.generation == 1)
        _ = try await mounting.call(arguments: AmbientToolArguments(value: "uncapped-fork-chain-inner"))
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
        // never cap(bind(tool)) (see ``ToolMounting/makeSessionMounted``).
        // The no-cap check below is type-guaranteed for a non-String
        // output (``TokenCappingTool`` wraps only `Tool<Arguments, String>`)
        // — it documents the shape; the load-bearing chain proof is
        // `wrapped` being the original instance directly.
        #expect(!(failureDeliveryPeeled(container.lastTools.first) is TokenCappingTool<AmbientToolArguments>))
        let bound = try #require(
            failureDeliveryPeeled(container.lastTools.first)
                as? ContextBindingTool<AmbientToolArguments, NonStringToolOutput>)
        let inner = try #require(bound.wrapped as? AmbientNonStringOutputTool)
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

        let childActor = try #require(child as? RoutedSessionActor)
        // The same bind-only chain as the root site at every budget level:
        // capping has no String output to truncate, and the fixture is not
        // ForkableTool, so the very same instance passes through shared
        // into the child's own binding layer.
        // The no-cap check below is type-guaranteed for a non-String
        // output (``TokenCappingTool`` wraps only `Tool<Arguments, String>`)
        // — it documents the shape; the load-bearing chain proof is
        // `wrapped` being the original instance directly.
        #expect(!(failureDeliveryPeeled(childActor.tools.first) is TokenCappingTool<AmbientToolArguments>))
        let childBound = try #require(
            failureDeliveryPeeled(childActor.tools.first)
                as? ContextBindingTool<AmbientToolArguments, NonStringToolOutput>)
        let childInner = try #require(childBound.wrapped as? AmbientNonStringOutputTool)
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

    // MARK: - Background-run behavior through a session's composed tool list

    @Test(
        "a slow background tool returns the pending envelope, and its later .completed rides the next submission's preamble and lands as a durable OperationEventSegment"
    )
    @MainActor
    func backgroundSlowToolCompletionRidesNextSubmission() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let container = ToolCapturingLLMContainer()
        let recorder = InMemoryRecorder()
        let router = Self.makeRouter(container: container, cacheDir: dir, recorder: recorder)
        let profile = try await router.resolve(profile: Self.profile, reporting: ResolutionProgress())

        let gate = RunLatch()
        defer { await gate.open() }
        let session = profile.standard.makeSession(tools: [GatedBackgroundToolRunner(gate: gate)])
        let backend = try #require(container.lastBackend)
        let mounted = try #require(
            failureDeliveryPeeled(container.lastTools.first) as? BackgroundToolRunner<FakeToolArguments>)

        // The tool declared background, so the model-facing call returns
        // the pending envelope on the wire at once.
        let rendered = try await mounted.call(arguments: FakeToolArguments(value: "slow"))
        let envelope = try JSONDecoder().decode(PendingRunEnvelope.self, from: Data(rendered.utf8))
        #expect(envelope.pending)

        // Let the background run finish; its synthesized `.completed` funnels
        // into this session's own outbox. The funnel of the run stages the
        // terminal in the outbox before the run plane settles the run, so
        // after the settlement one read of the outbox finds it.
        await gate.open()
        _ = try await MountFixtures.settledTerminal(of: envelope.completionToken, in: session.runPlane)
        let pendingEvents = await session.outbox.pending().events.map(\.event)
        let completed = try #require(pendingEvents.first { $0.kind == .completed })
        #expect(completed.correlationID == envelope.completionToken)
        #expect(completed.detail == "gated: slow")

        // The next submission drains it: the composed prompt the backend receives
        // carries the preamble line, and the recorded `.prompt` entry
        // carries the same event as a durable OperationEventSegment.
        _ = try await session.respond(to: "follow-up")
        let expectedLine = OperationEventSegment.renderedLine(for: completed)
        let composed = try #require(backend.receivedPrompts.last)
        #expect(composed.contains(expectedLine))
        #expect(composed.hasSuffix("\n\nfollow-up"))

        let events = await recorder.events
        let promptEvent = try #require(events.last { $0.kind == .prompt })
        // The delivered run mail is a mail record on the `.prompt` entry. The
        // public reader gives its run event.
        let journaled = promptEvent.operationEvents
        #expect(journaled.contains { $0.kind == .completed && $0.correlationID == envelope.completionToken })
    }

    @Test("a fork's tracked background run lives in the fork's own run plane. The run plane of the parent does not change")
    @MainActor
    func forkBackgroundRunLivesInForkRunPlane() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let container = ToolCapturingLLMContainer()
        let router = Self.makeRouter(container: container, cacheDir: dir)
        let profile = try await router.resolve(profile: Self.profile, reporting: ResolutionProgress())

        let gate = RunLatch()
        defer { await gate.open() }
        let session = profile.standard.makeSession(tools: [GatedBackgroundToolRunner(gate: gate)])
        let child = try await session.fork(workingDirectory: nil)

        let childActor = try #require(child as? RoutedSessionActor)
        let childMounted = try #require(
            failureDeliveryPeeled(childActor.tools.first) as? BackgroundToolRunner<FakeToolArguments>)

        let rendered = try await childMounted.call(arguments: FakeToolArguments(value: "forked"))
        let envelope = try JSONDecoder().decode(PendingRunEnvelope.self, from: Data(rendered.utf8))
        #expect(envelope.pending)

        let childTokens = await child.runPlane.backgroundRuns().map(\.completionToken)
        #expect(childTokens == [envelope.completionToken])
        let parentRuns = await session.runPlane.backgroundRuns()
        #expect(parentRuns.isEmpty)

        // Settle the background run so no background work outlives the test.
        await gate.open()
        _ = try await MountFixtures.settledTerminal(of: envelope.completionToken, in: child.runPlane)
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
        defer { await gate.open() }
        // toolOutputLimit 5 is far below the envelope's own estimated size:
        // real tool output at this cap is truncated, but the envelope —
        // control-plane data whose completionToken the model must keep —
        // must pass through untouched.
        let session = profile.standard.makeSession(
            tools: [GatedBackgroundToolRunner(gate: gate)],
            budget: Self.budgetWithSmallToolOutputCap
        )

        let capping = try #require(
            failureDeliveryPeeled(container.lastTools.first) as? TokenCappingTool<FakeToolArguments>)
        let rendered = try await capping.call(arguments: FakeToolArguments(value: "capped-slow"))
        let envelope = try JSONDecoder().decode(PendingRunEnvelope.self, from: Data(rendered.utf8))
        #expect(envelope.pending)
        #expect(ULID(envelope.completionToken) != nil)
        // Byte-for-byte what the mount layer rendered: the capping
        // decorator still recognizes the envelope's wire form, so neither the
        // completionToken nor the next-step instruction it carries is
        // truncated away.
        #expect(rendered == PendingRunEnvelope(completionToken: envelope.completionToken).rendered)
        #expect(PendingRunEnvelope.isRendered(text: rendered))

        // Settle the background run so no background work outlives the test.
        await gate.open()
        _ = try await MountFixtures.settledTerminal(of: envelope.completionToken, in: session.runPlane)
    }

    @Test(
        "cancelling an answer backgrounds an in-flight tool call: it is tracked in the session's run plane and later settles normally, never dying with the answer"
    )
    @MainActor
    func cancellingAnAnswerBackgroundsInFlightToolCall() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // The answer hold keeps the answer in flight after the tool returns.
        // The background tool hands its call back at once, so with no hold
        // the answer ends before the test can stop it.
        let answerHold = RunLatch()
        let container = ToolInvokingLLMContainer(answerHold: answerHold)
        let router = Self.makeRouter(container: container, cacheDir: dir)
        let profile = try await router.resolve(profile: Self.profile, reporting: ResolutionProgress())

        let gate = RunLatch()
        defer {
            await answerHold.open()
            await gate.open()
        }
        let session = profile.standard.makeSession(tools: [GatedBackgroundToolRunner(gate: gate)])
        let backend = try #require(container.lastBackend)

        // Drive an answer whose backend invokes the composed background tool,
        // then stop the answer while the run of that tool is in flight. The
        // tool declared background, so the call is handed back as a token
        // with or without the stop. This test proves what the stop does NOT
        // do: it does not kill the background run.
        let answerEnds = RunCount()
        let answer = Task {
            defer {
                answerEnds.increment()
                backend.changes.signal()
            }
            return try await session.respond(to: "cancel me")
        }
        // The backend signals its change after the tool call handed back
        // its envelope. Rule T1: the wait also ends when the answer ended.
        // The answer hold keeps the answer open after the tool call
        // returned, so in a test that passes the answer cannot end first.
        try await backend.changes.wait(until: { backend.toolCallReturned }, endingOn: { answerEnds.value > 0 })
        #expect(backend.toolCallStarted)
        // Only the stop of the running answer: a cancelAll would also sweep
        // the background runs, and this test proves that the stop of the
        // answer leaves the run alive. The answer hold keeps the answer in
        // flight, so the pump runs the work of the answer now.
        #expect(await session.stopRunningWork())

        // The run was tracked in this session's run plane, and it is still running
        // with the answer stopped. Read the run plane here, before the gate
        // opens: after the run settles, the run plane forgets it, and a read
        // then says nothing about what the stop did. The run plane tracks
        // the run before the call hands back its envelope, and the gate is
        // closed, so one read finds the run.
        let trackedTokens = await session.runPlane.backgroundRuns().map(\.completionToken)
        #expect(!trackedTokens.isEmpty)

        // Release the stopped answer, so that its caller finishes. Then the
        // background run, which outlived the stopped answer with no cancel,
        // settles as a normal success when the gate opens.
        await answerHold.open()
        _ = try? await answer.value
        await gate.open()

        // The tool call answered with the pending envelope, not a
        // CancellationError, and that envelope's token is the run that was
        // tracked.
        let rendered = try #require(backend.renderedToolOutputs.first)
        let envelope = try JSONDecoder().decode(PendingRunEnvelope.self, from: Data(rendered.utf8))
        #expect(envelope.pending)
        #expect(trackedTokens == [envelope.completionToken])

        let terminal = try await MountFixtures.settledTerminal(of: envelope.completionToken, in: session.runPlane)
        #expect(terminal.outcome == .succeeded)
        #expect(terminal.detail == "gated: cancel me")
    }

    // MARK: - The run signals a background run owes the model (task ^ftdmr58)

    /// Vends a session over a fresh ``BackgroundingLLMContainer`` mounting
    /// `tools`, and hands back the backend that drives it.
    ///
    /// - Parameters:
    ///   - tools: The tools the session mounts.
    ///   - dir: The temporary directory the router caches under.
    /// - Returns: The session and its backend.
    private static func makeBackgroundingSession(
        tools: [any Tool], dir: URL
    ) async throws -> (session: any RoutedSession, backend: BackgroundingBackend) {
        let container = BackgroundingLLMContainer()
        let router = makeRouter(container: container, cacheDir: dir)
        let profile = try await router.resolve(profile: profile, reporting: ResolutionProgress())
        let session = profile.standard.makeSession(tools: tools)
        let backend = try #require(container.lastBackend)
        return (session, backend)
    }

    /// Opens `gate` and waits, with no deadline, for every run tracked on
    /// `session` to settle.
    ///
    /// - Parameters:
    ///   - session: The session whose runs are settled.
    ///   - gate: The latch the runs' bodies wait on.
    private static func settleBackgroundRuns(on session: any RoutedSession, opening gate: RunLatch) async {
        let tokens = await session.runPlane.backgroundRuns().map(\.completionToken)
        await gate.open()
        for token in tokens {
            _ = await session.runPlane.wait(completionToken: token, seconds: nil)
        }
    }

    @Test("signal 1, I started: the pending envelope is what the tool call hands the model, and it names the run tracked on the session")
    @MainActor
    func startedSignalReachesTheModelAsThePendingEnvelope() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let gate = RunLatch()
        let (session, backend) = try await Self.makeBackgroundingSession(
            tools: [LatchedBackgroundToolRunner(name: "job", gate: gate, output: "job done")], dir: dir)
        defer { await Self.settleBackgroundRuns(on: session, opening: gate) }

        for try await _ in await session.streamEvents(to: "start the job") {}

        let rendered = try #require(backend.toolOutputs.first)
        let envelope = try JSONDecoder().decode(PendingRunEnvelope.self, from: Data(rendered.utf8))
        #expect(envelope.pending)
        #expect(await session.runPlane.backgroundRuns().map(\.completionToken) == [envelope.completionToken])
    }

    @Test("signal 2, I am making progress: a progress report updates the run's latest detail and rides the next submission's preamble")
    @MainActor
    func progressSignalReachesTheModel() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let gate = RunLatch()
        let reported = RunLatch()
        let (session, backend) = try await Self.makeBackgroundingSession(
            tools: [ProgressReportingBackgroundToolRunner(gate: gate, reported: reported)], dir: dir)
        defer { await Self.settleBackgroundRuns(on: session, opening: gate) }

        for try await _ in await session.streamEvents(to: "start the job") {}

        // The report lands on the run plane and in the staging area. The
        // post of the report returns only after both, and the tool opens
        // `reported` after the post returned.
        //
        // Rule T1: the wait also ends when the run settled. The tool waits
        // on its gate after it opened `reported`, so in a test that passes
        // the run cannot settle first. A run that settles with no report
        // ends the wait, and the checks below then fail.
        let envelope = try JSONDecoder().decode(
            PendingRunEnvelope.self, from: Data(try #require(backend.toolOutputs.first).utf8))
        let runEnd = Task {
            _ = await session.runPlane.wait(completionToken: envelope.completionToken, seconds: nil)
            await reported.open()
        }
        await reported.waitUntilOpen()
        #expect(await session.outbox.pending().events.contains { $0.event.kind == .progress })
        let run = try #require(await session.runPlane.backgroundRuns().first)
        #expect(run.latestProgressDetail == ProgressReportingBackgroundToolRunner.progressDetail)

        // The next submission carries it to the model.
        _ = try await session.respond(to: "how is it going?")
        let progress = OperationEvent(
            tool: run.tool, op: run.op, correlationID: run.completionToken,
            kind: .progress, detail: ProgressReportingBackgroundToolRunner.progressDetail)
        let composed = try #require(backend.receivedPrompts.last)
        #expect(composed.contains(OperationEventSegment.renderedLine(for: progress)))
        await gate.open()
        await runEnd.value
    }

    @Test(
        "signal 3, I need to elicit: the question reaches the model and the host, only that run suspends, and the answer resumes it"
    )
    @MainActor
    func elicitationSignalReachesTheModelAndTheAnswerResumesTheRun() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let elicitationId = ULID.generate()
        let (session, backend) = try await Self.makeBackgroundingSession(
            tools: [ElicitingBackgroundToolRunner(elicitationId: elicitationId)], dir: dir)
        let feed = await SessionEventLog.watch(session)
        defer { feed.drain.cancel() }

        let responding = Task { try await session.respond(to: "start the job") }

        // The question is staged for the model, addressed by its own id. The
        // outbox stages the question before the session sends
        // `.elicitationRequested` on its feed.
        //
        // Rule T1: the wait also ends at the settle of a run. The run waits
        // for the answer of its question, so in a test that passes no run
        // settles before the question. A run that settles with no question
        // ends the wait, and the `#require` of the staged question then
        // fails.
        try await feed.log.wait(until: { events in
            events.contains { event in
                SessionEventCase.elicitationRequested.matches(event) || SessionEventCase.runSettled.matches(event)
            }
        })
        let staged = try #require(await session.outbox.pending().events.first { $0.event.kind == .elicitation }?.event)
        #expect(staged.elicitation?.elicitationId == elicitationId)

        // Only the run suspends: the session still runs a submission while the
        // question is pending, and that submission carries the question.
        _ = try await session.respond(to: "status?")
        let composed = try #require(backend.receivedPrompts.last)
        #expect(composed.contains(OperationEventSegment.renderedLine(for: staged)))

        // The answer resumes the run, which settles with what the user chose.
        // Its terminal is mail: the pump delivers it to the model in a
        // submission (task ^3qx0mpt).
        #expect(await session.respond(elicitationId: elicitationId.description, response: .accept(content: nil)) == .delivered)
        _ = try await responding.value
        try await backend.changes.wait(until: {
            backend.receivedPrompts.contains { $0.contains("answered: accept") }
        })
        // A delivered answer is also elicitation-answer mail, so the model
        // reads the answer of the user in a prompt too.
        let answerLine = "[answer to elicitation \(elicitationId.ulidString)] accept"
        try await backend.changes.wait(until: {
            backend.receivedPrompts.contains { $0.contains(answerLine) }
        })
    }
}
