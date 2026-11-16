import Foundation
import Testing

@testable import FoundationModelsRouter

/// Tests for the builtin named profiles of the router (``ModelProfiles``).
/// No test reads the network or loads a model.
@Suite("Builtin model profiles")
struct ModelProfilesTests {
    /// The names of the builtin profiles, from the largest to the smallest.
    static let expectedNames = ["large", "medium", "small", "tiny"]

    /// The `standard` candidates of the builtin profiles, in the order of
    /// ``expectedNames``.
    static let expectedStandard: [[ModelRef]] = [
        [ModelRef(repo: "mlx-community/Qwen3.8-27B-4bit", drafter: "mlx-community/Qwen3.8-27B-MTP-4bit")],
        ["mlx-community/Qwen3-14B-4bit"],
        ["mlx-community/Qwen3-8B-4bit"],
        ["mlx-community/Qwen3-4B-4bit"],
    ]

    /// The `embedding` candidates of each builtin profile.
    static let expectedEmbedding: [ModelRef] = ["erjigit17/embeddinggemma-300m-ane-coreml"]

    /// The text that separates two sentences.
    static let sentenceSeparator = ". "

    // MARK: - The list

    @Test("The builtin list has the four profiles from the largest to the smallest")
    func builtinHasTheFourProfilesInOrder() {
        #expect(ModelProfiles.builtin.map(\.name) == Self.expectedNames)
    }

    @Test("The names of the builtin profiles are unique")
    func builtinNamesAreUnique() {
        #expect(Set(ModelProfiles.builtin.map(\.name)).count == ModelProfiles.builtin.count)
    }

    // MARK: - The slots

    @Test("Each builtin profile has its model in the standard slot")
    func standardOfEachProfileIsItsModel() {
        #expect(ModelProfiles.builtin.map(\.standard) == Self.expectedStandard)
    }

    @Test("The flash slot of each builtin profile names the model of the standard slot")
    func flashEqualsStandard() {
        #expect(ModelProfiles.builtin.map(\.flash) == ModelProfiles.builtin.map(\.standard))
    }

    @Test("The embedding slot of each builtin profile names the Core ML embedding model")
    func embeddingIsTheCoreMLModel() {
        #expect(ModelProfiles.builtin.map(\.embedding) == Array(repeating: Self.expectedEmbedding, count: Self.expectedNames.count))
    }

    @Test("The decision slot of each builtin profile has the default decision candidates")
    func decisionIsTheDefaultCandidates() {
        #expect(
            ModelProfiles.builtin.map(\.decision)
                == Array(repeating: ProfileDefinition.defaultDecisionCandidates, count: Self.expectedNames.count))
    }

    @Test("Each slot of each builtin profile has one candidate")
    func eachSlotHasOneCandidate() {
        let counts = ModelProfiles.builtin.map { profile in
            [profile.standard, profile.flash, profile.embedding, profile.decision].map(\.count)
        }

        #expect(counts == Array(repeating: [1, 1, 1, 1], count: Self.expectedNames.count))
    }

    @Test("The drafter of the large profile is the MTP model")
    func largeDrafterIsTheMTPModel() {
        #expect(ModelProfiles.named("large")?.standard.first?.drafter == "mlx-community/Qwen3.8-27B-MTP-4bit")
    }

    // MARK: - The context

    @Test("The decision context of each builtin profile is the default decision context")
    func decisionContextIsTheDefault() {
        #expect(
            ModelProfiles.builtin.map(\.decisionContext)
                == Array(repeating: ProfileDefinition.defaultDecisionContext, count: Self.expectedNames.count))
    }

    @Test("No builtin profile sets a context override")
    func contextIsNil() {
        #expect(ModelProfiles.builtin.allSatisfy { $0.context == nil })
    }

    // MARK: - The descriptions

    @Test("Each builtin profile has a description that is not empty")
    func descriptionIsNotEmpty() {
        #expect(ModelProfiles.builtin.allSatisfy { !$0.description.isEmpty })
    }

    @Test("Each description of a builtin profile is one sentence")
    func descriptionIsOneSentence() {
        #expect(
            ModelProfiles.builtin.allSatisfy {
                $0.description.hasSuffix(".") && !$0.description.contains(Self.sentenceSeparator)
            })
    }

    // MARK: - The lookup by name

    @Test("named(_:) finds each builtin profile by its name")
    func namedFindsEachProfile() {
        #expect(Self.expectedNames.map { ModelProfiles.named($0)?.name } == Self.expectedNames)
    }

    @Test("named(_:) gives nil for an unknown name")
    func namedGivesNilForAnUnknownName() {
        #expect(ModelProfiles.named("huge") == nil)
    }

    @Test("The default name is large")
    func defaultNameIsLarge() {
        #expect(ModelProfiles.defaultName == "large")
    }

    @Test("named(_:) finds the profile of the default name")
    func namedFindsTheDefaultProfile() {
        #expect(ModelProfiles.named(ModelProfiles.defaultName) != nil)
    }
}
