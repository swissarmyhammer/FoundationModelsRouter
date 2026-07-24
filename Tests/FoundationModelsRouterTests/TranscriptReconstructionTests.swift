import Foundation
import FoundationModels
import Testing

@testable import FoundationModelsRouter

/// Exercises task dw0zx8k: reconstructing a real, SDK-native
/// `FoundationModels.Transcript` from a session's recorded events — the
/// data-level payoff of ``TranscriptTree/effectiveEntryEvents(forSession:)``
/// (see plan.md's "Transcript fidelity" section, "Reconstruction end-to-end").
///
/// Everything runs against stubs — a stub `ModelLoader`, a canned LLM
/// container backed by ``TrackedStubBackend``, and a `JSONLRecorder` writing
/// into a temp directory — so the suite needs no network and no GPU.
@Suite("TranscriptTree.effectiveTranscript: reconstructing a real Transcript from recorded events")
struct TranscriptReconstructionTests {
    // MARK: - Backend tracking

    /// Tracks every ``TrackedStubBackend`` this suite's stub containers
    /// create — via `makeSession(instructions:)` and via
    /// ``TrackedStubBackend/makeFork()`` — in creation order, so a test that
    /// calls `profile.standard.makeSession()` then `.fork(workingDirectory:)`
    /// a known number of times can correlate each call's resulting
    /// ``RoutedSession`` to its own backend purely by call order, since
    /// ``RoutedSession`` exposes no backend accessor.
    /// `@unchecked Sendable` is safe here because every access is sequential:
    /// `record(_:)` fires only from a `TrackedStubBackend` initializer or
    /// ``TrackedStubBackend/makeFork()``, and both are driven one call at a
    /// time by this suite's single awaited `@MainActor` test method — no two
    /// backends are ever created concurrently within a test — with any read
    /// from inside `RoutedSessionActor`'s chokepoint further serialized by
    /// the model's per-model serial gate (``RoutedModel/serialGate``).
    /// Nothing ever touches this instance concurrently.
    private final class BackendRegistry: @unchecked Sendable {
        private(set) var created: [TrackedStubBackend] = []
        func record(_ backend: TrackedStubBackend) {
            created.append(backend)
        }
    }

    /// A ``LanguageModelSessionBackend`` mirroring `StubSessionBackend`'s
    /// prompt/response-pair-per-turn transcript shape (see that type's own
    /// doc comment in `Helpers/StubSessionBackend.swift`), but self-registering
    /// into a shared ``BackendRegistry`` at creation and at every
    /// ``makeFork()`` — the hook this suite needs to look up a session's own
    /// in-memory transcript by call order.
    /// `@unchecked Sendable` is safe here for the same reason as
    /// ``BackendRegistry``: every mutation of `shouldThrow`,
    /// `throwsBeforeAppendingAnything`, `customSegment`, and `entries` comes
    /// either from direct test-code assignment between turns or from
    /// `respond`/`streamResponse`/`recordResponse()` invoked through
    /// `RoutedSessionActor`'s chokepoint — and both paths are driven one call
    /// at a time by this suite's single awaited `@MainActor` test method,
    /// with any actor-internal access further serialized by the model's
    /// per-model serial gate (``RoutedModel/serialGate``). Nothing ever
    /// touches an instance concurrently.
    private final class TrackedStubBackend: LanguageModelSessionBackend, @unchecked Sendable {
        enum StubError: Error, Equatable { case boom }

        let responseText: String
        var shouldThrow: Bool
        /// When `true`, every generation entry point throws immediately,
        /// *before* appending anything to ``entries`` at all — unlike
        /// ``shouldThrow``, which still records the `.prompt` first. This is
        /// the shape a real SDK backend can produce when it rejects a turn
        /// before ever durably appending to its own transcript (e.g. a
        /// guardrail refusal) — the scenario that makes
        /// `recordTranscriptDelta(grammar:since:)`'s diff find zero new
        /// entries and the router's synthetic bodyless close become the
        /// *only* event a failed first turn ever produces.
        var throwsBeforeAppendingAnything: Bool = false
        /// A custom segment ``recordResponse()`` appends to the response
        /// entry instead of plain text, when set — the hook the custom
        /// segment reconstruction tests need.
        var customSegment: (any Transcript.CustomSegment)?
        private(set) var entries: [Transcript.Entry]
        private let registry: BackendRegistry

        init(
            responseText: String = "stub response",
            shouldThrow: Bool = false,
            instructions: String? = nil,
            entries: [Transcript.Entry]? = nil,
            registry: BackendRegistry
        ) {
            self.responseText = responseText
            self.shouldThrow = shouldThrow
            self.registry = registry
            if let entries {
                self.entries = entries
            } else if let instructions {
                self.entries = [
                    .instructions(
                        Transcript.Instructions(
                            segments: [.text(Transcript.TextSegment(content: instructions))],
                            toolDefinitions: []
                        )
                    )
                ]
            } else {
                self.entries = []
            }
            registry.record(self)
        }

