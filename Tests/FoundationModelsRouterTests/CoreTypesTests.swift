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

    /// The candidates that the tests of the slot defaults set in a profile.
    private static let explicitCandidates: [ModelRef] = ["org/explicit-a", "org/explicit-b"]

    /// The JSON of ``explicitCandidates``.
    private static let explicitCandidatesJSON = #"["org/explicit-a", "org/explicit-b"]"#

    /// The description that the tests of the description default set in a profile.
    private static let explicitDescription = "coding profile"

    /// The profile that a document with only the `name` key gives: each other
    /// key has its default.
    private static let defaultedProfile = ProfileDefinition(
        name: "coder",
        description: ProfileDefinition.defaultDescription,
        standard: ProfileDefinition.defaultStandardCandidates,
        flash: ProfileDefinition.defaultStandardCandidates,
        embedding: ProfileDefinition.defaultEmbeddingCandidates
    )

    /// Decodes a profile from a JSON document.
    ///
    /// - Parameter json: The JSON document.
    /// - Returns: The profile.
    /// - Throws: `DecodingError` when the document is not a profile.
    private static func decodeProfile(_ json: String) throws -> ProfileDefinition {
        try JSONDecoder().decode(ProfileDefinition.self, from: Data(json.utf8))
    }

    /// Encodes a profile to JSON, and decodes it again.
    ///
    /// - Parameter profile: The profile.
    /// - Returns: The decoded profile.
    /// - Throws: What the encoder or the decoder throws.
    private static func roundTrip(_ profile: ProfileDefinition) throws -> ProfileDefinition {
        try JSONDecoder().decode(ProfileDefinition.self, from: JSONEncoder().encode(profile))
    }

    /// Expects that two profiles have the same value in each key.
    ///
    /// - Parameters:
    ///   - actual: The profile under test.
    ///   - expected: The profile that `actual` must equal.
    private static func expectSameProfile(_ actual: ProfileDefinition, _ expected: ProfileDefinition) {
        #expect(actual.name == expected.name)
        #expect(actual.description == expected.description)
        #expect(actual.standard == expected.standard)
        #expect(actual.flash == expected.flash)
        #expect(actual.embedding == expected.embedding)
        #expect(actual.decision == expected.decision)
        #expect(actual.context == expected.context)
        #expect(actual.decisionContext == expected.decisionContext)
        #expect(actual.kvCacheQuantization == expected.kvCacheQuantization)
    }

    @Test("ProfileDefinition's default standard candidates are Qwen3.5 9B 4-bit with its MTP drafter")
    func profileDefinitionDefaultStandardCandidatesAreQwen35NineB() {
        #expect(
            ProfileDefinition.defaultStandardCandidates == [
                ModelRef(repo: "mlx-community/Qwen3.5-9B-4bit", drafter: "mlx-community/Qwen3.5-9B-MTP-4bit")
            ])
    }

    @Test("ProfileDefinition's default embedding candidates are the Core ML embeddinggemma model")
    func profileDefinitionDefaultEmbeddingCandidatesAreEmbeddingGemma() {
        #expect(ProfileDefinition.defaultEmbeddingCandidates == ["erjigit17/embeddinggemma-300m-ane-coreml"])
    }

    @Test("ProfileDefinition's default description is empty")
    func profileDefinitionDefaultDescriptionIsEmpty() {
        #expect(ProfileDefinition.defaultDescription.isEmpty)
    }

    @Test("ProfileDefinition's initializer with only a name gives each default")
    func profileDefinitionInitializerWithOnlyANameGivesTheDefaults() {
        Self.expectSameProfile(ProfileDefinition(name: "coder"), Self.defaultedProfile)
    }

    @Test("ProfileDefinition's initializer gives the standard candidates to flash when flash is nil")
    func profileDefinitionInitializerGivesStandardToANilFlash() {
        let profile = ProfileDefinition(name: "coder", standard: Self.explicitCandidates, flash: nil)

        #expect(profile.flash == Self.explicitCandidates)
    }

    @Test("ProfileDefinition decodes JSON with only the name key to each default")
    func profileDefinitionDecodesJSONWithOnlyANameToTheDefaults() throws {
        let decoded = try Self.decodeProfile(#"{"name": "coder"}"#)

        Self.expectSameProfile(decoded, Self.defaultedProfile)
    }

    @Test("ProfileDefinition decodes the description key alone, and each other key to its default")
    func profileDefinitionDecodesTheDescriptionKeyAlone() throws {
        let decoded = try Self.decodeProfile(#"{"name": "coder", "description": "\#(Self.explicitDescription)"}"#)
        var expected = Self.defaultedProfile
        expected.description = Self.explicitDescription

        Self.expectSameProfile(decoded, expected)
    }

    @Test("ProfileDefinition decodes the standard key alone, and gives its list to flash too")
    func profileDefinitionDecodesTheStandardKeyAlone() throws {
        let decoded = try Self.decodeProfile(
            #"{"name": "coder", "standard": \#(Self.explicitCandidatesJSON)}"#)
        var expected = Self.defaultedProfile
        expected.standard = Self.explicitCandidates
        expected.flash = Self.explicitCandidates

        Self.expectSameProfile(decoded, expected)
    }

    @Test("ProfileDefinition decodes the flash key alone, and each other key to its default")
    func profileDefinitionDecodesTheFlashKeyAlone() throws {
        let decoded = try Self.decodeProfile(
            #"{"name": "coder", "flash": \#(Self.explicitCandidatesJSON)}"#)
        var expected = Self.defaultedProfile
        expected.flash = Self.explicitCandidates

        Self.expectSameProfile(decoded, expected)
    }

    @Test("ProfileDefinition decodes the embedding key alone, and each other key to its default")
    func profileDefinitionDecodesTheEmbeddingKeyAlone() throws {
        let decoded = try Self.decodeProfile(
            #"{"name": "coder", "embedding": \#(Self.explicitCandidatesJSON)}"#)
        var expected = Self.defaultedProfile
        expected.embedding = Self.explicitCandidates

        Self.expectSameProfile(decoded, expected)
    }

    @Test("ProfileDefinition does not decode JSON with no name key")
    func profileDefinitionDoesNotDecodeJSONWithNoName() {
        #expect(throws: DecodingError.self) {
            try Self.decodeProfile(#"{"description": "coding profile"}"#)
        }
    }

    @Test(
        "ProfileDefinition Codable round-trips each key, for an fp16 and an 8-bit KV cache",
        arguments: [nil, KVCacheQuantization.bits8])
    func profileDefinitionCodableRoundTripsEachKey(kvCacheQuantization: KVCacheQuantization?) throws {
        let profile = ProfileDefinition(
            name: "coder",
            description: Self.explicitDescription,
            standard: Self.explicitCandidates,
            flash: ["org/flash"],
            embedding: ["org/embedding"],
            decision: ["org/decider"],
            context: 16384,
            decisionContext: 2_048,
            kvCacheQuantization: kvCacheQuantization
        )

        Self.expectSameProfile(try Self.roundTrip(profile), profile)
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
            ModelSlot.decision.poolKey(of: ref, context: Self.decisionSlotContext, kvCache: nil)
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
