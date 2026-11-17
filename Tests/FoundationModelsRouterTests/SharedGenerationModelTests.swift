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
/// One model can thus serve both generation slots: the resolve loads it once,
/// and the flash slot is charged one session of KV cache at the context, the
/// cache that each flash session opens beside the standard session.
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

    /// The bytes of one session of KV cache of a generation model at
    /// `context`.
    private static func kvBytes(context: Int) -> Int64 {
        bytesPerToken * Int64(context)
    }

    /// A footprint that grows with the context for a generation model. A
    /// candidate that an allocated pool key serves, at any context as the key
    /// of an MLX model does, costs one session of KV cache in the flash slot
    /// and nothing in the decision slot, as the router prices it.
    private static func footprint(
        _ ref: ModelRef, _ slot: ModelSlot, _ context: Int, _ allocatedKeys: Set<ModelPoolKey>
    ) -> Result<Int64, RepoMetadataError> {
        guard ref != embeddingModel else { return .success(embeddingBytes) }
        let request = slot.poolKey(of: ref, context: context, kvCache: nil)
        guard !allocatedKeys.contains(where: { $0.withoutContext.canServe(request) }) else {
            return .success(slot == .flash ? kvBytes(context: context) : 0)
        }
        return .success(weightBytes + kvBytes(context: context))
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

    @Test("a derived window of one model in both slots is smaller by the KV cache of the flash session")
    func derivedWindowChargesTheFlashSessionKV() throws {
        let budget = Self.embeddingBytes + Self.weightBytes + Self.kvBytes(context: Self.nativeWindow)
        let result = try Self.jointFit(
            Self.profile(standard: [Self.standardModel], flash: [Self.standardModel], context: nil),
            budgetBytes: budget)

        #expect(try Self.resolution(result.slots, for: .standard).contextTokens == Self.nativeWindow / 2)
    }

    // MARK: - The price of the router

    /// The sizing metadata of the stub models of the resolve tests.
    private static func stubMetadata(of ref: ModelRef) throws -> RepoMetadata {
        try RepoMetadata(raw: RouterTestFixtures.rawMetadata, repo: ref.repo)
    }

    /// The price of the router of ``standardModel`` in `slot`, when the
    /// standard slot allocated it at `context`.
    private static func priceOfTheAllocatedStandardModel(in slot: ModelSlot, context: Int) throws -> Int64 {
        let metadata = try stubMetadata(of: standardModel)
        return try Router.footprintBytes(
            for: standardModel, in: slot, context: context, metadataByRef: [standardModel: .success(metadata)],
            membership: [standardModel: [.standard, .flash, .decision]], residentKeys: [],
            allocatedKeys: [ModelSlot.standard.poolKey(of: standardModel, context: context, kvCache: nil)]
        ).get()
    }

    @Test("the router charges a flash slot of the allocated standard model one session of KV cache")
    func routerChargesTheSharedFlashSessionKV() throws {
        let context = ScriptedSessionContext.tokens
        let price = try Self.priceOfTheAllocatedStandardModel(in: .flash, context: context)

        #expect(price == (try Self.stubMetadata(of: Self.standardModel)).footprint.kvBytes(context: context))
    }

    @Test("the router charges a decision slot of the allocated standard model nothing")
    func routerChargesTheSharedDecisionNothing() throws {
        #expect(try Self.priceOfTheAllocatedStandardModel(in: .decision, context: ScriptedSessionContext.tokens) == 0)
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

    @Test("resolve charges the flash handle of the standard model one session of KV cache")
    @MainActor
    func resolveChargesTheSharedFlashSessionKV() async throws {
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

        let kvBytes = try Self.stubMetadata(of: Self.standardModel).footprint
            .kvBytes(context: ScriptedSessionContext.tokens)
        #expect(resolved.flash.footprintBytes == kvBytes)
        #expect(resolved.standard.footprintBytes > kvBytes)
    }
}
