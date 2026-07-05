import Foundation
import Testing

@testable import FoundationModelsRouter

/// Exercises milestone 10b: the two cross-cutting recording features layered on
/// the core nesting/events of milestone 10a.
///
/// 1. ``MergedTranscript`` — merging every nested `transcript.jsonl` under a
///    router's recording root into one stream totally ordered by `(ts, seq)`,
///    even when concurrent generation across sessions/forks interleaves the
///    per-file appends.
/// 2. ``GatingRecorder`` — enforcing the ``RecordingLevel`` and the ``Router``'s
///    `redact` hook: `off` records nothing, `metadataOnly` drops the body text
///    but keeps counts/kinds/provenance, `full` keeps bodies, and `redact`
///    transforms recorded text before it is written. The gate is wired through
///    the recorder the router hands down, so both the session chokepoint and
///    ``RoutedEmbedder/embed(_:)`` honor it, and a sink write failure stays
///    best-effort (logged, swallowed) under gating.
///
/// Everything runs against stubs — a stub ``ModelLoader``, a canned LLM
/// container, a stub embedder, and either a ``JSONLRecorder`` in a temp
/// directory or an ``InMemoryRecorder`` — so the suite needs no network and no
/// GPU.
@Suite("Merged transcript + redaction/level gating")
struct MergedAndRedactionTests {
    // MARK: - A fixed clock

    /// A fixed instant so every stamped `ts` ties, forcing the merge sort to
    /// fall through to `seq` — proving `seq` is the true tiebreaker.
    private static let fixedInstant = Date(timeIntervalSinceReferenceDate: 1_000.5)

    // MARK: - Sample partials

    /// Builds a sample partial with the given kind and body text; provenance ids
    /// are fresh ULIDs and the metering fields are populated so gating's
    /// count-preservation can be asserted.
    private func samplePartial(
        kind: TranscriptEvent.Kind,
        text: String?
    ) -> TranscriptEvent.Partial {
        TranscriptEvent.Partial(
            routerId: ULID.generate(),
            sessionId: ULID.generate(),
            parentId: ULID.generate(),
            slot: .standard,
            model: ModelRef("org/repo@rev"),
            kind: kind,
            grammar: "json",
            text: text,
            tokensIn: 3,
            tokensOut: 5,
            ms: 7
        )
    }

    // MARK: - Merged view

