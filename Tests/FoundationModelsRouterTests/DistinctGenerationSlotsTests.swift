import Foundation
import FoundationModelsRouterTestSupport
import Testing

@testable import FoundationModelsRouter

/// Tests the rule that the `standard` slot and the `flash` slot of one resolved
/// profile never use the same model.
///
/// A synchronous tool call, for example the multitool `searchTools`, runs a
/// selection call on `flash` inside an open submission on `standard`. Each
/// model has one FIFO work queue, so one model in both slots would wait on
/// itself. The tests below hold ``JointFit``, ``ProfileDefinition`` and
/// ``Router/resolve(profile:reporting:)`` to that rule.
@Suite("Distinct generation slots")
struct DistinctGenerationSlotsTests {
    // MARK: - Candidate references

    /// The model the standard slot chooses in every test below.
    private static let standardModel: ModelRef = "org/distinct-std"

    /// A second generation model, different from ``standardModel``.
    private static let otherModel: ModelRef = "org/distinct-other"

    /// The embedding model of every profile below.
    private static let embeddingModel: ModelRef = "org/distinct-emb"

    // MARK: - Sizing

    /// The raw footprint of each model: small, so each trio fits ``ampleBudgetBytes``.
    private static let modelBytes: Int64 = 1_000

    /// A budget far above the footprint of any trio below.
    private static let ampleBudgetBytes: Int64 = 1_000_000

    /// The native max context of each generation model, for a derived context.
    private static let nativeWindow = 4_096

    /// The simulated RAM of the router in the resolve tests: ample for the stub
    /// metadata's tiny models.
    private static let routerRAMBytes: Int64 = 48 << 30

    /// A `footprint` closure that gives each model ``modelBytes`` at any context.
    private static func flatFootprint(_: ModelRef, _: Int) -> Result<Int64, RepoMetadataError> {
        .success(modelBytes)
    }

    /// A `nativeMaxContext` closure that gives each model ``nativeWindow``.
    private static func fixedNativeWindow(_: ModelRef) -> Result<Int, RepoMetadataError> {
        .success(nativeWindow)
    }

