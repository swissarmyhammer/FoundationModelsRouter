import Foundation
import FoundationModels
import Testing

@testable import FoundationModelsRouter

/// Exercises task 46adpch: ``RoutedSession/streamEvents(to:maxTokens:)`` — the
/// event-element variant of ``RoutedSession/streamResponse(to:maxTokens:)``
/// that surfaces tool calls, tool status, reasoning, and the turn's own
/// closing usage, derived from the same snapshot-diff the chokepoint already
/// runs (see ``RoutedSessionActor/recordTranscriptDelta(grammar:since:usage:pendingEvents:onEvent:)``).
///
/// Everything runs against a scripted backend whose ``ScriptedTranscriptBackend/entries``
/// a test sets directly — mirroring `TranscriptFidelityTests.VariableTranscriptBackend`
/// — so a test can force exactly the `.toolCalls`/`.toolOutput`/`.reasoning`/`.response`
/// shape it wants to observe translated into ``SessionEvent``s, with no
/// network and no GPU.
@Suite("streamEvents: SessionEvent derivation from the turn's own diff")
struct SessionEventStreamTests {
    // MARK: - Scripted backend

    /// A backend whose synthetic transcript is fully test-controlled:
    /// `respond`/`streamResponse` never append to ``entries`` themselves — a
    /// test sets ``entries`` directly to whatever this "turn" should appear
    /// to have durably produced, mirroring
    /// `TranscriptFidelityTests.VariableTranscriptBackend`.
    ///
    /// `@unchecked Sendable` is safe here for the same reason as that type:
    /// every access is sequential, driven by one awaited `@MainActor` test
    /// method at a time, with any read from inside `RoutedSessionActor`'s
    /// chokepoint further serialized by the model's serial gate.
    private final class ScriptedTranscriptBackend: LanguageModelSessionBackend, @unchecked Sendable {
        enum StubError: Error, Equatable { case boom }

        /// The transcript this "turn" should appear to have durably produced
        /// — set by the test before calling `streamEvents(to:)`.
        var entries: [Transcript.Entry] = []

        /// The live text fragments `streamResponse(to:maxTokens:)` yields,
        /// each becoming one ``SessionEvent/textDelta(_:)``.
        var responseChunks: [String] = ["ok"]

        /// When `true`, every generation entry point throws ``StubError/boom``
        /// instead of yielding ``responseChunks``.
        var shouldThrow = false

        /// The per-turn token counts folded into ``cumulativeUsage`` on every
        /// call, or `nil` to report no usage at all — mirrors
        /// ``StubSessionBackend/usageIncrement``.
        var usageIncrement: (input: Int, output: Int)?

        private var cumulativeUsage: (input: Int, output: Int) = (0, 0)

        func respond(to prompt: String, maxTokens: Int?) async throws -> String {
            if shouldThrow { throw StubError.boom }
            recordUsage()
            return responseChunks.joined()
        }

        func streamResponse(to prompt: String, maxTokens: Int?) -> AsyncThrowingStream<String, Error> {
            let chunks = responseChunks
            let shouldThrow = shouldThrow
            if !shouldThrow { recordUsage() }
            return AsyncThrowingStream { continuation in
                if shouldThrow {
                    continuation.finish(throwing: StubError.boom)
                } else {
                    for chunk in chunks { continuation.yield(chunk) }
                    continuation.finish()
                }
            }
        }

        func respond(to prompt: String, following grammar: Grammar, maxTokens: Int?) async throws -> String {
            try grammar.validateForXGrammar()
            if shouldThrow { throw StubError.boom }
            recordUsage()
            return responseChunks.joined()
        }

        func makeFork() -> any LanguageModelSessionBackend {
            let fork = ScriptedTranscriptBackend()
            fork.entries = entries
            fork.responseChunks = responseChunks
            fork.shouldThrow = shouldThrow
            fork.usageIncrement = usageIncrement
            fork.cumulativeUsage = cumulativeUsage
            return fork
        }

        func transcriptEntries() -> [Transcript.Entry] {
            entries
        }

        func usageTokenCounts() -> (input: Int, output: Int)? {
            guard usageIncrement != nil else { return nil }
            return cumulativeUsage
        }

