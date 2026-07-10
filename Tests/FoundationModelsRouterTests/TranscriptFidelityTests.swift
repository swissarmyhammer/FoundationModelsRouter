import Foundation
import FoundationModels
import Testing

@testable import FoundationModelsRouter

/// Exercises task qb9p7gs: the `generate` chokepoint's snapshot-diff
/// persistence — recorded per-turn content events are derived exclusively
/// from `backend.transcriptEntries()` deltas, not from hand-built
/// prompt/response strings. See plan.md's "Transcript fidelity" section and
/// ``RoutedSessionActor/recordTranscriptDelta(grammar:since:)``.
///
/// Everything runs against stubs — a stub ``ModelLoader``, canned/variable LLM
/// containers, and either a ``JSONLRecorder`` writing into a temp directory or
/// an ``InMemoryRecorder`` — so the suite needs no network and no GPU.
@Suite("Snapshot-diff persistence: real transcript entries")
struct TranscriptFidelityTests {
    // MARK: - Stub containers

    /// A stand-in for a loaded LLM container that returns canned text, no MLX.
    private struct CannedLLMContainer: LoadedLLMContainer {
        let text: String

        func makeSession(instructions: String?) -> any LanguageModelSessionBackend {
            StubSessionBackend(responseText: text)
        }
    }

    /// A stand-in for a loaded embedder container, no MLX.
    private struct StubEmbeddingContainer: LoadedEmbeddingContainer {
        let dimension: Int
        func embed(texts: [String]) async throws -> [[Float]] {
            texts.map { _ in [Float](repeating: 0.5, count: dimension) }
        }
    }

    /// A backend whose synthetic transcript is fully test-controlled — unlike
    /// ``StubSessionBackend``, `respond`/`streamResponse` never append to
    /// ``entries`` themselves. A test drives ``entries`` directly between
    /// turns so it can force the transcript to *shrink*, proving
    /// `recordTranscriptDelta(grammar:since:)`'s defensive clamp
    /// (`entries[min(persistedEntryCount, entries.count)...]`) never traps.
    ///
    /// `@unchecked Sendable` is safe here because every access is sequential:
    /// a test's direct mutations of `entries`/`responseText`/`shouldThrow`
    /// between turns and this session's `respond`/`streamResponse`/
    /// `transcriptEntries()` calls during a turn all happen on the awaited
    /// `@MainActor` test method, one at a time, and any read from inside
    /// `RoutedSessionActor`'s chokepoint is further serialized by the model's
    /// serial gate — nothing ever touches this instance concurrently.
    private final class VariableTranscriptBackend: LanguageModelSessionBackend, @unchecked Sendable {
        enum StubError: Error { case boom }

        var entries: [Transcript.Entry] = []
        var responseText = "ok"

        /// When `true`, `respond`/`streamResponse`/the guided `respond` throw
        /// after returning, so a test can simulate the SDK having durably
        /// appended `entries` (including, deliberately, a real `.response`
        /// entry) before the turn ultimately fails.
        var shouldThrow = false

        func respond(to prompt: String, maxTokens: Int?) async throws -> String {
            if shouldThrow { throw StubError.boom }
            return responseText
        }

        func streamResponse(to prompt: String, maxTokens: Int?) -> AsyncThrowingStream<String, Error> {
            let responseText = responseText
            let shouldThrow = shouldThrow
            return AsyncThrowingStream { continuation in
                if shouldThrow {
                    continuation.finish(throwing: StubError.boom)
                } else {
                    continuation.yield(responseText)
                    continuation.finish()
                }
            }
        }

        func respond(to prompt: String, following grammar: Grammar, maxTokens: Int?) async throws -> String {
            try grammar.validateForXGrammar()
            if shouldThrow { throw StubError.boom }
            return responseText
        }

        func makeFork() -> any LanguageModelSessionBackend {
            let fork = VariableTranscriptBackend()
            fork.entries = entries
            fork.responseText = responseText
            fork.shouldThrow = shouldThrow
            return fork
        }

        func transcriptEntries() -> [Transcript.Entry] {
            entries
        }
    }

