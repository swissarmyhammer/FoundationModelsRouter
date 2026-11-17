import Foundation
import FoundationModelsRouterTestSupport
import MLXLMCommon
import Testing

@testable import FoundationModelsRouter
@testable import MLXFoundationModels

/// Gated real-model coverage for a quantized KV cache (task ^2fet0gs): the
/// standard model, loaded by a live loader with an 8-bit cache, stores that
/// cache and still answers.
///
/// ## What it proves
///
/// ``LiveModelLoader`` with ``KVCacheQuantization/bits8`` gives the Extras
/// `HubModelLoader` an affine 8-bit cache, and the `MLXLanguageModel` that the
/// load returns runs under it. Two turns of one session then answer a sum.
/// The second turn reuses the cache of the first, so an 8-bit cache that MLX
/// did not save after a generation fails the second answer.
///
/// ## Why the coverage is gated
///
/// `Tests/FoundationModelsRouterTests/KVCacheQuantizationTests.swift` proves
/// the setting reaches the Extras loader. Only a real load proves the model
/// runs under it and answers.
@Suite(
    "Gated real-model coverage: the standard model answers under an 8-bit KV cache",
    .serialized,
    .exclusiveRealModel
)
struct QuantizedKVCacheIntegrationTests {
    /// The working context of the load, in tokens.
    private static let contextTokens = 8192

    /// The instructions of the session.
    private static let instructions = "You are a terse assistant. Answer with only the number."

    @Test("Qwen 3.8 loads with an 8-bit KV cache and answers two turns")
    func standardModelAnswersUnderEightBitCache() async throws {
        let loader = LiveModelLoader()
        let loaded = try await loader.loadLLM(
            ref: StandardModels.qwen38, slot: .standard, context: Self.contextTokens, kvCache: .bits8, reporting: { _ in })
        let container = try #require(loaded as? LiveLLMContainer)
        let model = try #require(container.model as? MLXLanguageModel)
        #expect(
            model.kvCache
                == KVCacheConfiguration(strategy: .affine(try AffineKVCacheConfiguration(bits: 8, groupSize: 64))))

        let session = container.makeSession(instructions: Self.instructions)
        let first = try await session.respondWithoutReasoning(
            to: "What is 17 + 25?", maxTokens: GatedRealModelBudget.responseTokenCeiling)
        let second = try await session.respondWithoutReasoning(
            to: "Add 100 to that.", maxTokens: GatedRealModelBudget.responseTokenCeiling)
        await loader.evict(container: container)

        #expect(first.contains("42"), "first answer: \(first)")
        #expect(second.contains("142"), "second answer: \(second)")
    }
}
