import Foundation
import FoundationModels
import FoundationModelsRouterTestSupport
import Testing

@testable import FoundationModelsRouter

/// Exercises task qb9p7gs: the `generate` chokepoint's snapshot-diff
/// persistence — recorded per-turn content events are derived exclusively
/// from `backend.transcriptEntries()` deltas, not from hand-built
/// prompt/response strings. See plan.md's "Transcript fidelity" section and
/// ``RoutedSessionActor/recordTranscriptDelta(grammar:since:usage:pendingEvents:onEvent:)``.
///
/// Everything runs against stubs — a stub ``ModelLoader``, canned/variable LLM
/// containers, and either a ``JSONLRecorder`` writing into a temp directory or
/// an ``InMemoryRecorder`` — so the suite needs no network and no GPU.
@Suite("Snapshot-diff persistence: real transcript entries")
struct TranscriptFidelityTests {
    // MARK: - Stub containers

    /// A stand-in for a loaded LLM container that returns canned text, no MLX.
    private struct CannedLLMContainer: PlainTranscriptStubContainer {
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
    /// `RoutedSessionActor`'s chokepoint is further serialized by the owning
    /// session's turn lock — nothing ever touches this instance concurrently.
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

        /// No usage is tracked here — this suite exercises snapshot-diff
        /// transcript persistence, not token metering (covered separately in
        /// `TokenUsageMeteringTests`).
        func usageTokenCounts() -> (input: Int, output: Int)? {
            nil
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

        func makeSession(transcript: Transcript) -> any LanguageModelSessionBackend {
            backend.entries = Array(transcript)
            return backend
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

    // MARK: - Shrink: the unseen entries and a marker are appended, the next turn diffs from the shrunken transcript

    /// Runs the three turns of the shrink scenario through `turn`, one call
    /// per turn, and asserts what the recorder holds after each one. The
    /// non-streaming and the streaming turn share this one script.
    @MainActor
    private static func assertShrinkAppendsUnseenEntries(
        container: VariableLLMContainer,
        recorder: InMemoryRecorder,
        turn: (String) async throws -> Void
    ) async throws {
        // Turn 1: the backend "SDK transcript" holds two entries. The diff
        // persists both and advances `persistedEntryCount` to 2.
        container.backend.entries = [
            .prompt(Transcript.Prompt(segments: [.text(Transcript.TextSegment(content: "turn1 prompt"))])),
            .response(Transcript.Response(segments: [.text(Transcript.TextSegment(content: "turn1 response"))])),
        ]
        try await turn("turn1")

        var events = await recorder.events
        #expect(events.map(\.kind) == [.session, .prompt, .response])

        // Turn 2: the backend's transcript *shrinks* to one entry the record
        // has never seen — fewer entries than the 2 already persisted. A
        // transcript only appends: the unseen entry is recorded, then one
        // `.divergence` marker that says the transcript shrank, and nothing
        // that was recorded before goes away.
        let postShrinkPrompt = Transcript.Entry.prompt(
            Transcript.Prompt(segments: [.text(Transcript.TextSegment(content: "post-shrink prompt"))]))
        container.backend.entries = [postShrinkPrompt]
        try await turn("turn2")

        events = await recorder.events
        #expect(events.map(\.kind) == [.session, .prompt, .response, .prompt, .divergence])
        let recordedAfterShrink = events.filter { $0.text == "post-shrink prompt" }
        #expect(recordedAfterShrink.count == 1)
        let marker = try #require(events.last)
        #expect(marker.text?.contains("shrank") == true)
        #expect(marker.entry == nil)

        // Turn 3: the backend grows again past the shrunken transcript, which
        // is the baseline now. The two new entries are appended after the
        // marker.
        let toolCall = Transcript.ToolCall(
            id: UUID().uuidString,
            toolName: "lookup",
            arguments: try GeneratedContent(json: "{}")
        )
        container.backend.entries = [
            postShrinkPrompt,
            .toolCalls(Transcript.ToolCalls([toolCall])),
            .response(Transcript.Response(segments: [.text(Transcript.TextSegment(content: "turn3 response"))])),
        ]
        try await turn("turn3")

        events = await recorder.events
        #expect(
            events.map(\.kind) == [.session, .prompt, .response, .prompt, .divergence, .toolCalls, .response])
        #expect(events.last?.text == "turn3 response")
    }

    @Test("a transcript that shrinks below persistedEntryCount records its unseen entries and a divergence marker; the next turn diffs from the shrunken transcript")
    @MainActor
    func shrinkingTranscriptAppendsUnseenEntriesAndAMarker() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let container = VariableLLMContainer()
        let recorder = InMemoryRecorder()
        let router = Self.makeRouter(container: container, recorder: recorder, cacheDir: dir)
        let profile = try await router.resolve(profile: Self.profile, reporting: ResolutionProgress())

        let session = profile.standard.makeSession()
        try await Self.assertShrinkAppendsUnseenEntries(container: container, recorder: recorder) { prompt in
            _ = try await session.respond(to: prompt)
        }
    }