        /// Folds ``usageIncrement`` (when set) into ``cumulativeUsage`` — the
        /// same "delta between two snapshots" mechanism ``StubSessionBackend/recordResponse()``
        /// uses, called only on a call known to succeed.
        private func recordUsage() {
            if let usageIncrement {
                cumulativeUsage = (
                    cumulativeUsage.input + usageIncrement.input,
                    cumulativeUsage.output + usageIncrement.output
                )
            }
        }
    }

    /// A ``LoadedLLMContainer`` that vends one ``ScriptedTranscriptBackend``
    /// and tracks it so a test can drive its ``ScriptedTranscriptBackend/entries``
    /// directly before streaming.
    ///
    /// `@unchecked Sendable` for the same reason as `TranscriptFidelityTests.VariableLLMContainer`:
    /// its only stored property is itself `@unchecked Sendable`, and every
    /// access is sequential.
    private final class ScriptedLLMContainer: LoadedLLMContainer, @unchecked Sendable {
        let backend = ScriptedTranscriptBackend()

        func makeSession(instructions: String?) -> any LanguageModelSessionBackend {
            backend
        }

        func makeSession(transcript: Transcript) -> any LanguageModelSessionBackend {
            backend.entries = Array(transcript)
            return backend
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

    private static func makeTempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SessionEventStreamTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Builds a router+resolved-profile pair wired with a fresh
    /// ``ScriptedLLMContainer``, returning the container and recorder so a
    /// test can drive the backend directly and inspect what was persisted.
    private static func makeSession(cacheDir: URL) async throws -> (
        session: RoutedSession, container: ScriptedLLMContainer, recorder: InMemoryRecorder
    ) {
        let container = ScriptedLLMContainer()
        let recorder = InMemoryRecorder()
        let router = Router(
            cacheDir: cacheDir,
            recorder: recorder,
            probe: StubProbe(chip: "Apple Test", totalRAM: 64 << 30, recommendedMaxWorkingSetSize: 48 << 30),
            metadataSource: StubMetadataSource(raw: rawMetadata),
            loader: StubModelLoader(container: container, dimension: stubDimension)
        )
        let profile = try await router.resolve(profile: Self.profile, reporting: ResolutionProgress())
        return (profile.standard.makeSession(), container, recorder)
    }

    /// Drains `stream` into an array, in order.
    private static func collect(_ stream: AsyncThrowingStream<SessionEvent, Error>) async throws -> [SessionEvent] {
        var collected: [SessionEvent] = []
        for try await event in stream {
            collected.append(event)
        }
        return collected
    }

    // MARK: - Plain text: textDelta only

    @Test("a plain-text turn with no tool calls or reasoning yields only textDelta fragments, in order")
    @MainActor
    func plainTextTurnYieldsOnlyTextDeltas() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let (session, container, _) = try await Self.makeSession(cacheDir: dir)
        container.backend.responseChunks = ["hello ", "world"]
        container.backend.entries = [
            .prompt(Transcript.Prompt(segments: [.text(Transcript.TextSegment(content: "hi"))])),
            .response(Transcript.Response(assetIDs: [], segments: [.text(Transcript.TextSegment(content: "hello world"))])),
        ]

        let events = try await Self.collect(session.streamEvents(to: "hi"))
        #expect(events == [.textDelta("hello "), .textDelta("world")])
    }

    // MARK: - Tool calls: toolCall + toolStatus(.running) then .completed

    @Test("a requested-and-answered tool call yields toolCall, toolStatus(.running), then toolStatus(.completed) with the tool's output as summary")
    @MainActor
    func toolCallRequestedAndAnsweredYieldsRunningThenCompleted() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let (session, container, _) = try await Self.makeSession(cacheDir: dir)
        let arguments = try GeneratedContent(json: #"{"query":"weather"}"#)
        container.backend.responseChunks = ["it's sunny"]
        container.backend.entries = [
            .prompt(Transcript.Prompt(segments: [.text(Transcript.TextSegment(content: "weather?"))])),
            .toolCalls(
                Transcript.ToolCalls(
                    id: "calls-1",
                    [Transcript.ToolCall(id: "call-1", toolName: "search", arguments: arguments)]
                )
            ),
            .toolOutput(
                Transcript.ToolOutput(
                    id: "call-1",
                    toolName: "search",
                    segments: [.text(Transcript.TextSegment(content: "72F and sunny"))]
                )
            ),
            .response(Transcript.Response(assetIDs: [], segments: [.text(Transcript.TextSegment(content: "it's sunny"))])),
        ]

        let events = try await Self.collect(session.streamEvents(to: "weather?"))
        #expect(
            events == [
                .textDelta("it's sunny"),
                .toolCall(id: "call-1", name: "search", argumentsJSON: arguments.jsonString),
                .toolStatus(id: "call-1", status: .running, summary: nil),
                .toolStatus(id: "call-1", status: .completed, summary: "72F and sunny"),
            ]
        )
    }

