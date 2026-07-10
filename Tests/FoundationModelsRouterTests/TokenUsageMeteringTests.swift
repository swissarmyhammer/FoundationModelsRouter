import Foundation
import FoundationModels
import Testing

@testable import FoundationModelsRouter

/// Exercises task v22nv1g: `RoutedSessionActor.generate(grammar:_:)` meters
/// `tokensIn`/`tokensOut` on each turn's final `.response`-kind event from the
/// backend's own ``LanguageModelSessionBackend/usageTokenCounts()`` delta —
/// captured as two snapshots immediately before and after the turn's body
/// runs, never the backend's raw cumulative totals. See
/// ``StubSessionBackend/usageIncrement`` for the stub's configurable canned
/// counts.
///
/// Everything runs against stubs — a stub `ModelLoader` and a container that
/// vends a ``StubSessionBackend`` with a test-configured `usageIncrement` —
/// so the suite needs no network and no GPU.
@Suite("Token usage metering: tokensIn/tokensOut from LanguageModelSessionBackend.usageTokenCounts()")
struct TokenUsageMeteringTests {
    // MARK: - Stub container

    /// Vends a single, test-configured ``StubSessionBackend`` per session, so
    /// a test can control ``StubSessionBackend/usageIncrement`` up front.
    private struct ConfiguredLLMContainer: LoadedLLMContainer {
        let text: String
        let usageIncrement: (input: Int, output: Int)?

        func makeSession(instructions: String?) -> any LanguageModelSessionBackend {
            StubSessionBackend(responseText: text, usageIncrement: usageIncrement)
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

    private static let profile = ProfileDefinition(
        name: "coding",
        description: "test profile",
        standard: ["org/std-a"],
        flash: ["org/flash-a"],
        embedding: ["org/emb-a"]
    )

    private static let stubDimension = 8
    private static let cannedText = "canned response"

    private static func makeTempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TokenUsageMeteringTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Builds a router wired with a ``ConfiguredLLMContainer`` carrying
    /// `usageIncrement` for every generation slot.
    private static func makeRouter(
        usageIncrement: (input: Int, output: Int)?,
        recorder: any TranscriptRecorder,
        cacheDir: URL
    ) -> Router {
        Router(
            cacheDir: cacheDir,
            recorder: recorder,
            probe: StubProbe(chip: "Apple Test", totalRAM: 64 << 30, recommendedMaxWorkingSetSize: 48 << 30),
            metadataSource: StubMetadataSource(raw: rawMetadata),
            loader: StubModelLoader(
                container: ConfiguredLLMContainer(text: cannedText, usageIncrement: usageIncrement),
                dimension: stubDimension
            )
        )
    }

    // MARK: - Canned counts: per-turn deltas, not cumulative totals

    @Test("two turns with canned usage counts record correct per-turn deltas, not cumulative totals")
    @MainActor
    func twoTurnsRecordPerTurnDeltasNotCumulativeTotals() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let recorder = InMemoryRecorder()
        let router = Self.makeRouter(usageIncrement: (input: 10, output: 5), recorder: recorder, cacheDir: dir)
        let profile = try await router.resolve(profile: Self.profile, reporting: ResolutionProgress())

        let session = profile.standard.makeSession()
        _ = try await session.respond(to: "first")
        _ = try await session.respond(to: "second")

        let events = await recorder.events
        let responseEvents = events.filter { $0.kind == .response }
        #expect(responseEvents.count == 2)
        // Each turn's own delta is 10/5 — a bug that surfaced the backend's
        // raw cumulative total instead of the before/after delta would show
        // [10, 20] and [5, 10] here instead.
        #expect(responseEvents.map(\.tokensIn) == [10, 10])
        #expect(responseEvents.map(\.tokensOut) == [5, 5])

        // Only the turn's final `.response`-kind event carries the usage
        // delta — not the `.prompt` event.
        let promptEvents = events.filter { $0.kind == .prompt }
        #expect(promptEvents.allSatisfy { $0.tokensIn == nil && $0.tokensOut == nil })
    }

    // MARK: - No usage reported: tokensIn/tokensOut stay nil

    @Test("a backend that reports no usage leaves tokensIn/tokensOut nil on every event")
    @MainActor
    func backendReportingNoUsageLeavesTokensNil() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let recorder = InMemoryRecorder()
        let router = Self.makeRouter(usageIncrement: nil, recorder: recorder, cacheDir: dir)
        let profile = try await router.resolve(profile: Self.profile, reporting: ResolutionProgress())

        let session = profile.standard.makeSession()
        _ = try await session.respond(to: "first")

        let events = await recorder.events
        #expect(!events.isEmpty)
        #expect(events.allSatisfy { $0.tokensIn == nil && $0.tokensOut == nil })
    }
}