    /// A profile with the given generation candidates and ``embeddingModel``.
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
            name: "distinct-slots",
            description: "the standard and flash slots must use different models",
            standard: standard,
            flash: flash,
            embedding: [embeddingModel],
            context: context
        )
    }

    /// Runs ``JointFit`` on `profile` with ample budget and flat footprints.
    private static func jointFit(_ profile: ProfileDefinition) throws -> JointResolution {
        try JointFit.resolve(
            profile: profile,
            budgetBytes: ampleBudgetBytes,
            footprint: flatFootprint,
            nativeMaxContext: fixedNativeWindow
        )
    }

    /// The resolution of `slot` in `slots`.
    private static func resolution(_ slots: [SlotResolution], for slot: ModelSlot) throws -> SlotResolution {
        try #require(slots.first { $0.slot == slot })
    }

    // MARK: - JointFit

    @Test("flash skips the model standard chose and takes its next candidate")
    func flashSkipsTheStandardModel() throws {
        let result = try Self.jointFit(
            Self.profile(standard: [Self.standardModel], flash: [Self.standardModel, Self.otherModel])
        )
        #expect(result.standard == Self.standardModel)
        #expect(result.flash == Self.otherModel)

        let flash = try Self.resolution(result.slots, for: .flash)
        #expect(flash.considered.map(\.ref) == [Self.standardModel, Self.otherModel])
        #expect(flash.considered.map(\.verdict) == [.sameModelAsStandard, .chosen])
    }

    @Test("a flash slot whose only candidate is the standard model fails with an error that names both slots")
    func flashWithOnlyTheStandardModelFails() throws {
        let failure = try #require(throws: ResolutionFailure.self) {
            try Self.jointFit(Self.profile(standard: [Self.standardModel], flash: [Self.standardModel]))
        }
        let flash = try Self.resolution(failure.slots, for: .flash)
        #expect(flash.chosen == nil)
        #expect(flash.considered.map(\.verdict) == [.sameModelAsStandard])

        let text = failure.description
        #expect(text.contains("flash"))
        #expect(text.contains(Self.standardModel.stringValue))
        #expect(text.contains("the standard slot already uses this model"))
    }

    @Test("with a derived context, standard takes its next candidate when flash can use only the first")
    func derivedContextMovesStandardToItsNextCandidate() throws {
        let result = try Self.jointFit(
            Self.profile(
                standard: [Self.standardModel, Self.otherModel],
                flash: [Self.standardModel],
                context: nil
            )
        )
        #expect(result.standard == Self.otherModel)
        #expect(result.flash == Self.standardModel)
    }

    // MARK: - ProfileDefinition

    @Test("a profile names one shared generation model only when both slots list that model alone")
    func sharedGenerationModelIsOnlyTheOneModelInBothSlots() {
        let shared = Self.profile(standard: [Self.standardModel], flash: [Self.standardModel])
        #expect(shared.sharedGenerationModel == Self.standardModel)

        let repeated = Self.profile(
            standard: [Self.standardModel, Self.standardModel], flash: [Self.standardModel]
        )
        #expect(repeated.sharedGenerationModel == Self.standardModel)

        let fallback = Self.profile(standard: [Self.standardModel], flash: [Self.standardModel, Self.otherModel])
        #expect(fallback.sharedGenerationModel == nil)

        let distinct = Self.profile(standard: [Self.standardModel], flash: [Self.otherModel])
        #expect(distinct.sharedGenerationModel == nil)

        let empty = Self.profile(standard: [], flash: [])
        #expect(empty.sharedGenerationModel == nil)
    }

    // MARK: - Router

    @Test("resolve rejects a profile with one model for both generation slots, and loads no model")
    @MainActor
    func resolveRejectsOneModelForBothGenerationSlots() async throws {
        let dir = RouterTestFixtures.makeTempDir(prefix: "DistinctGenerationSlotsTests")
        defer { try? FileManager.default.removeItem(at: dir) }
        let spy = LoadSpy()
        let router = ResidencyFixtures.makeRouter(
            spy: spy, recommendedMaxWorkingSetSize: Self.routerRAMBytes, cacheDir: dir
        )
        let progress = ResolutionProgress()

        let failure = try await #require(throws: SameGenerationModelFailure.self) {
            try await router.resolve(
                profile: Self.profile(standard: [Self.standardModel], flash: [Self.standardModel]),
                reporting: progress
            )
        }

        #expect(failure.model == Self.standardModel)
        #expect(failure.description.contains("standard"))
        #expect(failure.description.contains("flash"))
        #expect(failure.description.contains(Self.standardModel.stringValue))
        #expect(await spy.llmLoads.isEmpty)
        #expect(await spy.embedderLoads.isEmpty)
        #expect(progress.phase == .failed(failure.description))
    }

    @Test("resolve gives flash its next candidate when its first candidate is the standard model")
    @MainActor
    func resolveGivesFlashItsNextCandidate() async throws {
        let dir = RouterTestFixtures.makeTempDir(prefix: "DistinctGenerationSlotsTests")
        defer { try? FileManager.default.removeItem(at: dir) }
        let spy = LoadSpy()
        let router = ResidencyFixtures.makeRouter(
            spy: spy, recommendedMaxWorkingSetSize: Self.routerRAMBytes, cacheDir: dir
        )

        let resolved = try await router.resolve(
            profile: Self.profile(standard: [Self.standardModel], flash: [Self.standardModel, Self.otherModel]),
            reporting: ResolutionProgress()
        )

        #expect(resolved.standard.chosen == Self.standardModel)
        #expect(resolved.flash.chosen == Self.otherModel)
        #expect(await spy.llmLoads.sorted { $0.stringValue < $1.stringValue } == [Self.otherModel, Self.standardModel])
    }
}
