import Foundation
import FoundationModels
import FoundationModelsRouterRealModelSupport
import FoundationModelsRouterTestSupport
import Testing

@testable import FoundationModelsRouter

// MARK: - Models

/// The GGUF model of this suite: Qwen3.5 0.8B in the ggml-org Q8_0
/// conversion, 834 MB.
///
/// The ggml-org conversion keeps the MTP (`nextn`) layers of the model, so the
/// model drafts for itself with no drafter named. The regular Unsloth GGUFs
/// drop those layers. FoundationModelsLlamaCpp and FoundationModelsExtras test
/// with this same file.
///
/// The reference names a file inside a GGUF repository and no backend. The
/// router finds the backend from the files: a `.gguf` file loads with
/// llama.cpp.
private let ggufModel: ModelRef = "ggml-org/Qwen3.5-0.8B-GGUF/Qwen3.5-0.8B-Q8_0.gguf"

/// The `flash` candidate of each profile of this suite: the small MLX instruct
/// model the compaction smoke suites already load, 680 MB.
///
/// `Router.resolve(profile:reporting:)` fills all three slots, and the
/// `standard` and `flash` slots never use the same model. So a profile whose
/// `standard` slot is ``ggufModel`` names a different `flash` model. No test
/// of this suite generates on it.
private let flashModel: ModelRef = "mlx-community/Llama-3.2-1B-Instruct-4bit"

/// The MLX candidate of the mixed slot: the 17 GB model of the gated
/// profile. The resolve only sizes it, from the Hub metadata of the
/// repository, and never downloads it, because it does not fit
/// ``mixedSlotWorkingSetBytes``.
private let largeMLXModel: ModelRef = RealModels.standard

/// The working context of each profile of this suite, in tokens.
///
/// llama.cpp loads a GGUF model at a fixed context, which the router gives it
/// from the resolution. A small context keeps the KV cache of each model
/// small, and one answer of ``ggufAnswerTokenCeiling`` tokens fits it many
/// times over.
private let ggufProfileContext = 4096

/// The decoding of each router of this suite: argmax, the pin every gated
/// suite of this target states.
///
/// Greedy decoding pins the sampling. The suite pins no chat-template date:
/// llama.cpp renders the template of ``ggufModel`` from the GGUF file, and that
/// template writes no date into the prompt. `PinnedDateTokenizerLoader`
/// reaches only an MLX tokenizer.
private let ggufSamplingMode: GenerationOptions.SamplingMode = .greedy

/// The token ceiling of each generation call of the one answer of each
/// generating test.
///
/// Qwen3.5 can spend its whole budget on its reasoning, so each test checks
/// the token counts and the metadata of the calls, and never the text of the
/// answer. A call that ends inside its reasoning at this ceiling is a
/// reasoning stop, and the session recovers with more calls in the same
/// answer: the measured run of 2026-11-09 made four calls of 128 reasoning
/// tokens each.
private let ggufAnswerTokenCeiling = 128

/// The instructions of each session of this suite.
private let ggufInstructions = "You are a terse assistant."

/// The prompt of each answer: an easy list, so the drafter has many tokens to
/// predict.
private let ggufPrompt = "Count from one to twenty in words, separated by commas."

/// The working set the mixed-slot router reports: 8 GiB.
///
/// ``largeMLXModel`` needs about 17 GB, so it does not fit. ``ggufModel``,
/// ``flashModel`` and ``RealModels/embedding`` together need less than 3 GB at
/// ``ggufProfileContext``, so they fit with room to spare.
private let mixedSlotWorkingSetBytes: Int64 = 8 << 30

// MARK: - Profiles

/// The profile whose `standard` slot is ``ggufModel`` alone.
private let ggufProfile = ProfileDefinition(
    name: "gguf-mtp",
    description: "A GGUF standard model that drafts with its own MTP layers.",
    standard: [ggufModel],
    flash: [flashModel],
    embedding: [RealModels.embedding],
    context: ggufProfileContext
)

