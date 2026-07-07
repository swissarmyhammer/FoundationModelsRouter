import Foundation
import Testing

@testable import FoundationModelsRouter

/// Exercises milestone 8a: grammar-constrained decoding — the ``Grammar`` value,
/// the xgrammar-subset validation, the guided ``RoutedSession`` surface, and the
/// recorder-bracketed chokepoint stamping the grammar onto each turn.
///
/// Everything runs against stubs — a guided stub ``LoadedLLMContainer`` that
/// performs the real (GPU-free) grammar validation and returns canned text, plus
/// an ``InMemoryRecorder`` — so the suite needs no network and no GPU. Real
/// constrained decoding over MLX is gated to the milestone 7 integration suite.
@Suite("Guided generation: Grammar + raw guided sessions")
struct GuidedGenerationTests {
    // MARK: - Stub containers

    /// Records the `maxTokens` value each guided generation call on a
    /// ``GuidedStubContainer`` observed, so a test can assert
    /// ``RoutedModel/respond(to:following:maxTokens:)`` forwards an explicit
    /// override down to the container's guided entry point.
    private actor MaxTokensSpy {
        private(set) var observed: [Int?] = []
        func record(_ value: Int?) { observed.append(value) }
    }

    /// A loaded LLM container that runs the real grammar validation behind its
    /// guided entry point and returns canned constrained text on success — the
    /// GPU-free stand-in for the xgrammar engine.
    private struct GuidedStubContainer: LoadedLLMContainer {
        let canned: String
        var maxTokensSpy: MaxTokensSpy?

        func makeSession(instructions: String?) -> any LanguageModelSessionBackend {
            let backend = StubSessionBackend(responseText: canned)
            guard let maxTokensSpy else { return backend }
            return MaxTokensRecordingBackend(backend: backend, spy: maxTokensSpy)
        }
    }

    /// Wraps a ``StubSessionBackend`` to additionally record each guided call's
    /// `maxTokens` into a ``MaxTokensSpy``, mirroring
    /// ``SessionChokepointTests``'s analogous wrapper for the plain (unguided)
    /// path.
    private final class MaxTokensRecordingBackend: LanguageModelSessionBackend, @unchecked Sendable {
        private let backend: StubSessionBackend
        private let spy: MaxTokensSpy

        init(backend: StubSessionBackend, spy: MaxTokensSpy) {
            self.backend = backend
            self.spy = spy
        }

        func respond(to prompt: String, maxTokens: Int?) async throws -> String {
            try await backend.respond(to: prompt, maxTokens: maxTokens)
        }

        func streamResponse(to prompt: String, maxTokens: Int?) -> AsyncThrowingStream<String, Error> {
            backend.streamResponse(to: prompt, maxTokens: maxTokens)
        }

        func respond(to prompt: String, following grammar: Grammar, maxTokens: Int?) async throws -> String {
            await spy.record(maxTokens)
            return try await backend.respond(to: prompt, following: grammar, maxTokens: maxTokens)
        }

        func makeFork() -> any LanguageModelSessionBackend {
            backend.makeFork()
        }
    }

    private struct StubEmbeddingContainer: LoadedEmbeddingContainer {
        let dimension: Int
        func embed(texts: [String]) async throws -> [[Float]] {
            texts.map { _ in [Float](repeating: 0.5, count: dimension) }
        }
    }

    /// A ``ModelLoader`` that vends the guided stub container and a stub embedder
    /// without download or GPU work.
    private struct StubModelLoader: ModelLoader {
        let dimension: Int
        let canned: String
        var maxTokensSpy: MaxTokensSpy?

