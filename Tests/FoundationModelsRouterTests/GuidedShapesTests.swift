#if canImport(FoundationModels)
    import Foundation
    import FoundationModels
    import Testing

    @testable import FoundationModelsRouter

    /// Exercises milestone 8b: the two higher-level guided response shapes built on
    /// the raw guided layer (milestone 8a) — the *typed* `respond(to:generating:)`
    /// whose schema is derived from a `@Generable` type and whose output is decoded
    /// back into that type, and the *dynamic* `respond(to:matching:)` for a runtime
    /// schema with no Swift type, whose output is parsed into ``JSONValue``.
    ///
    /// The pure, GPU-free halves — deriving a JSON Schema from a `@Generable` type,
    /// decoding raw JSON into that type, and parsing raw JSON into ``JSONValue`` —
    /// are asserted directly and end-to-end through a guided stub container that
    /// returns canned constrained JSON. Real constrained decoding over MLX is gated
    /// to the milestone 7 integration suite; nothing here needs network or GPU.
    @Suite("Guided generation: typed + dynamic-JSON response shapes")
    struct GuidedShapesTests {
        // MARK: - Sample @Generable type

        /// A small, flat `@Generable` type whose derived schema stays inside the
        /// xgrammar-supported subset (scalar properties only — no `$ref`/`format`).
        @Generable
        struct Person: Equatable {
            @Guide(description: "The person's name.")
            var name: String

            @Guide(description: "The person's age in years.")
            var age: Int
        }

        // MARK: - Stub container plumbing (no GPU / no network)

        /// A loaded LLM container that runs the real (GPU-free) grammar validation
        /// behind its guided entry point and returns canned constrained JSON on
        /// success — the stand-in for the xgrammar engine.
        private struct GuidedStubContainer: LoadedLLMContainer {
            let canned: String

            func respond(to prompt: String, instructions: String?) async throws -> String {
                canned
            }

            func streamResponse(
                to prompt: String,
                instructions: String?
            ) -> AsyncThrowingStream<String, Error> {
                let canned = canned
                return AsyncThrowingStream { continuation in
                    continuation.yield(canned)
                    continuation.finish()
                }
            }

            func respond(
                to prompt: String,
                instructions: String?,
                following grammar: Grammar
            ) async throws -> String {
                try grammar.validateForXGrammar()
                return canned
            }
        }

        private struct StubEmbeddingContainer: LoadedEmbeddingContainer {
            let dimension: Int
            func embed(_ texts: [String]) async throws -> [[Float]] {
                texts.map { _ in [Float](repeating: 0.5, count: dimension) }
            }
        }

        /// A ``ModelLoader`` that vends the guided stub container returning `canned`.
        private struct StubModelLoader: ModelLoader {
            let dimension: Int
            let canned: String

            func loadLLM(
                _ ref: ModelRef,
                slot: ModelSlot,
                context: Int,
                reporting: @escaping @Sendable (DownloadProgress) -> Void
            ) async throws -> any LoadedLLMContainer {
                reporting(DownloadProgress(bytesDownloaded: 1, bytesTotal: 1))
                return GuidedStubContainer(canned: canned)
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

        private struct StubProbe: MachineProbe {
            let chip: String
            let totalRAM: Int64
            let recommendedMaxWorkingSetSize: Int64
        }

        private struct StubMetadataSource: MetadataSource {
            let raw: RawRepoMetadata
            func fetchRawMetadata(repo: String, revision: String?) async throws -> RawRepoMetadata {
                raw
            }
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

        /// Canned constrained JSON the stub returns — a valid ``Person`` instance.
        private static let cannedPerson = "{\"name\":\"Ada\",\"age\":36}"

        /// A small object schema for the dynamic shape.
        private static let objectSchema = """
            {"type":"object","properties":{"name":{"type":"string"}},"required":["name"]}
            """

        private static func makeTempDir() -> URL {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("GuidedShapesTests-\(UUID().uuidString)", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir
        }

        private static func makeRouter(
            recorder: any TranscriptRecorder,
            cacheDir: URL,
            canned: String
        ) -> Router {
            Router(
                cacheDir: cacheDir,
                recorder: recorder,
                probe: StubProbe(
                    chip: "Apple Test",
                    totalRAM: 64 << 30,
                    recommendedMaxWorkingSetSize: 48 << 30
                ),
                metadataSource: StubMetadataSource(raw: rawMetadata),
                loader: StubModelLoader(dimension: 8, canned: canned)
            )
        }

        // MARK: - Pure schema derivation

        @Test("the schema derived from a @Generable type matches the type's shape")
        func derivedSchemaMatchesShape() throws {
            let schema = try GuidedShapes.derivedSchema(for: Person.self)

            // It is valid JSON describing an object with the type's two properties.
            let data = try #require(schema.data(using: .utf8))
            let root = try #require(
                try JSONSerialization.jsonObject(with: data) as? [String: Any]
            )
            #expect(root["type"] as? String == "object")

            let properties = try #require(root["properties"] as? [String: Any])
            #expect(Set(properties.keys) == ["name", "age"])
            let nameSchema = try #require(properties["name"] as? [String: Any])
            #expect(nameSchema["type"] as? String == "string")
            let ageSchema = try #require(properties["age"] as? [String: Any])
            #expect(ageSchema["type"] as? String == "integer")

            // The derived schema is inside the xgrammar-supported subset, so the raw
            // guided layer will accept it rather than reject it.
            try Grammar.jsonSchema(schema).validateForXGrammar()
        }

        // MARK: - Pure decode into T

        @Test("a canned raw-JSON string decodes into the @Generable type")
        func decodeCannedJSONIntoT() throws {
            let person = try GuidedShapes.decode(Self.cannedPerson, as: Person.self)
            #expect(person == Person(name: "Ada", age: 36))
        }

        @Test("a malformed raw-JSON string surfaces a typed GuidedGenerationError")
        func decodeMalformedRaisesGuidedError() throws {
            #expect(throws: GuidedGenerationError.self) {
                _ = try GuidedShapes.decode("not json at all", as: Person.self)
            }
        }

        // MARK: - Pure dynamic parse into JSONValue

        @Test("a canned schema-valid JSON string parses into the correct JSONValue")
        func dynamicParseIntoJSONValue() throws {
            let value = try GuidedShapes.parse("{\"name\":\"ok\",\"age\":1}")
            #expect(
                value == .object(["name": .string("ok"), "age": .number(1)])
            )
        }

        @Test("a malformed dynamic response surfaces a typed GuidedGenerationError")
        func dynamicParseMalformedRaisesGuidedError() throws {
            #expect(throws: GuidedGenerationError.self) {
                _ = try GuidedShapes.parse("not json at all")
            }
        }

        // MARK: - End-to-end through the raw guided layer (stub container)

        @Test("respond(to:generating:) derives, routes, and decodes into T")
        @MainActor
        func respondGeneratingDecodesTypedResult() async throws {
            let dir = Self.makeTempDir()
            defer { try? FileManager.default.removeItem(at: dir) }

            let recorder = InMemoryRecorder()
            let router = Self.makeRouter(
                recorder: recorder,
                cacheDir: dir,
                canned: Self.cannedPerson
            )
            let profile = try await router.resolve(Self.profile, reporting: ResolutionProgress())

            let person = try await profile.standard.respond(to: "hi", generating: Person.self)
            #expect(person == Person(name: "Ada", age: 36))

            // The turn still funnels through the recorder-bracketed chokepoint,
            // stamped with the derived schema. `GenerationSchema` encodes with
            // nondeterministic key ordering, so compare the stamped grammar to the
            // derived schema *semantically* (parsed) rather than byte-for-byte.
            let events = await recorder.events
            #expect(events.map(\.kind) == [.prompt, .response])
            let derived = try GuidedShapes.parse(GuidedShapes.derivedSchema(for: Person.self))
            for event in events {
                let stamped = try #require(event.grammar)
                #expect(try GuidedShapes.parse(stamped) == derived)
            }
        }

        @Test("respond(to:matching:) routes and parses into a dynamic JSONValue")
        @MainActor
        func respondMatchingReturnsJSONValue() async throws {
            let dir = Self.makeTempDir()
            defer { try? FileManager.default.removeItem(at: dir) }

            let recorder = InMemoryRecorder()
            let router = Self.makeRouter(
                recorder: recorder,
                cacheDir: dir,
                canned: "{\"name\":\"ok\"}"
            )
            let profile = try await router.resolve(Self.profile, reporting: ResolutionProgress())

            let value = try await profile.standard.respond(to: "hi", matching: Self.objectSchema)
            #expect(value == .object(["name": .string("ok")]))

            let events = await recorder.events
            #expect(events.map(\.kind) == [.prompt, .response])
            #expect(events.allSatisfy { $0.grammar == Self.objectSchema })
        }

        @Test("respond(to:matching:) with an over-spec schema throws a typed GuidedGenerationError")
        @MainActor
        func respondMatchingOverSpecSchemaThrows() async throws {
            let dir = Self.makeTempDir()
            defer { try? FileManager.default.removeItem(at: dir) }

            let router = Self.makeRouter(
                recorder: InMemoryRecorder(),
                cacheDir: dir,
                canned: "{}"
            )
            let profile = try await router.resolve(Self.profile, reporting: ResolutionProgress())

            await #expect(throws: GuidedGenerationError.self) {
                _ = try await profile.standard.respond(
                    to: "hi",
                    matching: "{\"$ref\":\"#/$defs/Y\"}"
                )
            }
        }
    }
#endif  // canImport(FoundationModels)