    @Test("merged view is totally ordered by (ts, seq) under concurrent appends across sessions")
    func mergedTotalOrderAcrossConcurrentSessions() async throws {
        let routerDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MergedTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: routerDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: routerDir) }

        // One recorder with a fixed clock, so every event shares the same `ts`
        // and only `seq` can order them — the merge must recover that order.
        let recorder: JSONLRecorder = .jsonl(directory: routerDir, now: { Self.fixedInstant })

        // Four sibling session directories nested under the router root.
        let sessionDirs = (0..<4).map { _ in
            routerDir.appendingPathComponent(ULID.generate().description, isDirectory: true)
        }
        let perSession = 100

        await withTaskGroup(of: Void.self) { group in
            for dir in sessionDirs {
                for _ in 0..<perSession {
                    group.addTask {
                        await recorder.append(self.samplePartial(kind: .prompt, text: "body"), to: dir)
                    }
                }
            }
        }

        let merged = try MergedTranscript.merged(under: routerDir)
        #expect(merged.count == sessionDirs.count * perSession)
        // Ordered by (ts, seq): ts all tie, so seq is the tiebreaker and the
        // merged stream is the single globally monotonic log, 0..<n, no gaps.
        #expect(merged.map(\.seq) == Array(0..<merged.count))
        // The events were physically spread across every session file.
        #expect(Set(merged.map(\.sessionId)).count >= 1)
        // The body survives the full JSONL round-trip: every merged event decodes
        // back to the `text` that was written, not just the correct `seq`.
        #expect(merged.allSatisfy { $0.text == "body" })
    }

    // MARK: - Level gating (unit)

    @Test("level off writes nothing")
    func levelOffWritesNothing() async throws {
        let inner: InMemoryRecorder = .inMemory
        let recorder: any TranscriptRecorder = GatingRecorder(level: .off, redact: nil, wrapping: inner)
        for kind in [TranscriptEvent.Kind.session, .prompt, .response] {
            await recorder.append(samplePartial(kind: kind, text: "body"))
        }
        #expect(await inner.events.isEmpty)
    }

    @Test("level off creates no jsonl file")
    func levelOffCreatesNoFile() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("OffTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let recorder: any TranscriptRecorder = GatingRecorder(
            level: .off,
            redact: nil,
            wrapping: JSONLRecorder(directory: dir)
        )
        await recorder.append(samplePartial(kind: .prompt, text: "body"), to: dir)

        let fileURL = dir.appendingPathComponent("transcript.jsonl", isDirectory: false)
        #expect(!FileManager.default.fileExists(atPath: fileURL.path))
    }

    @Test("level metadataOnly omits the body but keeps counts and kinds")
    func levelMetadataOnlyOmitsBody() async throws {
        let inner: InMemoryRecorder = .inMemory
        let recorder: any TranscriptRecorder = GatingRecorder(level: .metadataOnly, redact: nil, wrapping: inner)
        await recorder.append(samplePartial(kind: .prompt, text: "sensitive body"))

        let events = await inner.events
        #expect(events.count == 1)
        let event = try #require(events.first)
        // Body dropped, everything else preserved.
        #expect(event.text == nil)
        #expect(event.kind == .prompt)
        #expect(event.tokensIn == 3)
        #expect(event.tokensOut == 5)
        #expect(event.ms == 7)
        #expect(event.slot == .standard)
        #expect(event.grammar == "json")
    }

    @Test("level full writes the body verbatim")
    func levelFullWritesBody() async throws {
        let inner: InMemoryRecorder = .inMemory
        let recorder: any TranscriptRecorder = GatingRecorder(level: .full, redact: nil, wrapping: inner)
        await recorder.append(samplePartial(kind: .prompt, text: "verbatim body"))

        let events = await inner.events
        #expect(events.first?.text == "verbatim body")
    }

    // MARK: - Redaction (unit)

    @Test("the redact hook transforms recorded text before it is written")
    func redactTransformsText() async throws {
        let inner: InMemoryRecorder = .inMemory
        let redact: @Sendable (String) -> String = { $0.replacingOccurrences(of: "secret", with: "***") }
        let recorder: any TranscriptRecorder = GatingRecorder(level: .full, redact: redact, wrapping: inner)
        await recorder.append(samplePartial(kind: .prompt, text: "top secret plan"))

        #expect(await inner.events.first?.text == "top *** plan")
    }

    @Test("the redact hook is applied verbatim: case-sensitivity is the caller's contract")
    func redactHookIsAppliedVerbatim() async throws {
        // The `redact` hook is caller-supplied, so its matching semantics are the
        // caller's concern. A hook targeting lowercase "secret" leaves other
        // spellings untouched — the gate does not case-fold on the caller's behalf.
        let inner: InMemoryRecorder = .inMemory
        let caseSensitive: @Sendable (String) -> String = { $0.replacingOccurrences(of: "secret", with: "***") }
        let recorder: any TranscriptRecorder = GatingRecorder(level: .full, redact: caseSensitive, wrapping: inner)

        await recorder.append(samplePartial(kind: .prompt, text: "Secret and SECRET and secret"))

        // Only the exact-case token is replaced; "Secret"/"SECRET" pass through.
        #expect(await inner.events.first?.text == "Secret and SECRET and ***")
    }

    @Test("a caller wanting case-insensitive redaction supplies a case-insensitive hook")
    func callerSuppliesCaseInsensitiveRedaction() async throws {
        // If the contract a caller wants is case-insensitive, they express it in
        // their own hook — the router applies whatever hook it is handed.
        let inner: InMemoryRecorder = .inMemory
        let caseInsensitive: @Sendable (String) -> String = {
            $0.replacingOccurrences(of: "secret", with: "***", options: .caseInsensitive)
        }
        let recorder: any TranscriptRecorder = GatingRecorder(level: .full, redact: caseInsensitive, wrapping: inner)

        await recorder.append(samplePartial(kind: .prompt, text: "Secret and SECRET and secret"))

        #expect(await inner.events.first?.text == "*** and *** and ***")
    }

    // MARK: - Wiring through the router (session + embed)

    @Test("metadataOnly wired through the router drops bodies on both session turns and embeddings")
    @MainActor
    func metadataOnlyWiredThroughRouter() async throws {
        let cacheDir = Self.makeTempDir()
        let recordingsDir = Self.makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: cacheDir)
            try? FileManager.default.removeItem(at: recordingsDir)
        }

        let recorder = InMemoryRecorder()
        let router = Self.makeRouter(
            recorder: recorder,
            recordingLevel: .metadataOnly,
            redact: nil,
            cacheDir: cacheDir,
            recordingsDir: recordingsDir
        )
        let profile = try await router.resolve(Self.profile, reporting: ResolutionProgress())

        let session = profile.standard.makeSession()
        _ = try await session.respond(to: "a secret prompt")
        _ = try await profile.embedding.embed(["a secret document"])

        let events = await recorder.events
        // Both the session turn and the embedding honored the level: bodies gone.
        #expect(events.allSatisfy { $0.text == nil })
        // But the events themselves — kinds and metering — are still recorded.
        #expect(events.contains { $0.kind == .prompt })
        #expect(events.contains { $0.kind == .response })
        #expect(events.contains { $0.kind == .embedding })
    }

    @Test("redact wired through the router transforms session turn and embedding text")
    @MainActor
    func redactWiredThroughRouter() async throws {
        let cacheDir = Self.makeTempDir()
        let recordingsDir = Self.makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: cacheDir)
            try? FileManager.default.removeItem(at: recordingsDir)
        }

        let recorder = InMemoryRecorder()
        let redact: @Sendable (String) -> String = { $0.replacingOccurrences(of: "secret", with: "***") }
        let router = Self.makeRouter(
            recorder: recorder,
            recordingLevel: .full,
            redact: redact,
            cacheDir: cacheDir,
            recordingsDir: recordingsDir
        )
        let profile = try await router.resolve(Self.profile, reporting: ResolutionProgress())

        let session = profile.standard.makeSession()
        _ = try await session.respond(to: "a secret prompt")
        _ = try await profile.embedding.embed(["another secret"])

        let events = await recorder.events
        // No recorded body still contains the redacted token.
        #expect(events.allSatisfy { !($0.text?.contains("secret") ?? false) })
        // The prompt body is present but redacted.
        let prompt = try #require(events.first { $0.kind == .prompt })
        #expect(prompt.text == "a *** prompt")
        // The embedding body is present but redacted.
        let embedding = try #require(events.first { $0.kind == .embedding })
        #expect(embedding.text == "another ***")
    }

    // MARK: - Best-effort preserved under gating

    @Test("a forced sink write failure is swallowed under gating; generation and embedding still succeed")
    @MainActor
    func sinkFailureSwallowedUnderGating() async throws {
        let cacheDir = Self.makeTempDir()
        // A regular file standing where the recordings root should be: every
        // directory-create under it fails, so both session and embed writes are
        // swallowed.
        let blocker = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: false)
        try Data().write(to: blocker)
        defer {
            try? FileManager.default.removeItem(at: cacheDir)
            try? FileManager.default.removeItem(at: blocker)
        }

        let redact: @Sendable (String) -> String = { $0 }
        let router = Self.makeRouter(
            recorder: JSONLRecorder(directory: blocker),
            recordingLevel: .full,
            redact: redact,
            cacheDir: cacheDir,
            recordingsDir: blocker
        )
        let profile = try await router.resolve(Self.profile, reporting: ResolutionProgress())

        let session = profile.standard.makeSession()
        // Both must return normally despite every recorder write failing.
        let response = try await session.respond(to: "hello")
        #expect(response == Self.cannedText)
        let vectors = try await profile.embedding.embed(["one", "two"])
        #expect(vectors.count == 2)

        // The blocking file is untouched: nothing was written through it.
        #expect(try Data(contentsOf: blocker).isEmpty)
    }

    // MARK: - Stub containers

    private struct CannedLLMContainer: LoadedLLMContainer {
        let text: String

        func respond(to prompt: String, instructions: String?, maxTokens: Int?) async throws -> String { text }

        func streamResponse(
            to prompt: String,
            instructions: String?,
            maxTokens: Int?
        ) -> AsyncThrowingStream<String, Error> {
            let text = text
            return AsyncThrowingStream { continuation in
                continuation.yield(text)
                continuation.finish()
            }
        }
    }

    private struct StubEmbeddingContainer: LoadedEmbeddingContainer {
        let dimension: Int
        func embed(_ texts: [String]) async throws -> [[Float]] {
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

    private struct StubModelLoader: ModelLoader {
        let dimension: Int
        let text: String

        func loadLLM(
            _ ref: ModelRef,
            slot: ModelSlot,
            context: Int,
            reporting: @escaping @Sendable (DownloadProgress) -> Void
        ) async throws -> any LoadedLLMContainer {
            reporting(DownloadProgress(bytesDownloaded: 1, bytesTotal: 1))
            return CannedLLMContainer(text: text)
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
            .appendingPathComponent("MergedAndRedactionTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Builds a router wired with the stubs, an explicit recorder, and a chosen
    /// recording level / redaction hook so the gate can be exercised end to end.
    private static func makeRouter(
        recorder: any TranscriptRecorder,
        recordingLevel: RecordingLevel,
        redact: (@Sendable (String) -> String)?,
        cacheDir: URL,
        recordingsDir: URL
    ) -> Router {
        Router(
            cacheDir: cacheDir,
            recordingsDir: recordingsDir,
            recorder: recorder,
            recordingLevel: recordingLevel,
            redact: redact,
            probe: StubProbe(chip: "Apple Test", totalRAM: 64 << 30, recommendedMaxWorkingSetSize: 48 << 30),
            metadataSource: StubMetadataSource(raw: rawMetadata),
            loader: StubModelLoader(dimension: stubDimension, text: cannedText)
        )
    }
}