/// The profile whose `standard` slot is ``ggufModel`` with itself as its
/// drafter.
private let selfDraftingProfile = ProfileDefinition(
    name: "gguf-self-drafter",
    description: "A GGUF standard model that drafts with a second copy of itself.",
    standard: [ModelRef(repo: ggufModel.repo, path: ggufModel.path, revision: ggufModel.revision, drafter: ggufModel)],
    flash: [flashModel],
    embedding: [RealModels.embedding],
    context: ggufProfileContext
)

/// The profile whose `standard` slot names an MLX candidate first and the
/// GGUF candidate second.
private let mixedSlotProfile = ProfileDefinition(
    name: "gguf-mixed-slot",
    description: "An MLX candidate and a GGUF candidate in one slot.",
    standard: [largeMLXModel, ggufModel],
    flash: [flashModel],
    embedding: [RealModels.embedding],
    context: ggufProfileContext
)

// MARK: - Fixture

/// A ``MachineProbe`` that reports a fixed working set, and the chip and the
/// physical RAM of the host.
private struct FixedWorkingSetProbe: MachineProbe {
    /// The live probe that gives the chip and the physical RAM.
    private let live = SystemMachineProbe()

    /// The working set this probe reports, in bytes.
    let recommendedMaxWorkingSetSize: Int64

    var chip: String { live.chip }

    var totalRAM: Int64 { live.totalRAM }
}

/// One router of this suite over a live loader and a pool of its own, and the
/// directory it caches under.
///
/// The pool is never `ModelPool.shared`, so no other suite can hold a model in
/// it, and the test reads the eviction of each model of the profile from it.
private struct GGUFRouterFixture {
    /// The directory the router caches its sizing metadata under.
    let root: URL

    /// The pool the router resolves into.
    let pool: ModelPool

    /// The router.
    let router: Router

    /// Makes a router over a live loader and a new pool.
    ///
    /// - Parameter probe: The machine probe behind the budget of the router.
    init(probe: any MachineProbe = SystemMachineProbe()) {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GGUFProfileIntegrationTests-\(UUID().uuidString)", isDirectory: true)
        pool = ModelPool()
        router = Router(
            cacheDir: root.appendingPathComponent("cache", isDirectory: true),
            probe: probe,
            loader: LiveModelLoader(),
            samplingMode: ggufSamplingMode,
            pool: pool
        )
    }

    /// Resolves `profile` on the router.
    ///
    /// - Parameter profile: The authored profile.
    /// - Returns: The resolved, resident profile.
    /// - Throws: Whatever the resolve throws.
    func resolve(_ profile: ProfileDefinition) async throws -> LanguageModelProfile {
        try await router.resolve(profile: profile, reporting: ResolutionProgress())
    }

    /// Removes the cache directory of the router.
    func removeRoot() {
        try? FileManager.default.removeItem(at: root)
    }
}

// MARK: - Suite

/// Gated real-model coverage of a GGUF model through `Router.resolve`
/// (task ^44meq1j): a profile whose `standard` slot names a GGUF file
/// resolves, a session on it answers, and the answer decodes speculatively.
///
/// ## What it proves
///
/// 1. A profile that names a GGUF file, and no backend, resolves: the router
///    sizes the file from its header, loads it with llama.cpp at the resolved
///    context, and a session answers.
/// 2. The model drafts with its own MTP layers when the reference names no
///    drafter, and the router reports it in
///    ``GenerationCallUsage/speculativeDecoding`` of each call of the answer.
/// 3. The model drafts with a drafter the reference names, here a second copy
///    of itself, and each call of the answer reports the drafted tokens.
/// 4. One slot that names an MLX candidate and a GGUF candidate resolves by
///    fit: the MLX candidate does not fit the budget, and the GGUF candidate
///    wins the slot.
///
/// ## What each resolve loads
///
/// `Router.resolve(profile:reporting:)` fills all three slots, so each resolve
/// also loads ``flashModel`` and ``RealModels/embedding``. All three models are
/// small. The mixed-slot test never generates, and llama.cpp reads the weights
/// of a GGUF model only at its first request, so that resolve reads the
/// weights of the two MLX models only.
///
/// ## Teardown
///
/// Each test drops its profile and waits until its pool has no resident
/// model. The pool evicts each model through the live loader: an MLX model
/// leaves memory at once, and llama.cpp unloads the GGUF weights after its idle
/// timeout.
///
/// The suite has no time limit. A run ends when it ends, or when the caller
/// stops it.
@Suite(
    "Gated real-model coverage: a GGUF profile resolves, generates, and speculates",
    .serialized,
    .exclusiveRealModel
)
struct GGUFProfileIntegrationTests {
    /// The tag of the measurement line of each answer.
    private static let label = "ggufProfile"

