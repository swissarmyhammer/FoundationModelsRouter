import Foundation
import FoundationModels
import Testing

@testable import FoundationModelsRouter

/// Exercises task ^k4nygqa's host-side ambient binding: `RoutedSessionActor`
/// binds `ToolContext.$current` around every backend `respond()`/stream call,
/// carrying the session's identity, its mailbox, and its own `SessionOutbox`
/// as the upstream sink (eventplan.md § "The vocabulary and the host
/// substrate": "Router binds the task local around native `respond()` also").
///
/// Whether Apple's runtime propagates the task local into `Tool.call` is the
/// propagation-probe task's question — the binding here is correct either
/// way, and ``ElevatingTool`` also binds per call regardless. These tests
/// stand a probing backend in for the runtime: it reads
/// `ToolContext.current` from inside the model call and posts through it.
@Suite("ToolContext binding around native respond()/stream")
struct RoutedSessionToolContextBindingTests {
    // MARK: - Probing backend

    /// One binding observation a generation entry point captured.
    private struct ContextCapture {
        let sessionID: ULID
        let completionToken: String
        let isCancelled: Bool
    }

    /// A backend that captures the ambient ``ToolContext`` at each
    /// generation entry point — standing in for Apple's runtime invoking a
    /// tool from inside `respond()` — and posts one `.progress` event
    /// through it, so a test can prove the binding's sink is the calling
    /// session's own outbox.
    ///
    /// `@unchecked Sendable` on the same terms as ``StubSessionBackend``:
    /// the owning session drives one backend method at a time, and tests
    /// read captures only after the driving turn returned.
    private final class ContextProbingBackend: LanguageModelSessionBackend, @unchecked Sendable {
        private let inner = StubSessionBackend()

        /// Every ambient context `respond(to:maxTokens:)` observed, in
        /// call order — `nil` recorded when no binding was present.
        private(set) var respondCaptures: [ContextCapture?] = []

        /// The ambient context the last `streamResponse(to:maxTokens:)`
        /// observed, or `nil` when no binding was present.
        private(set) var streamCapture: ContextCapture??

        func respond(to prompt: String, maxTokens: Int?) async throws -> String {
            if let context = ToolContext.current {
                respondCaptures.append(
                    ContextCapture(
                        sessionID: context.sessionID,
                        completionToken: context.completionToken,
                        isCancelled: context.isCancelled
                    )
                )
                await context.progress("from inside respond")
            } else {
                respondCaptures.append(nil)
            }
            return try await inner.respond(to: prompt, maxTokens: maxTokens)
        }

