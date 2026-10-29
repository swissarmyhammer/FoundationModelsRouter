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

    // MARK: - Speed at a long context

    /// The window of the long-context runs: room for the ~20k-token prompt and
    /// the answer, so no compaction runs.
    private static let longContext = 32_768

    /// The ceiling of the answer of a long-context run.
    private static let longAnswerCeiling = 2_048

    /// A prompt of about 20k tokens: a numbered inventory the model must
    /// read, then a task with a long answer. The text is fixed, so each run
    /// sends the same tokens.
    private static let longPrompt: String = {
        let items = (1...1_500).map { index in
            "Item \(index): part \(index * 7 % 1000), bin \(index % 37), count \(index * 13 % 97)."
        }
        return items.joined(separator: "\n")
            + "\n\nUsing the inventory above, write a Python module that loads it into a dictionary keyed by item "
            + "number, with functions to find items by bin, total the counts per bin, and list the ten largest "
            + "counts. Include docstrings and a test for each function."
    }()

    /// What a long-context run measured, from the generation call usage of
    /// the router.
    private struct DecodeRun {
        /// The tokens the calls generated.
        let tokensOut: Int

        /// The decode time of the calls, from their first output token.
        let decodeSeconds: Double

        /// The tokens the calls fed the model.
        let tokensIn: Int

        /// The MTP outcome of the last call, or `nil` when it reported none.
        let outcome: SpeculativeDecodingOutcome?

        /// The decode rate: generated tokens per second of decode.
        var tokensPerSecond: Double { Double(tokensOut) / decodeSeconds }
    }

    /// Loads `ref` at ``longContext``, answers ``longPrompt`` through a
    /// routed session with greedy decoding, and evicts the model.
    ///
    /// - Parameter ref: The model, with or without a drafter.
    /// - Returns: The decode measurement of the answer.
    /// - Throws: The error of the load or of the answer.
    private static func decodeRun(_ ref: ModelRef) async throws -> DecodeRun {
        let loaded = try await RealModelContainer.load(ref: ref, context: longContext, samplingMode: .greedy)
        do {
            let run = try await answerLong(ref, on: loaded)
            await loaded.container.model.evict()
            return run
        } catch {
            await loaded.container.model.evict()
            throw error
        }
    }

    /// Answers ``longPrompt`` on `loaded` and sums the usage of its
    /// generation calls.
    private static func answerLong(_ ref: ModelRef, on loaded: RealModelContainer) async throws -> DecodeRun {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MTPDrafterIntegrationTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = RealModelHarness.make(
            model: ref, context: longContext, container: loaded.container, samplingMode: loaded.samplingMode,
            cacheDir: root.appendingPathComponent("cache", isDirectory: true),
            recordingsDir: root.appendingPathComponent("recordings", isDirectory: true))
        let session = profile.standard.makeSession(configuration: SessionConfiguration(instructions: nil))
        var calls: [GenerationCallUsage] = []
        for try await event in await session.streamEvents(to: longPrompt, maxTokens: longAnswerCeiling) {
            if case .generationCall(let usage) = event { calls.append(usage) }
        }
        await session.close()
        let decodeTimes = try calls.map { try #require($0.decodeTime, "a call of the answer had no decode time") }
        let run = DecodeRun(
            tokensOut: calls.map(\.tokensOut).reduce(0, +),
            decodeSeconds: decodeTimes.reduce(Duration.zero, +).seconds,
            tokensIn: calls.map(\.tokensIn).max() ?? 0,
            outcome: calls.last?.speculativeDecoding)
        print(
            "\(label) long ref=\(ref.stringValue) drafter=\(ref.drafter?.stringValue ?? "none") tokensIn=\(run.tokensIn) "
                + "tokensOut=\(run.tokensOut) decodeSeconds=\(run.decodeSeconds) tokensPerSecond=\(run.tokensPerSecond) "
                + "outcome=\(run.outcome.map(String.init(describing:)) ?? "none")")
        return run
    }

    /// Measured on 2026-10-29 (mlx-swift-lm d4bab584, Extras a23cd80): each
    /// run made two calls of about 18k tokens in, because the answer hit a
    /// reasoning stop at 2048 tokens and one recovery followed. Plain decode
    /// made 3086 tokens at 36.9 tok/s. MTP made 3207 tokens at 50.9 tok/s,
    /// accepting 858 of 946 drafted tokens, which is 1.38x plain decode.
    @Test("at a context of about 20k tokens, MTP decodes Qwen3.8-27B-4bit faster than plain decode")
    func mtpDecodesFasterAtLongContext() async throws {
        let plain = try await Self.decodeRun(Self.target)
        let speculating = try await Self.decodeRun(ModelRef(repo: Self.target.repo, drafter: Self.drafter))

        #expect(plain.tokensIn > 15_000, "the prompt is not a long context")
        #expect(plain.tokensOut > 500 && speculating.tokensOut > 500, "an answer was too short to measure a rate")
        #expect(
            speculating.tokensPerSecond > plain.tokensPerSecond,
            "MTP decoded at \(speculating.tokensPerSecond) tok/s, plain decode at \(plain.tokensPerSecond) tok/s")
        if let outcome = speculating.outcome {
            #expect(outcome.speculated, "MTP fell back to plain decode: \(outcome.fallbackReason ?? "no reason")")
        }
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
