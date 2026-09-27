import Foundation
import FoundationModelsRouterTestSupport
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

    // MARK: Raw footprints (the joint fit charges these bytes as they are)

    private static let raw: [ModelRef: Int64] = [
        std32b8: 32_000,
        std32b4: 18_000,
        std14b4: 9_000,
        flash3b: 2_000,
        embBge: 500,
    ]

    /// A footprint provider over an injected raw-byte table, surfacing
    /// `metadataUnavailable` for refs flagged unsizable or absent from the
    /// table. Every profile these fixtures back has an *explicit* context, so
    /// the context argument is never consulted.
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
    /// profile with an explicit context, the window search must never run, so
    /// this closure must never be called.
    private static func neverCalledNativeMaxContext(_: ModelRef) -> Result<Int, RepoMetadataError> {
        Issue.record("nativeMaxContext must not be called when ProfileDefinition.context is explicit")
        return .failure(.metadataUnavailable("nativeMaxContext should not be called"))
    }

    /// The portability profile: standard candidates in preference order
    /// (32B-8bit → 32B-4bit → 14B), one flash, one embedding, all sized at the
    /// default explicit context.
    private static func portabilityProfile() -> ProfileDefinition {
        ProfileDefinition(
            name: coderProfileName,
            description: "portability preference order",
            standard: [std32b8, std32b4, std14b4],
            flash: [flash3b],
            embedding: [embBge],
            context: ScriptedSessionContext.tokens
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
            profile: Self.portabilityProfile(),
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
            profile: Self.portabilityProfile(),
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
        // 32B-8bit (32_000) fits in 32_300 alone, but not after the
        // embedding's 500 is reserved (remaining 31_800) — so standard falls to
        // 32B-4bit. Proves the budget is shared and reduced embedding-first.
        let result = try JointFit.resolve(
            profile: Self.portabilityProfile(),
            budgetBytes: 32_300,
            footprint: Self.provider(),
            nativeMaxContext: Self.neverCalledNativeMaxContext
        )
        #expect(result.standard == Self.std32b4)

        let emb = Self.resolution(result, for: .embedding)
        let std = Self.resolution(result, for: .standard)
        #expect(emb.remainingBudgetBytes == 32_300)
        #expect(std.remainingBudgetBytes == 31_800)
    }

    // MARK: Raw footprint estimate

    @Test("estimatedFootprintBytes is the raw footprint estimate")
    func reportFootprintIsTheRawEstimate() throws {
        let result = try JointFit.resolve(
            profile: Self.portabilityProfile(),
            budgetBytes: 50_000,
            footprint: Self.provider(),
            nativeMaxContext: Self.neverCalledNativeMaxContext
        )
        let std = Self.resolution(result, for: .standard)
        #expect(std.considered[0].estimatedFootprintBytes == 32_000)
        let emb = Self.resolution(result, for: .embedding)
        #expect(emb.considered[0].estimatedFootprintBytes == 500)
    }

    @Test("a candidate is viable iff its raw footprint <= remaining, inclusive")
    func fitBoundaryIsInclusive() throws {
        let profile = ProfileDefinition(
            name: "boundary",
            description: "exact-fit profile",
            standard: [Self.std14b4],
            flash: [Self.flash3b],
            embedding: [Self.embBge],
            context: ScriptedSessionContext.tokens
        )
        // The raw sum is exactly 11_500. At the exact sum it resolves.
        let exact = try JointFit.resolve(
            profile: profile,
            budgetBytes: 11_500,
            footprint: Self.provider(),
            nativeMaxContext: Self.neverCalledNativeMaxContext
        )
        #expect(exact.flash == Self.flash3b)

        // One byte short, the last slot (flash) cannot fit.
        #expect(throws: ResolutionFailure.self) {
            try JointFit.resolve(
                profile: profile,
                budgetBytes: 11_499,
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
                profile: Self.portabilityProfile(),
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
                profile: Self.portabilityProfile(),
                budgetBytes: 5_000,
                footprint: Self.provider(),
                nativeMaxContext: Self.neverCalledNativeMaxContext
            )
        }
        let text = error.description
        #expect(text.contains(Self.coderProfileName))
        #expect(text.contains("5000"))
        #expect(text.contains(Self.std14b4.stringValue))
        #expect(text.contains("9000"))   // a candidate's raw footprint
    }

    // MARK: metadataUnavailable

    @Test("metadataUnavailable candidates are recorded and skipped, not chosen")
    func metadataUnavailableIsSkipped() throws {
        let profile = ProfileDefinition(
            name: "with-unsizable",
            description: "first candidate cannot be sized",
            standard: [Self.unsizable, Self.std14b4],
            flash: [Self.flash3b],
            embedding: [Self.embBge],
            context: ScriptedSessionContext.tokens
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

    // MARK: - The largest window that fits (ProfileDefinition.context == nil)

    /// Window-search candidate references, distinct from the explicit-context
    /// fixtures above so the two families never cross-contaminate.
    private static let windowBig: ModelRef = "org/window-big"
    private static let windowSmall: ModelRef = "org/window-small"
    private static let windowNativeFits: ModelRef = "org/window-native-fits"
    private static let windowEmb: ModelRef = "org/window-emb"
    private static let windowFlash: ModelRef = "org/window-flash"

    /// The native max context of ``windowBig`` and ``windowSmall``.
    private static let windowBigNative = 131_072

    /// ``windowBig``'s architecture: no weights, 400 KV bytes for each token
    /// (`2 × layers 1 × kvHeads 1 × headDim 100 × 2`).
    private static let windowBigFootprint = Footprint(weightBytes: 0, layers: 1, kvHeads: 1, headDim: 100)

    /// A budget ``windowBig`` does not fit at its native window. The trio
    /// charges `100 + 400 × window + 100` bytes, so the largest window that
    /// fits is `(15_800_000 − 200) / 400`, floored: 39_499.
    private static let windowBigBudget: Int64 = 15_800_000

    /// The largest window at which ``windowBig``'s trio co-fits ``windowBigBudget``.
    private static let windowBigWindow = 39_499

    /// A footprint provider backed by real ``Footprint`` fixtures, so the
    /// byte figure scales with the context argument the window search passes
    /// in — unlike ``provider(_:unavailable:)`` above, whose fixed tables
    /// never needed to vary with context.
    private static func sizedFootprint(
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
    private static func nativeMaxTable(
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
    /// (no KV cache: `layers: 0`) so every window scenario below reserves a
    /// constant 100 bytes for each, whatever the window.
    private static let windowEmbFlashFootprints: [ModelRef: Footprint] = [
        windowEmb: Footprint(weightBytes: 100, layers: 0, kvHeads: 0, headDim: 0),
        windowFlash: Footprint(weightBytes: 100, layers: 0, kvHeads: 0, headDim: 0),
    ]

    /// A profile over the given standard candidates, plus the shared window
    /// embedding/flash candidates, at `context`. A `nil` context makes the
    /// window search derive it.
    private static func windowProfile(standard: [ModelRef], context: Int? = nil) -> ProfileDefinition {
        ProfileDefinition(
            name: "window",
            description: "context is derived, not authored",
            standard: standard,
            flash: [Self.windowFlash],
            embedding: [Self.windowEmb],
            context: context
        )
    }

    /// The footprint table with ``windowBig`` and ``windowSmall`` beside the
    /// flat embedding/flash candidates. ``windowSmall`` has no KV cache.
    private static let windowBigSmallFootprints = windowEmbFlashFootprints.merging(
        [
            windowBig: windowBigFootprint,
            windowSmall: Footprint(weightBytes: 100, layers: 0, kvHeads: 0, headDim: 0),
        ]
    ) { _, new in new }

    /// Resolves ``windowBig`` alone at an explicit `context` against
    /// ``windowBigBudget``, as one trio attempt at that context.
    private static func resolveWindowBig(atContext context: Int) throws -> JointResolution {
        try JointFit.resolve(
            profile: windowProfile(standard: [windowBig], context: context),
            budgetBytes: windowBigBudget,
            footprint: sizedFootprint(windowBigSmallFootprints),
            nativeMaxContext: neverCalledNativeMaxContext
        )
    }

    @Test("native max fits: the candidate resolves at its own native max context")
    func nativeMaxFitsResolvesAtNativeMax() throws {
        // weightBytes: 0, coefficient 4 bytes/token (layers 1 × kvHeads 1 × headDim 1).
        // footprint(8192) = 32_768.
        let nativeFitsFootprint = Footprint(weightBytes: 0, layers: 1, kvHeads: 1, headDim: 1)
        let footprints = Self.windowEmbFlashFootprints.merging(
            [Self.windowNativeFits: nativeFitsFootprint]
        ) { _, new in new }
        let result = try JointFit.resolve(
            profile: Self.windowProfile(standard: [Self.windowNativeFits]),
            budgetBytes: 40_000,
            footprint: Self.sizedFootprint(footprints),
            nativeMaxContext: Self.nativeMaxTable([Self.windowNativeFits: 8_192])
        )
        #expect(result.standard == Self.windowNativeFits)
        let std = Self.resolution(result, for: .standard)
        #expect(std.contextTokens == 8_192)
        #expect(std.considered.count == 1)
        #expect(std.considered[0].verdict == .chosen)
        // The native window fit, so the record states it as the fitted window.
        #expect(
            std.considered[0].windowFit
                == WindowFit(
                    nativeContextTokens: 8_192,
                    outcome: .fits(
                        contextTokens: 8_192,
                        estimatedFootprintBytes: nativeFitsFootprint.footprint(context: 8_192)
                    )
                )
        )

        // Every slot in the resolution shares the same resolved context.
        #expect(Self.resolution(result, for: .embedding).contextTokens == 8_192)
        #expect(Self.resolution(result, for: .flash).contextTokens == 8_192)
    }

    @Test("a candidate too large at its native window resolves at the largest window that fits")
    func tooLargeAtNativeResolvesAtLargestWindow() throws {
        let result = try JointFit.resolve(
            profile: Self.windowProfile(standard: [Self.windowBig]),
            budgetBytes: Self.windowBigBudget,
            footprint: Self.sizedFootprint(Self.windowBigSmallFootprints),
            nativeMaxContext: Self.nativeMaxTable([Self.windowBig: Self.windowBigNative])
        )
        #expect(result.standard == Self.windowBig)
        let std = Self.resolution(result, for: .standard)
        #expect(std.contextTokens == Self.windowBigWindow)
        #expect(std.considered[0].verdict == .chosen)

        // The report states the native window and the computed window.
        #expect(
            std.considered[0].windowFit
                == WindowFit(
                    nativeContextTokens: Self.windowBigNative,
                    outcome: .fits(
                        contextTokens: Self.windowBigWindow,
                        estimatedFootprintBytes: Self.windowBigFootprint.footprint(context: Self.windowBigWindow)
                    )
                )
        )
    }

    @Test("the computed window is the largest: the trio co-fits at it and not at one token more")
    func computedWindowIsTheLargestThatFits() throws {
        let atWindow = try Self.resolveWindowBig(atContext: Self.windowBigWindow)
        #expect(atWindow.standard == Self.windowBig)
        #expect(throws: ResolutionFailure.self) {
            try Self.resolveWindowBig(atContext: Self.windowBigWindow + 1)
        }
    }

    @Test("model-outer preference: a bigger model at a smaller window beats a smaller model at a bigger window")
    func modelOuterPreferenceBeatsSmallerModelAtBiggerContext() throws {
        // "big" fits only below its native window. "small" has no KV cache at
        // all, so it fits at its own native window — but big is
        // preference-first, so big must win at its computed window rather than
        // small winning at its native window.
        let result = try JointFit.resolve(
            profile: Self.windowProfile(standard: [Self.windowBig, Self.windowSmall]),
            budgetBytes: Self.windowBigBudget,
            footprint: Self.sizedFootprint(Self.windowBigSmallFootprints),
            nativeMaxContext: Self.nativeMaxTable(
                [Self.windowBig: Self.windowBigNative, Self.windowSmall: Self.windowBigNative]
            )
        )
        #expect(result.standard == Self.windowBig)
        let std = Self.resolution(result, for: .standard)
        #expect(std.contextTokens == Self.windowBigWindow)
        #expect(std.considered.count == 2)
        #expect(std.considered[0].ref == Self.windowBig)
        #expect(std.considered[0].verdict == .chosen)
        // The smaller, later-preference model was never even tried — it is
        // recorded only as skipped, not as a rejected/failed candidate.
        #expect(std.considered[1].ref == Self.windowSmall)
        #expect(std.considered[1].verdict == .skippedHigherPreferenceChosen)
        #expect(std.considered[1].windowFit == nil)
    }

    @Test("a candidate that does not fit at one token is reported as not fitting")
    func notFittingAtOneTokenIsReportedAsNotFitting() throws {
        // A budget of 1 byte cannot fit even the embedding candidate (100),
        // so no standard candidate co-fits the trio at a window of one token.
        let error = try #require(throws: ResolutionFailure.self) {
            try JointFit.resolve(
                profile: Self.windowProfile(standard: [Self.windowBig, Self.windowSmall]),
                budgetBytes: 1,
                footprint: Self.sizedFootprint(Self.windowBigSmallFootprints),
                nativeMaxContext: Self.nativeMaxTable(
                    [Self.windowBig: Self.windowBigNative, Self.windowSmall: Self.windowBigNative]
                )
            )
        }
        let std = try #require(error.slots.first { $0.slot == .standard })
        #expect(std.chosen == nil)
        #expect(std.considered.count == 2)
        for candidate in std.considered {
            #expect(candidate.verdict == .tooLarge)
            // The record states the native window, and that the candidate
            // itself blocked the window of one token.
            let footprint = try #require(Self.windowBigSmallFootprints[candidate.ref])
            #expect(
                candidate.windowFit
                    == WindowFit(
                        nativeContextTokens: Self.windowBigNative,
                        outcome: .blocked(
                            by: .standard,
                            estimatedFootprintBytes: footprint.footprint(context: 1)
                        )
                    )
            )
        }
        // The description states the native window and that no window fits.
        #expect(error.description.contains("native window 131072 tokens"))
        #expect(error.description.contains("no window fits"))
    }

    @Test("an explicit context skips the window search: nativeMaxContext is never invoked")
    func explicitContextSkipsWindowSearch() throws {
        let footprints = Self.windowEmbFlashFootprints.merging(
            [Self.windowNativeFits: Footprint(weightBytes: 0, layers: 1, kvHeads: 1, headDim: 1)]
        ) { _, new in new }
        let result = try JointFit.resolve(
            profile: Self.windowProfile(standard: [Self.windowNativeFits], context: 8_192),
            budgetBytes: 40_000,
            footprint: Self.sizedFootprint(footprints),
            nativeMaxContext: Self.neverCalledNativeMaxContext
        )
        #expect(result.standard == Self.windowNativeFits)
        let std = Self.resolution(result, for: .standard)
        #expect(std.contextTokens == 8_192)
        // No window search is recorded for an explicit-context resolution.
        #expect(std.considered[0].windowFit == nil)
    }

    // MARK: - Two generation slots on two references

    /// The `standard` candidate of the profiles below.
    private static let generationModel: ModelRef = "org/generation-standard"

    /// The same repository as ``generationModel``, pinned to a revision. The
    /// pool keys on the reference as the author wrote it, so this is a second
    /// model, whatever commit the two resolve to.
    private static let generationModelPinned: ModelRef = "org/generation-standard@abc123"

    /// The embedding candidate the profiles below pair with.
    private static let generationEmbedding: ModelRef = "org/generation-emb"

    /// The explicit working context the profiles below are authored at, which
    /// keeps the window search out of the arithmetic below.
    private static let generationContext = 100

    /// ``generationModel``'s architecture: 20 KV bytes for each token
    /// (`2 × layers 1 × kvHeads 1 × headDim 5 × 2`) over 10_000 weight bytes.
    private static let generationFootprint = Footprint(
        weightBytes: 10_000, layers: 1, kvHeads: 1, headDim: 5
    )

    /// ``generationEmbedding``'s raw footprint: weights alone, no KV cache.
    private static let generationEmbeddingRawBytes: Int64 = 500

    /// ``generationModel``'s whole raw footprint at ``generationContext``:
    /// 10_000 weight bytes plus a 2_000-byte KV cache.
    private static let generationRawBytes: Int64 = 12_000

    /// The budget the trio needs when each generation slot is charged its own
    /// whole footprint: `500 + 12_000 + 12_000`.
    private static let twoGenerationModelsBudget: Int64 = 24_500

    /// The footprint table the profiles below are sized against.
    private static let generationFootprints: [ModelRef: Footprint] = [
        generationModel: generationFootprint,
        generationModelPinned: generationFootprint,
        generationEmbedding: Footprint.embedder(weightBytes: generationEmbeddingRawBytes),
    ]

    /// A profile whose two generation slots each name one reference, sized at
    /// ``generationContext``.
    private static func generationProfile(standard: ModelRef, flash: ModelRef) -> ProfileDefinition {
        ProfileDefinition(
            name: "two-generation-models",
            description: "each generation slot names its own reference",
            standard: [standard],
            flash: [flash],
            embedding: [generationEmbedding],
            context: generationContext
        )
    }

    @Test("two differently spelled references at one repository are two models, each charged in full")
    func differentlySpelledReferencesAreChargedSeparately() throws {
        // The pool never resolves the spelling, so a pinned revision and an
        // unpinned one are two models and cost two full footprints.
        let profile = Self.generationProfile(standard: Self.generationModel, flash: Self.generationModelPinned)
        #expect(throws: ResolutionFailure.self) {
            try JointFit.resolve(
                profile: profile,
                budgetBytes: Self.twoGenerationModelsBudget - 1,
                footprint: Self.sizedFootprint(Self.generationFootprints),
                nativeMaxContext: Self.neverCalledNativeMaxContext
            )
        }
        let result = try JointFit.resolve(
            profile: profile,
            budgetBytes: Self.twoGenerationModelsBudget,
            footprint: Self.sizedFootprint(Self.generationFootprints),
            nativeMaxContext: Self.neverCalledNativeMaxContext
        )
        #expect(result.standard == Self.generationModel)
        #expect(result.flash == Self.generationModelPinned)
        #expect(Self.resolution(result, for: .flash).considered[0].chargedBytes == Self.generationRawBytes)
    }

    // MARK: - One reference named across the embedding and generation roles

    /// A reference named by both the embedding slot and the standard slot. The
    /// router loads an embedder and a generation model under two pool keys, so
    /// this reference costs the budget two whole containers.
    private static let crossRoleShared: ModelRef = "org/embedder-and-standard"

    /// The flash candidate the cross-role profile pairs with.
    private static let crossRoleFlash: ModelRef = "org/cross-role-flash"

    /// ``crossRoleFlash``'s raw footprint: weights alone, no KV cache.
    private static let crossRoleFlashRawBytes: Int64 = 100

    /// The budget the cross-role profile needs when the one reference pays for
    /// two containers: `12_000 × 2 + 100`.
    private static let crossRoleSeparateBudget: Int64 = 24_100

    /// The footprint table the cross-role profile is sized against.
    private static let crossRoleFootprints: [ModelRef: Footprint] = [
        crossRoleShared: generationFootprint,
        crossRoleFlash: Footprint(weightBytes: crossRoleFlashRawBytes, layers: 0, kvHeads: 0, headDim: 0),
    ]

    /// A profile that names one reference in the embedding slot and in the
    /// standard slot, sized at ``generationContext``.
    private static func crossRoleProfile() -> ProfileDefinition {
        ProfileDefinition(
            name: "cross-role",
            description: "one reference serves the embedding slot and a generation slot",
            standard: [crossRoleShared],
            flash: [crossRoleFlash],
            embedding: [crossRoleShared],
            context: generationContext
        )
    }

    @Test("one reference in an embedding slot and a generation slot pays for two containers")
    func crossRoleReferenceIsChargedForTwoContainers() throws {
        let result = try JointFit.resolve(
            profile: Self.crossRoleProfile(),
            budgetBytes: Self.crossRoleSeparateBudget,
            footprint: Self.sizedFootprint(Self.crossRoleFootprints),
            nativeMaxContext: Self.neverCalledNativeMaxContext
        )
        let embeddingCharge = try #require(
            Self.resolution(result, for: .embedding).considered[0].chargedBytes
        )
        let standardCharge = try #require(
            Self.resolution(result, for: .standard).considered[0].chargedBytes
        )

        // An embedder and a generation model are different container types
        // under different pool keys. So the generation slot pays the whole
        // footprint, not the KV cache alone.
        #expect(embeddingCharge == Self.generationRawBytes)
        #expect(standardCharge == Self.generationRawBytes)
    }

    @Test("one reference across the embedding and generation roles does not fit on one container's budget")
    func crossRoleReferenceDoesNotFitOnOneContainerBudget() throws {
        // One byte below two whole containers, the flash candidate no longer
        // fits — so both charges really are full ones.
        #expect(throws: ResolutionFailure.self) {
            try JointFit.resolve(
                profile: Self.crossRoleProfile(),
                budgetBytes: Self.crossRoleSeparateBudget - 1,
                footprint: Self.sizedFootprint(Self.crossRoleFootprints),
                nativeMaxContext: Self.neverCalledNativeMaxContext
            )
        }
    }

    // MARK: - The profile the field report failed on

    /// The `multitool-cli-demo` generation model. The field report named it in
    /// both the `standard` and the `flash` slot. The two slots must now use
    /// two different models, so the profile below gives `flash`
    /// ``multitoolFlash``.
    private static let multitoolGeneration: ModelRef = "org/Qwen3.8-27B-mxfp4"

    /// The smaller generation model the `flash` slot of the profile below names.
    private static let multitoolFlash: ModelRef = "org/Qwen3-1.7B-4bit"

    /// The `multitool-cli-demo` embedding model.
    private static let multitoolEmbedding: ModelRef = "org/Qwen3-Embedding-0.6B-4bit-DWQ"

    /// The generation model's architecture, reconstructed from the report the
    /// field printed. The report printed each figure with an overhead factor
    /// that the fit no longer applies. The raw figures are 32393927268 bytes
    /// at 262144 tokens down to 15482493540 at 4096.
    private static let multitoolGenerationFootprint = Footprint(
        weightBytes: 15_214_058_084, layers: 64, kvHeads: 8, headDim: 32
    )

    /// The flash model's architecture: 1_000_000_000 weight bytes and 114_688
    /// KV bytes for each token (`2 × layers 28 × kvHeads 8 × headDim 128 × 2`).
    private static let multitoolFlashFootprint = Footprint(
        weightBytes: 1_000_000_000, layers: 28, kvHeads: 8, headDim: 128
    )

    /// The embedding model's raw weight bytes. The field report printed them
    /// with the overhead factor that the fit no longer applies.
    private static let multitoolEmbeddingWeightBytes: Int64 = 335_296_756

    /// The host budget the field report failed against.
    private static let multitoolBudgetBytes: Int64 = 26_800_603_136

    /// The generation model's native max context.
    private static let multitoolNativeMaxContext = 262_144

    /// The largest window at which the trio co-fits: the fixed bytes are the
    /// three models' weights, `16_549_354_840`, and each token adds
    /// `65_536 + 114_688 = 180_224` KV bytes over the two generation models.
    /// `(26_800_603_136 − 16_549_354_840) / 180_224`, floored, is 56_880.
    private static let multitoolResolvedContext = 56_880

    /// The footprint table the `multitool-cli-demo` profile is sized against.
    private static let multitoolFootprints: [ModelRef: Footprint] = [
        multitoolGeneration: multitoolGenerationFootprint,
        multitoolFlash: multitoolFlashFootprint,
        multitoolEmbedding: Footprint.embedder(weightBytes: multitoolEmbeddingWeightBytes),
    ]

    /// The reported profile with a separate flash model: one generation model
    /// for `standard`, ``multitoolFlash`` for `flash`, one embedding model, and
    /// `context` (`nil` to derive it).
    private static func multitoolProfile(context: Int? = nil) -> ProfileDefinition {
        ProfileDefinition(
            name: "multitool-cli-demo",
            description: "the standard and flash slots name two different models",
            standard: [multitoolGeneration],
            flash: [multitoolFlash],
            embedding: [multitoolEmbedding],
            context: context
        )
    }

    /// Resolves ``multitoolProfile(context:)`` against the reported budget.
    private static func resolveMultitool(context: Int?) throws -> JointResolution {
        try JointFit.resolve(
            profile: multitoolProfile(context: context),
            budgetBytes: multitoolBudgetBytes,
            footprint: sizedFootprint(multitoolFootprints),
            nativeMaxContext: nativeMaxTable([multitoolGeneration: multitoolNativeMaxContext])
        )
    }

    @Test("the multitool-cli-demo profile with a separate flash model co-fits the budget it failed against")
    func multitoolProfileCoFitsItsReportedBudget() throws {
        let result = try Self.resolveMultitool(context: nil)
        #expect(result.standard == Self.multitoolGeneration)
        #expect(result.flash == Self.multitoolFlash)
        #expect(result.embedding == Self.multitoolEmbedding)
        #expect(Self.resolution(result, for: .standard).contextTokens == Self.multitoolResolvedContext)
    }

    @Test("the multitool-cli-demo window is the largest: one token more does not co-fit")
    func multitoolWindowIsTheLargestThatFits() throws {
        _ = try Self.resolveMultitool(context: Self.multitoolResolvedContext)
        #expect(throws: ResolutionFailure.self) {
            try Self.resolveMultitool(context: Self.multitoolResolvedContext + 1)
        }
    }

    // MARK: - Verdicts that contradict each other

    /// An embedding candidate too large for ``blockedByEmbeddingBudget``, so
    /// the embedding slot blocks the trio at every window.
    private static let oversizedEmbedding: ModelRef = "org/oversized-emb"

    /// The raw footprint of ``oversizedEmbedding``: more than ``blockedByEmbeddingBudget``.
    private static let oversizedEmbeddingRawBytes: Int64 = 1_000_000

    /// A budget the generation models fit comfortably and the embedding model
    /// does not.
    private static let blockedByEmbeddingBudget: Int64 = 500_000

    /// The standard generation candidate's native max context.
    private static let blockedByEmbeddingNativeMax = 8_192

    /// The footprint table for the embedding-blocked profile.
    private static let blockedByEmbeddingFootprints: [ModelRef: Footprint] = [
        generationModel: generationFootprint,
        crossRoleFlash: Footprint(weightBytes: crossRoleFlashRawBytes, layers: 0, kvHeads: 0, headDim: 0),
        oversizedEmbedding: Footprint.embedder(weightBytes: oversizedEmbeddingRawBytes),
    ]

    /// A profile whose embedding slot cannot fit, while its two generation
    /// models fit at every window.
    private static func blockedByEmbeddingProfile() -> ProfileDefinition {
        ProfileDefinition(
            name: "blocked-by-embedding",
            description: "the embedding slot is what blocks the trio",
            standard: [generationModel],
            flash: [crossRoleFlash],
            embedding: [oversizedEmbedding],
            context: nil
        )
    }

    /// Resolves ``blockedByEmbeddingProfile()`` and returns the failure it
    /// always throws, so both tests below read one scenario.
    private static func blockedByEmbeddingFailure() throws -> ResolutionFailure {
        try #require(throws: ResolutionFailure.self) {
            try JointFit.resolve(
                profile: blockedByEmbeddingProfile(),
                budgetBytes: blockedByEmbeddingBudget,
                footprint: sizedFootprint(blockedByEmbeddingFootprints),
                nativeMaxContext: nativeMaxTable([generationModel: blockedByEmbeddingNativeMax])
            )
        }
    }

    /// Records an issue for every candidate one slot reported too large while a
    /// later slot reported the identical candidate chosen at a budget no
    /// smaller. The two verdicts cannot both be right, and that contradictory
    /// pair is what the field report on this defect carried.
    private static func expectNoContradictoryVerdicts(_ slots: [SlotResolution]) {
        for (index, slot) in slots.enumerated() {
            let rejected = slot.considered.filter { $0.verdict == .tooLarge }.map(\.ref)
            for later in slots[(index + 1)...]
            where later.remainingBudgetBytes >= slot.remainingBudgetBytes {
                guard let accepted = later.chosen, rejected.contains(accepted) else { continue }
                let message: String = """
                    \(slot.slot.rawValue) reported \(accepted.stringValue) too large at \
                    \(slot.remainingBudgetBytes) bytes, and \(later.slot.rawValue) chose it at \
                    \(later.remainingBudgetBytes) bytes
                    """
                Issue.record(Comment(rawValue: message))
            }
        }
    }

    @Test("no slot is reported too large at a budget a later slot accepts the same candidate at")
    func noSlotIsTooLargeWhereALaterSlotAcceptsTheSameCandidate() throws {
        let error = try Self.blockedByEmbeddingFailure()
        Self.expectNoContradictoryVerdicts(error.slots)
    }

    @Test("a window another slot blocked is not rendered as this candidate being too large")
    func windowBlockedByAnotherSlotIsNotRenderedAsTooLarge() throws {
        let error = try Self.blockedByEmbeddingFailure()
        let text = error.description
        #expect(text.contains("trio blocked by embedding"))
        #expect(!text.contains("\(Self.generationModel.stringValue) — unsized: too large"))
    }

    // MARK: - The model's window is the default context

    /// The native max context of ``windowNativeFits`` in the tests below.
    private static let modelWindowNative = 4_096

    /// A budget far above what the trio charges at ``modelWindowNative``.
    private static let modelWindowBudget: Int64 = 1_000_000

    /// The footprint table for a trio whose standard slot names ``windowNativeFits``.
    private static let modelWindowFootprints = windowEmbFlashFootprints.merging(
        [windowNativeFits: Footprint(weightBytes: 0, layers: 1, kvHeads: 1, headDim: 1)]
    ) { _, new in new }

    @Test("a profile made with no context argument has no context, and resolves at the model's window")
    func profileWithNoContextArgumentResolvesAtTheModelsWindow() throws {
        let profile = ProfileDefinition(
            name: "model-window",
            description: "names no context",
            standard: [Self.windowNativeFits],
            flash: [Self.windowFlash],
            embedding: [Self.windowEmb]
        )
        #expect(profile.context == nil)

        let result = try JointFit.resolve(
            profile: profile,
            budgetBytes: Self.modelWindowBudget,
            footprint: Self.sizedFootprint(Self.modelWindowFootprints),
            nativeMaxContext: Self.nativeMaxTable([Self.windowNativeFits: Self.modelWindowNative])
        )
        #expect(Self.resolution(result, for: .standard).contextTokens == Self.modelWindowNative)
    }

    @Test("a profile with no standard candidate fails with no window, and no slot is sized")
    func noStandardCandidateFailsWithNoWindow() throws {
        let failure = try #require(throws: NoWindowFailure.self) {
            try JointFit.resolve(
                profile: Self.windowProfile(standard: []),
                budgetBytes: Self.modelWindowBudget,
                footprint: Self.sizedFootprint(Self.modelWindowFootprints),
                nativeMaxContext: Self.neverCalledNativeMaxContext
            )
        }
        #expect(failure.standardConsidered.isEmpty)
    }

    @Test("a profile whose native windows cannot be read reports each candidate and no context")
    func unreadableWindowsFailWithNoWindow() throws {
        let failure = try #require(throws: NoWindowFailure.self) {
            try JointFit.resolve(
                profile: Self.windowProfile(standard: [Self.windowBig, Self.windowSmall]),
                budgetBytes: Self.modelWindowBudget,
                footprint: Self.sizedFootprint(Self.modelWindowFootprints),
                nativeMaxContext: Self.nativeMaxTable([:])
            )
        }
        let expectedVerdicts = [Self.windowBig, Self.windowSmall].map {
            Verdict.metadataUnavailable("no native max context injected for \($0.stringValue)")
        }
        #expect(failure.standardConsidered.map(\.verdict) == expectedVerdicts)
        #expect(failure.description.contains("There is no context, so no slot was sized."))
    }
}