    @Test("a transcript that shrinks below persistedEntryCount during a streaming turn records its unseen entries and a divergence marker; the next turn diffs from the shrunken transcript")
    @MainActor
    func streamingShrinkingTranscriptAppendsUnseenEntriesAndAMarker() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let container = VariableLLMContainer()
        let recorder = InMemoryRecorder()
        let router = Self.makeRouter(container: container, recorder: recorder, cacheDir: dir)
        let profile = try await router.resolve(profile: Self.profile, reporting: ResolutionProgress())

        // Mirrors the non-streaming scenario but drives every turn through
        // streamResponse(to:), so the streaming path appends the same events.
        let session = profile.standard.makeSession()
        try await Self.assertShrinkAppendsUnseenEntries(container: container, recorder: recorder) { prompt in
            for try await _ in await session.streamResponse(to: prompt) {}
        }
    }

    // MARK: - Non-append divergence: the turn's entries, then a loud marker beside them

    @Test("an in-place rewrite of an already-recorded entry records a divergence marker after the turn's entries, never a second event under the recorded id, and the next turn appends past it")
    @MainActor
    func inPlaceRewriteRecordsDivergenceMarkerAndRecovers() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let container = VariableLLMContainer()
        let recorder = InMemoryRecorder()
        let router = Self.makeRouter(container: container, recorder: recorder, cacheDir: dir)
        let profile = try await router.resolve(profile: Self.profile, reporting: ResolutionProgress())

        let session = profile.standard.makeSession()

        // Turn 1: two entries, both recorded. The `.response` carries an
        // explicit id so turn 2 can rewrite it IN PLACE — same id, same
        // count, changed content — the shape a positional diff cannot see.
        let promptEntry = Transcript.Entry.prompt(
            Transcript.Prompt(segments: [.text(Transcript.TextSegment(content: "turn1 prompt"))]))
        let responseId = UUID().uuidString
        container.backend.entries = [
            promptEntry,
            .response(Transcript.Response(id: responseId, segments: [.text(Transcript.TextSegment(content: "turn1 response"))])),
        ]
        _ = try await session.respond(to: "turn1")

        var events = await recorder.events
        #expect(events.map(\.kind) == [.session, .prompt, .response])

        // Turn 2: the backend rewrites the recorded `.response` in place. The
        // recorded id is already in the record, so no entry is new and the
        // turn appends one loud `.divergence` marker — never a second event
        // under the recorded id, and never a silently-stale record with no
        // signal at all.
        container.backend.entries = [
            promptEntry,
            .response(Transcript.Response(id: responseId, segments: [.text(Transcript.TextSegment(content: "rewritten response"))])),
        ]
        _ = try await session.respond(to: "turn2")

        events = await recorder.events
        #expect(events.map(\.kind) == [.session, .prompt, .response, .divergence])
        let marker = try #require(events.first { $0.kind == .divergence })
        #expect(marker.text != nil)
        #expect(marker.entry == nil)

