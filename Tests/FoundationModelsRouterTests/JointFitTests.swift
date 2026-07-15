import Foundation
import Testing

@testable import FoundationModelsRouter

/// Tests the pure joint-fit allocation and its diagnostic types with injected
/// footprints and native-max-contexts — no network, no MLX, no I/O.
@Suite("JointFit")
struct JointFitTests {
    // MARK: Candidate references

    /// Standard-slot candidates in author preference order (biggest/best first).
    private static let std32b8: ModelRef = "org/Qwen2.5-Coder-32B-Instruct-8bit"
    private static let std32b4: ModelRef = "org/Qwen2.5-Coder-32B-Instruct-4bit"
    private static let std14b4: ModelRef = "org/Qwen2.5-Coder-14B-Instruct-4bit"

    /// Flash-slot candidate.
    private static let flash3b: ModelRef = "org/Qwen2.5-Coder-3B-Instruct-4bit"

    /// Embedding-slot candidate.
    private static let embBge: ModelRef = "org/bge-small"

    /// A candidate whose sizing metadata cannot be read.
    private static let unsizable: ModelRef = "org/no-config"

    /// The name shared by the portability profile and its diagnostics assertions.
    private static let coderProfileName = "coder"

    // MARK: Raw footprints (multiples of 5 so the ×1.2 margin is exact)

    private static let raw: [ModelRef: Int64] = [
        std32b8: 32_000,   // ×1.2 = 38_400
        std32b4: 18_000,   // ×1.2 = 21_600
        std14b4: 9_000,    // ×1.2 = 10_800
        flash3b: 2_000,    // ×1.2 =  2_400
        embBge: 500,       // ×1.2 =    600
    ]

    /// A footprint provider over an injected raw-byte table, surfacing
    /// `metadataUnavailable` for refs flagged unsizable or absent from the
    /// table. Every profile these fixtures back has an *explicit* context, so
    /// the context argument is never consulted — matching the original
    /// (pre-ladder) fixture behavior exactly.
    private static func provider(
        _ table: [ModelRef: Int64] = raw,
        unavailable: [ModelRef: String] = [:]
    ) -> (ModelRef, Int) -> Result<Int64, RepoMetadataError> {
        { ref, _ in
            if let reason = unavailable[ref] {
                return .failure(.metadataUnavailable(reason))
            }
            if let bytes = table[ref] {
                return .success(bytes)
            }
            return .failure(.metadataUnavailable("no footprint injected for \(ref.stringValue)"))
        }
    }

    /// A ``JointFit/resolve(profile:budgetBytes:footprint:nativeMaxContext:)``
    /// `nativeMaxContext` closure that fails the test if invoked — for a
    /// profile with an explicit context, the ladder must never run, so this
    /// closure must never be called.
    private static func neverCalledNativeMaxContext(_ ref: ModelRef) -> Result<Int, RepoMetadataError> {
        Issue.record("nativeMaxContext must not be called when ProfileDefinition.context is explicit")
        return .failure(.metadataUnavailable("nativeMaxContext should not be called"))
    }

    /// The portability profile: a standard ladder (32B-8bit → 32B-4bit → 14B),
    /// one flash, one embedding, all sized at the default explicit context.
    private static func ladderProfile() -> ProfileDefinition {
        ProfileDefinition(
            name: coderProfileName,
            description: "portability ladder",
            standard: [std32b8, std32b4, std14b4],
            flash: [flash3b],
            embedding: [embBge]
        )
    }

    private static func resolution(
        _ result: JointResolution,
        for slot: ModelSlot
    ) -> SlotResolution {
        result.slots.first { $0.slot == slot }!
    }

    // MARK: Portability

    @Test("big budget chooses the largest standard (32B-8bit)")
    func bigBudgetChoosesLargestStandard() throws {
        let result = try JointFit.resolve(
            profile: Self.ladderProfile(),
            budgetBytes: 50_000,
            footprint: Self.provider(),
            nativeMaxContext: Self.neverCalledNativeMaxContext
        )
        #expect(result.embedding == Self.embBge)
        #expect(result.standard == Self.std32b8)
        #expect(result.flash == Self.flash3b)
    }

