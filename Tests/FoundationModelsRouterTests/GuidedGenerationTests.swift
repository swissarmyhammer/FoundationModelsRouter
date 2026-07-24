import Foundation
import FoundationModels
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

        /// Mirrors ``makeSession(instructions:)``'s ``maxTokensSpy`` wrapping
        /// instead of the shared plain default, so a future transcript-seeded
        /// test observing `maxTokens` through this container's spy is not
        /// silently unwrapped.
        func makeSession(transcript: Transcript) -> any LanguageModelSessionBackend {
            let backend = StubSessionBackend(entries: Array(transcript))
            guard let maxTokensSpy else { return backend }
            return MaxTokensRecordingBackend(backend: backend, spy: maxTokensSpy)
        }
    }

    /// Wraps a ``StubSessionBackend`` to additionally record each guided call's
    /// `maxTokens` into a ``MaxTokensSpy``, mirroring
    /// ``SessionChokepointTests``'s analogous wrapper for the plain (unguided)
    /// path.
    ///
    /// `@unchecked Sendable` is safe here because `RoutedSessionActor` serializes
    /// all method calls through the model's serial gate, and both wrapped fields
    /// (`backend`, `spy`) are themselves `Sendable` — `backend` is a `StubSessionBackend`
    /// and `spy` is an actor.
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

        /// Proxies ``StubSessionBackend/transcriptEntries()``.
        func transcriptEntries() -> [Transcript.Entry] {
            backend.transcriptEntries()
        }

        /// Proxies ``StubSessionBackend/usageTokenCounts()``.
        func usageTokenCounts() -> (input: Int, output: Int)? {
            backend.usageTokenCounts()
        }

        func makeFork() -> any LanguageModelSessionBackend {
            // `StubSessionBackend.makeFork()` always concretely returns another
            // `StubSessionBackend` (see its doc comment); preserve that identity
            // here so the fork keeps recording through `spy`, mirroring how the
            // live backend's wrapping would apply uniformly across forks.
            guard let fork = backend.makeFork() as? StubSessionBackend else {
                preconditionFailure("StubSessionBackend.makeFork() must return a StubSessionBackend")
            }
            return MaxTokensRecordingBackend(backend: fork, spy: spy)
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

    @Test("makeGuidedSession forwards budget/compactionPrompt to the vended session (task 8213x39)")
    @MainActor
    func guidedSessionForwardsAutoCompactionBudget() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let recorder = InMemoryRecorder()
        let router = Self.makeRouter(recorder: recorder, cacheDir: dir)
        let profile = try await router.resolve(profile: Self.profile, reporting: ResolutionProgress())

        let budget = TokenBudget(limit: 4096, trigger: 0.5, target: 0.2)
        let customPrompt = CompactionPrompt(name: "guided-test-prompt", text: "Summarize tersely.")
        let session = profile.standard.makeGuidedSession(
            grammar: .jsonSchema(Self.smallSchema), budget: budget, compactionPrompt: customPrompt)

        // `makeGuidedSession` shares the same internal builder as
        // `makeSession(instructions:workingDirectory:tools:budget:compactionPrompt:)`
        // — this asserts a guided session actually receives the opt-in rather
        // than silently dropping it, closing the gap a prior review found.
        let actor = try #require(session as? RoutedSessionActor)
        #expect(actor.autoCompactionBudget == budget)
        #expect(actor.autoCompactionPrompt == customPrompt)
    }

    // MARK: - Guided session end-to-end auto-compaction trigger

    /// Vends a single, test-retained ``StubSessionBackend`` per session,
    /// mirroring `AutoCompactionTests.ConfiguredLLMContainer` — lets a test
    /// mutate the returned backend's `usageIncrement` directly to drive
    /// `contextFill` up to a budget's trigger. Unlike ``StubModelLoader``
    /// above, this needs no `maxTokensSpy` wrapping and no separate guided
    /// container: ``StubSessionBackend``'s guided `respond(to:following:maxTokens:)`
    /// already runs the real xgrammar-subset validation, so a plain stub
    /// backend serves both the warm-up turns and the triggering turn.
    private final class AutoCompactionTriggerContainer: LoadedLLMContainer, @unchecked Sendable {
        let responseText: String
        private(set) var lastBackend: StubSessionBackend?

        init(responseText: String) {
            self.responseText = responseText
        }

        func makeSession(instructions: String?) -> any LanguageModelSessionBackend {
            let backend = StubSessionBackend(responseText: responseText, instructions: instructions)
            lastBackend = backend
            return backend
        }

        func makeSession(transcript: Transcript) -> any LanguageModelSessionBackend {
            StubSessionBackend(responseText: responseText, entries: Array(transcript))
        }
    }

    /// Vends `standard` for the `.standard` slot and `flash` for the `.flash`
    /// slot — mirrors `AutoCompactionTests.PerSlotModelLoader`, needed here
    /// (unlike this file's own ``StubModelLoader``, which ignores slot) so
    /// the guided auto-compaction test can tell which slot's model actually
    /// summarized.
    private struct AutoCompactionPerSlotModelLoader: ModelLoader {
        let standard: any LoadedLLMContainer
        let flash: any LoadedLLMContainer
        let dimension: Int

        func loadLLM(
            ref: ModelRef,
            slot: ModelSlot,
            context: Int,
            reporting: @escaping @Sendable (DownloadProgress) -> Void
        ) async throws -> any LoadedLLMContainer {
            reporting(DownloadProgress(bytesDownloaded: 1, bytesTotal: 1))
            return slot == .flash ? flash : standard
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

    /// A long-ish canned response repeated across every warm-up turn, so a
    /// handful of turns' worth of transcript already carries a real,
    /// non-trivial byte-size estimate — mirrors `AutoCompactionTests.cannedText`.
    private static let autoCompactionCannedText = String(
        repeating: "The quick brown fox jumps over the lazy dog. ", count: 12)

    /// How many warm-up turns the guided trigger test drives — past
    /// `TurnTruncation`'s default 4-turn recency window, so folding has real
    /// old-span content to work with. Mirrors `AutoCompactionTests.turnCount`.
    private static let autoCompactionTurnCount = 6

    /// The exact entries the guided trigger test's warm-up turns produce,
    /// computed without ever running a session — mirrors
    /// `AutoCompactionTests.expectedWarmUpEntries()`.
    private static func autoCompactionWarmUpEntries() -> [Transcript.Entry] {
        (0..<autoCompactionTurnCount).flatMap { index -> [Transcript.Entry] in
            [
                .prompt(Transcript.Prompt(segments: [.text(Transcript.TextSegment(content: "turn \(index)"))])),
                .response(
                    Transcript.Response(
                        assetIDs: [], segments: [.text(Transcript.TextSegment(content: autoCompactionCannedText))])),
            ]
        }
    }

    /// The estimated token size of just the warm-up entries' un-foldable
    /// recency window (the newest 4 turns) — the floor no deterministic
    /// stage can fold below, so a `budget.target` under this forces the
    /// model-assisted ``Summarization`` stage (and therefore a real
    /// summarizer call) to run. Mirrors `AutoCompactionTests.recencyWindowOnlyEstimate(_:)`.
    private static func autoCompactionRecencyWindowOnlyEstimate(_ entries: [Transcript.Entry]) -> Int {
        let (header, turns) = TranscriptTurns.split(entries)
        let (_, recent) = TranscriptTurns.partition(turns, keepRecentTurns: 4)
        return Compactor.estimatedTokenCount(of: Transcript(entries: header + recent.flatMap(\.entries)))
    }

    /// A budget whose target sits strictly below the warm-up transcript's own
    /// recency-window floor — forcing the triggering fold to need the
    /// model-assisted ``Summarization`` stage. Mirrors `AutoCompactionTests.fixedBudget`.
    private static let autoCompactionFixedBudget: TokenBudget = {
        let recencyOnly = autoCompactionRecencyWindowOnlyEstimate(autoCompactionWarmUpEntries())
        return TokenBudget(limit: recencyOnly * 2, trigger: 0.8, target: 0.25)
    }()

    /// Drains `stream` into an array, in order — mirrors `AutoCompactionTests.collect(_:)`.
    private static func collect(_ stream: AsyncThrowingStream<SessionEvent, Error>) async throws -> [SessionEvent] {
        var events: [SessionEvent] = []
        for try await event in stream {
            events.append(event)
        }
        return events
    }

    @Test(
        "a guided session vended with a budget auto-compacts once measured fill reaches the trigger, proving the guided path actually exercises auto-compaction end-to-end (task 8213x39)"
    )
    @MainActor
    func guidedSessionAutoCompactsAtTrigger() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let recorder = InMemoryRecorder()
        let standardContainer = AutoCompactionTriggerContainer(responseText: Self.autoCompactionCannedText)
        let flashContainer = AutoCompactionTriggerContainer(responseText: "FLASH-SUMMARY")
        let loader = AutoCompactionPerSlotModelLoader(standard: standardContainer, flash: flashContainer, dimension: 8)
        let router = Router(
            cacheDir: dir,
            recorder: recorder,
            probe: StubProbe(chip: "Apple Test", totalRAM: 64 << 30, recommendedMaxWorkingSetSize: 48 << 30),
            metadataSource: StubMetadataSource(raw: Self.rawMetadata),
            loader: loader
        )
        // A 100,000-token working context, mirroring `AutoCompactionTests.makeTriggeredSession(budget:)`'s
        // own profile so the same escalating-usage warm-up below produces
        // the same 0.9 final fill.
        var triggerProfile = Self.profile
        triggerProfile.context = 100_000
        let resolvedProfile = try await router.resolve(profile: triggerProfile, reporting: ResolutionProgress())

        let session = resolvedProfile.standard.makeGuidedSession(
            grammar: .jsonSchema(Self.smallSchema), budget: Self.autoCompactionFixedBudget)
        let backend = try #require(standardContainer.lastBackend)

        // Warm-up turns run through the guided path — `RoutedSessionActor.respond(to:maxTokens:)`
        // forwards this session's own `grammar` to `backend.respond(to:following:maxTokens:)`
        // (see that method's own doc comment) — with escalating measured
        // usage crossing the fixed budget's 0.8 trigger only on the final
        // warm-up turn, exactly like `AutoCompactionTests.makeTriggeredSession(budget:)`
        // drives for the unguided path.
        for turn in 0..<Self.autoCompactionTurnCount {
            backend.usageIncrement = (input: (turn + 1) * 15_000, output: 0)
            _ = try await session.respond(to: "turn \(turn)")
        }
        #expect(await session.contextFill == 0.9)

        // The next turn should fold automatically, before its own work runs,
        // with no caller-side `compact()` call anywhere in this test — the
        // same proof `AutoCompactionTests.proactiveFoldPrefersFlashSummarizer()`
        // gives for the unguided path, now for a session vended through
        // `makeGuidedSession`.
        let events = try await Self.collect(session.streamEvents(to: "turn 6", maxTokens: nil))

        guard case .compaction(let result) = events.first else {
            Issue.record("expected the first event to be .compaction, got \(String(describing: events.first))")
            return
        }
        #expect(result.stagesApplied.contains("Summarization"))
        // The summary text is flash's own canned response — proof flash,
        // not the session's own model, actually produced it, mirroring the
        // unguided proof.
        #expect(result.summary == "FLASH-SUMMARY")

        // The triggering turn's own work still ran normally afterward.
        #expect(events.contains(.textDelta(Self.autoCompactionCannedText)))
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