    /// A ``LoadedLLMContainer`` that vends one ``VariableTranscriptBackend`` and
    /// tracks it so a test can drive its ``VariableTranscriptBackend/entries``
    /// directly between turns.
    ///
    /// `@unchecked Sendable` is safe here because its only stored property,
    /// `backend`, is itself `@unchecked Sendable` for the same reason (see
    /// ``VariableTranscriptBackend``): every access is sequential, driven by
    /// one awaited `@MainActor` test method at a time.
    private final class VariableLLMContainer: LoadedLLMContainer, @unchecked Sendable {
        let backend = VariableTranscriptBackend()

        func makeSession(instructions: String?) -> any LanguageModelSessionBackend {
            backend
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
            .appendingPathComponent("TranscriptFidelityTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Builds a router wired with `container` for every generation slot.
    private static func makeRouter(
        container: any LoadedLLMContainer,
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

    // MARK: - Two-turn entry order + payload

    @Test("two turns produce entry events in exact stub-transcript order with correct kinds and payloads")
    @MainActor
    func twoTurnsProduceEntriesInStubTranscriptOrder() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let recorder = InMemoryRecorder()
        let router = Self.makeRouter(
            container: CannedLLMContainer(text: Self.cannedText),
            recorder: recorder,
            cacheDir: dir
        )
        let profile = try await router.resolve(profile: Self.profile, reporting: ResolutionProgress())

        let session = profile.standard.makeSession()
        _ = try await session.respond(to: "first")
        _ = try await session.respond(to: "second")

        let events = await recorder.events
        // session meta, then (prompt, response) per turn, in stub-transcript
        // order — never the old hand-built single prompt/response pair.
        #expect(events.map(\.kind) == [.session, .prompt, .response, .prompt, .response])

        let promptEvents = events.filter { $0.kind == .prompt }
        #expect(promptEvents.map(\.text) == ["first", "second"])
        #expect(promptEvents.allSatisfy { $0.entry != nil })

        let responseEvents = events.filter { $0.kind == .response }
        #expect(responseEvents.map(\.text) == [Self.cannedText, Self.cannedText])
        #expect(responseEvents.allSatisfy { $0.entry != nil })
        // `ms` lands only on each turn's final `.response`-kind entry event.
        #expect(responseEvents.allSatisfy { $0.ms != nil })
        #expect(promptEvents.allSatisfy { $0.ms == nil })

        // seq is contiguous across the whole session, not per-turn.
        #expect(events.map(\.seq) == [0, 1, 2, 3, 4])
    }

    // MARK: - Fork baseline: child sees only its own delta

    @Test("a fork after turn 1 records only its own delta; parent/child turns never leak across files")
    @MainActor
    func forkRecordsOnlyItsOwnDelta() async throws {
        let dir = Self.makeTempDir()
        let recordingsDir = Self.makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: dir)
            try? FileManager.default.removeItem(at: recordingsDir)
        }

        let router = Router(
            cacheDir: dir,
            recordingsDir: recordingsDir,
            recorder: JSONLRecorder(directory: recordingsDir),
            probe: StubProbe(chip: "Apple Test", totalRAM: 64 << 30, recommendedMaxWorkingSetSize: 48 << 30),
            metadataSource: StubMetadataSource(raw: Self.rawMetadata),
            loader: StubModelLoader(container: CannedLLMContainer(text: Self.cannedText), dimension: Self.stubDimension)
        )
        let profile = try await router.resolve(profile: Self.profile, reporting: ResolutionProgress())

        let root = profile.standard.makeSession()
        _ = try await root.respond(to: "root turn 1")

        let child = try await root.fork(workingDirectory: nil)
        _ = try await child.respond(to: "child turn")

        // The child's file holds only its own delta: a session meta line plus
        // its own turn's prompt/response — nothing from the parent's turn 1,
        // which the child's backend started already holding as inherited
        // (unrecorded-by-the-child) history.
        let childEvents = try Self.events(in: child.recordingDirectory)
        #expect(childEvents.map(\.kind) == [.session, .prompt, .response])
        #expect(childEvents.first { $0.kind == .prompt }?.text == "child turn")

        // A further parent turn after the fork does not leak into the child's
        // file, and the child's turn does not leak into the parent's.
        _ = try await root.respond(to: "root turn 2")

        let rootEvents = try Self.events(in: root.recordingDirectory)
        #expect(rootEvents.map(\.kind) == [.session, .prompt, .response, .prompt, .response])
        #expect(rootEvents.filter { $0.kind == .prompt }.map(\.text) == ["root turn 1", "root turn 2"])

        let childEventsAfter = try Self.events(in: child.recordingDirectory)
        #expect(childEventsAfter.count == childEvents.count)
    }