    @Test("small budget falls through to 14B for the same profile")
    func smallBudgetFallsThroughToSmallestStandard() throws {
        let result = try JointFit.resolve(
            profile: Self.ladderProfile(),
            budgetBytes: 15_000,
            footprint: Self.provider(),
            nativeMaxContext: Self.neverCalledNativeMaxContext
        )
        #expect(result.standard == Self.std14b4)
        #expect(result.embedding == Self.embBge)
        #expect(result.flash == Self.flash3b)

        let std = Self.resolution(result, for: .standard)
        // The two bigger quants are recorded as too large, in preference order.
        #expect(std.considered[0].ref == Self.std32b8)
        #expect(std.considered[0].verdict == .tooLarge)
        #expect(std.considered[1].ref == Self.std32b4)
        #expect(std.considered[1].verdict == .tooLarge)
        #expect(std.considered[2].ref == Self.std14b4)
        #expect(std.considered[2].verdict == .chosen)
    }

    // MARK: Embedding-first reservation

    @Test("embedding reservation reduces the budget standard sees")
    func embeddingReservationReducesStandardBudget() throws {
        // 32B-8bit (×1.2 = 38_400) fits in 38_900 alone, but not after the
        // embedding's 600 is reserved (remaining 38_300) — so standard falls to
        // 32B-4bit. Proves the budget is shared and reduced embedding-first.
        let result = try JointFit.resolve(
            profile: Self.ladderProfile(),
            budgetBytes: 38_900,
            footprint: Self.provider(),
            nativeMaxContext: Self.neverCalledNativeMaxContext
        )
        #expect(result.standard == Self.std32b4)

        let emb = Self.resolution(result, for: .embedding)
        let std = Self.resolution(result, for: .standard)
        #expect(emb.remainingBudgetBytes == 38_900)
        #expect(std.remainingBudgetBytes == 38_300)
    }

    // MARK: ×1.2 margin

    @Test("estimatedFootprintBytes reflects the ×1.2 margin")
    func reportFootprintIsScaledByMargin() throws {
        let result = try JointFit.resolve(
            profile: Self.ladderProfile(),
            budgetBytes: 50_000,
            footprint: Self.provider(),
            nativeMaxContext: Self.neverCalledNativeMaxContext
        )
        let std = Self.resolution(result, for: .standard)
        // 32_000 raw × 1.2 = 38_400.
        #expect(std.considered[0].estimatedFootprintBytes == 38_400)
        let emb = Self.resolution(result, for: .embedding)
        #expect(emb.considered[0].estimatedFootprintBytes == 600)
    }

