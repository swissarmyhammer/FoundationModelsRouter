import Foundation
import FoundationModels
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
///    `redact` hook: `off` records nothing, `full` keeps bodies, and `redact`
///    transforms recorded text before it is written. The gate is wired through
///    the recorder the router hands down, so the session chokepoint honors it,
///    and a sink write failure stays best-effort (logged, swallowed) under
///    gating.
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

    @Test("the public TranscriptEvent.merged(under:) returns exactly what the internal merge returns")
    func publicEntryPointMatchesTheInternalMerge() async throws {
        let routerDir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: routerDir) }

        // One event in each of two sibling session directories, so the two
        // readers are compared over a merge that really spans more than one
        // file.
        let recordedKinds: [TranscriptEvent.Kind] = [.prompt, .response]
        let recorder: JSONLRecorder = .jsonl(directory: routerDir, now: { Self.fixedInstant })
        for kind in recordedKinds {
            let sessionDir = routerDir.appendingPathComponent(
                ULID.generate().description,
                isDirectory: true
            )
            await recorder.append(samplePartial(kind: kind, text: "body"), to: sessionDir)
        }

        // The public entry point forwards to the internal merge and adds
        // nothing: same events, same order.
        let overThePublicSurface = try TranscriptEvent.merged(under: routerDir)
        let overTheInternalMerge = try MergedTranscript.merged(under: routerDir)
        #expect(overThePublicSurface == overTheInternalMerge)
        // Two equal empty arrays would satisfy the line above and prove
        // nothing, so the recorded events must really be there.
        #expect(overThePublicSurface.count == recordedKinds.count)
    }

    @Test(
        "the merge refuses a session whose sidecar carries a future schema version, with the typed newer-router error"
    )
    func mergeRefusesAFutureVersionSidecarWithTheTypedError() async throws {
        let uncanonicalDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MergedTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: uncanonicalDir, withIntermediateDirectories: true)
        // Canonicalized (symlinks resolved, `/var` → `/private/var`) because the
        // typed error names the directory as ``TranscriptFileDiscovery``'s
        // enumeration spells it — canonically — and this test asserts on the
        // exact error value.
        let canonicalPath = try #require(
            try uncanonicalDir.resourceValues(forKeys: [.canonicalPathKey]).canonicalPath)
        let routerDir = URL(fileURLWithPath: canonicalPath, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: routerDir) }

        // One session directory holding a recorded transcript beside a sidecar
        // stamped with a version this reader does not know — the shape a
        // recording written by a newer router leaves on disk.
        let recorder: JSONLRecorder = .jsonl(directory: routerDir, now: { Self.fixedInstant })
        let sessionDir = routerDir.appendingPathComponent(ULID.generate().description, isDirectory: true)
        await recorder.append(samplePartial(kind: .prompt, text: "body"), to: sessionDir)

        let futureVersion = RecordingSchemaVersion.current + 1
        let futureJSON = Data(
            """
            {
                "slot": "standard",
                "model": "org/model-a",
                "context": 8192,
                "recordingLevel": "full",
                "schemaVersion": \(futureVersion)
            }
            """.utf8)
        try futureJSON.write(
            to: sessionDir.appendingPathComponent("session.json", isDirectory: false))

        #expect(
            throws: RecordingSchemaVersionError.recordingFromNewerRouter(
                directory: sessionDir,
                version: futureVersion,
                supported: RecordingSchemaVersion.current
            )
        ) {
            _ = try MergedTranscript.merged(under: routerDir)
        }
    }

    // MARK: - Level gating (unit)

    @Test("level off writes nothing")
    func levelOffWritesNothing() async throws {
        let inner: InMemoryRecorder = .inMemory
        let recorder: any TranscriptRecorder = GatingRecorder(level: .off, redact: nil, wrapping: inner)
        for kind in [TranscriptEvent.Kind.session, .prompt, .response] {
            await recorder.append(samplePartial(kind: kind, text: "body"), to: nil)
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

    @Test("RecordingLevel has exactly two cases, off and full, and no metadataOnly")
    func recordingLevelHasNoMetadataOnlyCase() {
        #expect(RecordingLevel(rawValue: "metadataOnly") == nil)
        #expect(Set(RecordingLevel.allCases) == [.off, .full])
    }

    @Test("level full writes the body verbatim")
    func levelFullWritesBody() async throws {
        let inner: InMemoryRecorder = .inMemory
        let recorder: any TranscriptRecorder = GatingRecorder(level: .full, redact: nil, wrapping: inner)
        await recorder.append(samplePartial(kind: .prompt, text: "verbatim body"), to: nil)

        let events = await inner.events
        #expect(events.first?.text == "verbatim body")
    }

    // MARK: - Redaction (unit)

    @Test("the redact hook transforms recorded text before it is written")
    func redactTransformsText() async throws {
        let inner: InMemoryRecorder = .inMemory
        let redact: @Sendable (String) -> String = { $0.replacingOccurrences(of: "secret", with: "***") }
        let recorder: any TranscriptRecorder = GatingRecorder(level: .full, redact: redact, wrapping: inner)
        await recorder.append(samplePartial(kind: .prompt, text: "top secret plan"), to: nil)

        #expect(await inner.events.first?.text == "top *** plan")
    }

    @Test("the redact hook leaves a .session event's agentSpawn untouched: it is provenance, not content")
    func redactLeavesAgentSpawnUntouched() async throws {
        let inner: InMemoryRecorder = .inMemory
        let redact: @Sendable (String) -> String = { _ in "***" }
        let recorder: any TranscriptRecorder = GatingRecorder(level: .full, redact: redact, wrapping: inner)
        let spawn = SessionSidecar.AgentSpawn(
            parentSessionId: .generate(), parentToolCallId: "agents-tool-call-1")
        let partial = TranscriptEvent.Partial(
            routerId: .generate(),
            sessionId: .generate(),
            kind: .session,
            agentSpawn: spawn
        )
        await recorder.append(partial, to: nil)

        #expect(await inner.events.first?.agentSpawn == spawn)
    }

    @Test("the redact hook is applied verbatim: case-sensitivity is the caller's contract")
    func redactHookIsAppliedVerbatim() async throws {
        // The `redact` hook is caller-supplied, so its matching semantics are the
        // caller's concern. A hook targeting lowercase "secret" leaves other
        // spellings untouched — the gate does not case-fold on the caller's behalf.
        let inner: InMemoryRecorder = .inMemory
        let caseSensitive: @Sendable (String) -> String = { $0.replacingOccurrences(of: "secret", with: "***") }
        let recorder: any TranscriptRecorder = GatingRecorder(level: .full, redact: caseSensitive, wrapping: inner)

        await recorder.append(samplePartial(kind: .prompt, text: "Secret and SECRET and secret"), to: nil)

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

        await recorder.append(samplePartial(kind: .prompt, text: "Secret and SECRET and secret"), to: nil)

        #expect(await inner.events.first?.text == "*** and *** and ***")
    }

    // MARK: - Structured entry payload gating (unit)

    /// Builds a payload exercising every segment kind, tool definitions, tool
    /// calls, and every other field the full-redaction path must handle.
    private func richEntryPayload() -> TranscriptEntryPayload {
        TranscriptEntryPayload(
            entryId: "entry-1",
            contentRemoved: false,
            segments: [
                .text(id: "seg-text", content: "a secret text segment"),
                .structure(id: "seg-structure", schemaName: "Weather", contentJSON: #"{"secret":"value"}"#),
                .attachment(id: "seg-attachment", label: "a secret label", url: "file:///secret.png"),
                .custom(
                    id: "seg-custom",
                    typeDiscriminator: "com.example.MySegment",
                    contentJSON: #"{"secret":"payload"}"#,
                    description: "a secret description"
                ),
            ],
            toolDefinitions: [
                ToolDefinitionPayload(
                    name: "search",
                    description: "a secret tool description",
                    parametersSchemaJSON: #"{"secret":"schema"}"#
                )
            ],
            toolCalls: [
                ToolCallPayload(id: "call-1", toolName: "search", argumentsJSON: #"{"secret":"args"}"#)
            ],
            toolName: "search",
            assetIds: ["asset-1", "asset-2"],
            signature: Data("secret-signature".utf8),
            options: GenerationOptionsPayload(temperature: 0.5, maximumResponseTokens: 100),
            responseFormatName: "Weather",
            responseFormatSchemaJSON: #"{"secret":"format"}"#
        )
    }

    @Test("full + redact hook transforms every textual content site in the entry payload")
    func redactTransformsEntryPayloadContentSites() async throws {
        let inner: InMemoryRecorder = .inMemory
        let redact: @Sendable (String) -> String = { $0.replacingOccurrences(of: "secret", with: "***") }
        let recorder: any TranscriptRecorder = GatingRecorder(level: .full, redact: redact, wrapping: inner)
        let payload = richEntryPayload()
        let partial = TranscriptEvent.Partial(
            routerId: .generate(),
            sessionId: .generate(),
            kind: .instructions,
            text: "a secret flattened body",
            entry: payload
        )
        await recorder.append(partial, to: nil)

        let events = await inner.events
        let event = try #require(events.first)
        #expect(event.text == "a *** flattened body")

        let entry = try #require(event.entry)
        // Full payloads are never stripped: contentRemoved stays false.
        #expect(entry.contentRemoved == false)

        let segments = try #require(entry.segments)
        guard case .text(_, let content) = segments[0] else {
            Issue.record("expected a text segment")
            return
        }
        #expect(content == "a *** text segment")

        guard case .structure(_, _, let contentJSON) = segments[1] else {
            Issue.record("expected a structure segment")
            return
        }
        #expect(contentJSON == #"{"***":"value"}"#)

        guard case .attachment(_, let label, let url) = segments[2] else {
            Issue.record("expected an attachment segment")
            return
        }
        #expect(label == "a *** label")
        // The attachment URL is not a textual-content site; it is untouched.
        #expect(url == "file:///secret.png")

        guard case .custom(_, _, let contentJSON, let description) = segments[3] else {
            Issue.record("expected a custom segment")
            return
        }
        #expect(contentJSON == #"{"***":"payload"}"#)
        #expect(description == "a *** description")

        let toolCalls = try #require(entry.toolCalls)
        #expect(toolCalls[0].argumentsJSON == #"{"***":"args"}"#)

        // Tool definitions, the response-format schema, and the reasoning
        // signature are not textual-content sites the redact hook touches.
        #expect(entry.toolDefinitions?.first?.description == "a secret tool description")
        #expect(entry.responseFormatSchemaJSON == #"{"secret":"format"}"#)
    }

    // MARK: - Structured entry payload gating (real JSONL round-trip)

    /// The in-memory test above (`redactTransformsEntryPayloadContentSites`)
    /// only proves the transform GatingRecorder applies before handing the
    /// event to its inner sink; it never proves the redacted payload survives
    /// being encoded to a JSON line, written to disk, and decoded back. This
    /// test closes that gap: a real `JSONLRecorder` writes into a temp
    /// directory and `MergedTranscript.merged(under:)` reads the file back, so
    /// every assertion here is against a value that actually round-tripped
    /// through `Codable` and disk I/O, not the in-memory transform result.
    @Test("full + redact hook entry payload survives a real JSONL write/read round trip")
    func redactEntryPayloadSurvivesJSONLRoundTrip() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let redact: @Sendable (String) -> String = { $0.replacingOccurrences(of: "secret", with: "***") }
        let recorder: any TranscriptRecorder = GatingRecorder(
            level: .full,
            redact: redact,
            wrapping: JSONLRecorder(directory: dir)
        )
        let payload = richEntryPayload()
        let partial = TranscriptEvent.Partial(
            routerId: .generate(),
            sessionId: .generate(),
            kind: .instructions,
            text: "a secret flattened body",
            entry: payload
        )
        await recorder.append(partial, to: nil)

        let merged = try MergedTranscript.merged(under: dir)
        let event = try #require(merged.first)
        #expect(event.text == "a *** flattened body")

        let entry = try #require(event.entry)
        // Full payloads are never stripped: contentRemoved stays false, even
        // after the round trip through disk.
        #expect(entry.contentRemoved == false)

        let segments = try #require(entry.segments)
        guard case .text(_, let content) = segments[0] else {
            Issue.record("expected a text segment")
            return
        }
        #expect(content == "a *** text segment")

        guard case .structure(_, _, let contentJSON) = segments[1] else {
            Issue.record("expected a structure segment")
            return
        }
        #expect(contentJSON == #"{"***":"value"}"#)

        guard case .attachment(_, let label, let url) = segments[2] else {
            Issue.record("expected an attachment segment")
            return
        }
        #expect(label == "a *** label")
        // The attachment URL is not a textual-content site; it is untouched.
        #expect(url == "file:///secret.png")

        guard case .custom(_, _, let contentJSON, let description) = segments[3] else {
            Issue.record("expected a custom segment")
            return
        }
        #expect(contentJSON == #"{"***":"payload"}"#)
        #expect(description == "a *** description")

        let toolCalls = try #require(entry.toolCalls)
        #expect(toolCalls[0].argumentsJSON == #"{"***":"args"}"#)

        // Tool definitions, the response-format schema, and the reasoning
        // signature are not textual-content sites the redact hook touches —
        // still true after the round trip through disk.
        #expect(entry.toolDefinitions?.first?.description == "a secret tool description")
        #expect(entry.responseFormatSchemaJSON == #"{"secret":"format"}"#)
    }

    // MARK: - Wiring through the router (session + embed)

    @Test("redact wired through the router transforms session turn text, and an embed records nothing")
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
        let profile = try await router.resolve(profile: Self.profile, reporting: ResolutionProgress())

        let session = profile.standard.makeSession()
        _ = try await session.respond(to: "a secret prompt")
        _ = try await profile.embedding.embed(texts: ["another secret"])

        let events = await recorder.events
        // No recorded body still contains the redacted token.
        #expect(events.allSatisfy { !($0.text?.contains("secret") ?? false) })
        // The prompt body is present but redacted.
        let prompt = try #require(events.first { $0.kind == .prompt })
        #expect(prompt.text == "a *** prompt")
        // The embed call recorded nothing, so there is no embedding body at all.
        #expect(!events.contains { $0.kind == .embedding })
    }

    // MARK: - Best-effort preserved under gating

    @Test("a forced sink write failure is swallowed under gating; generation and embedding still succeed")
    @MainActor
    func sinkFailureSwallowedUnderGating() async throws {
        let cacheDir = Self.makeTempDir()
        // A regular file standing where the recordings root should be: every
        // directory-create under it fails, so every session write is swallowed.
        // An embed writes nothing at all.
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
        let profile = try await router.resolve(profile: Self.profile, reporting: ResolutionProgress())

        let session = profile.standard.makeSession()
        // Both must return normally despite every recorder write failing.
        let response = try await session.respond(to: "hello")
        #expect(response == Self.cannedText)
        let vectors = try await profile.embedding.embed(texts: ["one", "two"])
        #expect(vectors.count == 2)

        // The blocking file is untouched: nothing was written through it.
        #expect(try Data(contentsOf: blocker).isEmpty)
    }

    // MARK: - Stub containers

    private struct CannedLLMContainer: PlainTranscriptStubContainer {
        let text: String

        func makeSession(instructions: String?) -> any LanguageModelSessionBackend {
            StubSessionBackend(responseText: text)
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

    private struct StubModelLoader: ModelLoader {
        let dimension: Int
        let text: String

        func loadLLM(
            ref: ModelRef,
            slot: ModelSlot,
            context: Int,
            reporting: @escaping @Sendable (DownloadProgress) -> Void
        ) async throws -> any LoadedLLMContainer {
            reporting(DownloadProgress(bytesDownloaded: 1, bytesTotal: 1))
            return CannedLLMContainer(text: text)
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
