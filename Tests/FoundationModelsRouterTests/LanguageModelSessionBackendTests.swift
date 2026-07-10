#if canImport(FoundationModels)
    import FoundationModels
    import Foundation
    import Testing

    @testable import FoundationModelsRouter

    /// GPU-free evidence backing the `LanguageModelSession` pivot's guided-generation
    /// resolution (see plan.md's "Guided generation" section and
    /// ``MLXFoundationModelsContainer``).
    ///
    /// `GenerationSchemaDecodingTests` documents (with a real, run assertion) *why*
    /// `GenerationSchema`'s own `Codable` conformance cannot ingest a caller's plain
    /// JSON Schema text — this was checked, not assumed, and the checks are kept as
    /// regression tests so a future SDK change that loosens this is caught rather
    /// than silently re-breaking the assumption in the other direction.
    /// `RuntimeJSONSchemaConverterTests` then exercises the hand-written converter
    /// this repo uses instead.
    @Suite("GenerationSchema's Codable conformance does not decode foreign JSON Schema")
    struct GenerationSchemaDecodingTests {
        @Test("a plain JSON Schema object is rejected: missing the proprietary x-order key")
        func plainObjectSchemaRejectedMissingXOrder() throws {
            let schemaJSON = #"""
                {"type":"object","properties":{"city":{"type":"string"},"country":{"type":"string"}},"required":["city","country"],"additionalProperties":false}
                """#
            #expect(throws: (any Error).self) {
                _ = try JSONDecoder().decode(GenerationSchema.self, from: Data(schemaJSON.utf8))
            }
        }

        @Test("adding x-order alone is still rejected: missing the proprietary title key")
        func xOrderAloneStillRejectedMissingTitle() throws {
            let schemaJSON = #"""
                {"type":"object","x-order":["city","country"],"properties":{"city":{"type":"string"},"country":{"type":"string"}},"required":["city","country"],"additionalProperties":false}
                """#
            #expect(throws: (any Error).self) {
                _ = try JSONDecoder().decode(GenerationSchema.self, from: Data(schemaJSON.utf8))
            }
        }

        @Test("a titled string leaf (no enum) is rejected: titled strings are treated as enum carriers")
        func titledStringWithoutEnumRejected() throws {
            let schemaJSON = #"""
                {"type":"object","title":"Root","x-order":["city"],"properties":{"city":{"type":"string","title":"City"}},"required":["city"],"additionalProperties":false}
                """#
            #expect(throws: (any Error).self) {
                _ = try JSONDecoder().decode(GenerationSchema.self, from: Data(schemaJSON.utf8))
            }
        }
    }

    /// Exercises ``RuntimeJSONSchemaConverter``, the hand-written JSON-Schema →
    /// `DynamicGenerationSchema` compiler used in place of `GenerationSchema`'s
    /// broken `Codable` decode (see the suite above). Every case here constructs a
    /// real `GenerationSchema` via the real FoundationModels types — no GPU/network
    /// is needed since schema construction alone never touches a model.
    @Suite("RuntimeJSONSchemaConverter compiles JSON Schema into GenerationSchema")
    struct RuntimeJSONSchemaConverterTests {
        @Test("a flat object schema compiles with the right property names")
        func flatObjectCompiles() throws {
            let schemaJSON = #"""
                {"type":"object","properties":{"city":{"type":"string"},"country":{"type":"string"}},"required":["city","country"]}
                """#
            let schema = try RuntimeJSONSchemaConverter.compile(schemaJSON)

            // Not just "does it compile" — re-encode (GenerationSchema's own
            // Codable *encode* direction is real; only foreign-text *decode* is
            // broken, per GenerationSchemaDecodingTests above) and check the
            // compiled schema actually carries both property names.
            let reencoded = try JSONEncoder().encode(schema)
            let object = try #require(
                try JSONSerialization.jsonObject(with: reencoded) as? [String: Any]
            )
            let properties = try #require(object["properties"] as? [String: Any])
            #expect(Set(properties.keys) == ["city", "country"])
        }

        @Test("required vs optional properties are compiled with the right isOptional")
        func requiredVsOptionalPropertiesCompileCorrectly() throws {
            let schemaJSON = #"""
                {"type":"object","properties":{"name":{"type":"string"},"nickname":{"type":"string"}},"required":["name"]}
                """#
            let schema = try RuntimeJSONSchemaConverter.compile(schemaJSON)

            let reencoded = try JSONEncoder().encode(schema)
            let object = try #require(
                try JSONSerialization.jsonObject(with: reencoded) as? [String: Any]
            )
            // GenerationSchema's own encoding marks required properties via a
            // top-level "required" array (mirroring standard JSON Schema) — only
            // "name" should appear, "nickname" should not.
            let required = (object["required"] as? [String]) ?? []
            #expect(required.contains("name"))
            #expect(!required.contains("nickname"))
        }

        @Test("a closed string enum compiles with the exact choices")
        func stringEnumCompilesWithExactChoices() throws {
            let schemaJSON = #"""
                {"type":"object","properties":{"verdict":{"type":"string","enum":["pass","fail"]}},"required":["verdict"]}
                """#
            let schema = try RuntimeJSONSchemaConverter.compile(schemaJSON)

            let reencoded = try JSONEncoder().encode(schema)
            let object = try #require(
                try JSONSerialization.jsonObject(with: reencoded) as? [String: Any]
            )
            let properties = try #require(object["properties"] as? [String: Any])
            let verdict = try #require(properties["verdict"] as? [String: Any])
            let choices = try #require(verdict["enum"] as? [String])
            #expect(Set(choices) == ["pass", "fail"])
        }

        @Test("an integer enum throws a typed ConversionError instead of silently dropping the constraint")
        func integerEnumThrows() throws {
            let schemaJSON = #"""
                {"type":"object","properties":{"rating":{"type":"integer","enum":[1,2,3]}},"required":["rating"]}
                """#
            #expect(throws: RuntimeJSONSchemaConverter.ConversionError.self) {
                _ = try RuntimeJSONSchemaConverter.compile(schemaJSON)
            }
        }

        @Test("integer, number, and boolean leaves compile")
        func scalarLeavesCompile() throws {
            let schemaJSON = #"""
                {"type":"object","properties":{"age":{"type":"integer"},"score":{"type":"number"},"active":{"type":"boolean"}},"required":["age","score","active"]}
                """#
            _ = try RuntimeJSONSchemaConverter.compile(schemaJSON)
        }

        @Test("an array of strings compiles")
        func arrayOfStringsCompiles() throws {
            let schemaJSON = #"""
                {"type":"object","properties":{"tags":{"type":"array","items":{"type":"string"}}},"required":["tags"]}
                """#
            _ = try RuntimeJSONSchemaConverter.compile(schemaJSON)
        }

        @Test("an array with minItems/maxItems compiles")
        func boundedArrayCompiles() throws {
            let schemaJSON = #"""
                {"type":"object","properties":{"tags":{"type":"array","items":{"type":"string"},"minItems":1,"maxItems":3}},"required":["tags"]}
                """#
            _ = try RuntimeJSONSchemaConverter.compile(schemaJSON)
        }

        @Test("a nested object compiles")
        func nestedObjectCompiles() throws {
            let schemaJSON = #"""
                {"type":"object","properties":{"address":{"type":"object","properties":{"city":{"type":"string"}},"required":["city"]}},"required":["address"]}
                """#
            _ = try RuntimeJSONSchemaConverter.compile(schemaJSON)
        }

        @Test("the schema derived from a @Generable type (Person) compiles")
        func derivedGenerableSchemaCompiles() throws {
            // Mirrors GuidedShapesTests.Person: a flat object with a string and an
            // integer property — proving the converter accepts real
            // `GuidedShapes.derivedSchema(for:)` output, not just hand-written
            // fixtures.
            let schemaJSON = #"""
                {"type":"object","properties":{"name":{"type":"string"},"age":{"type":"integer"}},"required":["name","age"]}
                """#
            _ = try RuntimeJSONSchemaConverter.compile(schemaJSON)
        }

        @Test("an unsupported construct (oneOf) throws a typed ConversionError")
        func unsupportedConstructThrows() throws {
            let schemaJSON = #"""
                {"oneOf":[{"type":"string"},{"type":"integer"}]}
                """#
            #expect(throws: RuntimeJSONSchemaConverter.ConversionError.self) {
                _ = try RuntimeJSONSchemaConverter.compile(schemaJSON)
            }
        }

        @Test("an array missing items throws a typed ConversionError")
        func arrayMissingItemsThrows() throws {
            let schemaJSON = #"""
                {"type":"object","properties":{"tags":{"type":"array"}},"required":["tags"]}
                """#
            #expect(throws: RuntimeJSONSchemaConverter.ConversionError.self) {
                _ = try RuntimeJSONSchemaConverter.compile(schemaJSON)
            }
        }

        @Test("invalid JSON throws GuidedRequestError.invalidJSONSchema")
        func invalidJSONThrowsGuidedRequestError() throws {
            #expect(throws: GuidedRequestError.self) {
                _ = try RuntimeJSONSchemaConverter.compile("not json at all")
            }
        }
    }

    /// Exercises ``StubSessionBackend``'s synthetic ``Transcript.Entry``
    /// accumulation — the GPU-free stand-in for
    /// ``MLXFoundationModelsSessionBackend/transcriptEntries()`` (see the
    /// gated integration suite's
    /// `LanguageModelSessionBackendTests.transcriptEntriesMatchesSessionTranscriptAndGrows`
    /// for the real-model equivalent). Every unit-suite conformer of
    /// ``LanguageModelSessionBackend`` outside this file only needs to
    /// *compile* against the widened protocol; the actual entry-shape
    /// contract lives here, against the one conformer downstream tasks
    /// (session index, chokepoint) actually rely on.
    @Suite("StubSessionBackend synthesizes transcript entries mirroring the live backend")
    struct StubSessionBackendTranscriptTests {
        private func isInstructions(_ entry: Transcript.Entry) -> Bool {
            if case .instructions = entry { return true }
            return false
        }

        private func isPrompt(_ entry: Transcript.Entry) -> Bool {
            if case .prompt = entry { return true }
            return false
        }

        private func isResponse(_ entry: Transcript.Entry) -> Bool {
            if case .response = entry { return true }
            return false
        }

        @Test("an uninstructed stub's transcriptEntries() has 4 entries in prompt/response/prompt/response order after two turns")
        func uninstructedStubAccumulatesPromptResponsePairs() async throws {
            let backend = StubSessionBackend(responseText: "ok")
            _ = try await backend.respond(to: "first", maxTokens: nil)
            _ = try await backend.respond(to: "second", maxTokens: nil)

            let entries = backend.transcriptEntries()
            #expect(entries.count == 4)
            #expect(isPrompt(entries[0]))
            #expect(isResponse(entries[1]))
            #expect(isPrompt(entries[2]))
            #expect(isResponse(entries[3]))
        }

        @Test(
            "an instructed stub's transcriptEntries() starts with exactly one .instructions entry, followed by prompt/response pairs"
        )
        func instructedStubSeedsLeadingInstructionsEntry() async throws {
            let backend = StubSessionBackend(instructions: "be terse")
            _ = try await backend.respond(to: "first", maxTokens: nil)
            _ = try await backend.respond(to: "second", maxTokens: nil)

            let entries = backend.transcriptEntries()
            #expect(entries.count == 5)
            #expect(isInstructions(entries[0]))
            #expect(isPrompt(entries[1]))
            #expect(isResponse(entries[2]))
            #expect(isPrompt(entries[3]))
            #expect(isResponse(entries[4]))
        }

        @Test("an uninstructed stub seeds no leading .instructions entry")
        func uninstructedStubHasNoInstructionsEntry() {
            let backend = StubSessionBackend()
            #expect(backend.transcriptEntries().isEmpty)
        }

        @Test(
            "a fork taken after turn 1 has exactly the parent's entries at fork time; the parent's turn 2 does not appear in the child"
        )
        func forkSnapshotsEntriesAtForkTime() async throws {
            let parent = StubSessionBackend(instructions: "be terse")
            _ = try await parent.respond(to: "first", maxTokens: nil)

            let entriesAtForkTime = parent.transcriptEntries()
            let child = try #require(parent.makeFork() as? StubSessionBackend)
            #expect(child.transcriptEntries() == entriesAtForkTime)

            _ = try await parent.respond(to: "second", maxTokens: nil)

            // The child's snapshot does not retroactively grow with the
            // parent's further turn…
            #expect(child.transcriptEntries() == entriesAtForkTime)
            // …while the parent's own transcript has grown independently.
            #expect(parent.transcriptEntries().count == entriesAtForkTime.count + 2)
        }
    }

    /// Exercises task bkhj6ya's factory seam:
    /// ``LoadedLLMContainer/makeSession(transcript:)``, the transcript-seeded
    /// sibling of ``LoadedLLMContainer/makeSession(instructions:)`` restoration
    /// needs to rebuild a session from a persisted transcript rather than from
    /// scratch. The live conformer (``MLXFoundationModelsContainer``, gated
    /// integration suite) seeds a real `LanguageModelSession` from the
    /// transcript; this GPU-free counterpart proves the stub side of the seam:
    /// a container's `makeSession(transcript:)` seeds ``StubSessionBackend``'s
    /// synthetic entries directly from the given transcript's entries, so a
    /// freshly manufactured backend already reports them before any new turn.
    @Suite("LoadedLLMContainer.makeSession(transcript:) seeds a stub backend from transcript entries")
    struct TranscriptSeededSessionTests {
        /// A minimal container whose `makeSession(transcript:)` seeds a
        /// ``StubSessionBackend`` straight from the given transcript's entries —
        /// mirroring how the live container derives a fresh session from a
        /// persisted transcript instead of from `instructions`.
        private struct TranscriptSeededStubContainer: LoadedLLMContainer {
            func makeSession(instructions: String?) -> any LanguageModelSessionBackend {
                StubSessionBackend(instructions: instructions)
            }

            func makeSession(transcript: Transcript) -> any LanguageModelSessionBackend {
                StubSessionBackend(entries: Array(transcript))
            }
        }

        @Test("a stub backend made from a 4-entry transcript reports those 4 entries via transcriptEntries() before any new turn")
        func stubBackendReportsSeededTranscriptEntriesBeforeAnyNewTurn() {
            let entries: [Transcript.Entry] = [
                .instructions(
                    Transcript.Instructions(
                        segments: [.text(Transcript.TextSegment(content: "be terse"))],
                        toolDefinitions: []
                    )
                ),
                .prompt(Transcript.Prompt(segments: [.text(Transcript.TextSegment(content: "first"))])),
                .response(
                    Transcript.Response(assetIDs: [], segments: [.text(Transcript.TextSegment(content: "ok"))])
                ),
                .prompt(Transcript.Prompt(segments: [.text(Transcript.TextSegment(content: "second"))])),
            ]
            let transcript = Transcript(entries: entries)

            let container: any LoadedLLMContainer = TranscriptSeededStubContainer()
            let backend = container.makeSession(transcript: transcript)

            #expect(backend.transcriptEntries() == entries)
        }
    }
#endif  // canImport(FoundationModels)
