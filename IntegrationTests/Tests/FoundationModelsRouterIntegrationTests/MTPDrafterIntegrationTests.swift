import Foundation
import FoundationModels
import FoundationModelsExtras
import FoundationModelsRouterTestSupport
import Testing

@testable import FoundationModelsRouter
@testable import FoundationModelsRouterRealModelSupport

/// Gated real-model coverage of MTP speculative decoding through the router:
/// a ``ModelRef`` that names an MTP drafter (``ModelRef/drafter``) loads
/// through ``LiveModelLoader`` with the drafter registration of the router,
/// and still generates.
///
/// The target is the 4-bit Qwen3.8 27B. A note of the ACP agent of 2026-09-08
/// says that this build made no tokens through the router, so the suite first
/// proves that it generates with plain decode, then with its drafter. Each
/// run prints its decode rate, so a reader can compare the two. When the MLX
/// executor reports the MTP outcome in the response metadata, the suite reads
/// it and requires that MTP drafted.
@Suite(
    "Gated real-model coverage: MTP drafter through the router",
    .serialized,
    .exclusiveRealModel
)
struct MTPDrafterIntegrationTests {
    /// The target checkpoint.
    private static let target: ModelRef = "mlx-community/Qwen3.8-27B-4bit"

    /// The MTP drafter of ``target``.
    private static let drafter: ModelRef = "mlx-community/Qwen3.8-27B-MTP-4bit"

    /// The ceiling of the one answer of each run. The model reasons first, for
    /// about 500 tokens, and greedy MTP decode is not token for token the same
    /// as plain decode (the batched verify can flip a near tie), so a ceiling
    /// of 512 cut one run inside its reasoning and not the other. Measured on
    /// 2026-10-29: 719 tokens plain, 749 with MTP.
    private static let responseTokenCeiling = 2048

    /// The prompt of each run: a long, easy output, so the decode rate is
    /// measured over many tokens.
    private static let prompt = "Write the numbers from 1 to 80 in words, separated by commas. Output only the list."

    /// The tag of the measurement line of each run.
    private static let label = "mtpDrafter"

    /// What one run measured.
    private struct Run {
        /// The text of the answer.
        let reply: String

        /// The tokens the answer generated.
        let tokensOut: Int

        /// The tokens of the answer, divided by the wall time of the answer.
        let tokensPerSecond: Double

        /// The MTP outcome the executor reported, or `nil` when it reported none.
        let outcome: SpeculativeDecodingOutcome?
    }

    /// Loads `ref`, answers ``prompt`` one time with greedy decoding, and
    /// evicts the model.
    ///
    /// - Parameter ref: The model, with or without a drafter.
    /// - Returns: What the run measured.
    /// - Throws: The error of the load or of the answer.
    private static func run(_ ref: ModelRef) async throws -> Run {
        let loaded = try await RealModelContainer.load(ref: ref, samplingMode: .greedy)
        do {
            let run = try await answer(ref, on: loaded)
            await loaded.container.model.evict()
            return run
        } catch {
            await loaded.container.model.evict()
            throw error
        }
    }

    /// Answers ``prompt`` one time on `loaded` and measures the answer.
    ///
    /// - Parameters:
    ///   - ref: The model that `loaded` holds.
    ///   - loaded: The loaded model.
    /// - Returns: What the run measured.
    /// - Throws: The error of the answer.
    private static func answer(_ ref: ModelRef, on loaded: RealModelContainer) async throws -> Run {
        let backend = try #require(
            loaded.container.makeSession(instructions: nil, samplingMode: loaded.samplingMode)
                as? MLXFoundationModelsSessionBackend)
        let before = backend.usageTokenCounts()?.output ?? 0
        let started = ContinuousClock.now
        let reply = try await backend.respond(to: prompt, maxTokens: responseTokenCeiling)
        let seconds = (ContinuousClock.now - started).seconds
        let tokensOut = (backend.usageTokenCounts()?.output ?? 0) - before
        let outcome = SpeculativeDecodingOutcome.newest(in: backend.session.transcript, after: nil)?.outcome
        print(
            "\(label) ref=\(ref.stringValue) drafter=\(ref.drafter?.stringValue ?? "none") tokensOut=\(tokensOut) "
                + "seconds=\(seconds) tokensPerSecond=\(Double(tokensOut) / seconds) "
                + "outcome=\(outcome.map(String.init(describing:)) ?? "none") reply=\(reply.prefix(80))")
        return Run(reply: reply, tokensOut: tokensOut, tokensPerSecond: Double(tokensOut) / seconds, outcome: outcome)
    }

    @Test("Qwen3.8-27B-4bit generates through the router, with plain decode and with its MTP drafter")
    func targetGeneratesWithAndWithoutDrafter() async throws {
        let plain = try await Self.run(Self.target)
        let speculating = try await Self.run(ModelRef(repo: Self.target.repo, drafter: Self.drafter))

        #expect(plain.tokensOut > 0)
        #expect(speculating.tokensOut > 0)
        #expect(plain.reply.lowercased().contains("eighty"))
        #expect(speculating.reply.lowercased().contains("eighty"))
        if let outcome = speculating.outcome {
            #expect(outcome.speculated)
            #expect(outcome.fallbackReason == nil)
        }
        #expect(plain.outcome == nil)
    }
}