    @Test("two concurrent same-name tool calls in one .toolCalls entry are distinguished by id")
    @MainActor
    func twoConcurrentSameNameToolCallsAreDistinguishedById() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let (session, container, _) = try await Self.makeSession(cacheDir: dir)
        let argumentsA = try GeneratedContent(json: #"{"city":"NYC"}"#)
        let argumentsB = try GeneratedContent(json: #"{"city":"SF"}"#)
        container.backend.entries = [
            .toolCalls(
                Transcript.ToolCalls(
                    id: "calls-1",
                    [
                        Transcript.ToolCall(id: "call-a", toolName: "search", arguments: argumentsA),
                        Transcript.ToolCall(id: "call-b", toolName: "search", arguments: argumentsB),
                    ]
                )
            ),
            .toolOutput(
                Transcript.ToolOutput(id: "call-a", toolName: "search", segments: [.text(Transcript.TextSegment(content: "NYC: sunny"))])
            ),
            .toolOutput(
                Transcript.ToolOutput(id: "call-b", toolName: "search", segments: [.text(Transcript.TextSegment(content: "SF: foggy"))])
            ),
            .response(Transcript.Response(assetIDs: [], segments: [.text(Transcript.TextSegment(content: "done"))])),
        ]

        let events = try await Self.collect(session.streamEvents(to: "compare weather"))
        #expect(
            events == [
                .textDelta("ok"),
                .toolCall(id: "call-a", name: "search", argumentsJSON: argumentsA.jsonString),
                .toolStatus(id: "call-a", status: .running, summary: nil),
                .toolCall(id: "call-b", name: "search", argumentsJSON: argumentsB.jsonString),
                .toolStatus(id: "call-b", status: .running, summary: nil),
                .toolStatus(id: "call-a", status: .completed, summary: "NYC: sunny"),
                .toolStatus(id: "call-b", status: .completed, summary: "SF: foggy"),
            ]
        )
    }

    @Test("a tool call with no matching toolOutput in this turn's diff is reported failed")
    @MainActor
    func danglingToolCallIsReportedFailed() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let (session, container, _) = try await Self.makeSession(cacheDir: dir)
        container.backend.entries = [
            .toolCalls(
                Transcript.ToolCalls(
                    id: "calls-1",
                    [
                        Transcript.ToolCall(
                            id: "call-1", toolName: "search", arguments: try GeneratedContent(json: "{}"))
                    ]
                )
            ),
            .response(Transcript.Response(assetIDs: [], segments: [.text(Transcript.TextSegment(content: "ok"))])),
        ]