    // MARK: - Streaming matches non-streaming

    @Test("a streaming turn records the same entry events (kinds + text) as a non-streaming turn")
    @MainActor
    func streamingMatchesNonStreamingEntryEvents() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let respondRecorder = InMemoryRecorder()
        let respondRouter = Self.makeRouter(
            container: CannedLLMContainer(text: Self.cannedText),
            recorder: respondRecorder,
            cacheDir: dir
        )
        let respondProfile = try await respondRouter.resolve(profile: Self.profile, reporting: ResolutionProgress())
        let respondSession = respondProfile.standard.makeSession()
        _ = try await respondSession.respond(to: "hello")

        let streamRecorder = InMemoryRecorder()
        let streamRouter = Self.makeRouter(
            container: CannedLLMContainer(text: Self.cannedText),
            recorder: streamRecorder,
            cacheDir: dir
        )
        let streamProfile = try await streamRouter.resolve(profile: Self.profile, reporting: ResolutionProgress())
        let streamSession = streamProfile.standard.makeSession()
        var collected = ""
        for try await chunk in await streamSession.streamResponse(to: "hello") {
            collected += chunk
        }
        #expect(collected == Self.cannedText)

        let respondEvents = await respondRecorder.events
        let streamEvents = await streamRecorder.events

        // Same kind sequence and flattened text, ignoring provenance ids/seq/ts
        // that legitimately differ across the two independent sessions — and,
        // crucially, no per-chunk events on the streaming side: the snapshot
        // diff runs exactly once, after the chunk loop completes.
        #expect(respondEvents.map(\.kind) == streamEvents.map(\.kind))
        #expect(respondEvents.map(\.text) == streamEvents.map(\.text))
        #expect(streamEvents.map(\.kind) == [.session, .prompt, .response])
    }

    // MARK: - Grammar stamping (guided path)

    @Test("a guided session's recorded entry events carry the session's grammar source")
    @MainActor
    func guidedSessionStampsGrammarOnEntryEvents() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let recorder = InMemoryRecorder()
        let router = Self.makeRouter(
            container: CannedLLMContainer(text: Self.cannedText),
            recorder: recorder,
            cacheDir: dir
        )
        let profile = try await router.resolve(profile: Self.profile, reporting: ResolutionProgress())

        // Every other test in this file exercises the plain path, whose
        // events carry `grammar == nil`. A guided session runs through the
        // very same `generate(grammar:_:)` chokepoint with a non-nil
        // grammar, so this proves the mapped entry events (not just the
        // `session` meta line) are stamped with it too.
        let grammar = Grammar.ebnf(#"root ::= "ok""#)
        let session = profile.standard.makeGuidedSession(grammar: grammar)
        _ = try await session.respond(to: "hello")

        let events = await recorder.events
        #expect(events.map(\.kind) == [.session, .prompt, .response])
        #expect(events.allSatisfy { $0.grammar == grammar.source })

        let promptEvent = try #require(events.first { $0.kind == .prompt })
        #expect(promptEvent.entry != nil)
        let responseEvent = try #require(events.first { $0.kind == .response })
        #expect(responseEvent.entry != nil)
    }

    // MARK: - Shrink clamp: never traps, resets baseline, recovers next turn

    @Test("a transcript that shrinks below persistedEntryCount does not crash; the next turn diffs from the new baseline")
    @MainActor
    func shrinkingTranscriptClampsWithoutCrashing() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let container = VariableLLMContainer()
        let recorder = InMemoryRecorder()
        let router = Self.makeRouter(container: container, recorder: recorder, cacheDir: dir)
        let profile = try await router.resolve(profile: Self.profile, reporting: ResolutionProgress())

        let session = profile.standard.makeSession()

        // Turn 1: the backend "SDK transcript" holds two entries. The diff
        // persists both and advances `persistedEntryCount` to 2.
        container.backend.entries = [
            .prompt(Transcript.Prompt(segments: [.text(Transcript.TextSegment(content: "turn1 prompt"))])),
            .response(Transcript.Response(assetIDs: [], segments: [.text(Transcript.TextSegment(content: "turn1 response"))])),
        ]
        _ = try await session.respond(to: "turn1")

        var events = await recorder.events
        #expect(events.map(\.kind) == [.session, .prompt, .response])

