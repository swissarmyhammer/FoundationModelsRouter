import Foundation
import FoundationModels
import FoundationModelsRouterTestSupport
import Testing

@testable import FoundationModelsRouter

/// Exercises task 1334fk3: ``TokenBudget/toolOutputLimit`` and the capping it
/// drives in Router's own tool-instancing pipeline
/// (``RoutedModel/makeSession(instructions:workingDirectory:recordingRoot:tools:budget:compactionPrompt:summarization:agentSpawn:discoveryPriming:toolOutputProtection:)``/
/// ``RoutedSessionActor/fork(workingDirectory:)``) — ``ToolOutputCapping``'s
/// truncation rule and dynamic wrapping, plus the wiring that threads a
/// capped tool to the model-facing container/backend boundary exactly the
/// way `SessionOutboxToolWiringTests` proves for the mount layer and
/// `ForkableTool`.
///
/// Everything runs against stubs — no MLX, no network, no GPU.
@Suite("TokenBudget.toolOutputLimit: ToolOutputCapping truncation and tool-instancing wiring")
struct ToolOutputCappingTests {
    // MARK: - Test tools

    @Generable
    struct FakeToolArguments {
        let value: String
    }

    /// A plain `String`-output `Tool` returning a fixed canned string,
    /// regardless of `arguments` — the common shape ``ToolOutputCapping``
    /// caps.
    private struct StringOutputTool: Tool {
        let name = "string-tool"
        let description = "returns a fixed string"
        let output: String

        func call(arguments: FakeToolArguments) async throws -> String {
            output
        }
    }

    /// A non-`String`-output `Tool` — proves ``ToolOutputCapping/makeWrapped(tool:toTokenLimit:counter:)``
    /// passes a tool through unchanged when its `Output` cannot be
    /// generically recovered and re-truncated as text.
    private struct NonStringOutput: PromptRepresentable, Sendable {
        let text: String
        var promptRepresentation: Prompt { Prompt(text) }
    }

    private struct NonStringOutputTool: Tool {
        let name = "non-string-tool"
        let description = "returns a non-String PromptRepresentable"

        func call(arguments: FakeToolArguments) async throws -> NonStringOutput {
            NonStringOutput(text: "ignored")
        }
    }

    // MARK: - The counter and the sizes the truncation tests state

    /// The counter every cap in this suite is measured with: one token per
    /// `Character`. A tool output of N characters is N tokens, and the kept
    /// prefix of a cut output is its first `limit` characters.
    private static let counter = CharacterTokenCounter()

    /// The token limit the truncation tests cap at.
    private static let truncationLimit = 5

    /// The length, in characters and so in tokens, of the oversized fixtures
    /// the truncation tests cut: eight times ``truncationLimit``.
    private static let oversizedTextLength = 40

    /// The length of a fixture that stays under ``truncationLimit``.
    private static let shortTextLength = 3

    /// How many emoji the multi-byte fixture holds. Each emoji is four UTF-8
    /// bytes and one `Character`, so the fixture is ten tokens.
    private static let multiByteFixtureLength = 10

    /// A limit that keeps nothing: zero.
    private static let emptyingLimit = 0

    /// A limit no fixture in this suite reaches, for the tests that show an
    /// output under its limit passes untouched.
    private static let generousLimit = 100

    /// The `toolOutputLimit` the acceptance tests apply: 1,500 tokens, the
    /// figure the task card states.
    private static let acceptanceLimit = 1_500

    // MARK: - ToolOutputCapping.capped(text:toTokenLimit:counter:)

    @Test("capped(text:toTokenLimit:counter:) returns text unchanged when its token count is under the limit")
    func cappedLeavesShortTextUnchanged() {
        // 3 characters are 3 tokens under this counter, under a limit of 5.
        let text = String(repeating: "a", count: Self.shortTextLength)
        #expect(ToolOutputCapping.capped(text: text, toTokenLimit: Self.truncationLimit, counter: Self.counter) == text)
    }

    @Test("capped(text:toTokenLimit:counter:) returns text unchanged when its token count exactly equals the limit")
    func cappedLeavesExactlyAtLimitTextUnchanged() {
        // 5 characters are 5 tokens, exactly the limit.
        let text = String(repeating: "a", count: Self.truncationLimit)
        #expect(ToolOutputCapping.capped(text: text, toTokenLimit: Self.truncationLimit, counter: Self.counter) == text)
    }

