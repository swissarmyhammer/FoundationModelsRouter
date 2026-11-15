import Foundation
import FoundationModelsRouterTestSupport
import Testing

@testable import FoundationModelsRouter

/// Tests of one model in both the `standard` and the `flash` slot (task
/// ^t4zn88x).
///
/// The model call of a session holds the lock of its model only for the call
/// into the model, and a tool body holds nothing (task ^qhgfajc), so a flash
/// call inside an open submission on the same model does not wait on itself.
/// One model can thus serve both generation slots: the flash slot takes the
/// standard model at no extra charge, and the resolve loads it once.
@Suite("One model in both generation slots")
struct SharedGenerationModelTests {
    // MARK: - Candidate references

    /// The model of the standard slot in every test below.
    private static let standardModel: ModelRef = "org/shared-std"

    /// A second generation model, different from ``standardModel``.
    private static let otherModel: ModelRef = "org/shared-other"

    /// The embedding model of every profile below.
    private static let embeddingModel: ModelRef = "org/shared-emb"

    // MARK: - Sizing

    /// The weight bytes of each generation model.
    private static let weightBytes: Int64 = 1_000

    /// The bytes of KV cache that each generation model adds for each token.
    private static let bytesPerToken: Int64 = 2

    /// The bytes of the embedding model.
    private static let embeddingBytes: Int64 = 100

    /// A budget far above the footprint of any profile below.
    private static let ampleBudgetBytes: Int64 = 1_000_000

    /// The native max context of each generation model, for a derived context.
    private static let nativeWindow = 4_096

    /// The simulated RAM of the router in the resolve tests: ample for the stub
    /// metadata's tiny models.
    private static let routerRAMBytes: Int64 = 48 << 30

    /// A footprint that grows with the context for a generation model, and
    /// that is 0 for a model that an allocated pool key serves, as the
    /// router prices it.
    private static func footprint(
        _ ref: ModelRef, _ context: Int, _ allocatedKeys: Set<ModelPoolKey>
    ) -> Result<Int64, RepoMetadataError> {
        guard ref != embeddingModel else { return .success(embeddingBytes) }
        let request = ModelSlot.flash.poolKey(of: ref, context: context)
        guard !allocatedKeys.contains(where: { $0.canServe(request) }) else { return .success(0) }
        return .success(weightBytes + bytesPerToken * Int64(context))
    }

    /// A `nativeMaxContext` closure that gives each model ``nativeWindow``.
    private static func fixedNativeWindow(_: ModelRef) -> Result<Int, RepoMetadataError> {
        .success(nativeWindow)
    }

    /// A profile with the given generation candidates and ``embeddingModel``.
    /// The decision slot names the flash candidates.
    ///
    /// - Parameters:
    ///   - standard: The standard-slot candidates, in preference order.
    ///   - flash: The flash-slot candidates, in preference order.
    ///   - context: The working context, or `nil` to derive it.
    /// - Returns: The profile definition.
    private static func profile(
        standard: [ModelRef],
        flash: [ModelRef],
        context: Int? = ScriptedSessionContext.tokens
    ) -> ProfileDefinition {
        ProfileDefinition(
            name: "shared-slots",
            description: "one model in both generation slots",
            standard: standard,
            flash: flash,
            embedding: [embeddingModel],
            decision: flash,
            context: context
        )
    }

    /// Runs ``JointFit`` on `profile` against `budgetBytes`.
    private static func jointFit(
        _ profile: ProfileDefinition, budgetBytes: Int64 = ampleBudgetBytes
    ) throws -> JointResolution {
        try JointFit.resolve(
            profile: profile,
            budgetBytes: budgetBytes,
            footprint: footprint,
            nativeMaxContext: fixedNativeWindow
        )
    }

    /// The resolution of `slot` in `slots`.
    private static func resolution(_ slots: [SlotResolution], for slot: ModelSlot) throws -> SlotResolution {
        try #require(slots.first { $0.slot == slot })
    }

    // MARK: - JointFit

    @Test("the flash slot takes the standard model when it is the first flash candidate")
    func flashTakesTheStandardModel() throws {
        let result = try Self.jointFit(
            Self.profile(standard: [Self.standardModel], flash: [Self.standardModel, Self.otherModel]))

        #expect(result.standard == Self.standardModel)
        #expect(result.flash == Self.standardModel)
    }

    @Test("the flash slot of the standard model is charged 0 bytes")
    func flashOfTheStandardModelIsFree() throws {
        let result = try Self.jointFit(Self.profile(standard: [Self.standardModel], flash: [Self.standardModel]))
        let flash = try Self.resolution(result.slots, for: .flash)

        #expect(
            flash.considered
                == [CandidateReport(ref: Self.standardModel, estimatedFootprintBytes: 0, chargedBytes: 0, verdict: .chosen)])
    }

    @Test("a derived window of one model in both slots is charged that model once")
    func derivedWindowChargesTheSharedModelOnce() throws {
        let budget = Self.embeddingBytes + Self.weightBytes + Self.bytesPerToken * Int64(Self.nativeWindow)
        let result = try Self.jointFit(
            Self.profile(standard: [Self.standardModel], flash: [Self.standardModel], context: nil),
            budgetBytes: budget)

        #expect(try Self.resolution(result.slots, for: .standard).contextTokens == Self.nativeWindow)
    }

    // MARK: - Router

    @Test("resolve gives one model to both generation slots, and loads it once")
    @MainActor
    func resolveLoadsTheSharedModelOnce() async throws {
        let dir = RouterTestFixtures.makeTempDir(prefix: "SharedGenerationModelTests")
        defer { try? FileManager.default.removeItem(at: dir) }
        let spy = LoadSpy()
        let router = ResidencyFixtures.makeRouter(
            spy: spy, recommendedMaxWorkingSetSize: Self.routerRAMBytes, cacheDir: dir
        )

        let resolved = try await router.resolve(
            profile: Self.profile(standard: [Self.standardModel], flash: [Self.standardModel]),
            reporting: ResolutionProgress()
        )

        #expect(resolved.standard.chosen == Self.standardModel)
        #expect(resolved.flash.chosen == Self.standardModel)
        #expect(await spy.llmLoads == [Self.standardModel])
    }

    @Test("resolve charges the flash handle of the standard model no footprint")
    @MainActor
    func resolveChargesTheSharedFlashNothing() async throws {
        let dir = RouterTestFixtures.makeTempDir(prefix: "SharedGenerationModelTests")
        defer { try? FileManager.default.removeItem(at: dir) }
        let spy = LoadSpy()
        let router = ResidencyFixtures.makeRouter(
            spy: spy, recommendedMaxWorkingSetSize: Self.routerRAMBytes, cacheDir: dir
        )

        let resolved = try await router.resolve(
            profile: Self.profile(standard: [Self.standardModel], flash: [Self.standardModel]),
            reporting: ResolutionProgress()
        )

        #expect(resolved.flash.footprintBytes == 0)
        #expect(resolved.standard.footprintBytes > 0)
    }
}
