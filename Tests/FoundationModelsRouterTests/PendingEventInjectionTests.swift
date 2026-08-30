import Foundation
import FoundationModels
import Testing

@testable import FoundationModelsRouter

/// Exercises task 9drp1rz: draining a session's `SessionOutbox` at the
/// start of a turn, composing the drained events into the model-visible
/// prompt as a plain-text preamble, and persisting the same events as typed
/// ``OperationEventSegment``s on the recorded `.prompt` entry.
///
/// Everything runs against stubs — a plain ``StubSessionBackend`` and an
/// ``InMemoryRecorder`` — so the suite needs no network and no GPU.
@Suite("Pending event injection: outbox drain -> turn preamble + persisted custom segment")
struct PendingEventInjectionTests {
    // MARK: - Stub container

    private final class BasicLLMContainer: PlainTranscriptStubContainer {
        let responseText: String
        init(responseText: String = "stub response") {
            self.responseText = responseText
        }
        func makeSession(instructions: String?) -> any LanguageModelSessionBackend {
            StubSessionBackend(responseText: responseText)
        }
    }

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
            .appendingPathComponent("PendingEventInjectionTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Builds a fresh router + resolved profile + vended session over a plain
    /// stub backend, recording through `recorder`.
    private static func makeSession(
        recorder: any TranscriptRecorder,
        responseText: String = "stub response"
    ) async throws -> (session: RoutedSession, dir: URL) {
        let dir = Self.makeTempDir()
        let container = BasicLLMContainer(responseText: responseText)
        let router = Router(
            cacheDir: dir,
            recorder: recorder,
            probe: StubProbe(chip: "Apple Test", totalRAM: 64 << 30, recommendedMaxWorkingSetSize: 48 << 30),
            metadataSource: StubMetadataSource(raw: rawMetadata),
            loader: StubModelLoader(container: container, dimension: stubDimension)
        )
        let profile = try await router.resolve(profile: Self.profile, reporting: ResolutionProgress())
        return (profile.standard.makeSession(), dir)
    }

    /// Builds a canned ``OperationEvent`` for a given tool/correlation/kind.
    private static func event(
        tool: String = "shell",
        op: String = "run command",
        correlationID: String = "1",
        kind: OperationEventKind,
        detail: String
    ) -> OperationEvent {
        OperationEvent(tool: tool, op: op, correlationID: correlationID, kind: kind, detail: detail)
    }

    // MARK: - Preamble rendering format

    @Test("renderedLine renders tool, op, correlationID, state, and detail as one line")
    func renderedLineFormat() {
        let completed = Self.event(tool: "shell", op: "run command", correlationID: "3", kind: .completed, detail: "exit 0, 2481 lines")
        #expect(
            OperationEventSegment.renderedLine(for: completed)
                == "[shell] run command (3) completed: exit 0, 2481 lines")

        let progress = Self.event(tool: "shell", op: "run command", correlationID: "3", kind: .progress, detail: "812 lines so far")
        #expect(
            OperationEventSegment.renderedLine(for: progress)
                == "[shell] run command (3) running: 812 lines so far")
    }

    // MARK: - Empty outbox: byte-identical behavior

    @Test("an empty outbox leaves the prompt and recorded transcript unchanged")
    @MainActor
    func emptyOutboxIsNoOp() async throws {
        let recorder = InMemoryRecorder()
        let (session, dir) = try await Self.makeSession(recorder: recorder)
        defer { try? FileManager.default.removeItem(at: dir) }

        let text = try await session.respond(to: "hello")
        #expect(text == "stub response")

        let events = await recorder.events
        let promptEvent = try #require(events.first { $0.kind == .prompt })
        #expect(promptEvent.text == "hello")
        #expect(promptEvent.entry?.segments?.count == 1)
        guard case .text = promptEvent.entry?.segments?.first else {
            Issue.record("expected the sole segment to be the plain .text prompt, with no injected custom segment")
            return
        }
    }

    // MARK: - A single pending event becomes a preamble + a persisted segment

    @Test("a pending .completed event's rendered line begins the model-visible prompt and is persisted as a custom segment")
    @MainActor
    func pendingCompletedEventBecomesPreambleAndSegment() async throws {
        let recorder = InMemoryRecorder()
        let (session, dir) = try await Self.makeSession(recorder: recorder)
        defer { try? FileManager.default.removeItem(at: dir) }

        let posted = Self.event(correlationID: "3", kind: .completed, detail: "exit 0, 2481 lines")
        await session.outbox.post(event: posted)

        _ = try await session.respond(to: "what happened?")

        let events = await recorder.events
        let promptEvent = try #require(events.first { $0.kind == .prompt })
        let expectedLine = OperationEventSegment.renderedLine(for: posted)
        #expect(promptEvent.text == expectedLine + "\n\nwhat happened?")

        let segments = try #require(promptEvent.entry?.segments)
        #expect(segments.count == 2)
        guard case .structure(let id, let schemaName, let contentJSON) = segments.last else {
            Issue.record("expected a trailing .structure segment")
            return
        }
        #expect(!id.isEmpty)
        #expect(schemaName == OperationEventSegment.schemaName)
        let decoded = try JSONDecoder().decode(OperationEvent.self, from: Data(contentJSON.utf8))
        #expect(decoded == posted)
        // The segment and the preamble line are two views of one event, so the
        // line the segment renders is the line the preamble carried.
        #expect(OperationEventSegment.renderedLine(for: decoded) == expectedLine)
    }

    @Test("a drained event does not reappear on the next turn")
    @MainActor
    func drainedEventDoesNotReappearNextTurn() async throws {
        let recorder = InMemoryRecorder()
        let (session, dir) = try await Self.makeSession(recorder: recorder)
        defer { try? FileManager.default.removeItem(at: dir) }

        await session.outbox.post(event: Self.event(correlationID: "1", kind: .completed, detail: "first"))
        _ = try await session.respond(to: "first turn")
        _ = try await session.respond(to: "second turn")

        let events = await recorder.events
        let promptEvents = events.filter { $0.kind == .prompt }
        #expect(promptEvents.count == 2)
        #expect(promptEvents[1].text == "second turn")
        #expect(promptEvents[1].entry?.segments?.count == 1)
    }

    // MARK: - Multiple pending events preserve outbox order

    @Test("multiple pending events render and persist in outbox order (coalesced progress collapses first)")
    @MainActor
    func multiplePendingEventsPreserveOutboxOrder() async throws {
        let recorder = InMemoryRecorder()
        let (session, dir) = try await Self.makeSession(recorder: recorder)
        defer { try? FileManager.default.removeItem(at: dir) }

        // Two .progress posts for the same correlation coalesce to the
        // latest; the interleaved .completed for a different correlation
        // survives alongside it, in post order.
        await session.outbox.post(event: Self.event(correlationID: "c1", kind: .progress, detail: "10%"))
        await session.outbox.post(event: Self.event(correlationID: "c1", kind: .progress, detail: "50%"))
        await session.outbox.post(event: Self.event(correlationID: "c2", kind: .completed, detail: "done"))

        _ = try await session.respond(to: "status?")

        let expectedEvents = [
            Self.event(correlationID: "c1", kind: .progress, detail: "50%"),
            Self.event(correlationID: "c2", kind: .completed, detail: "done"),
        ]
        let expectedPreamble = expectedEvents.map(OperationEventSegment.renderedLine(for:)).joined(separator: "\n")

        let events = await recorder.events
        let promptEvent = try #require(events.first { $0.kind == .prompt })
        #expect(promptEvent.text == expectedPreamble + "\n\nstatus?")

        let segmentEvents: [OperationEvent] = (promptEvent.entry?.segments ?? []).compactMap { segment in
            guard case .structure(_, let schemaName, let contentJSON) = segment,
                schemaName == OperationEventSegment.schemaName
            else { return nil }
            return try? JSONDecoder().decode(OperationEvent.self, from: Data(contentJSON.utf8))
        }
        #expect(segmentEvents == expectedEvents)
    }

    // MARK: - A turn whose backend throws before appending anything survives

    /// Mirrors `MLXFoundationModelsSessionBackend.respond(to:following:maxTokens:)`'s
    /// `.ebnf` path (`Sources/FoundationModelsRouter/Resolution/LiveModelLoader.swift`):
    /// it calls `grammar.validateForXGrammar()` and throws *before ever
    /// touching its live session* — so `transcriptEntries()` never gains
    /// anything for the turn at all, on every single call. Every generation
    /// entry point on this backend always throws immediately, without
    /// appending anything to ``entries``.
    ///
    /// `@unchecked Sendable` is safe here because the type carries no stored
    /// state at all — every method is a pure function of its arguments
    /// (throwing `Failure.boom` or returning a fixed empty/`nil` value) with
    /// nothing to race on across isolation boundaries.
    private final class ThrowsBeforeAppendingBackend: LanguageModelSessionBackend, @unchecked Sendable {
        enum Failure: Error { case boom }

        func respond(to prompt: String, maxTokens: Int?) async throws -> String {
            throw Failure.boom
        }

        func streamResponse(to prompt: String, maxTokens: Int?) -> AsyncThrowingStream<String, Error> {
            AsyncThrowingStream { continuation in continuation.finish(throwing: Failure.boom) }
        }

        func respond(to prompt: String, following grammar: Grammar, maxTokens: Int?) async throws -> String {
            throw Failure.boom
        }

        func makeFork() -> any LanguageModelSessionBackend { ThrowsBeforeAppendingBackend() }
        func transcriptEntries() -> [Transcript.Entry] { [] }
        func usageTokenCounts() -> (input: Int, output: Int)? { nil }
    }

    private final class ThrowsBeforeAppendingContainer: LoadedLLMContainer {
        func makeSession(instructions: String?) -> any LanguageModelSessionBackend {
            ThrowsBeforeAppendingBackend()
        }
        func makeSession(transcript: Transcript) -> any LanguageModelSessionBackend {
            ThrowsBeforeAppendingBackend()
        }
    }

    @Test("a pending event survives a turn whose backend throws before appending anything to its transcript")
    @MainActor
    func pendingEventSurvivesThrowBeforeAnyTranscriptAppend() async throws {
        let recorder = InMemoryRecorder()
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let router = Router(
            cacheDir: dir,
            recorder: recorder,
            probe: StubProbe(chip: "Apple Test", totalRAM: 64 << 30, recommendedMaxWorkingSetSize: 48 << 30),
            metadataSource: StubMetadataSource(raw: Self.rawMetadata),
            loader: StubModelLoader(container: ThrowsBeforeAppendingContainer(), dimension: Self.stubDimension)
        )
        let profile = try await router.resolve(profile: Self.profile, reporting: ResolutionProgress())
        let session = profile.standard.makeSession()

        let posted = Self.event(correlationID: "1", kind: .completed, detail: "first")
        await session.outbox.post(event: posted)

        await #expect(throws: (any Error).self) {
            _ = try await session.respond(to: "hi")
        }

        // The turn produced zero new transcript entries (the backend threw
        // before appending anything at all) — nowhere to attach the drained
        // event's segment, and the model never actually received the
        // composed preamble either. The drained event must be re-posted back
        // onto the outbox rather than silently destroyed by the drain.
        let pendingAfterThrow = await session.outbox.pending()
        #expect(pendingAfterThrow.events.map(\.event) == [posted])
    }

    // MARK: - A .prompt partial with no entry payload cannot be augmented

    @Test("a .prompt partial carrying no entry payload reports the events unattached, so the turn re-queues them instead of dropping them")
    func promptPartialWithoutEntryReportsUnattached() {
        let posted = Self.event(correlationID: "1", kind: .completed, detail: "first")
        // The differ always populates `entry` today, so this shape is built by
        // hand — the guard exists so a future partial source without one
        // triggers a re-queue rather than a silent drop.
        let entrylessPrompt = TranscriptEvent.Partial(
            routerId: .generate(), sessionId: .generate(), kind: .prompt, text: "hello")

        let (partials, attached) = RoutedSessionActor.attachingPendingEventSegments(
            events: [posted], to: [entrylessPrompt])

        // Unattached AND untouched: the events are neither embedded in the
        // recorded partial nor claimed attached, so the chokepoint's
        // attach-or-requeue rule (`finishTurnAndRequeueIfUnattached`) re-posts
        // them onto the outbox — the path
        // `pendingEventSurvivesThrowBeforeAnyTranscriptAppend` proves end to
        // end.
        #expect(!attached)
        #expect(partials == [entrylessPrompt])
    }

    // MARK: - Round-trip

    @Test("OperationEventSegment round-trips through the mapper with no caller setup")
    func operationEventSegmentRoundTrips() throws {
        let event = Self.event(correlationID: "c9", kind: .completed, detail: "done")
        let segment = OperationEventSegment(id: "seg-1", content: event)
        let entry = Transcript.Entry.prompt(
            Transcript.Prompt(segments: [segment.transcriptSegment])
        )
        let (kind, payload, _) = TranscriptEntryMapper.event(from: entry)

        let rebuilt = try TranscriptEntryMapper.entry(from: payload, kind: kind)

        guard case .prompt(let rebuiltPrompt) = rebuilt,
            case .structure(let structured) = rebuiltPrompt.segments.first,
            let rebuiltOperationSegment = try OperationEventSegment(structuredSegment: structured)
        else {
            Issue.record("expected a rebuilt .prompt entry with a .structure OperationEventSegment")
            return
        }
        #expect(rebuiltOperationSegment.content == event)
        #expect(rebuiltOperationSegment.id == "seg-1")
    }

    @Test("a legacy .custom carrier rebuilds as the .structure segment it has become")
    func legacyCustomCarrierRebuildsAsStructure() throws {
        let event = Self.event(correlationID: "c9", kind: .completed, detail: "done")
        let contentJSON = String(decoding: try JSONEncoder().encode(event), as: UTF8.self)
        // The shape a recording written before the macOS 27 SDK removed
        // `Transcript.Segment.custom` carries on disk.
        let payload = TranscriptEntryPayload(
            entryId: "prompt-1",
            segments: [
                .custom(
                    id: "seg-1",
                    typeDiscriminator: OperationEventSegment.schemaName,
                    contentJSON: contentJSON,
                    description: "[shell] run command (c9) completed: done"
                )
            ]
        )

        let rebuilt = try TranscriptEntryMapper.entry(from: payload, kind: .prompt)

        guard case .prompt(let rebuiltPrompt) = rebuilt,
            case .structure(let structured) = rebuiltPrompt.segments.first,
            let rebuiltOperationSegment = try OperationEventSegment(structuredSegment: structured)
        else {
            Issue.record("expected the legacy carrier to rebuild as a .structure OperationEventSegment")
            return
        }
        #expect(rebuiltOperationSegment.id == "seg-1")
        #expect(rebuiltOperationSegment.content == event)
    }
}