    @Test("a GGUF standard model with no drafter answers and drafts with its MTP layers")
    func ggufAnswersWithMTP() async throws {
        let fixture = GGUFRouterFixture()
        defer { fixture.removeRoot() }

        var profile: LanguageModelProfile? = try await fixture.resolve(ggufProfile)
        let calls = try await Self.answerOnce(on: try #require(profile).standard)
        profile = nil
        #expect(await fixture.pool.awaitNoResidentModel())

        for usage in calls {
            #expect(usage.tokensIn > 0)
            #expect(usage.tokensOut > 0)
            #expect(usage.tokensOut <= ggufAnswerTokenCeiling)
            let outcome = try #require(usage.speculativeDecoding)
            #expect(outcome.speculated)
            #expect(outcome.fallbackReason == nil)
        }
    }

    @Test("a GGUF standard model with itself as its drafter drafts tokens")
    func ggufAnswersWithItselfAsDrafter() async throws {
        let fixture = GGUFRouterFixture()
        defer { fixture.removeRoot() }

        var profile: LanguageModelProfile? = try await fixture.resolve(selfDraftingProfile)
        let calls = try await Self.answerOnce(on: try #require(profile).standard)
        profile = nil
        #expect(await fixture.pool.awaitNoResidentModel())

        for usage in calls {
            #expect(usage.tokensOut > 0)
            let outcome = try #require(usage.speculativeDecoding)
            #expect(outcome.draftedTokenCount > 0)
        }
    }

    @Test("a slot with an MLX candidate and a GGUF candidate resolves by fit")
    func mixedSlotResolvesByFit() async throws {
        let fixture = GGUFRouterFixture(
            probe: FixedWorkingSetProbe(recommendedMaxWorkingSetSize: mixedSlotWorkingSetBytes))
        defer { fixture.removeRoot() }

        var profile: LanguageModelProfile? = try await fixture.resolve(mixedSlotProfile)
        let standard = try #require(profile).standard.resolution
        profile = nil
        #expect(await fixture.pool.awaitNoResidentModel())

        #expect(standard.chosen == ggufModel)
        #expect(standard.considered.map(\.ref) == [largeMLXModel, ggufModel])
        #expect(standard.considered.map(\.verdict) == [.tooLarge, .chosen])
    }

    /// Makes one session on `model`, answers ``ggufPrompt`` one time, and
    /// returns the usage of each generation call of the answer.
    ///
    /// The session is local to this call, so it is gone when the call
    /// returns, and the caller can drop the profile the session retains.
    ///
    /// - Parameter model: The model to answer on.
    /// - Returns: The usage of each generation call of the answer, in order.
    ///   It holds at least one call.
    /// - Throws: Whatever the answer throws, or an expectation failure when the
    ///   answer reported no generation call.
    private static func answerOnce(on model: RoutedLLM) async throws -> [GenerationCallUsage] {
        let session = model.makeSession(instructions: ggufInstructions)
        var calls: [GenerationCallUsage] = []
        let started = ContinuousClock.now
        for try await event in await session.streamEvents(to: ggufPrompt, maxTokens: ggufAnswerTokenCeiling) {
            if case .generationCall(let usage) = event {
                calls.append(usage)
            }
            if case .answerFailed(let failure) = event {
                Issue.record("the answer failed: \(failure)")
            }
        }
        try #require(!calls.isEmpty)
        // swiftlint:disable:next no_direct_standard_out_logs - the gated run's record; this target does not ship
        print("[\(label)] ref=\(model.chosen.stringValue) answer=\(ContinuousClock.now - started) calls=\(calls)")
        return calls
    }
}
