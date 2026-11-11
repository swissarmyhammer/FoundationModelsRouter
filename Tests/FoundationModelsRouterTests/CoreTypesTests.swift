import Testing
import Foundation

@testable import FoundationModelsRouter

@Suite("CoreTypes")
struct CoreTypesTests {
    @Test("ProfileDefinition names no context by default, so resolution uses the model's window")
    func profileDefinitionDefaultContextIsTheModelsWindow() {
        let profile = ProfileDefinition(
            name: "coder",
            description: "coding profile",
            standard: ["org/standard"],
            flash: ["org/flash"],
            embedding: ["org/embedding"]
        )

        #expect(profile.context == nil)
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

    /// The working context of the pool-key test of the decision slot.
    private static let decisionSlotContext = 8192

    /// The JSON of a list that holds the decision slot alone.
    private static let decisionSlotJSON = #"["decision"]"#

    @Test("the decision slot encodes to the wire form \"decision\"")
    func decisionSlotEncodesToItsWireForm() throws {
        let data = try JSONEncoder().encode([ModelSlot.decision])

        #expect(String(decoding: data, as: UTF8.self) == Self.decisionSlotJSON)
    }

    @Test("the wire form \"decision\" decodes to the decision slot")
    func decisionWireFormDecodesToTheDecisionSlot() throws {
        let slots = try JSONDecoder().decode([ModelSlot].self, from: Data(Self.decisionSlotJSON.utf8))

        #expect(slots == [.decision])
    }

    @Test("the decision slot uses the LLM pool role")
    func decisionSlotPoolRoleIsLLM() {
        #expect(ModelSlot.decision.poolRole == .llm)
    }

    @Test("the pool key of the decision slot has the context of the profile")
    func decisionSlotPoolKeyHasTheProfileContext() {
        let ref: ModelRef = "org/decider"

        #expect(
            ModelSlot.decision.poolKey(of: ref, context: Self.decisionSlotContext)
                == ModelPoolKey(ref: ref, role: .llm, contextSize: Self.decisionSlotContext))
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
