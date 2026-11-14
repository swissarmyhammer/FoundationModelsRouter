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

    /// The decision model that a profile with no `decision` key gets: the
    /// h2o-lightning-4b GGUF, quantized to `Q4_K_M`, at the pinned revision.
    private static let defaultDeciderRef = ModelRef(
        repo: "h2oai/h2o-lightning-4b-gguf", path: "h2o-lightning-4b-Q4_K_M.gguf",
        revision: "61f8d8b7a8c2d84426d0d143ca187f65d235934b")

    /// A profile JSON document with one candidate for each slot of the trio,
    /// and no `decision` key.
    private static let jsonWithoutDecision = """
        {
            "name": "coding",
            "description": "test profile",
            "standard": ["org/std-a"],
            "flash": ["org/flash-a"],
            "embedding": ["org/emb-a"],
            "context": \(ScriptedSessionContext.tokens)
        }
        """

    /// A metadata source that gives the canned metadata of the fixtures for
    /// each repo, but a GGUF repository with a supported decision type for
    /// the repo of ``deciderRef``.
    private static var ggufDeciderSource: FileServingMetadataSource {
        ggufDecisionSource(serving: deciderRef.repo, fileName: ggufFileName)
    }

    /// A metadata source that gives the canned metadata of the fixtures for
    /// each repo, but a GGUF repository with a supported decision type for
    /// `repo`.
    ///
    /// - Parameters:
    ///   - repo: The repository of the GGUF decision model.
    ///   - fileName: The path of the model file in `repo`.
    /// - Returns: The source.
    private static func ggufDecisionSource(serving repo: String, fileName: String) -> FileServingMetadataSource {
        let tree = HubTreeListing.json([.lfsFile(fileName, size: ggufFileBytes)])
        return FileServingMetadataSource(
            rawByRepo: [repo: RawRepoMetadata(configJSON: nil, treeJSON: tree)],
            defaultRaw: RouterTestFixtures.rawMetadata,
            files: ["\(repo)/\(fileName)": GGUFHeaderFixtures.decisionBytes(decisionType: GGUFHeaderFixtures.supportedDecisionType)])
    }

    /// Resolves `definition` over `source` and a live container of a model
    /// with native decision code, and asks the decision slot ``question``.
    ///
    /// - Parameters:
    ///   - definition: The profile.
    ///   - source: The metadata source.
    ///   - ref: The ref of the live container.
    /// - Returns: The probability that the decision slot gives.
    /// - Throws: What the resolve or the decision throws.
    @MainActor
    private static func nativeProbability(
        resolving definition: ProfileDefinition, over source: FileServingMetadataSource, ref: ModelRef
    ) async throws -> Double {
        let cacheDir = RouterTestFixtures.makeTempDir(prefix: tempDirPrefix)
        defer { try? FileManager.default.removeItem(at: cacheDir) }
        let container = LiveLLMContainer(
            model: DecisionsStubLanguageModel(type: GGUFHeaderFixtures.supportedDecisionType), ref: ref,
            contextWindow: liveContextWindow, tokenCounter: CharacterTokenCounter())
        let router = Router(
            cacheDir: cacheDir, probe: RouterTestFixtures.stubProbe, metadataSource: source,
            loader: StubModelLoader(container: container, dimension: RouterTestFixtures.stubDimension),
            pool: ModelPool())
        let profile = try await router.resolve(profile: definition, reporting: ResolutionProgress())
        return try await profile.decision.makeSession(state: state).probability(of: question)
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
        var definition = RouterTestFixtures.profile()
        definition.decision = [Self.deciderRef]

        let probability = try await Self.nativeProbability(
            resolving: definition, over: Self.ggufDeciderSource, ref: Self.deciderRef)

        #expect(probability == DecisionsStubLanguageModel.trueProbability)
    }

    @Test("a profile with no decision key answers with the native decision code of h2o-lightning-4b")
    @MainActor
    func profileWithNoDecisionKeyAnswersNatively() async throws {
        let definition = try JSONDecoder().decode(ProfileDefinition.self, from: Data(Self.jsonWithoutDecision.utf8))
        let source = Self.ggufDecisionSource(
            serving: Self.defaultDeciderRef.repo, fileName: try #require(Self.defaultDeciderRef.path))

        let probability = try await Self.nativeProbability(
            resolving: definition, over: source, ref: Self.defaultDeciderRef)

        #expect(probability == DecisionsStubLanguageModel.trueProbability)
    }
}
