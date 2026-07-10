import Foundation
import FoundationModels
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

    /// Records the `maxTokens` value each generation call on a
    /// ``CannedLLMContainer`` observed, so a test can assert it was threaded
    /// through unmodified from the session's `respond(to:maxTokens:)` call.
    private actor MaxTokensSpy {
        private(set) var observed: [Int?] = []
        func record(_ value: Int?) { observed.append(value) }
    }

    /// A stand-in for a loaded LLM container that returns canned text (or throws
    /// a configured error), with no MLX dependency.
    private struct CannedLLMContainer: LoadedLLMContainer {
        let text: String
        let shouldThrow: Bool
        var maxTokensSpy: MaxTokensSpy?

        func makeSession(instructions: String?) -> any LanguageModelSessionBackend {
            let backend = StubSessionBackend(responseText: text, shouldThrow: shouldThrow)
            guard let maxTokensSpy else { return backend }
            return MaxTokensRecordingBackend(backend: backend, spy: maxTokensSpy)
        }
    }

    /// Wraps a ``StubSessionBackend`` to additionally record each call's
    /// `maxTokens` into a ``MaxTokensSpy``, so this suite's maxTokens-threading
    /// assertions keep working now that generation runs through a persistent
    /// backend rather than the container directly.
    ///
    /// `@unchecked Sendable` is safe here because `RoutedSessionActor` serializes
    /// all method calls through the model's serial gate, and both wrapped fields
    /// (`backend`, `spy`) are themselves `Sendable` — `backend` is a `StubSessionBackend`
    /// and `spy` is an actor; both are also `let` and never mutated after
    /// initialization.
    private final class MaxTokensRecordingBackend: LanguageModelSessionBackend, @unchecked Sendable {
        private let backend: StubSessionBackend
        private let spy: MaxTokensSpy

        init(backend: StubSessionBackend, spy: MaxTokensSpy) {
            self.backend = backend
            self.spy = spy
        }

        func respond(to prompt: String, maxTokens: Int?) async throws -> String {
            await spy.record(maxTokens)
            return try await backend.respond(to: prompt, maxTokens: maxTokens)
        }

        func streamResponse(to prompt: String, maxTokens: Int?) -> AsyncThrowingStream<String, Error> {
            let backend = backend
            let spy = spy
            return AsyncThrowingStream { continuation in
                // `streamResponse` is a non-async protocol requirement, so the spy
                // (an actor) can only be recorded from inside a `Task`. The record
                // happens before any chunk is yielded/finished, so a consumer that
                // has finished draining the stream is guaranteed to observe it.
                Task {
                    await spy.record(maxTokens)
                    await Self.forward(
                        backend.streamResponse(to: prompt, maxTokens: maxTokens),
                        to: continuation
                    )
                }
            }
        }

        /// Drains `stream` into `continuation`, finishing it (with or without
        /// an error) once the source stream ends — extracted out of
        /// ``streamResponse(to:maxTokens:)``'s `Task` closure to keep that
        /// closure's control flow shallow.
        private static func forward(
            _ stream: AsyncThrowingStream<String, Error>,
            to continuation: AsyncThrowingStream<String, Error>.Continuation
        ) async {
            do {
                for try await chunk in stream {
                    continuation.yield(chunk)
                }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }

        func respond(to prompt: String, following grammar: Grammar, maxTokens: Int?) async throws -> String {
            await spy.record(maxTokens)
            return try await backend.respond(to: prompt, following: grammar, maxTokens: maxTokens)
        }

        /// Proxies ``StubSessionBackend/transcriptEntries()``.
        func transcriptEntries() -> [Transcript.Entry] {
            backend.transcriptEntries()
        }

        func makeFork() -> any LanguageModelSessionBackend {
            // `StubSessionBackend.makeFork()` always concretely returns another
            // `StubSessionBackend` (see its doc comment); preserve that identity
            // here so the fork keeps recording through `spy`, mirroring how the
            // live backend's wrapping would apply uniformly across forks.
            guard let fork = backend.makeFork() as? StubSessionBackend else {
                preconditionFailure("StubSessionBackend.makeFork() must return a StubSessionBackend")
            }
            return MaxTokensRecordingBackend(backend: fork, spy: spy)
        }
    }

    /// A stand-in for a loaded embedder container that returns fixed-length
    /// vectors, with no MLX dependency.
    private struct StubEmbeddingContainer: LoadedEmbeddingContainer {
        let dimension: Int

        func embed(texts: [String]) async throws -> [[Float]] {
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
        var maxTokensSpy: MaxTokensSpy?

        func loadLLM(
            ref: ModelRef,
            slot: ModelSlot,
            context: Int,
            reporting: @escaping @Sendable (DownloadProgress) -> Void
        ) async throws -> any LoadedLLMContainer {
            reporting(DownloadProgress(bytesDownloaded: 1, bytesTotal: 1))
            return CannedLLMContainer(text: text, shouldThrow: shouldThrow, maxTokensSpy: maxTokensSpy)
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

        func evict(container: any LoadedModelContainer) async {
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
        shouldThrow: Bool = false,
        maxTokensSpy: MaxTokensSpy? = nil
    ) -> Router {
        Router(
            cacheDir: cacheDir,
            recorder: recorder,
            probe: StubProbe(chip: "Apple Test", totalRAM: 64 << 30, recommendedMaxWorkingSetSize: 48 << 30),
            metadataSource: StubMetadataSource(raw: rawMetadata),
            loader: StubModelLoader(
                spy: spy,
                dimension: stubDimension,
                text: text,
                shouldThrow: shouldThrow,
                maxTokensSpy: maxTokensSpy
            )
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
        let profile = try await router.resolve(profile: Self.profile, reporting: ResolutionProgress())

        let session = profile.standard.makeSession()
        let text = try await session.respond(to: "hello")
        #expect(text == Self.cannedText)

        let events = await recorder.events
        // A first-line `session` meta event precedes the turn's open + close.
        #expect(events.count == 3)
        #expect(events.map(\.kind) == [.session, .prompt, .response])
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
        let profile = try await router.resolve(profile: Self.profile, reporting: ResolutionProgress())

        let session = profile.standard.makeSession()
        var collected = ""
        for try await chunk in await session.streamResponse(to: "hello") {
            collected += chunk
        }
        #expect(collected == Self.cannedText)

        let events = await recorder.events
        // A first-line `session` meta event precedes the turn's open + close.
        #expect(events.count == 3)
        #expect(events.map(\.kind) == [.session, .prompt, .response])
    }

    @Test("the chokepoint emits a close event even when the body throws")
    @MainActor
    func closeEventEmittedOnThrow() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let spy = EvictionSpy()
        let recorder = InMemoryRecorder()
        let router = Self.makeRouter(spy: spy, recorder: recorder, cacheDir: dir, shouldThrow: true)
        let profile = try await router.resolve(profile: Self.profile, reporting: ResolutionProgress())

        let session = profile.standard.makeSession()
        await #expect(throws: (any Error).self) {
            _ = try await session.respond(to: "hello")
        }

        let events = await recorder.events
        // A first-line `session` meta event precedes the turn's open + close,
        // which is still recorded on the throwing path.
        #expect(events.count == 3)
        #expect(events.map(\.kind) == [.session, .prompt, .response])
    }

    // MARK: - Profile retention

    @Test("a live session retains its profile: dropping the handle does not evict; the last release does")
    @MainActor
    func sessionRetainsProfile() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let spy = EvictionSpy()
        let router = Self.makeRouter(spy: spy, recorder: InMemoryRecorder(), cacheDir: dir)

        var profile: LanguageModelProfile? = try await router.resolve(profile: Self.profile, reporting: ResolutionProgress())
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
        let profile = try await router.resolve(profile: Self.profile, reporting: ResolutionProgress())

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

    // MARK: - maxTokens threading

    @Test("respond threads an explicit maxTokens override to the container; omitting it passes nil")
    @MainActor
    func respondThreadsMaxTokensOverride() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let spy = EvictionSpy()
        let maxTokensSpy = MaxTokensSpy()
        let router = Self.makeRouter(
            spy: spy,
            recorder: InMemoryRecorder(),
            cacheDir: dir,
            maxTokensSpy: maxTokensSpy
        )
        let profile = try await router.resolve(profile: Self.profile, reporting: ResolutionProgress())

        let session = profile.standard.makeSession()
        _ = try await session.respond(to: "hello", maxTokens: 4096)
        _ = try await session.respond(to: "hello")

        // The router does not silently substitute its own default before the
        // container boundary — an explicit override reaches the container
        // unchanged, and omitting it reaches the container as `nil` (the
        // default lives in `LiveModelLoader` only).
        #expect(await maxTokensSpy.observed == [4096, nil])
    }

    @Test("streamResponse threads an explicit maxTokens override to the container; omitting it passes nil")
    @MainActor
    func streamResponseThreadsMaxTokensOverride() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let spy = EvictionSpy()
        let maxTokensSpy = MaxTokensSpy()
        let router = Self.makeRouter(
            spy: spy,
            recorder: InMemoryRecorder(),
            cacheDir: dir,
            maxTokensSpy: maxTokensSpy
        )
        let profile = try await router.resolve(profile: Self.profile, reporting: ResolutionProgress())

        let session = profile.standard.makeSession()
        for try await _ in await session.streamResponse(to: "hello", maxTokens: 8192) {}
        for try await _ in await session.streamResponse(to: "hello") {}

        // Mirrors respondThreadsMaxTokensOverride for the streaming path: an
        // explicit override reaches the container unchanged, and omitting it
        // reaches the container as `nil` (the default lives in
        // `LiveModelLoader` only).
        #expect(await maxTokensSpy.observed == [8192, nil])
    }
}
