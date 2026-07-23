import Foundation
import FoundationModels
import Testing

@testable import FoundationModelsRouter

/// Exercises task 1peq9n7: ``TokenBudget``'s defaults and ``RoutedSession/contextFill``'s
/// measured (never estimated, never the backend's raw cumulative total) token
/// accounting (compaction_plan.md §1.4-1.5).
///
/// Everything runs against stubs — a stub `ModelLoader` and a container that
/// vends a ``StubSessionBackend`` with a test-configured `usageIncrement` —
/// so the suite needs no network and no GPU. Every profile fixture pins an
/// explicit `context:`, bypassing the context ladder entirely, so the
/// denominator ``RoutedSession/contextFill`` divides by is a known constant.
@Suite("TokenBudget defaults and contextFill measured token accounting")
struct TokenBudgetTests {
    // MARK: - Stub container

    /// Vends a single, test-configured ``StubSessionBackend`` per session,
    /// retaining the most recently vended one so a test can mutate it (e.g.
    /// flip ``StubSessionBackend/shouldThrow``) after the session already
    /// exists.
    ///
    /// `@unchecked Sendable` invariant: `lastBackend` is written synchronously
    /// inside `makeSession(instructions:)` — itself called synchronously (no
    /// `await` between call and the write) from `RoutedModel.makeSession`,
    /// which is not actor-isolated and so never hops off the calling thread.
    /// Every test that reads `lastBackend` does so from the same `@MainActor`
    /// test method that made the (synchronous) `makeSession` call chain,
    /// after it returns — so every write and every read happen on the same
    /// thread, never concurrently. No lock is needed for a field that is
    /// never actually accessed from more than one thread.
    private final class ConfiguredLLMContainer: LoadedLLMContainer, @unchecked Sendable {
        let text: String
        let usageIncrement: (input: Int, output: Int)?
        private(set) var lastBackend: StubSessionBackend?

        init(text: String, usageIncrement: (input: Int, output: Int)?) {
            self.text = text
            self.usageIncrement = usageIncrement
        }

        func makeSession(instructions: String?) -> any LanguageModelSessionBackend {
            let backend = StubSessionBackend(responseText: text, usageIncrement: usageIncrement)
            lastBackend = backend
            return backend
        }

        func makeSession(transcript: Transcript) -> any LanguageModelSessionBackend {
            StubSessionBackend(entries: Array(transcript), usageIncrement: usageIncrement)
        }
    }

    private struct StubEmbeddingContainer: LoadedEmbeddingContainer {
        let dimension: Int
        func embed(texts: [String]) async throws -> [[Float]] {
            texts.map { _ in [Float](repeating: 0.5, count: dimension) }
        }
    }

    // MARK: - Stubs

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
    /// ``LoadedLLMContainer`` for every generation slot. No download, no GPU.
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

    /// A profile with an explicit, small `context`, so the denominator
    /// ``RoutedSession/contextFill`` divides by is this exact constant rather
    /// than whatever the ladder would have derived.
    private static func profile(context: Int) -> ProfileDefinition {
        ProfileDefinition(
            name: "coding",
            description: "test profile",
            standard: ["org/std-a"],
            flash: ["org/flash-a"],
            embedding: ["org/emb-a"],
            context: context
        )
    }

    private static let stubDimension = 8
    private static let cannedText = "canned response"

    private static func makeTempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TokenBudgetTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Builds a router wired with a ``ConfiguredLLMContainer`` carrying
    /// `usageIncrement` for every generation slot.
    private static func makeRouter(
        container: ConfiguredLLMContainer,
        recorder: any TranscriptRecorder,
        cacheDir: URL
    ) -> Router {
        Router(
            cacheDir: cacheDir,
            recorder: recorder,
            probe: StubProbe(chip: "Apple Test", totalRAM: 64 << 30, recommendedMaxWorkingSetSize: 48 << 30),
            metadataSource: StubMetadataSource(raw: rawMetadata),
            loader: StubModelLoader(container: container, dimension: stubDimension)
        )
    }

    // MARK: - TokenBudget defaults

    @Test("TokenBudget defaults trigger to 0.80 and target to 0.50")
    func budgetDefaults() {
        let budget = TokenBudget(limit: 4096)
        #expect(budget.limit == 4096)
        #expect(budget.trigger == 0.80)
        #expect(budget.target == 0.50)
    }

    @Test("TokenBudget accepts overridden trigger and target")
    func budgetOverrides() {
        let budget = TokenBudget(limit: 4096, trigger: 0.9, target: 0.6)
        #expect(budget.limit == 4096)
        #expect(budget.trigger == 0.9)
        #expect(budget.target == 0.6)
    }

    // MARK: - Brand-new session

    @Test("a brand-new session reports contextFill ≈ 0 before its first turn")
    @MainActor
    func newSessionReportsZeroFill() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let recorder = InMemoryRecorder()
        let container = ConfiguredLLMContainer(text: Self.cannedText, usageIncrement: (input: 100, output: 50))
        let router = Self.makeRouter(container: container, recorder: recorder, cacheDir: dir)
        let profile = try await router.resolve(profile: Self.profile(context: 1000), reporting: ResolutionProgress())

        let session = profile.standard.makeSession()
        #expect(await session.contextFill == 0)
    }

    // MARK: - Live fill: last-turn delta, never the cumulative total

    @Test("contextFill after one turn is that turn's usage delta over the resolved context")
    @MainActor
    func singleTurnFillIsDeltaOverContext() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let recorder = InMemoryRecorder()
        let container = ConfiguredLLMContainer(text: Self.cannedText, usageIncrement: (input: 100, output: 50))
        let router = Self.makeRouter(container: container, recorder: recorder, cacheDir: dir)
        let profile = try await router.resolve(profile: Self.profile(context: 1000), reporting: ResolutionProgress())

        let session = profile.standard.makeSession()
        _ = try await session.respond(to: "first")

        #expect(await session.contextFill == 0.15)
    }

    @Test(
        "after multiple turns contextFill reflects only the newest turn's delta, not the cumulative total"
    )
    @MainActor
    func multiTurnFillReflectsOnlyNewestDelta() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let recorder = InMemoryRecorder()
        let container = ConfiguredLLMContainer(text: Self.cannedText, usageIncrement: (input: 100, output: 50))
        let router = Self.makeRouter(container: container, recorder: recorder, cacheDir: dir)
        let profile = try await router.resolve(profile: Self.profile(context: 1000), reporting: ResolutionProgress())

        let session = profile.standard.makeSession()
        _ = try await session.respond(to: "first")
        _ = try await session.respond(to: "second")

        // A bug reading the backend's raw cumulative total instead of the
        // per-turn delta would report 300/1000 = 0.3 here instead of 0.15.
        #expect(await session.contextFill == 0.15)
    }

    // MARK: - A failed turn that never reached the backend leaves fill unchanged

    @Test("a turn that fails before the backend records anything leaves contextFill unchanged")
    @MainActor
    func failedTurnLeavesFillUnchanged() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let recorder = InMemoryRecorder()
        let container = ConfiguredLLMContainer(text: Self.cannedText, usageIncrement: (input: 100, output: 50))
        let router = Self.makeRouter(container: container, recorder: recorder, cacheDir: dir)
        let profile = try await router.resolve(profile: Self.profile(context: 1000), reporting: ResolutionProgress())

        let session = profile.standard.makeSession()
        _ = try await session.respond(to: "first")
        #expect(await session.contextFill == 0.15)

        container.lastBackend?.shouldThrow = true
        _ = try? await session.respond(to: "second")

        #expect(await session.contextFill == 0.15)
    }
}