        func streamResponse(to prompt: String, maxTokens: Int?) -> AsyncThrowingStream<String, Error> {
            streamCapture = ToolContext.current.map {
                ContextCapture(
                    sessionID: $0.sessionID,
                    completionToken: $0.completionToken,
                    isCancelled: $0.isCancelled
                )
            }
            return inner.streamResponse(to: prompt, maxTokens: maxTokens)
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

    /// Vends one retained ``ContextProbingBackend`` per session.
    private final class ProbingLLMContainer: PlainTranscriptStubContainer, @unchecked Sendable {
        private(set) var lastBackend: ContextProbingBackend?

        func makeSession(instructions: String?) -> any LanguageModelSessionBackend {
            let backend = ContextProbingBackend()
            lastBackend = backend
            return backend
        }
    }

    /// A backend whose `respond` polls the ambient context's `isCancelled`
    /// — never structured task cancellation — and returns the moment the
    /// flag flips, proving the binding's probe mirrors the bound model-call
    /// task rather than reporting a constant.
    ///
    /// `@unchecked Sendable` on the same terms as ``ContextProbingBackend``.
    private final class CancellationObservingBackend: LanguageModelSessionBackend, @unchecked Sendable {
        private let inner = StubSessionBackend()

        /// Flips when `respond` begins polling, so a test can wait for the
        /// model call to be in flight before cancelling the turn.
        private(set) var respondStarted = false

        /// Whether the ambient probe ever reported `true`.
        private(set) var observedCancellation = false

        func respond(to prompt: String, maxTokens: Int?) async throws -> String {
            respondStarted = true
            if let context = ToolContext.current {
                for _ in 0..<6_000 {
                    if context.isCancelled {
                        observedCancellation = true
                        break
                    }
                    // Deliberately swallow the cancellation error: this
                    // backend cooperates through the ambient flag alone.
                    try? await Task.sleep(nanoseconds: 5_000_000)
                }
            }
            return try await inner.respond(to: prompt, maxTokens: maxTokens)
        }

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

    /// Vends one retained ``CancellationObservingBackend`` per session.
    private final class CancellationObservingLLMContainer: PlainTranscriptStubContainer, @unchecked Sendable {
        private(set) var lastBackend: CancellationObservingBackend?

        func makeSession(instructions: String?) -> any LanguageModelSessionBackend {
            let backend = CancellationObservingBackend()
            lastBackend = backend
            return backend
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
            .appendingPathComponent(
                "RoutedSessionToolContextBindingTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Builds a fresh router + resolved profile + vended session over a
    /// ``ContextProbingBackend``.
    private static func makeSession() async throws -> (
        session: RoutedSession, backend: ContextProbingBackend, dir: URL
    ) {
        let dir = makeTempDir()
        let container = ProbingLLMContainer()
        let router = Router(
            cacheDir: dir,
            recorder: InMemoryRecorder(),
            probe: StubProbe(chip: "Apple Test", totalRAM: 64 << 30, recommendedMaxWorkingSetSize: 48 << 30),
            metadataSource: StubMetadataSource(raw: rawMetadata),
            loader: StubModelLoader(container: container, dimension: stubDimension)
        )
        let profile = try await router.resolve(profile: Self.profile, reporting: ResolutionProgress())
        let session = profile.standard.makeSession()
        let backend = try #require(container.lastBackend)
        return (session, backend, dir)
    }

    // MARK: - Tests

    @Test("respond binds ToolContext around the backend call: session identity, mailbox scope, live cancellation probe")
    @MainActor
    func respondBindsToolContext() async throws {
        let (session, backend, dir) = try await Self.makeSession()
        defer { try? FileManager.default.removeItem(at: dir) }

        _ = try await session.respond(to: "hello")

        let capture = try #require(backend.respondCaptures.first ?? nil)
        #expect(capture.sessionID == session.id)
        #expect(!capture.isCancelled)

        // The event posted through the ambient context from inside
        // respond() landed in this session's own outbox — the binding's
        // sink is the session's SessionOutbox — stamped with the turn
        // binding's host identity and its per-turn completionToken.
        let pending = await session.outbox.pending()
        let posted = try #require(pending.events.first?.event)
        #expect(posted.kind == .progress)
        #expect(posted.detail == "from inside respond")
        #expect(posted.tool == "session")
        #expect(posted.op == "respond")
        #expect(posted.correlationID == capture.completionToken)
    }

    @Test("streamResponse binds the same ambient context around the backend stream call")
    @MainActor
    func streamResponseBindsToolContext() async throws {
        let (session, backend, dir) = try await Self.makeSession()
        defer { try? FileManager.default.removeItem(at: dir) }

        for try await _ in await session.streamResponse(to: "hello") {}

        let capture = try #require(backend.streamCapture ?? nil)
        #expect(capture.sessionID == session.id)
        #expect(!capture.isCancelled)
    }

    @Test("each turn mints a fresh completionToken into its binding — run scope, never session scope")
    @MainActor
    func eachTurnMintsFreshCompletionToken() async throws {
        let (session, backend, dir) = try await Self.makeSession()
        defer { try? FileManager.default.removeItem(at: dir) }

        _ = try await session.respond(to: "first")
        _ = try await session.respond(to: "second")

        let first = try #require(backend.respondCaptures.first ?? nil)
        let second = try #require(backend.respondCaptures.last ?? nil)
        #expect(first.completionToken != second.completionToken)
    }

    @Test("cancelling the turn flips the binding's isCancelled probe to true — it mirrors the model-call task, never a constant")
    @MainActor
    func cancellingTheTurnFlipsTheBoundProbe() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let container = CancellationObservingLLMContainer()
        let router = Router(
            cacheDir: dir,
            recorder: InMemoryRecorder(),
            probe: StubProbe(chip: "Apple Test", totalRAM: 64 << 30, recommendedMaxWorkingSetSize: 48 << 30),
            metadataSource: StubMetadataSource(raw: Self.rawMetadata),
            loader: StubModelLoader(container: container, dimension: Self.stubDimension)
        )
        let profile = try await router.resolve(profile: Self.profile, reporting: ResolutionProgress())
        let session = profile.standard.makeSession()
        let backend = try #require(container.lastBackend)

        let turn = Task { try await session.respond(to: "poll the flag") }
        for _ in 0..<600 {
            if backend.respondStarted { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(backend.respondStarted)
        await session.cancelCurrentTurn()
        _ = try? await turn.value

        #expect(backend.observedCancellation)
    }
}
