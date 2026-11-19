import Foundation
import MLXFoundationModels
import Testing

@testable import FoundationModelsRouter

/// D205 (f), part 2: `MLXLanguageModel` copies the prompt cache of a session
/// for a fork, and the router maps the result of mlx-swift-lm to its own
/// ``PromptCacheCopyOutcome``.
///
/// The model of these tests is an ``UnloadableMLXModel``: no test loads it,
/// so no test needs the GPU. Each copy names sessions that no pass used, so
/// the process-wide store of mlx-swift-lm holds nothing for them. The copy of
/// a real cache is in `ForkPromptCacheCopyIntegrationTests` of the
/// integration package.
@Suite struct MLXPromptCacheCopyTests {
    /// The repository id of the model of each test.
    private static let repo = "test/mlx-prompt-cache-copy"

    /// A token count of a copy. The router does not keep it.
    private static let copiedTokenCount = 12

    /// Each result of mlx-swift-lm, with the router outcome that it maps to.
    private static let outcomeOfEachResult: [(PromptCacheCopyResult, PromptCacheCopyOutcome)] = [
        (.copied(tokenCount: copiedTokenCount), .copied),
        (.sourceNotFound, .sourceNotFound),
        (.sourceInUse, .sourceInUse),
        (.refused(.sameSession), .refused(.sameSession)),
        (.refused(.destinationHasCache), .refused(.destinationHasCache)),
        (.refused(.destinationInUse), .refused(.destinationInUse)),
        (.refused(.copyFailed), .refused(.copyFailed)),
    ]

    /// Each outcome that a copy can give.
    private static let allOutcomes: [PromptCacheCopyOutcome] = outcomeOfEachResult.map(\.1)

    /// The production change that makes this test fail: a map that loses a
    /// refusal, or that gives one result the outcome of another.
    @Test(arguments: outcomeOfEachResult)
    func eachResultMapsToItsOutcome(result: PromptCacheCopyResult, expected: PromptCacheCopyOutcome) {
        #expect(PromptCacheCopyOutcome(result) == expected)
    }

    /// The production change that makes this test fail: a log value that
    /// two outcomes share, for example one value for each refusal, so the log
    /// does not tell the reason of a refusal.
    @Test func eachOutcomeHasItsOwnLogValue() {
        #expect(Set(Self.allOutcomes.map(\.logValue)).count == Self.allOutcomes.count)
    }

    /// The production change that makes this test fail: an `MLXLanguageModel`
    /// that does not conform to ``SessionPromptCacheCopying``, so the backend
    /// gives no outcome and a fork never copies a cache.
    @Test func theBackendOfAnMLXModelCopiesThroughTheModel() async throws {
        let container = UnloadableMLXModel.liveContainer(repo: Self.repo)
        let backend = try #require(container.makeSession(instructions: nil) as? MLXFoundationModelsSessionBackend)

        let outcome = await backend.copyPromptCache(
            fromSession: ULID.generate().description, toSession: ULID.generate().description)

        #expect(outcome == .sourceNotFound)
    }

    /// The production change that makes this test fail: a conformance that
    /// maps a refusal of mlx-swift-lm to another outcome.
    @Test func aCopyOfASessionToItselfIsRefused() async {
        let model: any SessionPromptCacheCopying = UnloadableMLXModel.make(repo: Self.repo)
        let session = ULID.generate().description

        let outcome = await model.copyPromptCache(fromSession: session, toSession: session)

        #expect(outcome == .refused(.sameSession))
    }
}