    @Test("capped(text:toTokenLimit:counter:) truncates oversized text and appends an explicit marker naming kept and original token counts")
    func cappedTruncatesOversizedTextWithMarker() {
        // 40 characters are 40 tokens. A limit of 5 keeps the first 5
        // characters, and the marker states 5 of 40.
        let text = String(repeating: "b", count: Self.oversizedTextLength)
        let result = ToolOutputCapping.capped(text: text, toTokenLimit: Self.truncationLimit, counter: Self.counter)

        let expectedKept = String(repeating: "b", count: Self.truncationLimit)
        #expect(Self.counter.count(expectedKept) == Self.truncationLimit)
        #expect(result == "\(expectedKept)… [truncated: \(Self.truncationLimit) of \(Self.oversizedTextLength) tokens]")
    }

    @Test("capped(text:toTokenLimit:counter:) never grows the returned text beyond the original plus its marker")
    func cappedNeverGrowsBeyondOriginal() {
        let text = String(repeating: "c", count: Self.oversizedTextLength)
        let marker = "… [truncated: \(Self.truncationLimit) of \(Self.oversizedTextLength) tokens]"
        let result = ToolOutputCapping.capped(text: text, toTokenLimit: Self.truncationLimit, counter: Self.counter)
        #expect(Self.counter.count(result) <= Self.counter.count(text) + Self.counter.count(marker))
    }

    @Test("capped(text:toTokenLimit:counter:) cuts multi-byte (non-ASCII) text on whole characters, the unit its counter counts")
    func cappedTruncatesMultiByteTextOnWholeCharacters() {
        // Each "🎉" is 4 UTF-8 bytes and one Character, so ten of them are
        // ten tokens under this counter. The cut keeps what the counter
        // decodes back, never a byte count, so it never splits a character.
        let text = String(repeating: "🎉", count: Self.multiByteFixtureLength)
        let result = ToolOutputCapping.capped(text: text, toTokenLimit: Self.truncationLimit, counter: Self.counter)

        // A limit of 5 tokens keeps exactly 5 whole emoji, never the whole
        // 10-emoji original.
        let expectedKept = String(repeating: "🎉", count: Self.truncationLimit)
        let marker = "… [truncated: \(Self.truncationLimit) of \(Self.multiByteFixtureLength) tokens]"
        #expect(result == "\(expectedKept)\(marker)")

        // Truncation must actually have happened: never the whole original
        // text with a marker bolted on top.
        #expect(result != text + marker)
    }

    @Test("capped(text:toTokenLimit:counter:) returns an empty prefix for a non-positive limit, still marking the truncation")
    func cappedWithNonPositiveLimitReturnsEmptyPrefix() {
        let text = String(repeating: "z", count: Self.oversizedTextLength)
        let result = ToolOutputCapping.capped(text: text, toTokenLimit: Self.emptyingLimit, counter: Self.counter)
        #expect(result == "… [truncated: \(Self.emptyingLimit) of \(Self.oversizedTextLength) tokens]")
    }

    // MARK: - Acceptance: a toolOutputLimit of 1,500 tokens

    @Test("a tool output of exactly toolOutputLimit tokens passes uncut")
    func aToolOutputAtTheLimitPassesUncut() async throws {
        // The task card's acceptance: a tool output of 1,500 tokens passes a
        // toolOutputLimit of 1,500 uncut. Under this counter that output is
        // 1,500 characters.
        let text = String(repeating: "t", count: Self.acceptanceLimit)
        #expect(Self.counter.count(text) == Self.acceptanceLimit)
        let capping = TokenCappingTool(
            wrapped: StringOutputTool(output: text), limit: Self.acceptanceLimit, counter: Self.counter)

        let result = try await capping.call(arguments: FakeToolArguments(value: "x"))
        #expect(result == text)
    }

    @Test("a tool output one token over toolOutputLimit is cut to the limit, with a marker that states the limit of the original count")
    func aToolOutputOneTokenOverTheLimitIsCutToTheLimit() async throws {
        // The task card's acceptance: a tool output of 1,501 tokens is cut to
        // 1,500 tokens with a marker that states 1,500 of 1,501.
        let text = String(repeating: "t", count: Self.acceptanceLimit + 1)
        #expect(Self.counter.count(text) == Self.acceptanceLimit + 1)
        let capping = TokenCappingTool(
            wrapped: StringOutputTool(output: text), limit: Self.acceptanceLimit, counter: Self.counter)

        let result = try await capping.call(arguments: FakeToolArguments(value: "x"))

        let marker = "… [truncated: 1500 of 1501 tokens]"
        #expect(result.hasSuffix(marker))
        let kept = String(result.dropLast(marker.count))
        #expect(Self.counter.count(kept) == Self.acceptanceLimit)
        #expect(kept == String(repeating: "t", count: Self.acceptanceLimit))
        #expect(result == "\(kept)\(marker)")
    }