        // Turn 3: the rewritten transcript is the baseline now, so an append
        // past it records normally again.
        container.backend.entries.append(
            .response(Transcript.Response(segments: [.text(Transcript.TextSegment(content: "turn3 response"))])))
        _ = try await session.respond(to: "turn3")

        events = await recorder.events
        #expect(events.map(\.kind) == [.session, .prompt, .response, .divergence, .response])
        #expect(events.last?.text == "turn3 response")
    }

    @Test("a mid-transcript insertion records the inserted entry, then a divergence marker, and never re-records (duplicates) the tail")
    @MainActor
    func midTranscriptInsertionRecordsInsertedEntryThenMarkerWithoutDuplicatingTail() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let container = VariableLLMContainer()
        let recorder = InMemoryRecorder()
        let router = Self.makeRouter(container: container, recorder: recorder, cacheDir: dir)
        let profile = try await router.resolve(profile: Self.profile, reporting: ResolutionProgress())

        let session = profile.standard.makeSession()

        // Turn 1: two entries, both recorded. The entry VALUES are kept so
        // turn 2's insertion leaves their ids intact around the new entry.
        let promptEntry = Transcript.Entry.prompt(
            Transcript.Prompt(segments: [.text(Transcript.TextSegment(content: "turn1 prompt"))]))
        let responseEntry = Transcript.Entry.response(
            Transcript.Response(segments: [.text(Transcript.TextSegment(content: "turn1 response"))]))
        container.backend.entries = [promptEntry, responseEntry]
        _ = try await session.respond(to: "turn1")

        var events = await recorder.events
        #expect(events.map(\.kind) == [.session, .prompt, .response])

        // Turn 2: the backend inserts an entry MID-transcript, so the count
        // grows but the new entry is not at the tail. A purely positional
        // diff would re-record the last entry (the old tail) as if it were
        // new. The diff runs by entry id instead: the inserted entry, whose
        // id the record has never seen, is appended, then a loud
        // `.divergence` marker, and the tail is not duplicated.
        container.backend.entries = [
            promptEntry,
            .prompt(Transcript.Prompt(segments: [.text(Transcript.TextSegment(content: "inserted prompt"))])),
            responseEntry,
        ]
        _ = try await session.respond(to: "turn2")

        events = await recorder.events
        #expect(events.map(\.kind) == [.session, .prompt, .response, .prompt, .divergence])
        #expect(events.filter { $0.text == "inserted prompt" }.count == 1)
        #expect(events.filter { $0.text == "turn1 response" }.count == 1)

        // Turn 3: the transcript with the insertion is the baseline now, so
        // an append past it records normally again.
        container.backend.entries.append(
            .response(Transcript.Response(segments: [.text(Transcript.TextSegment(content: "turn3 response"))])))
        _ = try await session.respond(to: "turn3")

        events = await recorder.events
        #expect(events.map(\.kind) == [.session, .prompt, .response, .prompt, .divergence, .response])
        #expect(events.last?.text == "turn3 response")
    }

    @Test("a turn that diverges is recorded whole: its prompt, its toolCalls with argumentsJSON, its response with an entry, then the divergence marker beside them")
    @MainActor
    func divergedTurnRecordsItsEntriesThenTheMarker() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let container = VariableLLMContainer()
        let recorder = InMemoryRecorder()
        let router = Self.makeRouter(container: container, recorder: recorder, cacheDir: dir)
        let profile = try await router.resolve(profile: Self.profile, reporting: ResolutionProgress())

        let session = profile.standard.makeSession()

        // Turn 1: two entries, both recorded. The `.response` carries an
        // explicit id so turn 2 can rewrite it in place.
        let promptEntry = Transcript.Entry.prompt(
            Transcript.Prompt(segments: [.text(Transcript.TextSegment(content: "turn1 prompt"))]))
        let responseId = UUID().uuidString
        container.backend.entries = [
            promptEntry,
            .response(Transcript.Response(id: responseId, segments: [.text(Transcript.TextSegment(content: "turn1 response"))])),
        ]
        _ = try await session.respond(to: "turn1")

        // Turn 2: the backend rewrites the recorded `.response` in place AND
        // appends a whole tool-using turn after it. The divergence is a note
        // about the record, not a reason to drop the turn: the turn's three
        // new entries are appended in transcript order, then the marker.
        let arguments = try GeneratedContent(json: #"{"query":"weather"}"#)
        let toolCalls = Transcript.ToolCalls(
            id: "calls-1", [Transcript.ToolCall(id: "call-1", toolName: "lookup", arguments: arguments)])
        container.backend.entries = [
            promptEntry,
            .response(Transcript.Response(id: responseId, segments: [.text(Transcript.TextSegment(content: "rewritten response"))])),
            .prompt(Transcript.Prompt(segments: [.text(Transcript.TextSegment(content: "turn2 prompt"))])),
            .toolCalls(toolCalls),
            .response(Transcript.Response(id: "resp-2", segments: [.text(Transcript.TextSegment(content: "turn2 response"))])),
        ]
        _ = try await session.respond(to: "turn2")

        let events = await recorder.events
        #expect(events.map(\.kind) == [.session, .prompt, .response, .prompt, .toolCalls, .response, .divergence])
        #expect(events.filter { $0.text == "turn1 response" }.count == 1)

        let turnTwoPrompt = try #require(events.first { $0.text == "turn2 prompt" })
        #expect(turnTwoPrompt.entry != nil)

        let recordedToolCalls = try #require(events.first { $0.kind == .toolCalls })
        let recordedCall = try #require(recordedToolCalls.entry?.toolCalls?.first)
        #expect(recordedCall.id == "call-1")
        #expect(recordedCall.toolName == "lookup")
        #expect(recordedCall.argumentsJSON == arguments.jsonString)

        let turnTwoResponse = try #require(events.first { $0.text == "turn2 response" })
        #expect(turnTwoResponse.entry?.entryId == "resp-2")
        // The turn's own close carries the turn's `ms` stamp, as on a plain turn.
        #expect(turnTwoResponse.ms != nil)

        let marker = try #require(events.last)
        #expect(marker.kind == .divergence)
        #expect(marker.text?.contains(responseId) == true)
        #expect(marker.entry == nil)
    }

    @Test("a turn that diverges still emits SessionEvent.toolCall on the wire for the tool call it recorded")
    @MainActor
    func divergedTurnEmitsToolCallOnTheWire() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let container = VariableLLMContainer()
        let recorder = InMemoryRecorder()
        let router = Self.makeRouter(container: container, recorder: recorder, cacheDir: dir)
        let profile = try await router.resolve(profile: Self.profile, reporting: ResolutionProgress())

        let session = profile.standard.makeSession()

        let promptEntry = Transcript.Entry.prompt(
            Transcript.Prompt(segments: [.text(Transcript.TextSegment(content: "turn1 prompt"))]))
        let responseId = UUID().uuidString
        container.backend.entries = [
            promptEntry,
            .response(Transcript.Response(id: responseId, segments: [.text(Transcript.TextSegment(content: "turn1 response"))])),
        ]
        for try await _ in await session.streamEvents(to: "turn1") {}

        // Turn 2 diverges (the recorded `.response` is rewritten in place)
        // and holds one answered tool call. The wire must carry that call
        // exactly as it does for a plain turn.
        let arguments = try GeneratedContent(json: #"{"query":"weather"}"#)
        let outputSegment = Transcript.TextSegment(content: "found it")
        container.backend.entries = [
            promptEntry,
            .response(Transcript.Response(id: responseId, segments: [.text(Transcript.TextSegment(content: "rewritten response"))])),
            .prompt(Transcript.Prompt(segments: [.text(Transcript.TextSegment(content: "turn2 prompt"))])),
            .toolCalls(
                Transcript.ToolCalls(
                    id: "calls-1", [Transcript.ToolCall(id: "call-1", toolName: "lookup", arguments: arguments)])),
            .toolOutput(Transcript.ToolOutput(id: "call-1", toolName: "lookup", segments: [.text(outputSegment)])),
            .response(Transcript.Response(id: "resp-2", segments: [.text(Transcript.TextSegment(content: "ok"))])),
        ]
        var wire: [SessionEvent] = []
        for try await event in await session.streamEvents(to: "turn2") {
            wire.append(event)
        }

        #expect(
            eventsAfterTurnFrame(wire) == [
                .textDelta("ok"),
                .toolCall(id: "call-1", name: "lookup", argumentsJSON: arguments.jsonString),
                .toolStatus(id: "call-1", status: .running, summary: nil, output: nil),
                .entryRecorded(id: "calls-1", kind: .toolCalls),
                .toolStatus(
                    id: "call-1", status: .completed, summary: "found it",
                    output: [.text(id: outputSegment.id, content: "found it")]),
                .entryRecorded(id: "resp-2", kind: .response),
            ]
        )

        // And the record holds the same turn, with the marker beside it.
        let events = await recorder.events
        #expect(
            events.map(\.kind) == [
                .session, .prompt, .response, .prompt, .toolCalls, .toolOutput, .response, .divergence,
            ])
    }

    @Test("the recorded entry count never falls between two reads of one session, across a shrink, a rewrite, and a failed turn")
    @MainActor
    func recordedEntryCountNeverFallsAcrossTurns() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let container = VariableLLMContainer()
        let recorder = InMemoryRecorder()
        let router = Self.makeRouter(container: container, recorder: recorder, cacheDir: dir)
        let profile = try await router.resolve(profile: Self.profile, reporting: ResolutionProgress())

        let session = profile.standard.makeSession()

        let promptEntry = Transcript.Entry.prompt(
            Transcript.Prompt(segments: [.text(Transcript.TextSegment(content: "turn1 prompt"))]))
        let responseId = UUID().uuidString
        // Each script is what the backend holds after one turn: a plain
        // turn, a shrink, an in-place rewrite that grows, a plain append, and
        // one more plain append the failed turn below reads.
        let scripts: [[Transcript.Entry]] = [
            [
                promptEntry,
                .response(Transcript.Response(id: responseId, segments: [.text(Transcript.TextSegment(content: "turn1 response"))])),
            ],
            [promptEntry],
            [
                promptEntry,
                .response(Transcript.Response(id: responseId, segments: [.text(Transcript.TextSegment(content: "rewritten"))])),
                .prompt(Transcript.Prompt(segments: [.text(Transcript.TextSegment(content: "turn3 prompt"))])),
            ],
        ]

        var lastEventCount = 0
        var lastEntryCount = 0
        for (index, script) in scripts.enumerated() {
            container.backend.entries = script
            _ = try await session.respond(to: "turn \(index)")
            let events = await recorder.events
            #expect(events.count >= lastEventCount)
            let entryCount = events.count { $0.kind.isEntryKind }
            #expect(entryCount >= lastEntryCount)
            lastEventCount = events.count
            lastEntryCount = entryCount
        }

        // A failed turn appends its close and nothing goes away.
        container.backend.shouldThrow = true
        await #expect(throws: (any Error).self) {
            _ = try await session.respond(to: "failing turn")
        }
        let events = await recorder.events
        #expect(events.count > lastEventCount)
        #expect(events.count { $0.kind.isEntryKind } > lastEntryCount)
    }

    @Test("a bare handle whose synced transcript rewrites an entry in place records a divergence marker, never a second event under the recorded id, and appends past it on the next sync")
    @MainActor
    func handleInPlaceRewriteRecordsDivergenceMarkerAndRecovers() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let recorder = InMemoryRecorder()
        let router = Self.makeRouter(container: UndrivenLanguageModelContainer(), recorder: recorder, cacheDir: dir)
        let profile = try await router.resolve(profile: Self.profile, reporting: ResolutionProgress())

        // The bare-handle sibling of the session-path tests above:
        // `sync(_:)` runs the same last-seen-vs-current diff, so the same
        // rule holds there. Entries are fabricated directly (see
        // CompactionSegmentTests' resume test for the same technique).
        let handle = profile.standard.makeLanguageModel()
        let promptEntry = Transcript.Entry.prompt(
            Transcript.Prompt(segments: [.text(Transcript.TextSegment(content: "turn1 prompt"))]))
        let responseId = UUID().uuidString
        await handle.sync(
            Transcript(entries: [
                promptEntry,
                .response(Transcript.Response(id: responseId, segments: [.text(Transcript.TextSegment(content: "turn1 response"))])),
            ]))

        var events = await recorder.events
        #expect(events.map(\.kind) == [.session, .prompt, .response])

        // Sync 2: the same transcript with its `.response` rewritten in
        // place — same id, same count, changed content. No id is new, so
        // only the marker is appended.
        let rewrittenResponse = Transcript.Entry.response(
            Transcript.Response(id: responseId, segments: [.text(Transcript.TextSegment(content: "rewritten response"))]))
        await handle.sync(Transcript(entries: [promptEntry, rewrittenResponse]))

        events = await recorder.events
        #expect(events.map(\.kind) == [.session, .prompt, .response, .divergence])
        #expect(events.filter { $0.kind == .response }.count == 1)

        // Sync 3: the rewritten transcript is the baseline now, so an append
        // past it records normally again.
        await handle.sync(
            Transcript(entries: [
                promptEntry,
                rewrittenResponse,
                .response(Transcript.Response(segments: [.text(Transcript.TextSegment(content: "turn3 response"))])),
            ]))

        events = await recorder.events
        #expect(events.map(\.kind) == [.session, .prompt, .response, .divergence, .response])
        #expect(events.last?.text == "turn3 response")
    }

    @Test("a bare handle whose synced transcript rewrites an entry in place and appends a new one records the new entry, then the divergence marker")
    @MainActor
    func handleDivergedSyncRecordsItsNewEntriesThenTheMarker() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let recorder = InMemoryRecorder()
        let router = Self.makeRouter(container: UndrivenLanguageModelContainer(), recorder: recorder, cacheDir: dir)
        let profile = try await router.resolve(profile: Self.profile, reporting: ResolutionProgress())

        let handle = profile.standard.makeLanguageModel()
        let promptEntry = Transcript.Entry.prompt(
            Transcript.Prompt(segments: [.text(Transcript.TextSegment(content: "turn1 prompt"))]))
        let responseId = UUID().uuidString
        await handle.sync(
            Transcript(entries: [
                promptEntry,
                .response(Transcript.Response(id: responseId, segments: [.text(Transcript.TextSegment(content: "turn1 response"))])),
            ]))

        // Sync 2: the recorded `.response` is rewritten in place AND a new
        // `.response` follows it. The new entry is appended, then the marker.
        await handle.sync(
            Transcript(entries: [
                promptEntry,
                .response(Transcript.Response(id: responseId, segments: [.text(Transcript.TextSegment(content: "rewritten response"))])),
                .response(Transcript.Response(segments: [.text(Transcript.TextSegment(content: "second response"))])),
            ]))

        let events = await recorder.events
        #expect(events.map(\.kind) == [.session, .prompt, .response, .response, .divergence])
        #expect(events.filter { $0.kind == .response }.map(\.text) == ["turn1 response", "second response"])
        let marker = try #require(events.last)
        #expect(marker.text?.contains(responseId) == true)
    }

    @Test("a bare handle whose synced transcript shrinks records the unseen entries, then a divergence marker, and appends past the shrunken transcript on the next sync")
    @MainActor
    func handleShrinkRecordsUnseenEntriesThenTheMarker() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let recorder = InMemoryRecorder()
        let router = Self.makeRouter(container: UndrivenLanguageModelContainer(), recorder: recorder, cacheDir: dir)
        let profile = try await router.resolve(profile: Self.profile, reporting: ResolutionProgress())

        let handle = profile.standard.makeLanguageModel()
        await handle.sync(
            Transcript(entries: [
                .prompt(Transcript.Prompt(segments: [.text(Transcript.TextSegment(content: "turn1 prompt"))])),
                .response(Transcript.Response(segments: [.text(Transcript.TextSegment(content: "turn1 response"))])),
            ]))

        var events = await recorder.events
        #expect(events.map(\.kind) == [.session, .prompt, .response])

        // Sync 2: the transcript shrinks to one entry the record has never
        // seen. That entry is appended, then the marker.
        let postShrinkPrompt = Transcript.Entry.prompt(
            Transcript.Prompt(segments: [.text(Transcript.TextSegment(content: "post-shrink prompt"))]))
        await handle.sync(Transcript(entries: [postShrinkPrompt]))

        events = await recorder.events
        #expect(events.map(\.kind) == [.session, .prompt, .response, .prompt, .divergence])
        let marker = try #require(events.last)
        #expect(marker.text?.contains("shrank") == true)

        // Sync 3: the shrunken transcript is the baseline now, so an append
        // past it records normally again.
        await handle.sync(
            Transcript(entries: [
                postShrinkPrompt,
                .response(Transcript.Response(segments: [.text(Transcript.TextSegment(content: "turn3 response"))])),
            ]))

        events = await recorder.events
        #expect(events.map(\.kind) == [.session, .prompt, .response, .prompt, .divergence, .response])
        #expect(events.last?.text == "turn3 response")
    }

    // MARK: - Unchanged tool surface across turns: no false divergence

    @Test("two turns over one unchanged tool surface record no divergence marker")
    @MainActor
    func unchangedToolSurfaceAcrossTurnsRecordsNoDivergence() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let recorder = InMemoryRecorder()
        let router = Self.makeRouter(container: UndrivenLanguageModelContainer(), recorder: recorder, cacheDir: dir)
        let profile = try await router.resolve(profile: Self.profile, reporting: ResolutionProgress())

        // A consuming agent builds its one `LanguageModelSession` over a
        // handle and mounts a fixed tool surface for the session's life. The
        // handle's first sync sees the session's opening transcript — the
        // `.instructions` entry alone — so for the first turn that entry is
        // the baseline's boundary at index 0. Its tool definitions never
        // change, so no later turn may read it as rewritten.
        let handle = profile.standard.makeLanguageModel()
        let instructions = FixedToolSurface.instructionsEntry(id: "instr-1", text: "be terse")
        await handle.sync(Transcript(entries: [instructions]))

        let firstTurn: [Transcript.Entry] = [
            instructions,
            .prompt(Transcript.Prompt(segments: [.text(Transcript.TextSegment(content: "turn1 prompt"))])),
            .response(Transcript.Response(segments: [.text(Transcript.TextSegment(content: "turn1 response"))])),
        ]
        await handle.sync(Transcript(entries: firstTurn))

        let secondTurn: [Transcript.Entry] = firstTurn + [
            .prompt(Transcript.Prompt(segments: [.text(Transcript.TextSegment(content: "turn2 prompt"))])),
            .response(Transcript.Response(segments: [.text(Transcript.TextSegment(content: "turn2 response"))])),
        ]
        await handle.sync(Transcript(entries: secondTurn))

        let events = await recorder.events
        #expect(events.map(\.kind) == [.session, .instructions, .prompt, .response, .prompt, .response])
        #expect(!events.contains { $0.kind == .divergence })
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
            .response(Transcript.Response(segments: [.text(Transcript.TextSegment(content: "got this far"))])),
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
        // It is the SDK's own entry (an entry with a segment, its real text),
        // not the router-only synthetic close (an entry with no segment and
        // no text), and it
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
            .response(Transcript.Response(segments: [.text(Transcript.TextSegment(content: "got this far"))])),
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
        let decoder = JSONDecoder()
        return try TextFileLines.read(from: fileURL).map {
            try decoder.decode(TranscriptEvent.self, from: Data($0.utf8))
        }
    }
}
