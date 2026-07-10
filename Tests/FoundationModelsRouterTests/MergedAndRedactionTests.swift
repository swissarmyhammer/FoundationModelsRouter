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

    // MARK: - Structured entry payload gating (unit)

    /// Builds a payload exercising every segment kind, tool definitions, tool
    /// calls, and every other field the metadataOnly-stripping and
    /// full-redaction paths must handle.
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

    @Test("metadataOnly strips entry payload content but keeps shape")
    func metadataOnlyStripsEntryPayloadContent() async throws {
        let inner: InMemoryRecorder = .inMemory
        let recorder: any TranscriptRecorder = GatingRecorder(level: .metadataOnly, redact: nil, wrapping: inner)
        let payload = richEntryPayload()
        let partial = TranscriptEvent.Partial(
            routerId: .generate(),
            sessionId: .generate(),
            kind: .instructions,
            text: "sensitive flattened body",
            entry: payload
        )
        await recorder.append(partial)

        let events = await inner.events
        let event = try #require(events.first)
        #expect(event.text == nil)

        let entry = try #require(event.entry)
        #expect(entry.contentRemoved == true)
        #expect(entry.entryId == "entry-1")

        let segments = try #require(entry.segments)
        #expect(segments.count == 4)

        guard case .text(let id, let content) = segments[0] else {
            Issue.record("expected a text segment")
            return
        }
        #expect(id == "seg-text")
        #expect(content.isEmpty)

        guard case .structure(let structureId, let schemaName, let contentJSON) = segments[1] else {
            Issue.record("expected a structure segment")
            return
        }
        #expect(structureId == "seg-structure")
        #expect(schemaName == "Weather")
        #expect(contentJSON.isEmpty)

        guard case .attachment(let attachmentId, let label, let url) = segments[2] else {
            Issue.record("expected an attachment segment")
            return
        }
        #expect(attachmentId == "seg-attachment")
        #expect(label == nil)
        #expect(url == nil)

        guard case .custom(let customId, let typeDiscriminator, let contentJSON, let description) = segments[3] else {
            Issue.record("expected a custom segment")
            return
        }
        #expect(customId == "seg-custom")
        #expect(typeDiscriminator == "com.example.MySegment")
        #expect(contentJSON.isEmpty)
        #expect(description == nil)

        let toolDefinitions = try #require(entry.toolDefinitions)
        #expect(toolDefinitions.count == 1)
        #expect(toolDefinitions[0].name == "search")
        #expect(toolDefinitions[0].description.isEmpty)
        #expect(toolDefinitions[0].parametersSchemaJSON.isEmpty)

        let toolCalls = try #require(entry.toolCalls)
        #expect(toolCalls.count == 1)
        #expect(toolCalls[0].id == "call-1")
        #expect(toolCalls[0].toolName == "search")
        #expect(toolCalls[0].argumentsJSON.isEmpty)

        #expect(entry.toolName == "search")
        #expect(entry.assetIds?.count == 2)
        #expect(entry.assetIds == ["", ""])
        #expect(entry.signature == nil)
        #expect(entry.options == payload.options)
        #expect(entry.responseFormatName == "Weather")
        #expect(entry.responseFormatSchemaJSON?.isEmpty == true)
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
        await recorder.append(partial)

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

    @Test("metadataOnly with no entry payload still nils text and writes no entry content")
    func metadataOnlyWithNilEntryPayload() async throws {
        let inner: InMemoryRecorder = .inMemory
        let recorder: any TranscriptRecorder = GatingRecorder(level: .metadataOnly, redact: nil, wrapping: inner)
        await recorder.append(samplePartial(kind: .prompt, text: "sensitive body"))

        let events = await inner.events
        let event = try #require(events.first)
        #expect(event.text == nil)
        #expect(event.entry == nil)
    }

    // MARK: - Structured entry payload gating (real JSONL round-trip)

    /// The in-memory tests above (`metadataOnlyStripsEntryPayloadContent`,
    /// `redactTransformsEntryPayloadContentSites`) only prove the transform
    /// GatingRecorder applies before handing the event to its inner sink; they
    /// never prove the stripped/redacted payload survives being encoded to a
    /// JSON line, written to disk, and decoded back. These two tests close that
    /// gap: a real `JSONLRecorder` writes into a temp directory and
    /// `MergedTranscript.merged(under:)` reads the file back, so every
    /// assertion here is against a value that actually round-tripped through
    /// `Codable` and disk I/O, not the in-memory transform result.
    @Test("metadataOnly-stripped entry payload survives a real JSONL write/read round trip")
    func metadataOnlyEntryPayloadSurvivesJSONLRoundTrip() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let recorder: any TranscriptRecorder = GatingRecorder(
            level: .metadataOnly,
            redact: nil,
            wrapping: JSONLRecorder(directory: dir)
        )
        let payload = richEntryPayload()
        let partial = TranscriptEvent.Partial(
            routerId: .generate(),
            sessionId: .generate(),
            kind: .instructions,
            text: "sensitive flattened body",
            entry: payload
        )
        await recorder.append(partial)

        let merged = try MergedTranscript.merged(under: dir)
        let event = try #require(merged.first)
        #expect(event.text == nil)

        let entry = try #require(event.entry)
        #expect(entry.contentRemoved == true)
        #expect(entry.entryId == "entry-1")

        let segments = try #require(entry.segments)
        #expect(segments.count == 4)

        guard case .text(let id, let content) = segments[0] else {
            Issue.record("expected a text segment")
            return
        }
        #expect(id == "seg-text")
        #expect(content.isEmpty)

        guard case .structure(let structureId, let schemaName, let contentJSON) = segments[1] else {
            Issue.record("expected a structure segment")
            return
        }
        #expect(structureId == "seg-structure")
        #expect(schemaName == "Weather")
        #expect(contentJSON.isEmpty)

        guard case .attachment(let attachmentId, let label, let url) = segments[2] else {
            Issue.record("expected an attachment segment")
            return
        }
        #expect(attachmentId == "seg-attachment")
        #expect(label == nil)
        #expect(url == nil)

        guard case .custom(let customId, let typeDiscriminator, let contentJSON, let description) = segments[3] else {
            Issue.record("expected a custom segment")
            return
        }
        #expect(customId == "seg-custom")
        #expect(typeDiscriminator == "com.example.MySegment")
        #expect(contentJSON.isEmpty)
        #expect(description == nil)

        let toolDefinitions = try #require(entry.toolDefinitions)
        #expect(toolDefinitions.count == 1)
        #expect(toolDefinitions[0].name == "search")
        #expect(toolDefinitions[0].description.isEmpty)
        #expect(toolDefinitions[0].parametersSchemaJSON.isEmpty)

        let toolCalls = try #require(entry.toolCalls)
        #expect(toolCalls.count == 1)
        #expect(toolCalls[0].id == "call-1")
        #expect(toolCalls[0].toolName == "search")
        #expect(toolCalls[0].argumentsJSON.isEmpty)

        #expect(entry.toolName == "search")
        #expect(entry.assetIds?.count == 2)
        #expect(entry.assetIds == ["", ""])
        #expect(entry.signature == nil)
        #expect(entry.options == payload.options)
        #expect(entry.responseFormatName == "Weather")
        #expect(entry.responseFormatSchemaJSON?.isEmpty == true)
    }

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
        await recorder.append(partial)

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
        let profile = try await router.resolve(profile: Self.profile, reporting: ResolutionProgress())

        let session = profile.standard.makeSession()
        _ = try await session.respond(to: "a secret prompt")
        _ = try await profile.embedding.embed(texts: ["a secret document"])

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