    // MARK: - ToolOutputCapping.makeWrapped(tool:toTokenLimit:counter:)

    @Test("makeWrapped(tool:toTokenLimit:counter:) wraps a String-output tool in a TokenCappingTool that caps its call() result")
    func wrappingCapsStringOutputToolCallResult() async throws {
        let text = String(repeating: "d", count: Self.oversizedTextLength)
        let tool = StringOutputTool(output: text)

        let wrapped = ToolOutputCapping.makeWrapped(tool: tool, toTokenLimit: Self.truncationLimit, counter: Self.counter)
        let capping = try #require(wrapped as? TokenCappingTool<FakeToolArguments>)

        let result = try await capping.call(arguments: FakeToolArguments(value: "x"))
        let expectedKept = String(repeating: "d", count: Self.truncationLimit)
        #expect(result == "\(expectedKept)… [truncated: \(Self.truncationLimit) of \(Self.oversizedTextLength) tokens]")
    }

    @Test("makeWrapped(tool:toTokenLimit:counter:) leaves a short String-output tool's result untouched")
    func wrappingLeavesShortStringOutputUnchanged() async throws {
        let tool = StringOutputTool(output: "short")
        let wrapped = ToolOutputCapping.makeWrapped(tool: tool, toTokenLimit: Self.generousLimit, counter: Self.counter)

        let capping = try #require(wrapped as? TokenCappingTool<FakeToolArguments>)
        let result = try await capping.call(arguments: FakeToolArguments(value: "x"))
        #expect(result == "short")
    }

    @Test("makeWrapped(tool:toTokenLimit:counter:) forwards name/description/parameters/includesSchemaInInstructions to the wrapped tool")
    func wrappingForwardsToolMetadata() throws {
        let tool = StringOutputTool(output: "x")
        let wrapped = ToolOutputCapping.makeWrapped(tool: tool, toTokenLimit: Self.truncationLimit, counter: Self.counter)

        let capping = try #require(wrapped as? TokenCappingTool<FakeToolArguments>)
        #expect(capping.name == tool.name)
        #expect(capping.description == tool.description)
        #expect(capping.includesSchemaInInstructions == tool.includesSchemaInInstructions)
    }

    @Test("makeWrapped(tool:toTokenLimit:counter:) passes a non-String-output tool through unchanged")
    func wrappingPassesNonStringOutputToolThroughUnchanged() {
        let tool = NonStringOutputTool()
        let wrapped = ToolOutputCapping.makeWrapped(tool: tool, toTokenLimit: Self.truncationLimit, counter: Self.counter)
        #expect(wrapped is NonStringOutputTool)
    }

    // MARK: - Stub container capturing the threaded tool list

    /// `@unchecked Sendable` invariant: `lastTools` is written only inside
    /// `makeSession(instructions:tools:)`; `lastBackend` is written by both
    /// that method and `makeSession(instructions:)` (required by
    /// `LoadedLLMContainer` — see `ModelLoader.swift` — and, in production,
    /// the entry point `performAutoCompaction`/`runCompaction` calls on the *flash*
    /// tier's container, from `RoutedSessionActor`'s own actor isolation, to
    /// build the compaction summarizer). Both overloads write synchronously
    /// (no `await` between call and write) from whichever context calls
    /// them.
    ///
    /// This suite's `StubModelLoader` always vends the *same*
    /// `ToolCapturingLLMContainer` instance regardless of slot, so a test
    /// that ever exercised `RoutedSession.compact(prompt:budget:)` or
    /// triggered auto-compaction would call `makeSession(instructions:)`
    /// from `RoutedSessionActor`'s isolation — a different context from the
    /// `@MainActor` test body — and this class would need real
    /// synchronization. No test in this suite does that: every test here
    /// only calls `makeSession(tools:budget:)`/`fork(workingDirectory:)`,
    /// both of which drive `makeSession(instructions:tools:)` synchronously
    /// from the `@MainActor` test method, and reads `lastTools`/`lastBackend`
    /// only afterward, from that same method — so every write and every read
    /// this suite actually performs land on the same thread, never
    /// concurrently. A future test that adds `.compact()` coverage against
    /// this container must revisit this invariant.
    private final class ToolCapturingLLMContainer: LoadedLLMContainer, @unchecked Sendable {
        /// The scripted counter of this container: one token per `Character`.
        let tokenCounter: any TokenCounter = CharacterTokenCounter()