        // Turn 2: the backend's transcript *shrinks* to a single entry — fewer
        // than the 2 already persisted. This must never trap: it logs a
        // warning, records nothing for this turn, and resets the baseline to
        // the smaller count (1) instead of indexing `entries[2...]` on a
        // 1-element array.
        container.backend.entries = [
            .prompt(Transcript.Prompt(segments: [.text(Transcript.TextSegment(content: "post-shrink prompt"))]))
        ]
        _ = try await session.respond(to: "turn2")

        events = await recorder.events
        // No new entry events from the shrunk turn — only the router-only
        // bodyless-close-equivalent is absent too, since this turn succeeded
        // (not threw); a successful turn with a shrink simply adds nothing.
        #expect(events.map(\.kind) == [.session, .prompt, .response])

        // Turn 3: the backend grows again, from the *new* (post-shrink)
        // baseline of 1. Two more entries are appended past index 1.
        let toolCall = Transcript.ToolCall(
            id: UUID().uuidString,
            toolName: "lookup",
            arguments: try GeneratedContent(json: "{}")
        )
        container.backend.entries = [
            .prompt(Transcript.Prompt(segments: [.text(Transcript.TextSegment(content: "post-shrink prompt"))])),
            .toolCalls(Transcript.ToolCalls([toolCall])),
            .response(Transcript.Response(assetIDs: [], segments: [.text(Transcript.TextSegment(content: "turn3 response"))])),
        ]
        _ = try await session.respond(to: "turn3")