        func respond(to prompt: String, maxTokens: Int?) async throws -> String {
            if throwsBeforeAppendingAnything { throw StubError.boom }
            entries.append(
                .prompt(Transcript.Prompt(segments: [.text(Transcript.TextSegment(content: prompt))])))
            if shouldThrow { throw StubError.boom }
            recordResponse()
            return responseText
        }

        func streamResponse(to prompt: String, maxTokens: Int?) -> AsyncThrowingStream<String, Error> {
            entries.append(
                .prompt(Transcript.Prompt(segments: [.text(Transcript.TextSegment(content: prompt))])))
            let responseText = responseText
            let shouldThrow = shouldThrow
            if !shouldThrow { recordResponse() }
            return AsyncThrowingStream { continuation in
                if shouldThrow {
                    continuation.finish(throwing: StubError.boom)
                } else {
                    continuation.yield(responseText)
                    continuation.finish()
                }
            }
        }

        func respond(to prompt: String, following grammar: Grammar, maxTokens: Int?) async throws
            -> String
        {
            entries.append(
                .prompt(Transcript.Prompt(segments: [.text(Transcript.TextSegment(content: prompt))])))
            try grammar.validateForXGrammar()
            if shouldThrow { throw StubError.boom }
            recordResponse()
            return responseText
        }

        func makeFork() -> any LanguageModelSessionBackend {
            let fork = TrackedStubBackend(
                responseText: responseText,
                shouldThrow: shouldThrow,
                entries: entries,
                registry: registry
            )
            fork.customSegment = customSegment
            return fork
        }

        func transcriptEntries() -> [Transcript.Entry] { entries }

        /// No usage is tracked here — this suite exercises transcript-tree
        /// reconstruction, not token metering.
        func usageTokenCounts() -> (input: Int, output: Int)? { nil }

        private func recordResponse() {
            if let customSegment {
                entries.append(
                    .response(Transcript.Response(assetIDs: [], segments: [.custom(customSegment)])))
            } else {
                entries.append(
                    .response(Transcript.Response(assetIDs: [], segments: [.text(Transcript.TextSegment(content: responseText))]))
                )
            }
        }
    }

    /// A ``LoadedLLMContainer`` that vends ``TrackedStubBackend``s registered
    /// into a shared ``BackendRegistry``.
    private struct TrackedLLMContainer: LoadedLLMContainer {
        let text: String
        let registry: BackendRegistry

        func makeSession(instructions: String?) -> any LanguageModelSessionBackend {
            TrackedStubBackend(responseText: text, instructions: instructions, registry: registry)
        }

        func makeSession(transcript: Transcript) -> any LanguageModelSessionBackend {
            TrackedStubBackend(responseText: text, entries: Array(transcript), registry: registry)
        }
    }

    // MARK: - Test-only PersistableCustomSegment conformer

    private struct Note: Codable, Equatable, Sendable {
        var body: String
    }

    private struct NoteSegment: PersistableCustomSegment, Equatable, CustomStringConvertible {
        let id: String
        let content: Note

        var description: String { "Note: \(content.body)" }
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
            .appendingPathComponent(
                "TranscriptReconstructionTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Creates a session's directory the way a real session's creation does —
    /// by writing its write-once sidecar — so a hand-fabricated
    /// `transcript.jsonl` written into it afterward sits in a directory
    /// ``TranscriptTree`` recognizes as a session's.
    ///
    /// The facts are placeholders: these tests fabricate *event lines* to
    /// exercise reconstruction, and never read the sidecar back.
    ///
    /// - Parameter sessionDir: The session directory to create.
    /// - Returns: `sessionDir`, for chaining.
    @discardableResult
    private static func makeSessionDir(_ sessionDir: URL) throws -> URL {
        try SessionSidecar.write(
            SessionSidecar(
                slot: .standard,
                model: "org/model-a",
                context: 8_192,
                instructions: nil,
                grammar: nil,
                recordingLevel: .full,
                forkedAtEntryCount: nil,
                profile: nil
            ),
            to: sessionDir
        )
        return sessionDir
    }

    /// Builds a minimal, mapper-satisfying entry-kind event carrying a single
    /// text segment — a hand-fabricated stand-in for a real recorded
    /// `.instructions`/`.prompt`/`.response` line, used by the compaction
    /// checkpoint fixtures below so they need no live backend.
    private static func textEntryEvent(
        seq: Int,
        sessionId: ULID,
        routerId: ULID,
        kind: TranscriptEvent.Kind,
        entryId: String,
        text: String
    ) -> TranscriptEvent {
        TranscriptEvent(
            routerId: routerId,
            sessionId: sessionId,
            seq: seq,
            ts: Date(timeIntervalSince1970: TimeInterval(seq)),
            kind: kind,
            text: text,
            entry: TranscriptEntryPayload(
                entryId: entryId,
                segments: [.text(id: "\(entryId)-text", content: text)],
                toolDefinitions: kind == .instructions ? [] : nil,
                assetIds: kind == .response ? [] : nil
            )
        )
    }

    /// Writes `events` as a session's `transcript.jsonl`, one JSON object per
    /// line — the on-disk shape ``TranscriptTree`` reads.
    private static func writeTranscript(_ events: [TranscriptEvent], to sessionDir: URL) throws {
        let encoder = JSONEncoder()
        let lines = try events.map { try encoder.encode($0) }.map { String(data: $0, encoding: .utf8)! }
        try lines.joined(separator: "\n").write(
            to: sessionDir.appendingPathComponent("transcript.jsonl", isDirectory: false),
            atomically: true,
            encoding: .utf8
        )
    }

    private static func makeRouter(
        container: any LoadedLLMContainer,
        recorder: any TranscriptRecorder,
        cacheDir: URL,
        recordingsDir: URL,
        recordingLevel: RecordingLevel = .full
    ) -> Router {
        Router(
            maxConcurrentForks: 4,
            cacheDir: cacheDir,
            recordingsDir: recordingsDir,
            recorder: recorder,
            recordingLevel: recordingLevel,
            probe: StubProbe(
                chip: "Apple Test", totalRAM: 64 << 30, recommendedMaxWorkingSetSize: 48 << 30),
            metadataSource: StubMetadataSource(raw: rawMetadata),
            loader: StubModelLoader(container: container, dimension: stubDimension)
        )
    }

    private func routerDirectory(router: Router, recordingsDir: URL) -> URL {
        recordingsDir.appendingPathComponent(router.id.description, isDirectory: true)
    }

    // MARK: - Root session round trip

    @Test("effectiveTranscript reconstructs a root session's Transcript equal to its stub backend's own transcriptEntries()")
    @MainActor
    func reconstructsRootSessionEqualToBackendEntries() async throws {
        let cacheDir = Self.makeTempDir()
        let recordingsDir = Self.makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: cacheDir)
            try? FileManager.default.removeItem(at: recordingsDir)
        }