        private(set) var lastTools: [any Tool] = []
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
            .appendingPathComponent("ToolOutputCappingTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func makeRouter(container: any LoadedLLMContainer, cacheDir: URL, pool: ModelPool = ModelPool()) -> Router {
        Router(
            cacheDir: cacheDir,
            recorder: InMemoryRecorder(),
            probe: StubProbe(chip: "Apple Test", totalRAM: 64 << 30, recommendedMaxWorkingSetSize: 48 << 30),
            metadataSource: StubMetadataSource(raw: rawMetadata),
            loader: StubModelLoader(container: container, dimension: stubDimension),
            pool: pool
        )
    }

    // MARK: - makeSession(tools:budget:) wiring

    @Test("makeSession(tools:budget:) with toolOutputLimit set threads a capped tool to the container")
    @MainActor
    func makeSessionWithToolOutputLimitThreadsCappedTool() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let container = ToolCapturingLLMContainer()
        let router = Self.makeRouter(container: container, cacheDir: dir)
        let profile = try await router.resolve(profile: Self.profile, reporting: ResolutionProgress())

        let longText = String(repeating: "e", count: 40)
        let tool = StringOutputTool(output: longText)
        _ = profile.standard.makeSession(
            tools: [tool],
            budget: TokenBudget(limit: 4096, toolOutputLimit: 5)
        )

        guard let capping = failureDeliveryPeeled(container.lastTools.first) as? TokenCappingTool<FakeToolArguments>,
            capping.wrapped is RunToCompletionRunner<FakeToolArguments>
        else {
            Issue.record("expected the container to receive a TokenCappingTool wrapping a RunToCompletionRunner")
            return
        }
        let result = try await capping.call(arguments: FakeToolArguments(value: "x"))
        // 40 characters are 40 tokens under the container's counter: the
        // first 5 stay, and the marker states 5 of 40.
        #expect(result == "\(String(repeating: "e", count: 5))… [truncated: 5 of 40 tokens]")
    }

    @Test("makeSession(tools:budget:) with no toolOutputLimit set applies no capping layer — only the mount layer wraps the tool")
    @MainActor
    func makeSessionWithNoToolOutputLimitLeavesToolUnwrapped() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let container = ToolCapturingLLMContainer()
        let router = Self.makeRouter(container: container, cacheDir: dir)
        let profile = try await router.resolve(profile: Self.profile, reporting: ResolutionProgress())

        let tool = StringOutputTool(output: "unchanged")
        _ = profile.standard.makeSession(
            tools: [tool],
            budget: TokenBudget(limit: 4096)
        )

