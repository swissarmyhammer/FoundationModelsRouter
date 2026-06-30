import Foundation
import Testing

@testable import FoundationModelsRouter

/// Exercises milestone 5b: the generation-session surface
/// (``RoutedModel/makeSession(instructions:workingDirectory:)``) and its single
/// recorder-bracketed `generate` chokepoint on the vended ``RoutedSession``.
///
/// Everything runs against stubs — a stub ``ModelLoader`` with an eviction spy,
/// a canned LLM container that returns fixed text (and can be made to throw),
/// and an ``InMemoryRecorder`` — so the suite needs no network and no GPU. Real
/// text generation is gated to the milestone 7 integration suite.
@Suite("Session chokepoint + makeSession")
struct SessionChokepointTests {
    // MARK: - Stub containers

    /// A failure a canned container can be configured to raise.
    private enum StubGenerationError: Error, Equatable {
        case boom
    }

    /// A stand-in for a loaded LLM container that returns canned text (or throws
    /// a configured error), with no MLX dependency.
    private struct CannedLLMContainer: LoadedLLMContainer {
        let text: String
        let shouldThrow: Bool

        func respond(to prompt: String, instructions: String?) async throws -> String {
            if shouldThrow { throw StubGenerationError.boom }
            return text
        }

        func streamResponse(
            to prompt: String,
            instructions: String?
        ) -> AsyncThrowingStream<String, Error> {
            let text = text
            let shouldThrow = shouldThrow
            return AsyncThrowingStream { continuation in
                if shouldThrow {
                    continuation.finish(throwing: StubGenerationError.boom)
                } else {
                    continuation.yield(text)
                    continuation.finish()
                }
            }
        }
    }

    /// A stand-in for a loaded embedder container that returns fixed-length
    /// vectors, with no MLX dependency.
    private struct StubEmbeddingContainer: LoadedEmbeddingContainer {
        let dimension: Int

        func embed(_ texts: [String]) async throws -> [[Float]] {
            texts.map { _ in [Float](repeating: 0.5, count: dimension) }
        }
    }

    // MARK: - Eviction spy

    /// Counts how many containers were evicted through the loader.
    private actor EvictionSpy {
        private(set) var count = 0
        func record() { count += 1 }
    }

    // MARK: - Stubs

    /// A ``MachineProbe`` returning fixed numbers so the budget is deterministic.
    private struct StubProbe: MachineProbe {
        let chip: String
        let totalRAM: Int64
        let recommendedMaxWorkingSetSize: Int64
    }

    /// A ``MetadataSource`` returning the same canned bytes for every repo.
    private struct StubMetadataSource: MetadataSource {
        let raw: RawRepoMetadata
        func fetchRawMetadata(repo: String, revision: String?) async throws -> RawRepoMetadata { raw }
    }

    /// A ``ModelLoader`` that returns canned LLM containers and stub embedders
    /// without download or GPU work and records every eviction through the spy.
    private struct StubModelLoader: ModelLoader {
        let spy: EvictionSpy
        let dimension: Int
        let text: String
        let shouldThrow: Bool

        func loadLLM(
            _ ref: ModelRef,
            slot: ModelSlot,
            context: Int,
            reporting: @escaping @Sendable (DownloadProgress) -> Void
        ) async throws -> any LoadedLLMContainer {
            reporting(DownloadProgress(bytesDownloaded: 1, bytesTotal: 1))
            return CannedLLMContainer(text: text, shouldThrow: shouldThrow)
        }

        func loadEmbedder(
            _ ref: ModelRef,
            slot: ModelSlot,
            reporting: @escaping @Sendable (DownloadProgress) -> Void
        ) async throws -> any LoadedEmbeddingContainer {
            reporting(DownloadProgress(bytesDownloaded: 1, bytesTotal: 1))
            return StubEmbeddingContainer(dimension: dimension)
        }

        func preload(_ container: any LoadedModelContainer) async throws {}

