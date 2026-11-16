import Foundation
import Testing

@testable import FoundationModelsRouter

/// Tests for the model of each slot of an authored profile
/// (``ProfileDefinition/slotModel(for:)``) and for the models that a slot can
/// take (``ProfileDefinition/choices(for:)`` and ``ModelChoices``). No test
/// reads the network or loads a model.
@Suite("Model choices of each slot")
struct ModelChoicesTests {
    /// A GGUF reference that names its file, at a pinned revision.
    static let ggufFileRef: ModelRef = "org/decider-GGUF/decider-Q4_K_M.gguf@abc123"

    /// A GGUF reference that names a quantization folder and not a file.
    static let ggufFolderRef: ModelRef = "org/model-GGUF/Q4_K_M"

    /// A local reference to a GGUF file on the disk.
    static let localGGUFRef: ModelRef = "/models/local-Q8_0.gguf"

    /// An MLX reference with an MTP drafter.
    static let drafterRef = ModelRef(repo: "org/target-4bit", drafter: "org/target-MTP-4bit")

    /// The builtin default model in its text form: the same model as the
    /// first builtin generation choice, with no drafter.
    static let defaultModelTextRef: ModelRef = "mlx-community/Qwen3.8-27B-4bit"

    /// The builtin default model with a drafter of its own, which is not the
    /// builtin drafter.
    static let defaultModelOwnDrafterRef = ModelRef(
        repo: "mlx-community/Qwen3.8-27B-4bit",
        drafter: "org/custom-MTP-4bit"
    )

    /// Makes a profile with the given candidates of the `standard` slot.
    ///
    /// - Parameter standard: The candidates of the `standard` slot.
    /// - Returns: The profile.
    static func makeProfile(standard: [ModelRef]) -> ProfileDefinition {
        ProfileDefinition(
            name: "coder",
            description: "coding profile",
            standard: standard,
            flash: ["org/flash"],
            embedding: ["org/embedding"]
        )
    }

    // MARK: - The model of a slot

    @Test("The model of a slot is the first candidate of the slot")
    func slotModelIsTheFirstCandidate() {
        let profile = Self.makeProfile(standard: [Self.drafterRef, "org/second"])

        #expect(profile.slotModel(for: .standard)?.ref == Self.drafterRef)
    }

    @Test("The model of a slot gives the drafter of its reference")
    func slotModelGivesTheDrafter() {
        let profile = Self.makeProfile(standard: [Self.drafterRef])

        #expect(profile.slotModel(for: .standard)?.drafter == "org/target-MTP-4bit")
    }

    @Test("A slot with no candidate has no model")
    func emptySlotHasNoModel() {
        let profile = Self.makeProfile(standard: [])

        #expect(profile.slotModel(for: .standard) == nil)
    }

    @Test("The model of the decision slot is the first default decision candidate")
    func decisionSlotModelIsTheDefaultCandidate() {
        let profile = Self.makeProfile(standard: ["org/standard"])

        #expect(profile.slotModel(for: .decision)?.ref == ProfileDefinition.defaultDecisionCandidates.first)
    }

    @Test("A reference that names a GGUF file gives that file")
    func ggufFileOfAFileReference() {
        #expect(SlotModel(slot: .decision, ref: Self.ggufFileRef).ggufFile == "decider-Q4_K_M.gguf")
    }

    @Test("A reference that names a quantization folder gives no GGUF file")
    func ggufFileOfAFolderReference() {
        #expect(SlotModel(slot: .standard, ref: Self.ggufFolderRef).ggufFile == nil)
    }

    @Test("An MLX reference gives no GGUF file")
    func ggufFileOfAnMLXReference() {
        #expect(SlotModel(slot: .standard, ref: Self.drafterRef).ggufFile == nil)
    }

    @Test("A local reference to a GGUF file gives the name of the file")
    func ggufFileOfALocalReference() {
        #expect(SlotModel(slot: .standard, ref: Self.localGGUFRef).ggufFile == "local-Q8_0.gguf")
    }

