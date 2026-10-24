import Foundation
import FoundationModels
import FoundationModelsRouterTestSupport
import Testing

@testable import FoundationModelsRouter

/// Exercises the persistent-``LanguageModelSessionBackend``-per-session seam
/// (see ``RoutedSessionActor``) purely against stubs: the same backend
/// instance must serve every answer on a session (not a fresh one rebuilt per
/// call).
///
/// The companion gated integration suite
/// (`Tests/FoundationModelsRouterIntegrationTests/LanguageModelSessionBackendTests.swift`)
/// proves the same properties against a real `LanguageModelSession`, plus the
/// harder KV-cache-reuse claim (`cachedTokenCount > 0` on a second answer) that
/// only a real model can demonstrate. This suite needs no network and no GPU.
@Suite("Session state over many messages: same backend across answers")
struct MultiMessageSessionTests {
    // MARK: - Tracking stub backend

    /// Wraps a ``StubSessionBackend``, proxying every generation call to it
    /// unchanged, so a test holding the container can read the call history
    /// of the backend (``RoutedSession`` never exposes its backend directly).
    ///
    /// `@unchecked Sendable` is safe for the same reason `StubSessionBackend`
    /// is: `RoutedSessionActor` drives every method call on one backend
    /// through the owning session's pump, one at a time, so there is never concurrent access to
    /// guard against in practice.
    private final class TrackingBackend: LanguageModelSessionBackend, @unchecked Sendable {
        /// The real stub every call is forwarded to.
        let backend: StubSessionBackend

        init(backend: StubSessionBackend = StubSessionBackend()) {
            self.backend = backend
        }

        /// Proxies ``StubSessionBackend/callCount``.
        var callCount: Int { backend.callCount }

        /// Proxies ``StubSessionBackend/receivedPrompts``.
        var receivedPrompts: [String] { backend.receivedPrompts }

        func respond(to prompt: String, maxTokens: Int?) async throws -> String {
            try await backend.respond(to: prompt, maxTokens: maxTokens)
        }

        func streamResponse(to prompt: String, maxTokens: Int?) -> AsyncThrowingStream<String, Error> {
            backend.streamResponse(to: prompt, maxTokens: maxTokens)
        }

        func respond(to prompt: String, following grammar: Grammar, maxTokens: Int?) async throws -> String {
            try await backend.respond(to: prompt, following: grammar, maxTokens: maxTokens)
        }

        /// Proxies ``StubSessionBackend/transcriptEntries()``.
        func transcriptEntries() -> [Transcript.Entry] {
            backend.transcriptEntries()
        }

        /// Proxies ``StubSessionBackend/usageTokenCounts()``.
        func usageTokenCounts() -> (input: Int, output: Int)? {
            backend.usageTokenCounts()
        }

        /// Proxies ``LanguageModelSessionBackend/cachedInputTokenCount()``.
        func cachedInputTokenCount() -> Int? {
            backend.cachedInputTokenCount()
        }

        /// Forks the wrapped stub and wraps the result the same way.
        func makeFork() -> any LanguageModelSessionBackend {
            guard let forkedStub = backend.makeFork() as? StubSessionBackend else {
                preconditionFailure("StubSessionBackend.makeFork() must return a StubSessionBackend")
            }
            return TrackingBackend(backend: forkedStub)
        }
    }

    /// A ``LoadedLLMContainer`` that vends ``TrackingBackend``s and tracks the
    /// most recently manufactured one, so a test can reach it via
    /// ``lastBackend``.
    ///
    /// `@unchecked Sendable` is safe here because ``lastBackend`` is written
    /// exactly once per session, synchronously inside `makeSession(instructions:)`
    /// — itself only ever called from `RoutedModel.makeSession`, on the single
    /// `@MainActor` test task each test in this suite runs on — and every read
    /// happens afterward from that same task, so there is no concurrent access
    /// across isolation domains in practice.
    private final class TrackingLLMContainer: LoadedLLMContainer, @unchecked Sendable {
        /// The scripted counter of this container: one token per `Character`.
        let tokenCounter: any TokenCounter = CharacterTokenCounter()

        private(set) var lastBackend: TrackingBackend?

        func makeSession(instructions: String?) -> any LanguageModelSessionBackend {
            let backend = TrackingBackend()
            lastBackend = backend
            return backend
        }

        func makeSession(transcript: Transcript) -> any LanguageModelSessionBackend {
            let stub = StubSessionBackend(entries: Array(transcript))
            let backend = TrackingBackend(backend: stub)
            lastBackend = backend
            return backend
        }
    }

    // MARK: - Stubs shared by every test in this suite

    /// A stub embedder container — never exercised here, present only so the
    /// profile resolves. No MLX.
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

    /// A ``ModelLoader`` that returns a single, test-supplied
    /// ``LoadedLLMContainer`` for every generation slot and a stub embedder.
    /// No download, no GPU.
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
            .appendingPathComponent("MultiMessageSessionTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Builds a router wired with the stub loader, vending `container` for
    /// every generation slot.
    private static func makeRouter(
        container: any LoadedLLMContainer,
        cacheDir: URL,
        pool: ModelPool = ModelPool()
    ) -> Router {
        Router(
            cacheDir: cacheDir,
            recorder: InMemoryRecorder(),
            probe: StubProbe(chip: "Apple Test", totalRAM: 64 << 30, recommendedMaxWorkingSetSize: 48 << 30),
            metadataSource: StubMetadataSource(raw: rawMetadata),
            loader: StubModelLoader(container: container, dimension: stubDimension),
            pool: pool
        )
    }

    // MARK: - Same backend serves every answer

    @Test("the same backend instance serves two respond() calls on one session")
    @MainActor
    func sameBackendServesTwoRespondCalls() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let container = TrackingLLMContainer()
        let router = Self.makeRouter(container: container, cacheDir: dir)
        let profile = try await router.resolve(profile: Self.profile, reporting: ResolutionProgress())

        let session = profile.standard.makeSession()
        defer { await session.close() }
        _ = try await session.respond(to: "first message")
        _ = try await session.respond(to: "second message")

        // A fresh backend per call would show callCount == 1 on two distinct
        // instances (or two containers manufactured); a persistent backend
        // shows one instance whose callCount reaches 2, having seen both
        // prompts in order.
        let stubBackend = try #require(container.lastBackend)
        #expect(stubBackend.callCount == 2)
        #expect(stubBackend.receivedPrompts == ["first message", "second message"])
    }
}