        events = await recorder.events
        // Diffing from the reset baseline (1) recovers correctly: the two
        // entries past index 1 (`.toolCalls`, `.response`) are newly persisted.
        #expect(events.map(\.kind) == [.session, .prompt, .response, .toolCalls, .response])
        #expect(events.last?.text == "turn3 response")
    }

    @Test("a transcript that shrinks below persistedEntryCount during a streaming turn does not crash; the next turn diffs from the new baseline")
    @MainActor
    func streamingShrinkingTranscriptClampsWithoutCrashing() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let container = VariableLLMContainer()
        let recorder = InMemoryRecorder()
        let router = Self.makeRouter(container: container, recorder: recorder, cacheDir: dir)
        let profile = try await router.resolve(profile: Self.profile, reporting: ResolutionProgress())

        let session = profile.standard.makeSession()

        // Turn 1 (streaming): the backend "SDK transcript" holds two entries.
        // The diff persists both and advances `persistedEntryCount` to 2,
        // mirroring shrinkingTranscriptClampsWithoutCrashing's non-streaming
        // turn 1 but driven through streamResponse(to:) instead.
        container.backend.entries = [
            .prompt(Transcript.Prompt(segments: [.text(Transcript.TextSegment(content: "turn1 prompt"))])),
            .response(Transcript.Response(assetIDs: [], segments: [.text(Transcript.TextSegment(content: "turn1 response"))])),
        ]
        for try await _ in await session.streamResponse(to: "turn1") {}

        var events = await recorder.events
        #expect(events.map(\.kind) == [.session, .prompt, .response])

        // Turn 2 (streaming): the backend's transcript *shrinks* to a single
        // entry — fewer than the 2 already persisted. This must never trap
        // on the streaming path either: it logs a warning, records nothing
        // for this turn, and resets the baseline to the smaller count (1).
        container.backend.entries = [
            .prompt(Transcript.Prompt(segments: [.text(Transcript.TextSegment(content: "post-shrink prompt"))]))
        ]
        for try await _ in await session.streamResponse(to: "turn2") {}

        events = await recorder.events
        #expect(events.map(\.kind) == [.session, .prompt, .response])

        // Turn 3 (streaming): the backend grows again, from the *new*
        // (post-shrink) baseline of 1. Two more entries are appended past
        // index 1, proving the streaming path recovers exactly like the
        // non-streaming path does.
        let toolCall = Transcript.ToolCall(
            id: UUID().uuidString,
            toolName: "lookup",
            arguments: try GeneratedContent(json: "{}")
        )
        container.backend.entries = [
            .prompt(Transcript.Prompt(segments: [.text(Transcript.TextSegment(content: "post-shrink prompt"))])),
            .toolCalls(Transcript.ToolCalls([toolCall])),
            .response(Transcript.Response(assetIDs: [], segments: [.text(Transcript.TextSegment(content: "turn3 response"))])),
        ]
        for try await _ in await session.streamResponse(to: "turn3") {}

        events = await recorder.events
        #expect(events.map(\.kind) == [.session, .prompt, .response, .toolCalls, .response])
        #expect(events.last?.text == "turn3 response")
    }

    // MARK: - Throwing turn whose SDK transcript already gained a real .response

    @Test("a turn that throws after the SDK durably appended a real .response entry records exactly one .response event")
    @MainActor
    func throwingTurnWithRealResponseEntryRecordsExactlyOneResponseEvent() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let container = VariableLLMContainer()
        let recorder = InMemoryRecorder()
        let router = Self.makeRouter(container: container, recorder: recorder, cacheDir: dir)
        let profile = try await router.resolve(profile: Self.profile, reporting: ResolutionProgress())

        let session = profile.standard.makeSession()

        // Simulates a post-generation failure (e.g. a guardrail or validation
        // error raised after the SDK already durably appended the turn's
        // `.prompt` and `.response` entries): the backend's transcript holds a
        // real `.response` entry, but `respond` still throws.
        container.backend.entries = [
            .prompt(Transcript.Prompt(segments: [.text(Transcript.TextSegment(content: "will fail"))])),
            .response(Transcript.Response(assetIDs: [], segments: [.text(Transcript.TextSegment(content: "got this far"))])),
        ]
        container.backend.shouldThrow = true

        await #expect(throws: (any Error).self) {
            _ = try await session.respond(to: "will fail")
        }

        let events = await recorder.events
        // Exactly one `.response` event — the SDK's own, not a duplicated
        // synthetic close — proving `generate(grammar:_:)` does not double up
        // when `recordTranscriptDelta` already persisted a real `.response`.
        #expect(events.map(\.kind) == [.session, .prompt, .response])
        let responseEvent = try #require(events.first { $0.kind == .response })
        // It is the SDK's own entry (non-nil `entry`, its real text), not the
        // router-only bodyless synthetic close (which carries neither), and it
        // still carries the turn's `ms` since it is the diff's last
        // `.response`-kind event.
        #expect(responseEvent.entry != nil)
        #expect(responseEvent.text == "got this far")
        #expect(responseEvent.ms != nil)
    }

    @Test("a streaming turn that throws after the SDK durably appended a real .response entry records exactly one .response event")
    @MainActor
    func streamingThrowWithRealResponseEntryRecordsExactlyOneResponseEvent() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let container = VariableLLMContainer()
        let recorder = InMemoryRecorder()
        let router = Self.makeRouter(container: container, recorder: recorder, cacheDir: dir)
        let profile = try await router.resolve(profile: Self.profile, reporting: ResolutionProgress())

        let session = profile.standard.makeSession()

        // Mirrors throwingTurnWithRealResponseEntryRecordsExactlyOneResponseEvent
        // but drives the same scenario through streamResponse(to:): the
        // streaming path shares generate(grammar:_:)'s throw handling, so
        // the same double-close regression must not reappear there either.
        container.backend.entries = [
            .prompt(Transcript.Prompt(segments: [.text(Transcript.TextSegment(content: "will fail"))])),
            .response(Transcript.Response(assetIDs: [], segments: [.text(Transcript.TextSegment(content: "got this far"))])),
        ]
        container.backend.shouldThrow = true

        await #expect(throws: (any Error).self) {
            for try await _ in await session.streamResponse(to: "will fail") {}
        }

        let events = await recorder.events
        // Exactly one `.response` event — the SDK's own, not a duplicated
        // synthetic close — proving the streaming path does not double up
        // when `recordTranscriptDelta` already persisted a real `.response`.
        #expect(events.map(\.kind) == [.session, .prompt, .response])
        let responseEvent = try #require(events.first { $0.kind == .response })
        #expect(responseEvent.entry != nil)
        #expect(responseEvent.text == "got this far")
        #expect(responseEvent.ms != nil)
    }

    // MARK: - Helpers

    /// Decodes every event from a session directory's `transcript.jsonl`.
    private static func events(in directory: URL) throws -> [TranscriptEvent] {
        let fileURL = directory.appendingPathComponent("transcript.jsonl", isDirectory: false)
        let text = try String(contentsOf: fileURL, encoding: .utf8)
        let decoder = JSONDecoder()
        return try text.split(separator: "\n").map {
            try decoder.decode(TranscriptEvent.self, from: Data($0.utf8))
        }
    }
}
