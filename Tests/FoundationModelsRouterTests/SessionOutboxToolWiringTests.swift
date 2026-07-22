import Foundation
import FoundationModels
import Operations
import Testing

@testable import FoundationModelsRouter

/// Exercises task 8cwwvaj's other half: ``RoutedModel/makeSession(instructions:workingDirectory:tools:)``
/// threading a tool list into the underlying session AND auto-connecting every
/// ``EventEmittingTool`` to the vended ``RoutedSession``'s own ``SessionOutbox`` —
/// with **no explicit connect call anywhere** in these tests. Also exercises the
/// fork decision: a fork gets its own fresh outbox, and an emitting tool passed
/// to the parent re-connects to the *fork's* outbox once forked (one sink at a
/// time — see ``EventEmittingTool``).
///
/// Everything runs against stubs — no MLX, no network, no GPU. Real
/// `LanguageModelSession(tools:)` wiring lives in the live
/// ``MLXFoundationModelsContainer``/``MLXFoundationModelsSessionBackend``
/// (`Sources/FoundationModelsRouter/Resolution/LiveModelLoader.swift`),
/// exercised end to end only by the gated integration suite.
@Suite("makeSession(tools:): auto-connected EventEmittingTool + fork outbox")
struct SessionOutboxToolWiringTests {
    // MARK: - Test tools

    @Generable
    struct FakeToolArguments {
        let value: String
    }

    /// A real `FoundationModels.Tool` that also conforms to `EventEmittingTool`,
    /// so a host discovers it by conformance cast and connects it automatically —
    /// mirroring how a real fused `OperationTool<Context: EventEmittingContext>`
    /// gets its conformance. `postEvent(_:)` is the test-only stand-in for what a
    /// real tool's `execute(in:)` would do: post through whatever sink is
    /// currently connected (or into the void if none is), through the same
    /// `OperationEventSinkHolder`-style single-sink-at-a-time discipline.
    private final class FakeEmittingTool: Tool, EventEmittingTool, @unchecked Sendable {
        let name = "fake-emitter"
        let description = "test-only tool that posts events once connected"

        private let lock = NSLock()
        private var sink: (any OperationEventSink)?

        func connect(_ sink: any OperationEventSink) {
            lock.withLock { self.sink = sink }
        }

        func call(arguments: FakeToolArguments) async throws -> String {
            "handled: \(arguments.value)"
        }

        /// Posts `event` through whichever sink is currently connected, or
        /// silently drops it if none is — never a direct reference to any
        /// particular `SessionOutbox`, so this can be called both before and
        /// after a fork reconnects this instance to a different outbox.
        func postEvent(_ event: OperationEvent) async {
            let current = lock.withLock { sink }
            await current?.post(event)
        }
    }

    /// A plain `Tool` with no `EventEmittingTool` conformance at all — proves a
    /// mixed tool list works: this one just passes through untouched.
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

        func makeSession(instructions: String?) -> any LanguageModelSessionBackend {
            StubSessionBackend()
        }

        func makeSession(instructions: String?, tools: [any Tool]) -> any LanguageModelSessionBackend {
            lastTools = tools
            return StubSessionBackend()
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

    @Test("makeSession(tools:) threads the exact tool list to the container/backend construction boundary")
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
        #expect(container.lastTools.contains { $0 is FakeEmittingTool })
        #expect(container.lastTools.contains { $0 is PlainTool })
    }

    // MARK: - Auto-connect: no explicit connect() call anywhere

    @Test("a fake emitting tool passed in tools: delivers events with no explicit connect call anywhere")
    @MainActor
    func emittingToolAutoConnectsToSessionOutbox() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let container = ToolCapturingLLMContainer()
        let router = Self.makeRouter(container: container, cacheDir: dir)
        let profile = try await router.resolve(profile: Self.profile, reporting: ResolutionProgress())

        let emitter = FakeEmittingTool()
        let session = profile.standard.makeSession(tools: [emitter])

        // No call to `emitter.connect(...)` appears anywhere in this test —
        // `makeSession(tools:)` itself must have wired it during construction.
        await emitter.postEvent(Self.event(detail: "auto-connected"))

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

        // The plain tool has no connect surface at all; the emitter still
        // auto-connects despite sharing the list with a non-emitting tool.
        await emitter.postEvent(Self.event(detail: "still works"))
        let pending = await session.outbox.pending()
        #expect(pending.events.map(\.event.detail) == ["still works"])

        let output = try await plain.call(arguments: FakeToolArguments(value: "x"))
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

    // MARK: - Fork behavior: fresh-per-session outbox, tool reconnects to the fork's

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

    @Test("forking reconnects a shared emitting tool to the fork's own outbox — events post-fork land in the child, not the parent")
    @MainActor
    func forkReconnectsEmittingToolToChildOutbox() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let container = ToolCapturingLLMContainer()
        let router = Self.makeRouter(container: container, cacheDir: dir)
        let profile = try await router.resolve(profile: Self.profile, reporting: ResolutionProgress())

        let emitter = FakeEmittingTool()
        let session = profile.standard.makeSession(tools: [emitter])

        // Before forking, the shared tool feeds the parent's outbox.
        await emitter.postEvent(Self.event(correlationID: "before", detail: "pre-fork"))
        let parentPendingBeforeFork = await session.outbox.pending()
        #expect(parentPendingBeforeFork.events.map(\.event.detail) == ["pre-fork"])

        let child = try await session.fork(workingDirectory: nil)

        // After forking, the (single, shared) tool instance has been
        // reconnected to the fork's outbox — one sink at a time, per
        // `EventEmittingTool`'s contract — so further events land in the
        // child, not the parent.
        await emitter.postEvent(Self.event(correlationID: "after", detail: "post-fork"))

        let childPending = await child.outbox.pending()
        #expect(childPending.events.map(\.event.detail) == ["post-fork"])

        let parentPendingAfterFork = await session.outbox.pending()
        #expect(parentPendingAfterFork.events.map(\.event.detail) == ["pre-fork"])
    }
}