    // MARK: - The choices of a slot

    @Test("The choices of a slot start with the candidates of the profile")
    func choicesStartWithTheProfileCandidates() {
        let profile = Self.makeProfile(standard: ["org/custom-a", "org/custom-b"])

        #expect(profile.choices(for: .standard).prefix(2) == ["org/custom-a", "org/custom-b"])
    }

    @Test("The choices of a slot end with the builtin choices of the slot")
    func choicesEndWithTheBuiltinChoices() {
        let profile = Self.makeProfile(standard: ["org/custom-a"])

        #expect(Array(profile.choices(for: .standard).dropFirst()) == ModelChoices.builtin(for: .standard))
    }

    @Test("A candidate that is also a builtin choice is a choice one time")
    func choicesHaveNoCopy() {
        let builtin = ModelChoices.builtin(for: .standard)
        let profile = Self.makeProfile(standard: builtin.reversed())

        #expect(profile.choices(for: .standard) == builtin.reversed())
    }

    @Test("A candidate in text form of a builtin model is one choice, with the builtin drafter")
    func textFormCandidateTakesTheBuiltinDrafter() {
        let profile = Self.makeProfile(standard: [Self.defaultModelTextRef])

        #expect(profile.choices(for: .standard) == ModelChoices.builtin(for: .standard))
    }

    @Test("A candidate with a drafter of its own keeps that drafter")
    func candidateKeepsItsOwnDrafter() {
        let profile = Self.makeProfile(standard: [Self.defaultModelOwnDrafterRef])

        #expect(profile.choices(for: .standard).first?.drafter == "org/custom-MTP-4bit")
    }

    @Test("A candidate with a drafter of its own is one choice for its model")
    func candidateWithItsOwnDrafterIsOneChoice() {
        let profile = Self.makeProfile(standard: [Self.defaultModelOwnDrafterRef])

        #expect(profile.choices(for: .standard).count == ModelChoices.builtin(for: .standard).count)
    }

    @Test("The other choices keep their order when a candidate takes the builtin drafter")
    func otherChoicesKeepTheirOrder() {
        let profile = Self.makeProfile(standard: ["org/custom-a", Self.defaultModelTextRef])

        #expect(profile.choices(for: .standard) == ["org/custom-a"] + ModelChoices.builtin(for: .standard))
    }

    @Test("The choices of the decision slot of a default profile are the default decision candidates")
    func decisionChoicesOfADefaultProfile() {
        let profile = Self.makeProfile(standard: ["org/standard"])

        #expect(profile.choices(for: .decision) == ProfileDefinition.defaultDecisionCandidates)
    }

    // MARK: - The builtin choices

    @Test("The builtin standard choices hold the 27B model with its MTP drafter")
    func builtinStandardHoldsTheDefaultModel() {
        let expected = ModelRef(repo: "mlx-community/Qwen3.8-27B-4bit", drafter: "mlx-community/Qwen3.8-27B-MTP-4bit")

        #expect(ModelChoices.builtin(for: .standard).contains(expected))
    }

    @Test("The builtin standard choices hold the smallest Qwen3 4-bit model")
    func builtinStandardHoldsASmallModel() {
        #expect(ModelChoices.builtin(for: .standard).contains("mlx-community/Qwen3-4B-4bit"))
    }

    @Test("The flash slot takes the same builtin choices as the standard slot")
    func builtinFlashIsTheStandardList() {
        #expect(ModelChoices.builtin(for: .flash) == ModelChoices.builtin(for: .standard))
    }

    @Test("The builtin embedding choices hold the Core ML embedding model")
    func builtinEmbeddingHoldsTheCoreMLModel() {
        #expect(ModelChoices.builtin(for: .embedding).contains("erjigit17/embeddinggemma-300m-ane-coreml"))
    }

    @Test("The builtin decision choices are the default decision candidates")
    func builtinDecisionIsTheDefaultCandidates() {
        #expect(ModelChoices.builtin(for: .decision) == ProfileDefinition.defaultDecisionCandidates)
    }
}
