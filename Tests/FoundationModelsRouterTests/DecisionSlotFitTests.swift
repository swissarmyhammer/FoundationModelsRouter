import Foundation
import FoundationModelsDecision
import FoundationModelsExtras
import FoundationModelsRouterTestSupport
import Testing

@testable import FoundationModelsRouter

/// Tests of the decision pass of the joint fit through
/// ``Router/resolve(profile:reporting:)``, over a stub loader and the canned
/// metadata of the fixtures. The budget of the fixtures has room for each
/// candidate, so a decision candidate fits after the trio. A GGUF decision
/// candidate gets the GGUF header of a decision model from a stub source. No
/// test downloads or loads a model, and no test makes a network request.
@Suite("The decision pass of a resolve")
struct DecisionSlotFitTests {
    /// The prefix of the temp directory of each test.
    private static let tempDirPrefix = "DecisionSlotFitTests"

    /// The one decision candidate of the test profile. It is not a candidate
    /// of another slot.
    private static let deciderRef: ModelRef = "org/decider-fits"

    /// The decision type of the GGUF decision candidate: a type that
    /// llama.cpp decides natively.
    private static let decisionType = "h2o-lightning"

    /// The path of the model file of the GGUF decision candidate.
    private static let ggufFileName = "model.gguf"

    /// The size of the model file of the GGUF decision candidate.
    private static let ggufFileBytes: Int64 = 4_000

    /// The context window of the live container of each generation slot.
    private static let liveContextWindow = 4096

    /// The state of the decision session.
    private static let state: DecisionState = "The build is red."

    /// The yes-or-no question of the decision session.
    private static let question = "Does the state report a failure?"

    /// A metadata source that gives the canned metadata of the fixtures for
    /// each repo, but a GGUF repository with a supported decision type for
    /// the repo of ``deciderRef``.
    private static var ggufDeciderSource: FileServingMetadataSource {
        let tree = HubTreeListing.json([.lfsFile(ggufFileName, size: ggufFileBytes)])
        return FileServingMetadataSource(
            rawByRepo: [deciderRef.repo: RawRepoMetadata(configJSON: nil, treeJSON: tree)],
            defaultRaw: RouterTestFixtures.rawMetadata,
            files: ["\(deciderRef.repo)/\(ggufFileName)": GGUFHeaderFixtures.decisionBytes(decisionType: decisionType)])
    }

    @Test("a decision candidate that fits is the chosen ref of the decision handle")
    @MainActor
    func decisionCandidateThatFitsIsTheChosenRef() async throws {
        let cacheDir = RouterTestFixtures.makeTempDir(prefix: Self.tempDirPrefix)
        defer { try? FileManager.default.removeItem(at: cacheDir) }
        let router = RouterTestFixtures.makeRouter(
            cacheDir: cacheDir,
            loader: StubModelLoader(container: BasicLLMContainer(), dimension: RouterTestFixtures.stubDimension))
        var definition = RouterTestFixtures.profile()
        definition.decision = [Self.deciderRef]

        let profile = try await router.resolve(profile: definition, reporting: ResolutionProgress())

        #expect(profile.decision.chosen == Self.deciderRef)
    }

    @Test("a GGUF decision candidate with a supported decision type answers with its native decision code")
    @MainActor
    func ggufDecisionCandidateAnswersNatively() async throws {
        let cacheDir = RouterTestFixtures.makeTempDir(prefix: Self.tempDirPrefix)
        defer { try? FileManager.default.removeItem(at: cacheDir) }
        let container = LiveLLMContainer(
            model: DecisionsStubLanguageModel(type: Self.decisionType), ref: Self.deciderRef,
            contextWindow: Self.liveContextWindow, tokenCounter: CharacterTokenCounter())
        let router = Router(
            cacheDir: cacheDir, probe: RouterTestFixtures.stubProbe, metadataSource: Self.ggufDeciderSource,
            loader: StubModelLoader(container: container, dimension: RouterTestFixtures.stubDimension),
            pool: ModelPool())
        var definition = RouterTestFixtures.profile()
        definition.decision = [Self.deciderRef]
        let profile = try await router.resolve(profile: definition, reporting: ResolutionProgress())

        let probability = try await profile.decision.makeSession(state: Self.state).probability(of: Self.question)

        #expect(probability == DecisionsStubLanguageModel.trueProbability)
    }
}