    @Test("a candidate is viable iff footprint × 1.2 <= remaining, inclusive")
    func marginBoundaryIsInclusive() throws {
        let profile = ProfileDefinition(
            name: "boundary",
            description: "exact-fit ladder",
            standard: [Self.std14b4],       // ×1.2 = 10_800
            flash: [Self.flash3b],          // ×1.2 =  2_400
            embedding: [Self.embBge]        // ×1.2 =    600
        )
        // Scaled sum is exactly 13_800. At the exact sum it resolves.
        let exact = try JointFit.resolve(
            profile: profile,
            budgetBytes: 13_800,
            footprint: Self.provider(),
            nativeMaxContext: Self.neverCalledNativeMaxContext
        )
        #expect(exact.flash == Self.flash3b)

        // One byte short, the last slot (flash) cannot fit.
        #expect(throws: ResolutionFailure.self) {
            try JointFit.resolve(
                profile: profile,
                budgetBytes: 13_799,
                footprint: Self.provider(),
                nativeMaxContext: Self.neverCalledNativeMaxContext
            )
        }
    }

    // MARK: Failure diagnostics

    @Test("an unsatisfiable profile throws with the unsatisfiable slot chosen == nil")
    func unsatisfiableSlotHasNilChosenInFailure() throws {
        let error = try #require(throws: ResolutionFailure.self) {
            try JointFit.resolve(
                profile: Self.ladderProfile(),
                budgetBytes: 5_000,
                footprint: Self.provider(),
                nativeMaxContext: Self.neverCalledNativeMaxContext
            )
        }
        #expect(error.profileName == Self.coderProfileName)
        #expect(error.budgetBytes == 5_000)

        // The failure carries every slot's resolution, not just the unsatisfiable one.
        #expect(error.slots.count == 3)
        #expect(error.slots.contains { $0.slot == .embedding })
        #expect(error.slots.contains { $0.slot == .flash })

        let std = error.slots.first { $0.slot == .standard }!
        #expect(std.chosen == nil)
        // Every standard candidate is recorded as too large.
        #expect(std.considered.allSatisfy { $0.verdict == .tooLarge })
    }

    @Test("failure description lists slots, candidates, footprints, and the budget")
    func failureDescriptionRendersDiagnostics() throws {
        let error = try #require(throws: ResolutionFailure.self) {
            try JointFit.resolve(
                profile: Self.ladderProfile(),
                budgetBytes: 5_000,
                footprint: Self.provider(),
                nativeMaxContext: Self.neverCalledNativeMaxContext
            )
        }
        let text = error.description
        #expect(text.contains(Self.coderProfileName))
        #expect(text.contains("5000"))
        #expect(text.contains(Self.std14b4.stringValue))
        #expect(text.contains("10800"))   // a candidate's ×1.2 footprint
    }

    // MARK: metadataUnavailable

    @Test("metadataUnavailable candidates are recorded and skipped, not chosen")
    func metadataUnavailableIsSkipped() throws {
        let profile = ProfileDefinition(
            name: "with-unsizable",
            description: "first candidate cannot be sized",
            standard: [Self.unsizable, Self.std14b4],
            flash: [Self.flash3b],
            embedding: [Self.embBge]
        )
        let result = try JointFit.resolve(
            profile: profile,
            budgetBytes: 50_000,
            footprint: Self.provider(unavailable: [Self.unsizable: "config.json is not present in the repo"]),
            nativeMaxContext: Self.neverCalledNativeMaxContext
        )
        #expect(result.standard == Self.std14b4)

        let std = Self.resolution(result, for: .standard)
        #expect(std.considered[0].ref == Self.unsizable)
        #expect(std.considered[0].estimatedFootprintBytes == nil)
        #expect(std.considered[0].verdict == .metadataUnavailable("config.json is not present in the repo"))
        #expect(std.considered[1].ref == Self.std14b4)
        #expect(std.considered[1].verdict == .chosen)
    }

    // MARK: - Context ladder (ProfileDefinition.context == nil)

    /// Ladder-test candidate references, distinct from the explicit-context
    /// fixtures above so the two families never cross-contaminate.
    private static let ladderBig: ModelRef = "org/ladder-big"
    private static let ladderSmall: ModelRef = "org/ladder-small"
    private static let ladderNativeFits: ModelRef = "org/ladder-native-fits"
    private static let ladderEmb: ModelRef = "org/ladder-emb"
    private static let ladderFlash: ModelRef = "org/ladder-flash"

    /// A footprint provider backed by real ``Footprint`` fixtures, so the
    /// byte figure genuinely scales with the context argument the ladder
    /// passes in — unlike ``provider(_:unavailable:)`` above, whose fixed
    /// tables never needed to vary with context.
    private static func ladderFootprint(
        _ table: [ModelRef: Footprint]
    ) -> (ModelRef, Int) -> Result<Int64, RepoMetadataError> {
        { ref, context in
            guard let footprint = table[ref] else {
                return .failure(.metadataUnavailable("no footprint injected for \(ref.stringValue)"))
            }
            return .success(footprint.footprint(context: context))
        }
    }

    /// A native-max-context provider over an injected table.
    private static func ladderNativeMax(
        _ table: [ModelRef: Int]
    ) -> (ModelRef) -> Result<Int, RepoMetadataError> {
        { ref in
            guard let native = table[ref] else {
                return .failure(.metadataUnavailable("no native max context injected for \(ref.stringValue)"))
            }
            return .success(native)
        }
    }

    /// Embedding/flash candidates with a flat, context-independent footprint
    /// (no KV cache: `layers: 0`) so every ladder scenario below reserves a
    /// constant 120 bytes (`100 × 1.2`) for each, regardless of which rung is
    /// under test.
    private static let ladderEmbFlashFootprints: [ModelRef: Footprint] = [
        ladderEmb: Footprint(weightBytes: 100, layers: 0, kvHeads: 0, headDim: 0),
        ladderFlash: Footprint(weightBytes: 100, layers: 0, kvHeads: 0, headDim: 0),
    ]

    /// A profile with `context: nil` — the ladder derives it — over the given
    /// standard candidates, plus the shared ladder embedding/flash candidates.
    private static func ladderProfile(standard: [ModelRef]) -> ProfileDefinition {
        ProfileDefinition(
            name: "ladder",
            description: "context is derived, not authored",
            standard: standard,
            flash: [Self.ladderFlash],
            embedding: [Self.ladderEmb],
            context: nil
        )
    }

    @Test("native max fits: the candidate resolves at its own native max context, capped")
    func nativeMaxFitsResolvesAtNativeMax() throws {
        // weightBytes: 0, coefficient 4 bytes/token (layers 1 × kvHeads 1 × headDim 1).
        // footprint(8192) = 32_768, × 1.2 = 39_322.
        let footprints = Self.ladderEmbFlashFootprints.merging(
            [Self.ladderNativeFits: Footprint(weightBytes: 0, layers: 1, kvHeads: 1, headDim: 1)]
        ) { _, new in new }
        let result = try JointFit.resolve(
            profile: Self.ladderProfile(standard: [Self.ladderNativeFits]),
            budgetBytes: 40_000,
            footprint: Self.ladderFootprint(footprints),
            nativeMaxContext: Self.ladderNativeMax([Self.ladderNativeFits: 8_192])
        )
        #expect(result.standard == Self.ladderNativeFits)
        let std = Self.resolution(result, for: .standard)
        #expect(std.contextTokens == 8_192)
        #expect(std.considered.count == 1)
        #expect(std.considered[0].verdict == .chosen)
        // Only the native-max rung was tried — it fit immediately, so the
        // ladder never had to step down.
        #expect(std.considered[0].ladderAttempts.count == 1)
        #expect(std.considered[0].ladderAttempts[0].contextTokens == 8_192)
        #expect(std.considered[0].ladderAttempts[0].fits == true)

        // Every slot in the resolution shares the same resolved context.
        #expect(Self.resolution(result, for: .embedding).contextTokens == 8_192)
        #expect(Self.resolution(result, for: .flash).contextTokens == 8_192)
    }

    @Test("step-down fits: a candidate too large at native max resolves at the largest fitting rung below it")
    func stepDownFitsResolvesAtLargestFittingRung() throws {
        // weightBytes: 0, coefficient 400 bytes/token (layers 1 × kvHeads 1 × headDim 100).
        // footprint(131_072) = 52_428_800, × 1.2 = 62_914_560 — too large.
        // footprint(65_536)  = 26_214_400, × 1.2 = 31_457_280 — too large.
        // footprint(32_768)  = 13_107_200, × 1.2 = 15_728_640 — fits.
        let footprints = Self.ladderEmbFlashFootprints.merging(
            [Self.ladderBig: Footprint(weightBytes: 0, layers: 1, kvHeads: 1, headDim: 100)]
        ) { _, new in new }
        // Budget covers embedding (120) + big@32_768 (15_728_640) + flash (120)
        // = 15_728_880, comfortably above that and comfortably below what
        // big@65_536 would need (31_457_520).
        let result = try JointFit.resolve(
            profile: Self.ladderProfile(standard: [Self.ladderBig]),
            budgetBytes: 15_800_000,
            footprint: Self.ladderFootprint(footprints),
            nativeMaxContext: Self.ladderNativeMax([Self.ladderBig: 131_072])
        )
        #expect(result.standard == Self.ladderBig)
        let std = Self.resolution(result, for: .standard)
        #expect(std.contextTokens == 32_768)
        #expect(std.considered[0].verdict == .chosen)

        let attempts = std.considered[0].ladderAttempts
        #expect(attempts.map(\.contextTokens) == [131_072, 65_536, 32_768])
        #expect(attempts.map(\.fits) == [false, false, true])
    }

    @Test("model-outer preference: a bigger model at a smaller rung beats a smaller model at a bigger rung")
    func modelOuterPreferenceBeatsSmallerModelAtBiggerContext() throws {
        // Same "big" fixture as the step-down test: fits only at 32_768.
        // "small" has no KV cache at all, so it trivially fits at its own
        // native max (131_072) — but big is preference-first, so if the
        // policy is truly model-outer/context-inner, big must win at 32_768
        // rather than small winning at 131_072.
        let footprints = Self.ladderEmbFlashFootprints.merging(
            [
                Self.ladderBig: Footprint(weightBytes: 0, layers: 1, kvHeads: 1, headDim: 100),
                Self.ladderSmall: Footprint(weightBytes: 100, layers: 0, kvHeads: 0, headDim: 0),
            ]
        ) { _, new in new }
        let result = try JointFit.resolve(
            profile: Self.ladderProfile(standard: [Self.ladderBig, Self.ladderSmall]),
            budgetBytes: 15_800_000,
            footprint: Self.ladderFootprint(footprints),
            nativeMaxContext: Self.ladderNativeMax([Self.ladderBig: 131_072, Self.ladderSmall: 131_072])
        )
        #expect(result.standard == Self.ladderBig)
        let std = Self.resolution(result, for: .standard)
        #expect(std.contextTokens == 32_768)
        #expect(std.considered.count == 2)
        #expect(std.considered[0].ref == Self.ladderBig)
        #expect(std.considered[0].verdict == .chosen)
        // The smaller, later-preference model was never even tried — it is
        // recorded only as skipped, not as a rejected/failed candidate.
        #expect(std.considered[1].ref == Self.ladderSmall)
        #expect(std.considered[1].verdict == .skippedHigherPreferenceChosen)
        #expect(std.considered[1].ladderAttempts.isEmpty)
    }

    @Test("nothing fits on any candidate at any rung throws ResolutionFailure with per-candidate ladder detail")
    func nothingFitsAtAnyRungThrowsWithLadderDetail() throws {
        let footprints = Self.ladderEmbFlashFootprints.merging(
            [
                Self.ladderBig: Footprint(weightBytes: 0, layers: 1, kvHeads: 1, headDim: 100),
                Self.ladderSmall: Footprint(weightBytes: 100, layers: 0, kvHeads: 0, headDim: 0),
            ]
        ) { _, new in new }
        // A budget of 1 byte can't even fit the embedding candidate (120),
        // so every rung of every standard candidate's ladder fails.
        let error = try #require(throws: ResolutionFailure.self) {
            try JointFit.resolve(
                profile: Self.ladderProfile(standard: [Self.ladderBig, Self.ladderSmall]),
                budgetBytes: 1,
                footprint: Self.ladderFootprint(footprints),
                nativeMaxContext: Self.ladderNativeMax([Self.ladderBig: 131_072, Self.ladderSmall: 131_072])
            )
        }
        let std = try #require(error.slots.first { $0.slot == .standard })
        #expect(std.chosen == nil)
        #expect(std.considered.count == 2)
        for candidate in std.considered {
            #expect(candidate.verdict == .tooLarge)
            // Six rungs: the native max (131_072) plus every step-down below it.
            #expect(candidate.ladderAttempts.count == 6)
            #expect(candidate.ladderAttempts.allSatisfy { $0.fits == false })
            #expect(candidate.ladderAttempts.map(\.contextTokens) == [131_072, 65_536, 32_768, 16_384, 8_192, 4_096])
        }
        // The description surfaces the ladder rungs, not just the top-level verdict.
        #expect(error.description.contains("131072 tokens"))
        #expect(error.description.contains("4096 tokens"))
    }

    @Test("an explicit context bypasses the ladder entirely: nativeMaxContext is never invoked")
    func explicitContextBypassesLadder() throws {
        let footprints = Self.ladderEmbFlashFootprints.merging(
            [Self.ladderNativeFits: Footprint(weightBytes: 0, layers: 1, kvHeads: 1, headDim: 1)]
        ) { _, new in new }
        let profile = ProfileDefinition(
            name: "explicit",
            description: "an authored, explicit context",
            standard: [Self.ladderNativeFits],
            flash: [Self.ladderFlash],
            embedding: [Self.ladderEmb],
            context: 8_192
        )
        let result = try JointFit.resolve(
            profile: profile,
            budgetBytes: 40_000,
            footprint: Self.ladderFootprint(footprints),
            nativeMaxContext: Self.neverCalledNativeMaxContext
        )
        #expect(result.standard == Self.ladderNativeFits)
        let std = Self.resolution(result, for: .standard)
        #expect(std.contextTokens == 8_192)
        // No ladder attempts are recorded for an explicit-context resolution.
        #expect(std.considered[0].ladderAttempts.isEmpty)
    }
}