        #expect(!(failureDeliveryPeeled(container.lastTools.first) is TokenCappingTool<FakeToolArguments>))
        #expect((failureDeliveryPeeled(container.lastTools.first) as? RunToCompletionRunner<FakeToolArguments>)?.wrapped is StringOutputTool)
    }

    @Test("makeSession(tools:budget:) with no budget at all applies no capping layer — only the mount layer wraps the tool")
    @MainActor
    func makeSessionWithNoBudgetLeavesToolUnwrapped() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let container = ToolCapturingLLMContainer()
        let router = Self.makeRouter(container: container, cacheDir: dir)
        let profile = try await router.resolve(profile: Self.profile, reporting: ResolutionProgress())

        let tool = StringOutputTool(output: "unchanged")
        _ = profile.standard.makeSession(tools: [tool])

        #expect(!(failureDeliveryPeeled(container.lastTools.first) is TokenCappingTool<FakeToolArguments>))
        #expect((failureDeliveryPeeled(container.lastTools.first) as? RunToCompletionRunner<FakeToolArguments>)?.wrapped is StringOutputTool)
    }

    @Test("makeSession(tools:budget:) caps outermost: the mount layer's ambient event route still reaches the session's outbox through the capped wrapper")
    @MainActor
    func cappingComposesWithAmbientEventRoute() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let container = ToolCapturingLLMContainer()
        let router = Self.makeRouter(container: container, cacheDir: dir)
        let profile = try await router.resolve(profile: Self.profile, reporting: ResolutionProgress())

        let longText = String(repeating: "f", count: 40)
        let tool = AmbientEventPostingTool(output: longText)
        let session = profile.standard.makeSession(
            tools: [tool],
            budget: TokenBudget(limit: 4096, toolOutputLimit: 5)
        )

        guard let capping = failureDeliveryPeeled(container.lastTools.first) as? TokenCappingTool<AmbientToolArguments>,
            let mounting = capping.wrapped as? RunToCompletionRunner<AmbientToolArguments>,
            let inner = mounting.wrapped as? AmbientEventPostingTool
        else {
            Issue.record("expected a TokenCappingTool wrapping the mounted AmbientEventPostingTool")
            return
        }
        #expect(inner === tool)

        // The call result is capped...
        let result = try await capping.call(arguments: AmbientToolArguments(value: "through-capped-wrapper"))
        #expect(result == "\(String(repeating: "f", count: 5))… [truncated: 5 of 40 tokens]")

        // ...and the tool's ambient-context post still reached this
        // session's own outbox through the capped wrapper's inner
        // mount layer.
        let pending = await session.outbox.pending()
        #expect(pending.events.map(\.event.detail) == ["through-capped-wrapper"])
    }

    // MARK: - fork() wiring

    @Test("fork() with an inherited toolOutputLimit caps the child's own tool list too")
    @MainActor
    func forkInheritsToolOutputLimitCapping() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let container = ToolCapturingLLMContainer()
        let router = Self.makeRouter(container: container, cacheDir: dir)
        let profile = try await router.resolve(profile: Self.profile, reporting: ResolutionProgress())

        let longText = String(repeating: "g", count: 40)
        let tool = StringOutputTool(output: longText)
        let session = profile.standard.makeSession(
            tools: [tool],
            budget: TokenBudget(limit: 4096, toolOutputLimit: 5)
        )
        let child = try await session.fork(workingDirectory: nil)

        guard let childActor = child as? RoutedSessionActor,
            let capping = failureDeliveryPeeled(childActor.tools.first) as? TokenCappingTool<FakeToolArguments>,
            capping.wrapped is RunToCompletionRunner<FakeToolArguments>
        else {
            Issue.record("expected the fork's own tool list to contain a TokenCappingTool wrapping a RunToCompletionRunner")
            return
        }
        let result = try await capping.call(arguments: FakeToolArguments(value: "x"))
        #expect(result == "\(String(repeating: "g", count: 5))… [truncated: 5 of 40 tokens]")
    }

    @Test("fork() with an inherited budget but no toolOutputLimit set applies no capping layer to the child's tool list — only the mount layer wraps it")
    @MainActor
    func forkWithNoToolOutputLimitLeavesChildToolsUnwrapped() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let container = ToolCapturingLLMContainer()
        let router = Self.makeRouter(container: container, cacheDir: dir)
        let profile = try await router.resolve(profile: Self.profile, reporting: ResolutionProgress())

        let tool = StringOutputTool(output: "unchanged")
        let session = profile.standard.makeSession(
            tools: [tool],
            budget: TokenBudget(limit: 4096)
        )
        let child = try await session.fork(workingDirectory: nil)

        guard let childActor = child as? RoutedSessionActor else {
            Issue.record("expected the fork to be a RoutedSessionActor")
            return
        }
        #expect(!(failureDeliveryPeeled(childActor.tools.first) is TokenCappingTool<FakeToolArguments>))
        #expect((failureDeliveryPeeled(childActor.tools.first) as? RunToCompletionRunner<FakeToolArguments>)?.wrapped is StringOutputTool)
    }

    @Test("fork() with no budget at all applies no capping layer to the child's tool list — only the mount layer wraps it")
    @MainActor
    func forkWithNoBudgetLeavesChildToolsUnwrapped() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let container = ToolCapturingLLMContainer()
        let router = Self.makeRouter(container: container, cacheDir: dir)
        let profile = try await router.resolve(profile: Self.profile, reporting: ResolutionProgress())

        let tool = StringOutputTool(output: "unchanged")
        let session = profile.standard.makeSession(tools: [tool])
        let child = try await session.fork(workingDirectory: nil)

        guard let childActor = child as? RoutedSessionActor else {
            Issue.record("expected the fork to be a RoutedSessionActor")
            return
        }
        #expect(!(failureDeliveryPeeled(childActor.tools.first) is TokenCappingTool<FakeToolArguments>))
        #expect((failureDeliveryPeeled(childActor.tools.first) as? RunToCompletionRunner<FakeToolArguments>)?.wrapped is StringOutputTool)
    }
}
