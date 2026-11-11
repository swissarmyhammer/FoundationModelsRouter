import Foundation
import Testing

@testable import FoundationModelsRouter

/// Tests for the `decision` candidate list of ``ProfileDefinition``.
@Suite("ProfileDefinition decision candidates")
struct ProfileDefinitionDecisionTests {
    /// The decision candidates that the explicit-list tests give.
    static let explicitDecision: [ModelRef] = ["org/decider-a", "org/decider-b"]

    /// A profile JSON document with no `decision` key.
    static let jsonWithoutDecision = """
        {
            "name": "coder",
            "description": "coding profile",
            "standard": ["org/standard"],
            "flash": ["org/flash"],
            "embedding": ["org/embedding"]
        }
        """

    /// A profile JSON document with an empty `decision` list.
    static let jsonWithEmptyDecision = """
        {
            "name": "coder",
            "description": "coding profile",
            "standard": ["org/standard"],
            "flash": ["org/flash"],
            "embedding": ["org/embedding"],
            "decision": []
        }
        """

    /// Makes a profile with the given decision candidates.
    static func makeProfile(decision: [ModelRef]) -> ProfileDefinition {
        ProfileDefinition(
            name: "coder",
            description: "coding profile",
            standard: ["org/standard"],
            flash: ["org/flash"],
            embedding: ["org/embedding"],
            decision: decision
        )
    }

    /// Decodes a profile from a JSON document.
    static func decode(_ json: String) throws -> ProfileDefinition {
        try JSONDecoder().decode(ProfileDefinition.self, from: Data(json.utf8))
    }

    @Test("The initializer without a decision list gives the default decision candidates")
    func initializerDefaultsTheDecisionCandidates() {
        let profile = ProfileDefinition(
            name: "coder",
            description: "coding profile",
            standard: ["org/standard"],
            flash: ["org/flash"],
            embedding: ["org/embedding"]
        )

        #expect(profile.decision == ProfileDefinition.defaultDecisionCandidates)
    }

    @Test("The initializer keeps an explicit decision list")
    func initializerKeepsAnExplicitDecisionList() {
        let profile = Self.makeProfile(decision: Self.explicitDecision)

        #expect(profile.decision == Self.explicitDecision)
    }

    @Test("JSON with no decision key decodes to the default decision candidates")
    func decodingWithoutTheDecisionKeyGivesTheDefault() throws {
        let profile = try Self.decode(Self.jsonWithoutDecision)

        #expect(profile.decision == ProfileDefinition.defaultDecisionCandidates)
    }

    @Test("JSON with an empty decision list decodes to an empty list")
    func decodingAnEmptyDecisionListGivesAnEmptyList() throws {
        let profile = try Self.decode(Self.jsonWithEmptyDecision)

        #expect(profile.decision.isEmpty)
    }

    @Test("A JSON round trip keeps the decision list")
    func jsonRoundTripKeepsTheDecisionList() throws {
        let profile = Self.makeProfile(decision: Self.explicitDecision)

        let data = try JSONEncoder().encode(profile)
        let decoded = try JSONDecoder().decode(ProfileDefinition.self, from: data)

        #expect(decoded.decision == Self.explicitDecision)
    }

    @Test("A JSON round trip keeps an empty decision list")
    func jsonRoundTripKeepsAnEmptyDecisionList() throws {
        let profile = Self.makeProfile(decision: [])

        let data = try JSONEncoder().encode(profile)
        let decoded = try JSONDecoder().decode(ProfileDefinition.self, from: data)

        #expect(decoded.decision.isEmpty)
    }
}
