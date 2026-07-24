import Foundation
import FoundationModels
import Operations
import Testing

@testable import FoundationModelsRouter

/// Exercises task 1334fk3: ``TokenBudget/toolOutputLimit`` and the capping it
/// drives in Router's own tool-instancing pipeline
/// (``RoutedModel/makeSession(instructions:workingDirectory:tools:budget:compactionPrompt:)``/
/// ``RoutedSessionActor/fork(workingDirectory:)``) — ``ToolOutputCapping``'s
/// truncation rule and dynamic wrapping, plus the wiring that threads a
/// capped tool to the model-facing container/backend boundary exactly the
/// way `SessionOutboxToolWiringTests` proves for `EventEmittingTool`/
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

    /// A non-`String`-output `Tool` — proves ``ToolOutputCapping/wrapping(_:toTokenLimit:)``
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

    /// A `String`-output `Tool` that also conforms to `EventEmittingTool`,
    /// mirroring `SessionOutboxToolWiringTests.FakeEmittingTool` — proves
    /// capping composes with the connect step rather than replacing it.
    private final class EmittingStringTool: Tool, EventEmittingTool, @unchecked Sendable {
        let name = "emitting-string-tool"
        let description = "emits and returns a fixed string"
        let output: String
        private let sink: (any OperationEventSink)?

        init(output: String, sink: (any OperationEventSink)? = nil) {
            self.output = output
            self.sink = sink
        }

        func connecting(_ sink: any OperationEventSink) -> any Tool {
            EmittingStringTool(output: output, sink: sink)
        }

        func call(arguments: FakeToolArguments) async throws -> String {
            output
        }

        func postEvent(_ event: OperationEvent) async {
            await sink?.post(event)
        }
    }

    private static func event(correlationID: String = "c1", detail: String = "done") -> OperationEvent {
        OperationEvent(tool: "emitting-string-tool", op: "run thing", correlationID: correlationID, kind: .completed, detail: detail)
    }

    // MARK: - ToolOutputCapping.capped(_:toTokenLimit:)

    @Test("capped(_:toTokenLimit:) returns text unchanged when its estimated size is under the limit")
    func cappedLeavesShortTextUnchanged() {
        // 8 ASCII bytes -> ceil(8/4) = 2 estimated tokens, well under limit 5.
        let text = "12345678"
        #expect(ToolOutputCapping.capped(text, toTokenLimit: 5) == text)
    }

    @Test("capped(_:toTokenLimit:) returns text unchanged when its estimated size exactly equals the limit")
    func cappedLeavesExactlyAtLimitTextUnchanged() {
        // 20 ASCII bytes -> ceil(20/4) = 5 estimated tokens, exactly the limit.
        let text = String(repeating: "a", count: 20)
        #expect(ToolOutputCapping.capped(text, toTokenLimit: 5) == text)
    }

    @Test("capped(_:toTokenLimit:) truncates oversized text and appends an explicit marker naming kept and original token counts")
    func cappedTruncatesOversizedTextWithMarker() {
        // 40 ASCII bytes -> ceil(40/4) = 10 estimated tokens; limit 5 keeps
        // floor(5*4) = 20 characters.
        let text = String(repeating: "b", count: 40)
        let result = ToolOutputCapping.capped(text, toTokenLimit: 5)

        let expectedKept = String(repeating: "b", count: 20)
        #expect(result == "\(expectedKept)… [truncated: 5 of 10 tokens]")
    }

    @Test("capped(_:toTokenLimit:) never grows the returned text beyond the original")
    func cappedNeverGrowsBeyondOriginal() {
        let text = String(repeating: "c", count: 40)
        let result = ToolOutputCapping.capped(text, toTokenLimit: 5)
        #expect(result.utf8.count <= text.utf8.count + "… [truncated: 5 of 10 tokens]".utf8.count)
    }

    @Test("capped(_:toTokenLimit:) truncates multi-byte (non-ASCII) text on the same byte-based unit its own token estimate uses")
    func cappedTruncatesMultiByteTextConsistentlyWithItsByteEstimate() {
        // Each "🎉" is 4 UTF-8 bytes; 10 of them is 40 bytes -> ceil(40/4) = 10
        // estimated tokens, matching the all-ASCII fixtures above exactly in
        // token terms but only 10 *characters* long — the exact mismatch
        // that silently defeated a Character-based prefix against a
        // byte-based total estimate.
        let text = String(repeating: "🎉", count: 10)
        let result = ToolOutputCapping.capped(text, toTokenLimit: 5)

        // limit 5 tokens -> floor(5*4) = 20 kept bytes -> exactly 5 emoji
        // (4 bytes each), never the whole 10-emoji original.
        let expectedKept = String(repeating: "🎉", count: 5)
        #expect(result == "\(expectedKept)… [truncated: 5 of 10 tokens]")

        // Truncation must actually have happened: never the whole original
        // text with a marker bolted on top.
        #expect(result != text + "… [truncated: 5 of 10 tokens]")
    }

    @Test("capped(_:toTokenLimit:) returns an empty prefix for a non-positive limit, still marking the truncation")
    func cappedWithNonPositiveLimitReturnsEmptyPrefix() {
        let text = String(repeating: "z", count: 40)
        let result = ToolOutputCapping.capped(text, toTokenLimit: 0)
        #expect(result == "… [truncated: 0 of 10 tokens]")
    }

    // MARK: - ToolOutputCapping.wrapping(_:toTokenLimit:)

    @Test("wrapping(_:toTokenLimit:) wraps a String-output tool in a TokenCappingTool that caps its call() result")
    func wrappingCapsStringOutputToolCallResult() async throws {
        let text = String(repeating: "d", count: 40)
        let tool = StringOutputTool(output: text)

        let wrapped = ToolOutputCapping.wrapping(tool, toTokenLimit: 5)
        guard let capping = wrapped as? TokenCappingTool<FakeToolArguments> else {
            Issue.record("expected wrapping(_:toTokenLimit:) to return a TokenCappingTool")
            return
        }

        let result = try await capping.call(arguments: FakeToolArguments(value: "x"))
        #expect(result == "\(String(repeating: "d", count: 20))… [truncated: 5 of 10 tokens]")
    }

    @Test("wrapping(_:toTokenLimit:) leaves a short String-output tool's result untouched")
    func wrappingLeavesShortStringOutputUnchanged() async throws {
        let tool = StringOutputTool(output: "short")
        let wrapped = ToolOutputCapping.wrapping(tool, toTokenLimit: 100)

        guard let capping = wrapped as? TokenCappingTool<FakeToolArguments> else {
            Issue.record("expected wrapping(_:toTokenLimit:) to return a TokenCappingTool")
            return
        }
        let result = try await capping.call(arguments: FakeToolArguments(value: "x"))
        #expect(result == "short")
    }

    @Test("wrapping(_:toTokenLimit:) forwards name/description/parameters/includesSchemaInInstructions to the wrapped tool")
    func wrappingForwardsToolMetadata() {
        let tool = StringOutputTool(output: "x")
        let wrapped = ToolOutputCapping.wrapping(tool, toTokenLimit: 5)

        guard let capping = wrapped as? TokenCappingTool<FakeToolArguments> else {
            Issue.record("expected wrapping(_:toTokenLimit:) to return a TokenCappingTool")
            return
        }
        #expect(capping.name == tool.name)
        #expect(capping.description == tool.description)
        #expect(capping.includesSchemaInInstructions == tool.includesSchemaInInstructions)
    }

    @Test("wrapping(_:toTokenLimit:) passes a non-String-output tool through unchanged")
    func wrappingPassesNonStringOutputToolThroughUnchanged() {
        let tool = NonStringOutputTool()
        let wrapped = ToolOutputCapping.wrapping(tool, toTokenLimit: 5)
        #expect(wrapped is NonStringOutputTool)
    }

    // MARK: - Stub container capturing the threaded tool list

    private final class ToolCapturingLLMContainer: LoadedLLMContainer, @unchecked Sendable {
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

    private static func makeRouter(container: any LoadedLLMContainer, cacheDir: URL) -> Router {
        Router(
            cacheDir: cacheDir,
            recorder: InMemoryRecorder(),
            probe: StubProbe(chip: "Apple Test", totalRAM: 64 << 30, recommendedMaxWorkingSetSize: 48 << 30),
            metadataSource: StubMetadataSource(raw: rawMetadata),
            loader: StubModelLoader(container: container, dimension: stubDimension)
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

        guard let capping = container.lastTools.first as? TokenCappingTool<FakeToolArguments> else {
            Issue.record("expected the container to receive a TokenCappingTool")
            return
        }
        let result = try await capping.call(arguments: FakeToolArguments(value: "x"))
        #expect(result == "\(String(repeating: "e", count: 20))… [truncated: 5 of 10 tokens]")
    }

    @Test("makeSession(tools:budget:) with no toolOutputLimit set leaves the tool unwrapped")
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

        #expect(container.lastTools.first is StringOutputTool)
    }

    @Test("makeSession(tools:budget:) with no budget at all leaves the tool unwrapped")
    @MainActor
    func makeSessionWithNoBudgetLeavesToolUnwrapped() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let container = ToolCapturingLLMContainer()
        let router = Self.makeRouter(container: container, cacheDir: dir)
        let profile = try await router.resolve(profile: Self.profile, reporting: ResolutionProgress())

        let tool = StringOutputTool(output: "unchanged")
        _ = profile.standard.makeSession(tools: [tool])

        #expect(container.lastTools.first is StringOutputTool)
    }

    @Test("makeSession(tools:budget:) caps outermost: an EventEmittingTool still delivers events through the capped wrapper's wrapped instance")
    @MainActor
    func cappingComposesWithEventEmittingTool() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let container = ToolCapturingLLMContainer()
        let router = Self.makeRouter(container: container, cacheDir: dir)
        let profile = try await router.resolve(profile: Self.profile, reporting: ResolutionProgress())

        let longText = String(repeating: "f", count: 40)
        let tool = EmittingStringTool(output: longText)
        let session = profile.standard.makeSession(
            tools: [tool],
            budget: TokenBudget(limit: 4096, toolOutputLimit: 5)
        )

        guard let capping = container.lastTools.first as? TokenCappingTool<FakeToolArguments>,
            let emitting = capping.wrapped as? EmittingStringTool
        else {
            Issue.record("expected a TokenCappingTool wrapping the connected EmittingStringTool")
            return
        }

        // The call result is capped...
        let result = try await capping.call(arguments: FakeToolArguments(value: "x"))
        #expect(result == "\(String(repeating: "f", count: 20))… [truncated: 5 of 10 tokens]")

        // ...and the wrapped instance is still the session-connected one,
        // posting to this session's own outbox.
        await emitting.postEvent(Self.event(detail: "through-capped-wrapper"))
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
            let capping = childActor.tools.first as? TokenCappingTool<FakeToolArguments>
        else {
            Issue.record("expected the fork's own tool list to contain a TokenCappingTool")
            return
        }
        let result = try await capping.call(arguments: FakeToolArguments(value: "x"))
        #expect(result == "\(String(repeating: "g", count: 20))… [truncated: 5 of 10 tokens]")
    }

    @Test("fork() with no toolOutputLimit leaves the child's tool list unwrapped")
    @MainActor
    func forkWithNoToolOutputLimitLeavesChildToolsUnwrapped() async throws {
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
        #expect(childActor.tools.first is StringOutputTool)
    }
}
