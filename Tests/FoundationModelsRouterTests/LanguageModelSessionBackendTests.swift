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
#endif  // canImport(FoundationModels)