        let events = try await Self.collect(session.streamEvents(to: "search something"))
        let statusEvents = events.compactMap { event -> ToolCallStatus? in
            guard case .toolStatus(id: "call-1", let status, _) = event else { return nil }
            return status
        }
        #expect(statusEvents == [.running, .failed])
    }

    // MARK: - Reasoning

    @Test("a .reasoning entry yields reasoningDelta with its flattened text")
    @MainActor
    func reasoningEntryYieldsReasoningDelta() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let (session, container, _) = try await Self.makeSession(cacheDir: dir)
        container.backend.entries = [
            .reasoning(
                Transcript.Reasoning(
                    id: "reasoning-1",
                    segments: [.text(Transcript.TextSegment(content: "the user wants the weather"))]
                )
            ),
            .response(Transcript.Response(assetIDs: [], segments: [.text(Transcript.TextSegment(content: "ok"))])),
        ]

        let events = try await Self.collect(session.streamEvents(to: "weather?"))
        #expect(events.contains(.reasoningDelta("the user wants the weather")))
    }

    // MARK: - turnEnded: emitted iff the backend reports usage

    @Test("a backend reporting usage closes the stream with turnEnded, last")
    @MainActor
    func turnEndedEmittedWhenUsageAvailable() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let (session, container, _) = try await Self.makeSession(cacheDir: dir)
        container.backend.usageIncrement = (input: 10, output: 5)
        container.backend.entries = [
            .response(Transcript.Response(assetIDs: [], segments: [.text(Transcript.TextSegment(content: "ok"))]))
        ]

        let events = try await Self.collect(session.streamEvents(to: "hi"))
        // contextFill is this turn's usage over the profile's default context
        // (``ProfileDefinition/defaultContext``, 8192) — this session was
        // vended with no explicit `context:`.
        #expect(events.last == .turnEnded(TokenUsage(tokensIn: 10, tokensOut: 5, contextFill: 15.0 / 8192.0)))
    }

    @Test("a backend reporting no usage never emits turnEnded")
    @MainActor
    func noTurnEndedWhenUsageUnavailable() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let (session, container, _) = try await Self.makeSession(cacheDir: dir)
        container.backend.entries = [
            .response(Transcript.Response(assetIDs: [], segments: [.text(Transcript.TextSegment(content: "ok"))]))
        ]

        let events = try await Self.collect(session.streamEvents(to: "hi"))
        #expect(!events.contains { if case .turnEnded = $0 { return true } else { return false } })
    }

    // MARK: - Throwing turn: events recorded before the throw still surface

    @Test("a turn that throws after the SDK durably recorded a tool call still yields that call's events before the stream fails")
    @MainActor
    func throwingTurnStillYieldsEventsRecordedBeforeTheThrow() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let (session, container, _) = try await Self.makeSession(cacheDir: dir)
        container.backend.shouldThrow = true
        container.backend.entries = [
            .toolCalls(
                Transcript.ToolCalls(
                    id: "calls-1",
                    [Transcript.ToolCall(id: "call-1", toolName: "search", arguments: try GeneratedContent(json: "{}"))]
                )
            ),
            .toolOutput(
                Transcript.ToolOutput(id: "call-1", toolName: "search", segments: [.text(Transcript.TextSegment(content: "result"))])
            ),
            .response(Transcript.Response(assetIDs: [], segments: [.text(Transcript.TextSegment(content: "ok"))])),
        ]

        var collected: [SessionEvent] = []
        var thrown: Error?
        do {
            for try await event in await session.streamEvents(to: "search something") {
                collected.append(event)
            }
        } catch {
            thrown = error
        }

        #expect(thrown as? ScriptedTranscriptBackend.StubError == .boom)
        #expect(
            collected == [
                .toolCall(id: "call-1", name: "search", argumentsJSON: "{}"),
                .toolStatus(id: "call-1", status: .running, summary: nil),
                .toolStatus(id: "call-1", status: .completed, summary: "result"),
            ]
        )
    }

    // MARK: - Recording is unaffected: streamEvents persists exactly like streamResponse

    @Test("streamEvents records the same transcript events streamResponse would, unaffected by the richer live stream")
    @MainActor
    func streamEventsRecordsSameTranscriptAsStreamResponse() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let (session, container, recorder) = try await Self.makeSession(cacheDir: dir)
        container.backend.responseChunks = ["hello"]
        container.backend.entries = [
            .prompt(Transcript.Prompt(segments: [.text(Transcript.TextSegment(content: "hi"))])),
            .response(Transcript.Response(assetIDs: [], segments: [.text(Transcript.TextSegment(content: "hello"))])),
        ]

        _ = try await Self.collect(session.streamEvents(to: "hi"))

        // Exactly the same persisted shape `streamResponseEmitsOpenAndClose`
        // (`SessionChokepointTests`) asserts for the plain `streamResponse`
        // path: a leading `session` meta line, then this turn's `.prompt` and
        // `.response` — the richer live event stream changes nothing about
        // what lands on disk.
        let events = await recorder.events
        #expect(events.map(\.kind) == [.session, .prompt, .response])
        #expect(events.first { $0.kind == .prompt }?.text == "hi")
        #expect(events.first { $0.kind == .response }?.text == "hello")
    }
}