        func loadLLM(
            ref: ModelRef,
            slot: ModelSlot,
            context: Int,
            reporting: @escaping @Sendable (DownloadProgress) -> Void
        ) async throws -> any LoadedLLMContainer {
            reporting(DownloadProgress(bytesDownloaded: 1, bytesTotal: 1))
            return GuidedStubContainer(canned: canned, maxTokensSpy: maxTokensSpy)
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

    private struct StubProbe: MachineProbe {
        let chip: String
        let totalRAM: Int64
        let recommendedMaxWorkingSetSize: Int64
    }

    private struct StubMetadataSource: MetadataSource {
        let raw: RawRepoMetadata
        func fetchRawMetadata(repo: String, revision: String?) async throws -> RawRepoMetadata { raw }
    }

    // MARK: - Fixtures

    private static let configJson = Data("""
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
        RawRepoMetadata(configJSON: configJson, treeJSON: treeJSON)
    }

    private static let profile = ProfileDefinition(
        name: "coding",
        description: "test profile",
        standard: ["org/std-a"],
        flash: ["org/flash-a"],
        embedding: ["org/emb-a"]
    )

    private static let canned = "{\"name\":\"ok\"}"
    private static let smallSchema = """
        {"type":"object","properties":{"name":{"type":"string"}},"required":["name"]}
        """
    private static let ebnf = "root ::= \"yes\" | \"no\""

    private static func makeTempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("GuidedGenerationTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func makeRouter(
        recorder: any TranscriptRecorder,
        cacheDir: URL,
        maxTokensSpy: MaxTokensSpy? = nil
    ) -> Router {
        Router(
            cacheDir: cacheDir,
            recorder: recorder,
            probe: StubProbe(chip: "Apple Test", totalRAM: 64 << 30, recommendedMaxWorkingSetSize: 48 << 30),
            metadataSource: StubMetadataSource(raw: rawMetadata),
            loader: StubModelLoader(dimension: 8, canned: canned, maxTokensSpy: maxTokensSpy)
        )
    }

    // MARK: - Pure validation

    @Test("a small JSON schema and an EBNF grammar pass xgrammar-subset validation")
    func validGrammarsCompile() throws {
        try Grammar.jsonSchema(Self.smallSchema).validateForXGrammar()
        try Grammar.ebnf(Self.ebnf).validateForXGrammar()
    }

    @Test(
        "unsupported JSON-schema constructs raise a typed GuidedRequestError",
        arguments: [
            ("{\"$ref\":\"#/$defs/Y\"}", "$ref"),
            ("{\"allOf\":[{\"type\":\"string\"}]}", "allOf"),
            ("{\"type\":\"string\",\"format\":\"email\"}", "format"),
        ]
    )
    func unsupportedConstructsRejected(schema: String, keyword: String) throws {
        #expect {
            try Grammar.jsonSchema(schema).validateForXGrammar()
        } throws: { error in
            guard case let GuidedRequestError.unsupportedSchemaConstructs(found) = error else {
                return false
            }
            return found.contains(keyword)
        }
    }

    @Test("a nested unsupported construct is detected anywhere in the schema")
    func nestedUnsupportedConstructRejected() throws {
        let schema = """
            {"type":"object","properties":{"x":{"$ref":"#/$defs/Y"}}}
            """
        #expect {
            try Grammar.jsonSchema(schema).validateForXGrammar()
        } throws: { error in
            guard case let GuidedRequestError.unsupportedSchemaConstructs(found) = error else {
                return false
            }
            return found.contains("$ref")
        }
    }

    @Test("a JSON-schema grammar that is not valid JSON raises a typed error")
    func invalidJSONRejected() throws {
        #expect(throws: GuidedRequestError.self) {
            try Grammar.jsonSchema("not json at all").validateForXGrammar()
        }
    }

    @Test("a property whose name matches a keyword is not mistaken for that keyword")
    func keywordAsPropertyNameAccepted() throws {
        // `format`/`$ref`/`allOf` as PROPERTY NAMES under `properties` are valid:
        // they sit in a name position, not a JSON-Schema keyword position.
        try Grammar.jsonSchema("""
            {"type":"object","properties":{"format":{"type":"string"}}}
            """).validateForXGrammar()
        try Grammar.jsonSchema("""
            {"type":"object","properties":{"$ref":{"type":"string"},"allOf":{"type":"number"}}}
            """).validateForXGrammar()
    }

    @Test("an unsupported keyword inside instance-data keywords is not flagged")
    func keywordInsideInstanceDataAccepted() throws {
        // `const`/`enum`/`default` carry instance data, not subschemas, so a key
        // named like a keyword inside them is data — not a keyword in use.
        try Grammar.jsonSchema("""
            {"type":"object","const":{"format":"email"}}
            """).validateForXGrammar()
        try Grammar.jsonSchema("""
            {"type":"object","enum":[{"allOf":1}]}
            """).validateForXGrammar()
    }

    @Test("a real keyword nested under a same-named property is still rejected")
    func realKeywordUnderSameNamedPropertyRejected() throws {
        // The property is named `format`, but its subschema genuinely uses the
        // `format` keyword — that must still be rejected.
        let schema = """
            {"type":"object","properties":{"format":{"type":"string","format":"email"}}}
            """
        #expect {
            try Grammar.jsonSchema(schema).validateForXGrammar()
        } throws: { error in
            guard case let GuidedRequestError.unsupportedSchemaConstructs(found) = error else {
                return false
            }
            return found.contains("format")
        }
    }

    // MARK: - Guided session through the chokepoint

    @Test("a guided session constrains respond and records the grammar")
    @MainActor
    func guidedSessionConstrainsAndRecords() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let recorder = InMemoryRecorder()
        let router = Self.makeRouter(recorder: recorder, cacheDir: dir)
        let profile = try await router.resolve(profile: Self.profile, reporting: ResolutionProgress())

        let session = profile.standard.makeGuidedSession(grammar: .jsonSchema(Self.smallSchema))
        let text = try await session.respond(to: "hi")
        #expect(text == Self.canned)

        let events = await recorder.events
        #expect(events.map(\.kind) == [.session, .prompt, .response])
        #expect(events.allSatisfy { $0.grammar == Self.smallSchema })
    }

    @Test("an EBNF guided session returns text and records the grammar")
    @MainActor
    func ebnfGuidedSession() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let recorder = InMemoryRecorder()
        let router = Self.makeRouter(recorder: recorder, cacheDir: dir)
        let profile = try await router.resolve(profile: Self.profile, reporting: ResolutionProgress())

        let session = profile.standard.makeGuidedSession(grammar: .ebnf(Self.ebnf))
        let text = try await session.respond(to: "hi")
        #expect(text == Self.canned)

        let events = await recorder.events
        #expect(events.allSatisfy { $0.grammar == Self.ebnf })
    }

    @Test("respond(to:following:) routes through the chokepoint and records the grammar")
    @MainActor
    func respondFollowingRecordsGrammar() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let recorder = InMemoryRecorder()
        let router = Self.makeRouter(recorder: recorder, cacheDir: dir)
        let profile = try await router.resolve(profile: Self.profile, reporting: ResolutionProgress())

        let text = try await profile.standard.respond(to: "hi", following: .jsonSchema(Self.smallSchema))
        #expect(text == Self.canned)

        let events = await recorder.events
        #expect(events.map(\.kind) == [.session, .prompt, .response])
        #expect(events.allSatisfy { $0.grammar == Self.smallSchema })
    }

    @Test("a guided session with unsupported constructs throws a typed error through the chokepoint")
    @MainActor
    func guidedSessionRejectsUnsupported() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let recorder = InMemoryRecorder()
        let router = Self.makeRouter(recorder: recorder, cacheDir: dir)
        let profile = try await router.resolve(profile: Self.profile, reporting: ResolutionProgress())

        let session = profile.standard.makeGuidedSession(grammar: .jsonSchema("{\"$ref\":\"#/$defs/Y\"}"))
        await #expect(throws: GuidedRequestError.self) {
            _ = try await session.respond(to: "hi")
        }

        // The chokepoint still brackets the failed turn: a `session` meta line,
        // then one open + one close.
        let events = await recorder.events
        #expect(events.map(\.kind) == [.session, .prompt, .response])
    }

    @Test("the grammar travels with the session so a milestone-9 fork inherits it")
    @MainActor
    func grammarTravelsWithSession() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let router = Self.makeRouter(recorder: InMemoryRecorder(), cacheDir: dir)
        let profile = try await router.resolve(profile: Self.profile, reporting: ResolutionProgress())

        let grammar = Grammar.jsonSchema(Self.smallSchema)
        let guided = profile.standard.makeGuidedSession(grammar: grammar)
        #expect(guided.grammar == grammar)

        // A plain session carries no grammar.
        let plain = profile.standard.makeSession()
        #expect(plain.grammar == nil)
    }

    // MARK: - Grammar validation gates a guided call before any live decode

    /// Replaces the removed `defaultContainerValidatesThenDefersLiveDecode`:
    /// that test exercised the `LoadedLLMContainer` default guided extension
    /// (validate, then defer to `GenerationError.notWiredForLiveInference`),
    /// which no longer exists now that a container only manufactures a
    /// ``LanguageModelSessionBackend`` via `makeSession(instructions:)` — there
    /// is no more container-level guided entry point to validate-then-defer
    /// through. The behavior worth guarding — a supported grammar passes
    /// ``Grammar/validateForXGrammar()`` while an unsupported one is rejected
    /// before any decode is attempted — still holds and is real, GPU-free logic
    /// every guided backend (stub or live) runs first; this asserts it directly.
    @Test("grammar.validateForXGrammar() accepts a supported schema and rejects an unsupported one")
    func validateForXGrammarAcceptsSupportedRejectsUnsupported() throws {
        // A supported schema passes validation with no error.
        try Grammar.jsonSchema(Self.smallSchema).validateForXGrammar()

        // An unsupported construct ($ref/allOf/format) is rejected before any
        // decode would be attempted.
        #expect(throws: GuidedRequestError.self) {
            try Grammar.jsonSchema("{\"allOf\":[{\"type\":\"string\"}]}").validateForXGrammar()
        }
    }

    // MARK: - maxTokens threading

    @Test("respond(to:following:maxTokens:) forwards an explicit override to the guided container call")
    @MainActor
    func respondFollowingForwardsMaxTokensOverride() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let maxTokensSpy = MaxTokensSpy()
        let router = Self.makeRouter(recorder: InMemoryRecorder(), cacheDir: dir, maxTokensSpy: maxTokensSpy)
        let profile = try await router.resolve(profile: Self.profile, reporting: ResolutionProgress())

        _ = try await profile.standard.respond(
            to: "hi",
            following: .jsonSchema(Self.smallSchema),
            maxTokens: 2048
        )
        _ = try await profile.standard.respond(to: "hi", following: .jsonSchema(Self.smallSchema))

        #expect(await maxTokensSpy.observed == [2048, nil])
    }
}
