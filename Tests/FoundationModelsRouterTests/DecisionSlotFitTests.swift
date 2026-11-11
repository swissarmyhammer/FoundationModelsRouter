import Foundation
import FoundationModelsRouterTestSupport
import Testing

@testable import FoundationModelsRouter

/// Tests of the decision pass of the joint fit through
/// ``Router/resolve(profile:reporting:)``, over a stub loader and the canned
/// metadata of the fixtures. The budget of the fixtures has room for each
/// candidate, so a decision candidate fits after the trio. No test downloads
/// or loads a model, and no test makes a network request.
@Suite("The decision pass of a resolve")
struct DecisionSlotFitTests {
    /// The prefix of the temp directory of each test.
    private static let tempDirPrefix = "DecisionSlotFitTests"

    /// The one decision candidate of the test profile. It is not a candidate
    /// of another slot.
    private static let deciderRef: ModelRef = "org/decider-fits"

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
}