        func evict(_ container: any LoadedModelContainer) async {
            await spy.record()
        }
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
            .appendingPathComponent("SessionChokepointTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Builds a router wired with the stubs and the given recorder.
    private static func makeRouter(
        spy: EvictionSpy,
        recorder: any TranscriptRecorder,
        cacheDir: URL,
        text: String = cannedText,
        shouldThrow: Bool = false
    ) -> Router {
        Router(
            cacheDir: cacheDir,
            recorder: recorder,
            probe: StubProbe(chip: "Apple Test", totalRAM: 64 << 30, recommendedMaxWorkingSetSize: 48 << 30),
            metadataSource: StubMetadataSource(raw: rawMetadata),
            loader: StubModelLoader(spy: spy, dimension: stubDimension, text: text, shouldThrow: shouldThrow)
        )
    }

    /// Polls the eviction spy until it reaches `count` or the timeout elapses,
    /// so a `deinit`-triggered (async) eviction can be observed deterministically.
    private static func waitForEvictions(_ spy: EvictionSpy, count: Int) async throws {
        for _ in 0..<200 {
            if await spy.count >= count { return }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    // MARK: - Chokepoint events

    @Test("respond emits exactly one open + one close event with correct provenance")
    @MainActor
    func respondEmitsOpenAndClose() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let spy = EvictionSpy()
        let recorder = InMemoryRecorder()
        let router = Self.makeRouter(spy: spy, recorder: recorder, cacheDir: dir)
        let profile = try await router.resolve(Self.profile, reporting: ResolutionProgress())

        let session = profile.standard.makeSession()
        let text = try await session.respond(to: "hello")
        #expect(text == Self.cannedText)

        let events = await recorder.events
        #expect(events.count == 2)
        #expect(events.map(\.kind) == [.prompt, .response])
        #expect(events.allSatisfy { $0.routerId == router.id })
        #expect(events.allSatisfy { $0.sessionId == session.id })
        #expect(events.allSatisfy { $0.slot == .standard })
        #expect(events.allSatisfy { $0.model == profile.standard.chosen })
    }

    @Test("streamResponse emits exactly one open + one close event around the stream")
    @MainActor
    func streamResponseEmitsOpenAndClose() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let spy = EvictionSpy()
        let recorder = InMemoryRecorder()
        let router = Self.makeRouter(spy: spy, recorder: recorder, cacheDir: dir)
        let profile = try await router.resolve(Self.profile, reporting: ResolutionProgress())

        let session = profile.standard.makeSession()
        var collected = ""
        for try await chunk in await session.streamResponse(to: "hello") {
            collected += chunk
        }
        #expect(collected == Self.cannedText)

        let events = await recorder.events
        #expect(events.count == 2)
        #expect(events.map(\.kind) == [.prompt, .response])
    }

    @Test("the chokepoint emits a close event even when the body throws")
    @MainActor
    func closeEventEmittedOnThrow() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let spy = EvictionSpy()
        let recorder = InMemoryRecorder()
        let router = Self.makeRouter(spy: spy, recorder: recorder, cacheDir: dir, shouldThrow: true)
        let profile = try await router.resolve(Self.profile, reporting: ResolutionProgress())

        let session = profile.standard.makeSession()
        await #expect(throws: (any Error).self) {
            _ = try await session.respond(to: "hello")
        }

        let events = await recorder.events
        #expect(events.count == 2)
        #expect(events.map(\.kind) == [.prompt, .response])
    }

    // MARK: - Profile retention

    @Test("a live session retains its profile: dropping the handle does not evict; the last release does")
    @MainActor
    func sessionRetainsProfile() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let spy = EvictionSpy()
        let router = Self.makeRouter(spy: spy, recorder: InMemoryRecorder(), cacheDir: dir)

        var profile: LanguageModelProfile? = try await router.resolve(Self.profile, reporting: ResolutionProgress())
        var session: RoutedSession? = profile!.standard.makeSession()

        // Dropping the external profile handle while the session is alive must
        // not evict: the session holds the profile resident. Wait past any
        // racing deinit before asserting, so a missing retention would have had
        // time to fire its eviction.
        profile = nil
        try await Task.sleep(for: .milliseconds(100))
        #expect(await spy.count == 0)

        // Releasing the last session lets the profile deinit and evict all three.
        session = nil
        try await Self.waitForEvictions(spy, count: 3)
        #expect(await spy.count == 3)

        _ = session
    }

    // MARK: - Working directory

    @Test("workingDirectory defaults to recordingDirectory and is overridable without moving it")
    @MainActor
    func workingDirectoryDefaultAndOverride() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let spy = EvictionSpy()
        let router = Self.makeRouter(spy: spy, recorder: InMemoryRecorder(), cacheDir: dir)
        let profile = try await router.resolve(Self.profile, reporting: ResolutionProgress())

        let defaultSession = profile.standard.makeSession()
        #expect(defaultSession.workingDirectory == defaultSession.recordingDirectory)

        let custom = FileManager.default.temporaryDirectory
            .appendingPathComponent("custom-wd-\(UUID().uuidString)", isDirectory: true)
        let overridden = profile.standard.makeSession(workingDirectory: custom)
        #expect(overridden.workingDirectory == custom)
        // The override must not move the recording directory.
        #expect(overridden.recordingDirectory != custom)
        #expect(overridden.recordingDirectory.lastPathComponent == overridden.id.description)
    }

    // MARK: - Fork (gated to milestone 9)

    @Test("fork is declared but not yet wired (milestone 9)")
    @MainActor
    func forkNotYetWired() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let spy = EvictionSpy()
        let router = Self.makeRouter(spy: spy, recorder: InMemoryRecorder(), cacheDir: dir)
        let profile = try await router.resolve(Self.profile, reporting: ResolutionProgress())

        let session = profile.standard.makeSession()
        await #expect(throws: SessionError.self) {
            _ = try await session.fork(workingDirectory: nil)
        }
    }
}
