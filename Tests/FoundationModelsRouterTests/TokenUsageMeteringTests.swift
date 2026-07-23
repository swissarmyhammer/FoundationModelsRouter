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
    /// a test can control ``StubSessionBackend/usageIncrement`` up front —
    /// and, via ``lastBackend``, mutate the already-vended backend afterward
    /// (e.g. flip ``StubSessionBackend/shouldThrow`` to force a failed turn).
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

    /// A profile with an explicit, small `context`, so restored
    /// ``RoutedSession/contextFill``'s denominator is a known constant rather
    /// than whatever the context ladder would have derived.
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

    /// Builds a router wired with a durable, on-disk recordings root, so a
    /// session vended from it can later be restored via
    /// ``RoutedModel/restoreSessionTree(root:registry:)``.
    private static func makeDurableRouter(
        id: ULID = .generate(),
        usageIncrement: (input: Int, output: Int)?,
        recordingsDir: URL,
        cacheDir: URL
    ) -> Router {
        makeDurableRouter(
            id: id,
            container: ConfiguredLLMContainer(text: cannedText, usageIncrement: usageIncrement),
            recordingsDir: recordingsDir,
            cacheDir: cacheDir
        )
    }

    /// Builds a router wired with a durable, on-disk recordings root over a
    /// caller-supplied container, so the caller can retain a reference to it
    /// and mutate its ``ConfiguredLLMContainer/lastBackend`` after vending a
    /// session (e.g. to force a later turn to fail).
    private static func makeDurableRouter(
        id: ULID = .generate(),
        container: ConfiguredLLMContainer,
        recordingsDir: URL,
        cacheDir: URL
    ) -> Router {
        Router(
            id: id,
            cacheDir: cacheDir,
            recordingsDir: recordingsDir,
            recorder: JSONLRecorder(directory: recordingsDir),
            probe: StubProbe(chip: "Apple Test", totalRAM: 64 << 30, recommendedMaxWorkingSetSize: 48 << 30),
            metadataSource: StubMetadataSource(raw: rawMetadata),
            loader: StubModelLoader(container: container, dimension: stubDimension)
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

    // MARK: - Restored fill: derived from the newest stamped event, or unknown

    @Test("a restored session's contextFill derives from the newest stamped .response event")
    @MainActor
    func restoredSessionFillDerivesFromNewestStamp() async throws {
        let cacheDir = Self.makeTempDir()
        let recordingsDir = Self.makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: cacheDir)
            try? FileManager.default.removeItem(at: recordingsDir)
        }

        let router1 = Self.makeDurableRouter(
            usageIncrement: (input: 100, output: 50), recordingsDir: recordingsDir, cacheDir: cacheDir)
        let profile1 = try await router1.resolve(profile: Self.profile(context: 1000), reporting: ResolutionProgress())

        let root = profile1.standard.makeSession()
        _ = try await root.respond(to: "first")
        _ = try await root.respond(to: "second")
        let rootId = root.id

        // "Fresh process": a second, independently constructed router/profile
        // resolving against the same id and recordings root, exactly as
        // SessionTreeRestorationTests simulates a restart.
        let router2 = Self.makeDurableRouter(
            id: router1.id, usageIncrement: (input: 100, output: 50), recordingsDir: recordingsDir, cacheDir: cacheDir)
        let profile2 = try await router2.resolve(profile: Self.profile(context: 1000), reporting: ResolutionProgress())

        let restored = try await profile2.standard.restoreSessionTree(root: rootId)
        // Each turn's own delta is 150 tokens (100 + 50); the newest stamp is
        // what a restored session's fill derives from, over the 1000-token
        // resolved context — never the two turns' 300-token cumulative sum.
        #expect(await restored.root.contextFill == 0.15)
    }

    @Test("a restored session with no stamped usage reports contextFill as unknown, never a guess")
    @MainActor
    func restoredSessionWithNoStampReportsUnknownFill() async throws {
        let cacheDir = Self.makeTempDir()
        let recordingsDir = Self.makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: cacheDir)
            try? FileManager.default.removeItem(at: recordingsDir)
        }

        let router1 = Self.makeDurableRouter(
            usageIncrement: nil, recordingsDir: recordingsDir, cacheDir: cacheDir)
        let profile1 = try await router1.resolve(profile: Self.profile(context: 1000), reporting: ResolutionProgress())

        let root = profile1.standard.makeSession()
        _ = try await root.respond(to: "first")
        let rootId = root.id

        let router2 = Self.makeDurableRouter(
            id: router1.id, usageIncrement: nil, recordingsDir: recordingsDir, cacheDir: cacheDir)
        let profile2 = try await router2.resolve(profile: Self.profile(context: 1000), reporting: ResolutionProgress())

        let restored = try await profile2.standard.restoreSessionTree(root: rootId)
        let fill = await restored.root.contextFill
        #expect(fill.isNaN)
    }

    @Test(
        "a failed turn's synthetic bodyless-close event is never mistaken for a real usage stamp on restore"
    )
    @MainActor
    func restoredFillIgnoresFailedTurnSyntheticCloseStamp() async throws {
        let cacheDir = Self.makeTempDir()
        let recordingsDir = Self.makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: cacheDir)
            try? FileManager.default.removeItem(at: recordingsDir)
        }

        let container = ConfiguredLLMContainer(text: Self.cannedText, usageIncrement: (input: 100, output: 50))
        let router1 = Self.makeDurableRouter(container: container, recordingsDir: recordingsDir, cacheDir: cacheDir)
        let profile1 = try await router1.resolve(profile: Self.profile(context: 1000), reporting: ResolutionProgress())

        let root = profile1.standard.makeSession()
        _ = try await root.respond(to: "first")
        let rootId = root.id

        // A failed turn after the successful one: `shouldThrow` makes the
        // backend throw before `recordResponse()` folds `usageIncrement`
        // into its cumulative total (see `StubSessionBackend.respond(to:
        // maxTokens:)`), so the delta the router synthesizes for the
        // resulting bodyless close is a meaningless (0, 0) — restored fill
        // must still reflect the prior successful turn's 150/1000 = 0.15,
        // never this failed turn's bogus zero.
        container.lastBackend?.shouldThrow = true
        _ = try? await root.respond(to: "second")

        let router2 = Self.makeDurableRouter(
            id: router1.id, usageIncrement: (input: 100, output: 50), recordingsDir: recordingsDir, cacheDir: cacheDir)
        let profile2 = try await router2.resolve(profile: Self.profile(context: 1000), reporting: ResolutionProgress())

        let restored = try await profile2.standard.restoreSessionTree(root: rootId)
        #expect(await restored.root.contextFill == 0.15)
    }

    // MARK: - Restored fork inherits the parent's stamp

    @Test("a restored fork with no turns of its own inherits the parent's stamped fill up to the fork's cut point")
    @MainActor
    func restoredForkInheritsParentStamp() async throws {
        let cacheDir = Self.makeTempDir()
        let recordingsDir = Self.makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: cacheDir)
            try? FileManager.default.removeItem(at: recordingsDir)
        }

        let router1 = Self.makeDurableRouter(
            usageIncrement: (input: 100, output: 50), recordingsDir: recordingsDir, cacheDir: cacheDir)
        let profile1 = try await router1.resolve(profile: Self.profile(context: 1000), reporting: ResolutionProgress())

        let root = profile1.standard.makeSession()
        _ = try await root.respond(to: "first")
        let fork = try await root.fork(workingDirectory: nil)
        let rootId = root.id
        let forkId = fork.id

        let router2 = Self.makeDurableRouter(
            id: router1.id, usageIncrement: (input: 100, output: 50), recordingsDir: recordingsDir, cacheDir: cacheDir)
        let profile2 = try await router2.resolve(profile: Self.profile(context: 1000), reporting: ResolutionProgress())

        let restored = try await profile2.standard.restoreSessionTree(root: rootId)
        let restoredFork = try #require(restored.session(forkId))
        // The fork itself never ran a turn, so it has no stamp of its own;
        // it inherits the root's 150/1000 = 0.15 up to its fork cut point,
        // mirroring live `fork()`'s own choice to inherit `usageState`
        // rather than starting the restored fork at an unknown/zero fill.
        #expect(await restoredFork.contextFill == 0.15)
    }
}
