import Testing
import Foundation

@testable import FoundationModelsRouter

@Suite("CoreTypes")
struct CoreTypesTests {
    @Test("a bare string literal is a ModelRef with no revision")
    func modelRefStringLiteral() {
        let ref: ModelRef = "mlx-community/Qwen2.5-Coder-32B-Instruct-8bit"

        #expect(ref.repo == "mlx-community/Qwen2.5-Coder-32B-Instruct-8bit")
        #expect(ref.revision == nil)
    }

    @Test("a revision-pinned literal parses repo and revision")
    func modelRefRevisionPinned() {
        let ref: ModelRef = "org/repo@abc123"

        #expect(ref.repo == "org/repo")
        #expect(ref.revision == "abc123")
    }

    @Test("ModelRef Codable round-trips the repo and revision")
    func modelRefCodableRoundTrip() throws {
        let ref: ModelRef = "org/repo@abc123"

        let data = try JSONEncoder().encode(ref)
        let decoded = try JSONDecoder().decode(ModelRef.self, from: data)

        #expect(decoded == ref)
    }

    @Test("ModelRef.init(repo:revision:) sets fields and matches the string-literal form")
    func modelRefMemberwiseInitWithRevision() {
        let ref = ModelRef(repo: "org/repo", revision: "abc123")
        let literal: ModelRef = "org/repo@abc123"

        #expect(ref.repo == "org/repo")
        #expect(ref.revision == "abc123")
        #expect(ref.stringValue == "org/repo@abc123")
        #expect(ref == literal)
    }

    @Test("ModelRef.init(repo:revision:) defaults revision to nil and matches the string-literal form")
    func modelRefMemberwiseInitWithoutRevision() {
        let ref = ModelRef(repo: "org/repo")
        let literal: ModelRef = "org/repo"

        #expect(ref.repo == "org/repo")
        #expect(ref.revision == nil)
        #expect(ref.stringValue == "org/repo")
        #expect(ref == literal)
    }

    @Test("ProfileDefinition defaults context to 8192")
    func profileDefinitionDefaultContext() {
        let profile = ProfileDefinition(
            name: "coder",
            description: "coding profile",
            standard: ["org/standard"],
            flash: ["org/flash"],
            embedding: ["org/embedding"]
        )

        #expect(profile.context == 8192)
    }

    @Test("ProfileDefinition.context accepts nil to signal the context should be derived at resolve time")
    func profileDefinitionContextNilSignalsDerivation() {
        let profile = ProfileDefinition(
            name: "coder",
            description: "coding profile",
            standard: ["org/standard"],
            flash: ["org/flash"],
            embedding: ["org/embedding"],
            context: nil
        )

        #expect(profile.context == nil)
    }

    @Test("ProfileDefinition Codable round-trips an explicit context")
    func profileDefinitionCodableRoundTripExplicitContext() throws {
        let profile = ProfileDefinition(
            name: "coder",
            description: "coding profile",
            standard: ["org/standard"],
            flash: ["org/flash"],
            embedding: ["org/embedding"],
            context: 16384
        )

        let data = try JSONEncoder().encode(profile)
        let decoded = try JSONDecoder().decode(ProfileDefinition.self, from: data)

        #expect(decoded.context == 16384)
        #expect(decoded.name == profile.name)
        #expect(decoded.standard == profile.standard)
    }

    @Test("ProfileDefinition Codable round-trips a nil context by omitting the key entirely")
    func profileDefinitionCodableRoundTripNilContext() throws {
        let profile = ProfileDefinition(
            name: "coder",
            description: "coding profile",
            standard: ["org/standard"],
            flash: ["org/flash"],
            embedding: ["org/embedding"],
            context: nil
        )

        let data = try JSONEncoder().encode(profile)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        #expect(json?["context"] == nil)

        let decoded = try JSONDecoder().decode(ProfileDefinition.self, from: data)
        #expect(decoded.context == nil)
    }

    @Test("ProfileDefinition decodes legacy JSON with a numeric context field")
    func profileDefinitionDecodesLegacyJSONWithContext() throws {
        let json = Data("""
            {
                "name": "coder",
                "description": "coding profile",
                "standard": ["org/standard"],
                "flash": ["org/flash"],
                "embedding": ["org/embedding"],
                "context": 32768
            }
            """.utf8)

        let decoded = try JSONDecoder().decode(ProfileDefinition.self, from: json)

        #expect(decoded.context == 32768)
    }

    @Test("ProfileDefinition decodes JSON lacking the context key to a nil context")
    func profileDefinitionDecodesJSONMissingContextKeyToNil() throws {
        let json = Data("""
            {
                "name": "coder",
                "description": "coding profile",
                "standard": ["org/standard"],
                "flash": ["org/flash"],
                "embedding": ["org/embedding"]
            }
            """.utf8)

        let decoded = try JSONDecoder().decode(ProfileDefinition.self, from: json)

        #expect(decoded.context == nil)
    }

    @Test("JSONValue round-trips a nested object/array/scalars document")
    func jsonValueRoundTrip() throws {
        let document: JSONValue = .object([
            "name": .string("router"),
            "count": .number(42),
            "ratio": .number(0.5),
            "enabled": .bool(true),
            "missing": .null,
            "tags": .array([.string("a"), .string("b")]),
            "nested": .object([
                "inner": .array([
                    .number(1),
                    .object(["deep": .bool(false)]),
                ])
            ]),
        ])

        let data = try JSONEncoder().encode(document)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: data)

        #expect(decoded == document)
    }
}