        let registry = BackendRegistry()
        let container = TrackedLLMContainer(text: Self.cannedText, registry: registry)
        let router = Self.makeRouter(
            container: container,
            recorder: JSONLRecorder(directory: recordingsDir),
            cacheDir: cacheDir,
            recordingsDir: recordingsDir
        )
        let profile = try await router.resolve(profile: Self.profile, reporting: ResolutionProgress())

        let root = profile.standard.makeSession()
        _ = try await root.respond(to: "turn 1")
        _ = try await root.respond(to: "turn 2")

        let tree = try TranscriptTree.load(
            under: routerDirectory(router: router, recordingsDir: recordingsDir))
        let reconstructed = try tree.effectiveTranscript(forSession: root.id)

        let backend = try #require(registry.created.first)
        #expect(Array(reconstructed) == backend.transcriptEntries())
        #expect(Array(reconstructed).map { TranscriptEntryMapper.event(from: $0).kind } == [.prompt, .response, .prompt, .response])
    }

    // MARK: - 3-level fork tree

    @Test("a 3-level fork tree: each node's reconstructed effective transcript matches its own backend's accumulated entries")
    @MainActor
    func reconstructsWholeForkTreeMatchingEachNodesBackend() async throws {
        let cacheDir = Self.makeTempDir()
        let recordingsDir = Self.makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: cacheDir)
            try? FileManager.default.removeItem(at: recordingsDir)
        }

        let registry = BackendRegistry()
        let container = TrackedLLMContainer(text: Self.cannedText, registry: registry)
        let router = Self.makeRouter(
            container: container,
            recorder: JSONLRecorder(directory: recordingsDir),
            cacheDir: cacheDir,
            recordingsDir: recordingsDir
        )
        let profile = try await router.resolve(profile: Self.profile, reporting: ResolutionProgress())

        let root = profile.standard.makeSession()
        _ = try await root.respond(to: "root-turn-1")
        let rootBackend = try #require(registry.created.first)

        let forkA = try await root.fork(workingDirectory: nil)
        let forkABackend = try #require(registry.created.last)
        let forkB = try await root.fork(workingDirectory: nil)
        let forkBBackend = try #require(registry.created.last)

        _ = try await forkA.respond(to: "forkA-turn-1")
        let grandfork = try await forkA.fork(workingDirectory: nil)
        let grandforkBackend = try #require(registry.created.last)
        _ = try await grandfork.respond(to: "grandfork-turn-1")
        _ = try await forkB.respond(to: "forkB-turn-1")

        let tree = try TranscriptTree.load(
            under: routerDirectory(router: router, recordingsDir: recordingsDir))

        for (session, backend) in [
            (root, rootBackend), (forkA, forkABackend), (forkB, forkBBackend),
            (grandfork, grandforkBackend),
        ] {
            let reconstructed = try tree.effectiveTranscript(forSession: session.id)
            #expect(Array(reconstructed) == backend.transcriptEntries())
        }
    }

    // MARK: - Custom segments: registered round-trip vs. empty registry

    @Test("a recording with a registered custom segment reconstructs the real segment; an empty registry throws the discriminator-naming error")
    @MainActor
    func customSegmentRoundTripsWithRegistryAndThrowsWithoutIt() async throws {
        let cacheDir = Self.makeTempDir()
        let recordingsDir = Self.makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: cacheDir)
            try? FileManager.default.removeItem(at: recordingsDir)
        }

        let registry = BackendRegistry()
        let container = TrackedLLMContainer(text: Self.cannedText, registry: registry)
        let router = Self.makeRouter(
            container: container,
            recorder: JSONLRecorder(directory: recordingsDir),
            cacheDir: cacheDir,
            recordingsDir: recordingsDir
        )
        let profile = try await router.resolve(profile: Self.profile, reporting: ResolutionProgress())

        let root = profile.standard.makeSession()
        let backend = try #require(registry.created.first)
        backend.customSegment = NoteSegment(id: "n1", content: Note(body: "hello"))
        _ = try await root.respond(to: "turn 1")

        let tree = try TranscriptTree.load(
            under: routerDirectory(router: router, recordingsDir: recordingsDir))

        var segmentRegistry = CustomSegmentRegistry()
        segmentRegistry.register(NoteSegment.self)
        let reconstructed = try tree.effectiveTranscript(forSession: root.id, registry: segmentRegistry)
        guard case .response(let response) = Array(reconstructed).last,
            case .custom(let segment) = response.segments.first,
            let note = segment as? NoteSegment
        else {
            Issue.record("expected a reconstructed .response entry with a .custom NoteSegment")
            return
        }
        #expect(note.content == Note(body: "hello"))

        let events = try tree.events(forSession: root.id)
        let responseEvent = try #require(events.first { $0.kind == .response })
        #expect(throws: TranscriptReconstructionError.unregisteredCustomSegmentType(
            session: root.id,
            seq: responseEvent.seq,
            discriminator: NoteSegment.typeDiscriminator
        )) {
            _ = try tree.effectiveTranscript(forSession: root.id)
        }
    }

    // MARK: - metadataOnly and v1 legacy: distinct typed errors

    @Test("reconstruction of a metadataOnly-stripped payload throws the contentRemoved error")
    @MainActor
    func metadataOnlyContentRemovedThrows() async throws {
        let cacheDir = Self.makeTempDir()
        let recordingsDir = Self.makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: cacheDir)
            try? FileManager.default.removeItem(at: recordingsDir)
        }

        let registry = BackendRegistry()
        let container = TrackedLLMContainer(text: Self.cannedText, registry: registry)
        let router = Self.makeRouter(
            container: container,
            recorder: JSONLRecorder(directory: recordingsDir),
            cacheDir: cacheDir,
            recordingsDir: recordingsDir,
            recordingLevel: .metadataOnly
        )
        let profile = try await router.resolve(profile: Self.profile, reporting: ResolutionProgress())

        let root = profile.standard.makeSession()
        _ = try await root.respond(to: "turn 1")

        let tree = try TranscriptTree.load(
            under: routerDirectory(router: router, recordingsDir: recordingsDir))
        let events = try tree.events(forSession: root.id)
        let promptEvent = try #require(events.first { $0.kind == .prompt })
        #expect(promptEvent.entry?.contentRemoved == true)

        #expect(
            throws: TranscriptReconstructionError.contentRemoved(session: root.id, seq: promptEvent.seq)
        ) {
            _ = try tree.effectiveTranscript(forSession: root.id)
        }
    }

    @Test("a fabricated v1 line (no entry field) throws the legacy-missing-payload error")
    func v1LegacyLineThrowsMissingPayloadError() throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let sessionId = ULID.generate()
        let sessionDir = try Self.makeSessionDir(
            dir.appendingPathComponent(sessionId.description, isDirectory: true))
        let json = """
            {"routerId":"\(ULID.generate().description)","sessionId":"\(sessionId.description)","seq":0,"ts":0,"kind":"prompt","text":"hello"}
            """
        try json.write(
            to: sessionDir.appendingPathComponent("transcript.jsonl", isDirectory: false),
            atomically: true,
            encoding: .utf8
        )

        let tree = try TranscriptTree.load(under: dir)
        #expect(
            throws: TranscriptReconstructionError.legacyEventMissingPayload(session: sessionId, seq: 0)
        ) {
            _ = try tree.effectiveTranscript(forSession: sessionId)
        }
    }

    @Test("a fabricated v1 turn (prompt then response, both entry-less, response shaped exactly like the router's synthetic close) throws on the prompt event, never silently skipping the response as if it were a failed-turn close")
    func v1TurnWithResponseShapedLikeBodylessCloseThrowsOnThePromptFirst() throws {
        // This pins down the reasoning in `isFailedTurnBodylessClose`'s doc
        // comment: a genuine v1 `.response` event recorded at `metadataOnly`
        // decodes with the exact same shape as the router's v2 synthetic
        // bodyless close (`entry == nil`, `text == nil`, `ms` set) — the two
        // are not distinguishable from that one event's fields alone. What
        // makes this safe is that the turn's own `.prompt` event (also
        // `entry == nil`, since it is a genuine v1 line) always precedes it
        // in `seq` order and is never `.response`-kind, so
        // `effectiveTranscript` throws on that earlier event first — the
        // ambiguous `.response` event is never reached, let alone
        // misclassified as a skippable close.
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let sessionId = ULID.generate()
        let sessionDir = try Self.makeSessionDir(
            dir.appendingPathComponent(sessionId.description, isDirectory: true))
        let routerId = ULID.generate().description
        // Line 1: a v1 `.prompt` (no `entry` key, `text` stripped by
        // metadataOnly, no `ms` — v1's bracket never stamped `ms` on prompt
        // events). Line 2: a v1 `.response` shaped exactly like the router's
        // v2 synthetic bodyless close.
        let lines = [
            """
            {"routerId":"\(routerId)","sessionId":"\(sessionId.description)","seq":0,"ts":0,"kind":"prompt"}
            """,
            """
            {"routerId":"\(routerId)","sessionId":"\(sessionId.description)","seq":1,"ts":1,"kind":"response","ms":42}
            """,
        ]
        try lines.joined(separator: "\n").write(
            to: sessionDir.appendingPathComponent("transcript.jsonl", isDirectory: false),
            atomically: true,
            encoding: .utf8
        )

        let tree = try TranscriptTree.load(under: dir)
        #expect(
            throws: TranscriptReconstructionError.legacyEventMissingPayload(session: sessionId, seq: 0)
        ) {
            _ = try tree.effectiveTranscript(forSession: sessionId)
        }
    }

    // MARK: - Non-refusal mapper errors still carry session/seq context

    @Test("a mapper error outside the three documented refusals (missingRequiredField) is still wrapped with session and seq context")
    @MainActor
    func otherMapperErrorsAreWrappedWithSessionAndSeqContext() async throws {
        let cacheDir = Self.makeTempDir()
        let recordingsDir = Self.makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: cacheDir)
            try? FileManager.default.removeItem(at: recordingsDir)
        }

        let registry = BackendRegistry()
        let container = TrackedLLMContainer(text: Self.cannedText, registry: registry)
        let router = Self.makeRouter(
            container: container,
            recorder: JSONLRecorder(directory: recordingsDir),
            cacheDir: cacheDir,
            recordingsDir: recordingsDir
        )
        let profile = try await router.resolve(profile: Self.profile, reporting: ResolutionProgress())

        let root = profile.standard.makeSession()
        _ = try await root.respond(to: "turn 1")

        let tree = try TranscriptTree.load(
            under: routerDirectory(router: router, recordingsDir: recordingsDir))
        let node = try #require(tree.session(root.id))
        let originalEvents = try tree.events(forSession: root.id)
        let promptEvent = try #require(originalEvents.first { $0.kind == .prompt })
        let promptEntryId = try #require(promptEvent.entry?.entryId)

        // Corrupt the on-disk payload directly: strip its segments while
        // leaving `contentRemoved == false` — a shape the mapper itself (not
        // the recording-level gate) refuses with `missingRequiredField`, not
        // `contentRemoved`. Rewrite every event back to disk with the
        // prompt's payload substituted, then reload a fresh tree so
        // `effectiveTranscript` reads the corrupted line off disk exactly
        // like any other reconstruction.
        let corruptedEvents = originalEvents.map { event -> TranscriptEvent in
            guard event.seq == promptEvent.seq else { return event }
            return TranscriptEvent(
                routerId: event.routerId,
                sessionId: event.sessionId,
                parentId: event.parentId,
                slot: event.slot,
                model: event.model,
                seq: event.seq,
                ts: event.ts,
                kind: event.kind,
                grammar: event.grammar,
                text: event.text,
                tokensIn: event.tokensIn,
                tokensOut: event.tokensOut,
                ms: event.ms,
                entry: TranscriptEntryPayload(entryId: promptEntryId)
            )
        }
        let encoder = JSONEncoder()
        let rewritten = try corruptedEvents.map { try encoder.encode($0) }
            .map { String(data: $0, encoding: .utf8)! }
            .joined(separator: "\n")
        try rewritten.write(
            to: node.directory.appendingPathComponent("transcript.jsonl", isDirectory: false),
            atomically: true,
            encoding: .utf8
        )

        let reloadedTree = try TranscriptTree.load(under: routerDirectory(router: router, recordingsDir: recordingsDir))
        #expect(throws: TranscriptReconstructionError.entryReconstructionFailed(
            session: root.id,
            seq: promptEvent.seq,
            underlying: .missingRequiredField(entryId: promptEntryId, field: "segments")
        )) {
            _ = try reloadedTree.effectiveTranscript(forSession: root.id)
        }
    }

    // MARK: - Failed-turn bodyless close is skipped, not an error

    @Test("a recording with a failed-turn bodyless close reconstructs successfully, skipping the close without error")
    @MainActor
    func failedTurnBodylessCloseIsSkippedWithoutError() async throws {
        let cacheDir = Self.makeTempDir()
        let recordingsDir = Self.makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: cacheDir)
            try? FileManager.default.removeItem(at: recordingsDir)
        }

        let registry = BackendRegistry()
        let container = TrackedLLMContainer(text: Self.cannedText, registry: registry)
        let router = Self.makeRouter(
            container: container,
            recorder: JSONLRecorder(directory: recordingsDir),
            cacheDir: cacheDir,
            recordingsDir: recordingsDir
        )
        let profile = try await router.resolve(profile: Self.profile, reporting: ResolutionProgress())

        let root = profile.standard.makeSession()
        _ = try await root.respond(to: "turn 1")

        let backend = try #require(registry.created.first)
        backend.shouldThrow = true
        await #expect(throws: (any Error).self) {
            _ = try await root.respond(to: "turn 2 (fails)")
        }

        let tree = try TranscriptTree.load(
            under: routerDirectory(router: router, recordingsDir: recordingsDir))
        let rawEvents = try tree.events(forSession: root.id)
        let closeEvent = try #require(rawEvents.last)
        #expect(closeEvent.kind == .response)
        #expect(closeEvent.entry == nil)
        #expect(closeEvent.text == nil)
        #expect(closeEvent.ms != nil)

        let reconstructed = try tree.effectiveTranscript(forSession: root.id)
        let kinds = Array(reconstructed).map { TranscriptEntryMapper.event(from: $0).kind }
        #expect(kinds == [.prompt, .response, .prompt])
    }

    @Test("a session whose very first turn fails before the backend appends anything at all reconstructs to an empty Transcript, not an error")
    @MainActor
    func firstTurnTotalFailureWithNoBackendEntriesReconstructsEmpty() async throws {
        // The sharper edge case behind `isFailedTurnBodylessClose`'s doc
        // comment: unlike a v1 recording (whose bracketing code wrote its
        // `.prompt` event *unconditionally*, before calling into the
        // backend at all — see `RoutedSession.swift` git history at
        // 06f8d16 — a v2 recording only ever gets a `.prompt` event once
        // the SDK backend has actually appended one). A real backend that
        // rejects a turn before appending anything (e.g. a guardrail
        // refusal) leaves `recordTranscriptDelta` with zero new entries, so
        // the router's synthetic bodyless close becomes the *only* event
        // this session ever records. That shape can never arise from a
        // genuine v1 recording (v1 always wrote `.prompt` first,
        // unconditionally), so it is unambiguous: skip it, and reconstruct
        // to an empty `Transcript` rather than throwing.
        let cacheDir = Self.makeTempDir()
        let recordingsDir = Self.makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: cacheDir)
            try? FileManager.default.removeItem(at: recordingsDir)
        }

        let registry = BackendRegistry()
        let container = TrackedLLMContainer(text: Self.cannedText, registry: registry)
        let router = Self.makeRouter(
            container: container,
            recorder: JSONLRecorder(directory: recordingsDir),
            cacheDir: cacheDir,
            recordingsDir: recordingsDir
        )
        let profile = try await router.resolve(profile: Self.profile, reporting: ResolutionProgress())

        let root = profile.standard.makeSession()
        let backend = try #require(registry.created.first)
        backend.throwsBeforeAppendingAnything = true
        await #expect(throws: (any Error).self) {
            _ = try await root.respond(to: "turn 1 (rejected before anything is appended)")
        }
        // Sanity: the backend truly appended nothing for this failed call.
        #expect(backend.transcriptEntries().isEmpty)

        let tree = try TranscriptTree.load(
            under: routerDirectory(router: router, recordingsDir: recordingsDir))
        let rawEvents = try tree.events(forSession: root.id)
        // Only the session meta line and the synthetic bodyless close were
        // ever recorded — no `.prompt`/`.instructions` at all.
        #expect(rawEvents.map(\.kind) == [.session, .response])
        let closeEvent = try #require(rawEvents.last)
        #expect(closeEvent.entry == nil)
        #expect(closeEvent.text == nil)
        #expect(closeEvent.ms != nil)

        let reconstructed = try tree.effectiveTranscript(forSession: root.id)
        #expect(Array(reconstructed).isEmpty)
    }

    // MARK: - Checkpoint-aware reconstruction: restore view, fullHistory view

    /// Fabricates a single session whose transcript carries one compaction
    /// checkpoint: a header instructions entry, an old prompt/response pair
    /// (folded away), a recent prompt/response pair (kept), the checkpoint
    /// itself, and one post-compaction prompt/response pair.
    ///
    /// - Returns: The tree, the session id, and every fabricated event in
    ///   `seq` order — so a test can assert against the exact ids/order it
    ///   fabricated rather than recomputing them.
    private static func makeSingleCheckpointFixture() throws -> (
        tree: TranscriptTree, sessionId: ULID, events: [TranscriptEvent]
    ) {
        let dir = Self.makeTempDir()
        let sessionId = ULID.generate()
        let routerId = ULID.generate()
        let sessionDir = try Self.makeSessionDir(
            dir.appendingPathComponent(sessionId.description, isDirectory: true))

        let events = try [
            Self.textEntryEvent(
                seq: 0, sessionId: sessionId, routerId: routerId, kind: .instructions,
                entryId: "instr-1", text: "system"),
            Self.textEntryEvent(
                seq: 1, sessionId: sessionId, routerId: routerId, kind: .prompt,
                entryId: "old-prompt-1", text: "old prompt"),
            Self.textEntryEvent(
                seq: 2, sessionId: sessionId, routerId: routerId, kind: .response,
                entryId: "old-response-1", text: "old response"),
            Self.textEntryEvent(
                seq: 3, sessionId: sessionId, routerId: routerId, kind: .prompt,
                entryId: "recent-prompt-1", text: "recent prompt"),
            Self.textEntryEvent(
                seq: 4, sessionId: sessionId, routerId: routerId, kind: .response,
                entryId: "recent-response-1", text: "recent response"),
            TranscriptFixtures.compactionCheckpointEvent(
                seq: 5, sessionId: sessionId, routerId: routerId, entryId: "checkpoint-1",
                summaryText: "summary of old turns",
                content: CompactionSegment.Content(
                    liveWindowEntryIds: ["instr-1", "checkpoint-1", "recent-prompt-1", "recent-response-1"],
                    foldedEntryIds: ["old-prompt-1", "old-response-1"],
                    tokensBefore: 1_000,
                    tokensAfter: 200,
                    stagesApplied: ["ToolOutputElision", "Summarization"],
                    promptName: "default"
                )
            ),
            Self.textEntryEvent(
                seq: 6, sessionId: sessionId, routerId: routerId, kind: .prompt,
                entryId: "post-prompt-1", text: "post prompt"),
            Self.textEntryEvent(
                seq: 7, sessionId: sessionId, routerId: routerId, kind: .response,
                entryId: "post-response-1", text: "post response"),
        ]
        try Self.writeTranscript(events, to: sessionDir)

        let tree = try TranscriptTree.load(under: dir)
        return (tree, sessionId, events)
    }

    @Test("restore view (default): the newest checkpoint's ordered live-window entries, plus everything recorded after it — never the folded-away entries")
    func restoreViewAppliesNewestCheckpoint() throws {
        let (tree, sessionId, _) = try Self.makeSingleCheckpointFixture()

        let reconstructed = try tree.effectiveTranscript(forSession: sessionId)
        #expect(
            Array(reconstructed).map(\.id) == [
                "instr-1", "checkpoint-1", "recent-prompt-1", "recent-response-1",
                "post-prompt-1", "post-response-1",
            ])

        // The default view is `.restore` — explicit and default agree.
        let explicitRestore = try tree.effectiveTranscript(forSession: sessionId, view: .restore)
        #expect(Array(explicitRestore).map(\.id) == Array(reconstructed).map(\.id))

        // The folded-away entries never appear.
        #expect(!Array(reconstructed).map(\.id).contains("old-prompt-1"))
        #expect(!Array(reconstructed).map(\.id).contains("old-response-1"))
    }

    @Test("fullHistory view: every recorded entry, in seq order, with the compaction entry present as a fold marker rather than duplicating what it replaced")
    func fullHistoryViewRetainsEveryEvent() throws {
        let (tree, sessionId, events) = try Self.makeSingleCheckpointFixture()

        let fullHistory = try tree.effectiveTranscript(forSession: sessionId, view: .fullHistory)
        let fullHistoryIds = Array(fullHistory).map(\.id)
        #expect(fullHistoryIds == events.map { $0.entry!.entryId })

        // Every entry — including the folded-away ones and the checkpoint
        // itself — appears exactly once: the checkpoint is a marker among
        // what it replaced, never a duplicate rendering of it. Explicit
        // per-id counts (not just the overall id-list equality above) so
        // this would fail if a future fold-marker rendering re-embedded the
        // folded entries' content alongside the checkpoint.
        for id in fullHistoryIds {
            #expect(fullHistoryIds.filter { $0 == id }.count == 1)
        }

        // The contrast that actually proves "fullHistory ignores the
        // checkpoint": the restore view for the *same* fixture is strictly
        // smaller (folded entries excluded), while fullHistory keeps every
        // entry the session ever recorded, checkpoint included.
        let restoreView = try tree.effectiveTranscript(forSession: sessionId)
        #expect(fullHistory.count == events.count)
        #expect(restoreView.count < fullHistory.count)
    }

    @Test("repeated compactions: only the newest checkpoint governs restore; the earlier one is a historical marker excluded from the restore view")
    func repeatedCompactionsOnlyNewestGovernsRestore() throws {
        let dir = Self.makeTempDir()
        let sessionId = ULID.generate()
        let routerId = ULID.generate()
        let sessionDir = try Self.makeSessionDir(
            dir.appendingPathComponent(sessionId.description, isDirectory: true))

        let events = try [
            Self.textEntryEvent(
                seq: 0, sessionId: sessionId, routerId: routerId, kind: .instructions,
                entryId: "instr-1", text: "system"),
            Self.textEntryEvent(
                seq: 1, sessionId: sessionId, routerId: routerId, kind: .prompt,
                entryId: "old-prompt-1", text: "old prompt"),
            Self.textEntryEvent(
                seq: 2, sessionId: sessionId, routerId: routerId, kind: .response,
                entryId: "old-response-1", text: "old response"),
            TranscriptFixtures.compactionCheckpointEvent(
                seq: 3, sessionId: sessionId, routerId: routerId, entryId: "checkpoint-1",
                summaryText: "first fold",
                content: CompactionSegment.Content(
                    liveWindowEntryIds: ["instr-1", "checkpoint-1"],
                    foldedEntryIds: ["old-prompt-1", "old-response-1"],
                    tokensBefore: 1_000,
                    tokensAfter: 300,
                    stagesApplied: ["Summarization"],
                    promptName: "default"
                )
            ),
            Self.textEntryEvent(
                seq: 4, sessionId: sessionId, routerId: routerId, kind: .prompt,
                entryId: "mid-prompt-1", text: "mid prompt"),
            Self.textEntryEvent(
                seq: 5, sessionId: sessionId, routerId: routerId, kind: .response,
                entryId: "mid-response-1", text: "mid response"),
            TranscriptFixtures.compactionCheckpointEvent(
                seq: 6, sessionId: sessionId, routerId: routerId, entryId: "checkpoint-2",
                summaryText: "second fold",
                content: CompactionSegment.Content(
                    // The second fold's live window folds the *first*
                    // checkpoint away too, along with the turn after it.
                    liveWindowEntryIds: ["instr-1", "checkpoint-2"],
                    foldedEntryIds: ["checkpoint-1", "mid-prompt-1", "mid-response-1"],
                    tokensBefore: 900,
                    tokensAfter: 150,
                    stagesApplied: ["Summarization"],
                    promptName: "default"
                )
            ),
            Self.textEntryEvent(
                seq: 7, sessionId: sessionId, routerId: routerId, kind: .prompt,
                entryId: "post-prompt-1", text: "post prompt"),
        ]
        try Self.writeTranscript(events, to: sessionDir)

        let tree = try TranscriptTree.load(under: dir)
        let reconstructed = try tree.effectiveTranscript(forSession: sessionId)
        #expect(Array(reconstructed).map(\.id) == ["instr-1", "checkpoint-2", "post-prompt-1"])
    }

    @Test("a recording with no compaction checkpoint restores exactly as it always has, under either view")
    func noCheckpointRestoresUnchanged() async throws {
        let cacheDir = Self.makeTempDir()
        let recordingsDir = Self.makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: cacheDir)
            try? FileManager.default.removeItem(at: recordingsDir)
        }

        let registry = BackendRegistry()
        let container = TrackedLLMContainer(text: Self.cannedText, registry: registry)
        let router = Self.makeRouter(
            container: container,
            recorder: JSONLRecorder(directory: recordingsDir),
            cacheDir: cacheDir,
            recordingsDir: recordingsDir
        )
        let profile = try await router.resolve(profile: Self.profile, reporting: ResolutionProgress())

        let root = profile.standard.makeSession()
        _ = try await root.respond(to: "turn 1")
        _ = try await root.respond(to: "turn 2")

        let tree = try TranscriptTree.load(
            under: routerDirectory(router: router, recordingsDir: recordingsDir))
        let backend = try #require(registry.created.first)

        #expect(Array(try tree.effectiveTranscript(forSession: root.id)) == backend.transcriptEntries())
        #expect(
            Array(try tree.effectiveTranscript(forSession: root.id, view: .restore))
                == backend.transcriptEntries())
        #expect(
            Array(try tree.effectiveTranscript(forSession: root.id, view: .fullHistory))
                == backend.transcriptEntries())
    }

    @Test("a checkpoint naming a live-window entry id absent from the session's recorded events throws checkpointEntryMissing")
    func checkpointNamingMissingLiveWindowEntryThrows() throws {
        let dir = Self.makeTempDir()
        let sessionId = ULID.generate()
        let routerId = ULID.generate()
        let sessionDir = try Self.makeSessionDir(
            dir.appendingPathComponent(sessionId.description, isDirectory: true))

        let checkpointEvent = try TranscriptFixtures.compactionCheckpointEvent(
            seq: 0, sessionId: sessionId, routerId: routerId, entryId: "checkpoint-1",
            summaryText: "fold",
            content: CompactionSegment.Content(
                liveWindowEntryIds: ["checkpoint-1", "ghost-entry"],
                foldedEntryIds: [],
                tokensBefore: 100,
                tokensAfter: 50,
                stagesApplied: ["Summarization"],
                promptName: "default"
            )
        )
        try Self.writeTranscript([checkpointEvent], to: sessionDir)

        let tree = try TranscriptTree.load(under: dir)
        #expect(
            throws: TranscriptReconstructionError.checkpointEntryMissing(
                session: sessionId, seq: 0, entryId: "ghost-entry")
        ) {
            _ = try tree.effectiveTranscript(forSession: sessionId)
        }
    }
}
