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

    /// A ``JointFit/resolve(profile:budgetBytes:footprint:sessionBytes:nativeMaxContext:)``
    /// `nativeMaxContext` closure that fails the test if invoked — for a
    /// profile with an explicit context, the window search must never run, so
    /// this closure must never be called.
    private static func neverCalledNativeMaxContext(_ ref: ModelRef) -> Result<Int, RepoMetadataError> {
        Issue.record("nativeMaxContext must not be called when ProfileDefinition.context is explicit")
        return .failure(.metadataUnavailable("nativeMaxContext should not be called"))
    }

    /// A ``JointFit/resolve(profile:budgetBytes:footprint:sessionBytes:nativeMaxContext:)``
    /// `sessionBytes` closure that fails the test if invoked. Only a slot that
    /// reuses an earlier slot's resident container charges a per-session KV
    /// cache, so a profile whose slots name no one container twice must never
    /// reach this closure.
    private static func neverCalledSessionBytes(
        _ ref: ModelRef, _ context: Int
    ) -> Result<Int64, RepoMetadataError> {
        Issue.record("sessionBytes must not be called when no two slots share one container")
        return .failure(.metadataUnavailable("sessionBytes should not be called"))
    }

    /// The per-session KV cache of an injected ``Footprint`` table — the part
    /// of a footprint a second slot on one resident container still pays for.
    ///
    /// It is the absolute figure, never discounted for residency, exactly as
    /// the router's own session-cache closure is.
    ///
    /// - Parameter table: The footprints every reference is sized from.
    /// - Returns: A session-cache closure over `table`.
    private static func sizedSessionBytes(
        _ table: [ModelRef: Footprint]
    ) -> (ModelRef, Int) -> Result<Int64, RepoMetadataError> {
        { ref, context in
            guard let footprint = table[ref] else {
                return .failure(.metadataUnavailable("no footprint injected for \(ref.stringValue)"))
            }
            return .success(footprint.kvBytes(context: context))
        }
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
            profile: Self.portabilityProfile(),
            budgetBytes: 50_000,
            footprint: Self.provider(),
            sessionBytes: Self.neverCalledSessionBytes,
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
            sessionBytes: Self.neverCalledSessionBytes,
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
            profile: Self.portabilityProfile(),
            budgetBytes: 38_900,
            footprint: Self.provider(),
            sessionBytes: Self.neverCalledSessionBytes,
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
            profile: Self.portabilityProfile(),
            budgetBytes: 50_000,
            footprint: Self.provider(),
            sessionBytes: Self.neverCalledSessionBytes,
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
            description: "exact-fit profile",
            standard: [Self.std14b4],       // ×1.2 = 10_800
            flash: [Self.flash3b],          // ×1.2 =  2_400
            embedding: [Self.embBge]        // ×1.2 =    600
        )
        // Scaled sum is exactly 13_800. At the exact sum it resolves.
        let exact = try JointFit.resolve(
            profile: profile,
            budgetBytes: 13_800,
            footprint: Self.provider(),
            sessionBytes: Self.neverCalledSessionBytes,
            nativeMaxContext: Self.neverCalledNativeMaxContext
        )
        #expect(exact.flash == Self.flash3b)

        // One byte short, the last slot (flash) cannot fit.
        #expect(throws: ResolutionFailure.self) {
            try JointFit.resolve(
                profile: profile,
                budgetBytes: 13_799,
                footprint: Self.provider(),
                sessionBytes: Self.neverCalledSessionBytes,
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
                sessionBytes: Self.neverCalledSessionBytes,
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
                sessionBytes: Self.neverCalledSessionBytes,
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
            sessionBytes: Self.neverCalledSessionBytes,
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
    /// charges `120 + 480 × window + 120` bytes, so the largest window that
    /// fits is `(15_800_000 − 240) / 480`, floored: 32_916.
    private static let windowBigBudget: Int64 = 15_800_000

    /// The largest window at which ``windowBig``'s trio co-fits ``windowBigBudget``.
    private static let windowBigWindow = 32_916

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
    /// constant 120 bytes (`100 × 1.2`) for each, whatever the window.
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
            sessionBytes: neverCalledSessionBytes,
            nativeMaxContext: neverCalledNativeMaxContext
        )
    }

    @Test("native max fits: the candidate resolves at its own native max context")
    func nativeMaxFitsResolvesAtNativeMax() throws {
        // weightBytes: 0, coefficient 4 bytes/token (layers 1 × kvHeads 1 × headDim 1).
        // footprint(8192) = 32_768, × 1.2 = 39_322.
        let nativeFitsFootprint = Footprint(weightBytes: 0, layers: 1, kvHeads: 1, headDim: 1)
        let footprints = Self.windowEmbFlashFootprints.merging(
            [Self.windowNativeFits: nativeFitsFootprint]
        ) { _, new in new }
        let result = try JointFit.resolve(
            profile: Self.windowProfile(standard: [Self.windowNativeFits]),
            budgetBytes: 40_000,
            footprint: Self.sizedFootprint(footprints),
            sessionBytes: Self.neverCalledSessionBytes,
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
                        estimatedFootprintBytes: JointFit.withMargin(nativeFitsFootprint.footprint(context: 8_192))
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
            sessionBytes: Self.neverCalledSessionBytes,
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
                        estimatedFootprintBytes: JointFit.withMargin(
                            Self.windowBigFootprint.footprint(context: Self.windowBigWindow)
                        )
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
            sessionBytes: Self.neverCalledSessionBytes,
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
        // A budget of 1 byte cannot fit even the embedding candidate (120),
        // so no standard candidate co-fits the trio at a window of one token.
        let error = try #require(throws: ResolutionFailure.self) {
            try JointFit.resolve(
                profile: Self.windowProfile(standard: [Self.windowBig, Self.windowSmall]),
                budgetBytes: 1,
                footprint: Self.sizedFootprint(Self.windowBigSmallFootprints),
                sessionBytes: Self.neverCalledSessionBytes,
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
                            estimatedFootprintBytes: JointFit.withMargin(footprint.footprint(context: 1))
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
            sessionBytes: Self.neverCalledSessionBytes,
            nativeMaxContext: Self.neverCalledNativeMaxContext
        )
        #expect(result.standard == Self.windowNativeFits)
        let std = Self.resolution(result, for: .standard)
        #expect(std.contextTokens == 8_192)
        // No window search is recorded for an explicit-context resolution.
        #expect(std.considered[0].windowFit == nil)
    }

    // MARK: - One reference named by two slots

    /// A reference named by both the `standard` and the `flash` slot. The two
    /// slots load one resident container for it, so its weights cost the
    /// budget one time.
    private static let sharedGeneration: ModelRef = "org/shared-standard-flash"

    /// The same repository as ``sharedGeneration``, pinned to a revision. The
    /// pool keys on the reference as the author wrote it, so this is a second
    /// container whatever commit the two resolve to.
    private static let sharedGenerationPinned: ModelRef = "org/shared-standard-flash@abc123"

    /// The embedding candidate the shared-reference profiles pair with.
    private static let sharedEmbedding: ModelRef = "org/shared-emb"

    /// The explicit working context the shared-reference profiles are authored
    /// at, which keeps the window search out of the arithmetic below.
    private static let sharedContext = 100

    /// ``sharedGeneration``'s architecture: 20 KV bytes for each token
    /// (`2 × layers 1 × kvHeads 1 × headDim 5 × 2`) over 10_000 weight bytes.
    private static let sharedGenerationFootprint = Footprint(
        weightBytes: 10_000, layers: 1, kvHeads: 1, headDim: 5
    )

    /// ``sharedEmbedding``'s raw footprint: weights alone, no KV cache.
    private static let sharedEmbeddingRawBytes: Int64 = 500

    /// ``sharedGeneration``'s whole raw footprint at ``sharedContext``: 10_000
    /// weight bytes plus a 2_000-byte KV cache.
    private static let sharedGenerationRawBytes: Int64 = 12_000

    /// ``sharedGeneration``'s raw KV cache at ``sharedContext``, which is the
    /// part a second slot on the same container still pays for.
    private static let sharedSessionRawBytes: Int64 = 2_000

    /// The budget that fits the trio once the shared weights are reserved a
    /// single time: `(500 + 12_000 + 2_000) × 1.2`.
    private static let sharedDedupedBudget: Int64 = 17_400

    /// The budget the trio needs when the two generation slots are charged for
    /// two separate containers: `600 + 14_400 + 14_400`.
    private static let sharedSeparateBudget: Int64 = 29_400

    /// The footprint table the shared-reference profiles are sized against.
    private static let sharedFootprints: [ModelRef: Footprint] = [
        sharedGeneration: sharedGenerationFootprint,
        sharedGenerationPinned: sharedGenerationFootprint,
        sharedEmbedding: Footprint.embedder(weightBytes: sharedEmbeddingRawBytes),
    ]

    /// A profile whose two generation slots each name one reference, sized at
    /// ``sharedContext``.
    private static func sharedProfile(standard: ModelRef, flash: ModelRef) -> ProfileDefinition {
        ProfileDefinition(
            name: "shared-generation",
            description: "one reference can serve both generation slots",
            standard: [standard],
            flash: [flash],
            embedding: [sharedEmbedding],
            context: sharedContext
        )
    }

    @Test("a reference named by two slots reserves its weights once and its KV cache twice")
    func sharedReferenceReservesWeightsOnce() throws {
        let result = try JointFit.resolve(
            profile: Self.sharedProfile(standard: Self.sharedGeneration, flash: Self.sharedGeneration),
            budgetBytes: Self.sharedDedupedBudget,
            footprint: Self.sizedFootprint(Self.sharedFootprints),
            sessionBytes: Self.sizedSessionBytes(Self.sharedFootprints),
            nativeMaxContext: Self.neverCalledNativeMaxContext
        )
        #expect(result.standard == Self.sharedGeneration)
        #expect(result.flash == Self.sharedGeneration)

        // One byte below the deduped total, the second slot's own KV cache no
        // longer fits — so the KV term really is charged a second time.
        #expect(throws: ResolutionFailure.self) {
            try JointFit.resolve(
                profile: Self.sharedProfile(standard: Self.sharedGeneration, flash: Self.sharedGeneration),
                budgetBytes: Self.sharedDedupedBudget - 1,
                footprint: Self.sizedFootprint(Self.sharedFootprints),
                sessionBytes: Self.sizedSessionBytes(Self.sharedFootprints),
                nativeMaxContext: Self.neverCalledNativeMaxContext
            )
        }
    }

    @Test("the margin is applied once to the deduped total, not twice to the shared weights")
    func marginIsAppliedOnceToTheDedupedTotal() throws {
        let result = try JointFit.resolve(
            profile: Self.sharedProfile(standard: Self.sharedGeneration, flash: Self.sharedGeneration),
            budgetBytes: Self.sharedDedupedBudget,
            footprint: Self.sizedFootprint(Self.sharedFootprints),
            sessionBytes: Self.sizedSessionBytes(Self.sharedFootprints),
            nativeMaxContext: Self.neverCalledNativeMaxContext
        )
        let standard = Self.resolution(result, for: .standard)
        let flash = Self.resolution(result, for: .flash)
        let standardCharge = try #require(standard.considered[0].chargedBytes)
        let flashCharge = try #require(flash.considered[0].chargedBytes)

        // Standard pays for the whole container. Flash pays for its own KV
        // cache alone, while its report still names the whole footprint, so a
        // reader sees the size of the model beside what it cost.
        #expect(standardCharge == JointFit.withMargin(Self.sharedGenerationRawBytes))
        #expect(flashCharge == JointFit.withMargin(Self.sharedSessionRawBytes))
        #expect(
            flash.considered[0].estimatedFootprintBytes
                == JointFit.withMargin(Self.sharedGenerationRawBytes)
        )

        // The two charges together are one margin over the deduped raw total,
        // so the shared weights carry the × 1.2 exactly once.
        #expect(
            standardCharge + flashCharge
                == JointFit.withMargin(Self.sharedGenerationRawBytes + Self.sharedSessionRawBytes)
        )
    }

    @Test("a slot reusing an earlier slot's container renders both its footprint and its charge")
    func sharedReferenceRendersBothFootprintAndCharge() throws {
        let error = try #require(throws: ResolutionFailure.self) {
            try JointFit.resolve(
                profile: Self.sharedProfile(standard: Self.sharedGeneration, flash: Self.sharedGeneration),
                budgetBytes: Self.sharedDedupedBudget - 1,
                footprint: Self.sizedFootprint(Self.sharedFootprints),
                sessionBytes: Self.sizedSessionBytes(Self.sharedFootprints),
                nativeMaxContext: Self.neverCalledNativeMaxContext
            )
        }
        let charge = JointFit.withMargin(Self.sharedSessionRawBytes)
        #expect(
            error.description.contains(
                "\(charge) bytes charged; an earlier slot already reserved the weights"
            )
        )
        #expect(error.description.contains("\(JointFit.withMargin(Self.sharedGenerationRawBytes)) bytes"))
    }

    @Test("two differently spelled references at one repository are reserved separately")
    func differentlySpelledReferencesAreReservedSeparately() throws {
        // The pool never resolves the spelling, so a pinned revision and an
        // unpinned one are two containers and cost two full footprints.
        #expect(throws: ResolutionFailure.self) {
            try JointFit.resolve(
                profile: Self.sharedProfile(
                    standard: Self.sharedGeneration, flash: Self.sharedGenerationPinned
                ),
                budgetBytes: Self.sharedDedupedBudget,
                footprint: Self.sizedFootprint(Self.sharedFootprints),
                sessionBytes: Self.sizedSessionBytes(Self.sharedFootprints),
                nativeMaxContext: Self.neverCalledNativeMaxContext
            )
        }
        let result = try JointFit.resolve(
            profile: Self.sharedProfile(
                standard: Self.sharedGeneration, flash: Self.sharedGenerationPinned
            ),
            budgetBytes: Self.sharedSeparateBudget,
            footprint: Self.sizedFootprint(Self.sharedFootprints),
            sessionBytes: Self.sizedSessionBytes(Self.sharedFootprints),
            nativeMaxContext: Self.neverCalledNativeMaxContext
        )
        #expect(result.standard == Self.sharedGeneration)
        #expect(result.flash == Self.sharedGenerationPinned)
    }

    // MARK: - A reference the router already holds resident

    /// The budget the trio needs when the router already holds the shared
    /// generation container: the embedding model, plus the second generation
    /// session's own KV cache. `(500 × 1.2) + (2_000 × 1.2)`.
    private static let sharedResidentBudget: Int64 = 3_000

    /// A footprint provider shaped like the router's own, which answers a
    /// *marginal* cost rather than an absolute one: a reference the pool
    /// already holds at the working context costs nothing more, so it answers
    /// zero there. Every other question is answered from `table`.
    ///
    /// - Parameters:
    ///   - table: The footprints every reference is sized from.
    ///   - resident: The references the pool already holds.
    ///   - residentContext: The working context the pool holds them at.
    /// - Returns: A footprint closure with the router's own residency rule.
    private static func poolResidentFootprint(
        _ table: [ModelRef: Footprint],
        resident: Set<ModelRef>,
        residentContext: Int
    ) -> (ModelRef, Int) -> Result<Int64, RepoMetadataError> {
        let sized = sizedFootprint(table)
        return { ref, context in
            guard resident.contains(ref), context == residentContext else {
                return sized(ref, context)
            }
            return .success(0)
        }
    }

    @Test("a pool-resident reference named by two generation slots still pays for the second session")
    func residentSharedReferenceChargesTheSecondSession() throws {
        let result = try JointFit.resolve(
            profile: Self.sharedProfile(standard: Self.sharedGeneration, flash: Self.sharedGeneration),
            budgetBytes: Self.sharedResidentBudget,
            footprint: Self.poolResidentFootprint(
                Self.sharedFootprints,
                resident: [Self.sharedGeneration],
                residentContext: Self.sharedContext
            ),
            sessionBytes: Self.sizedSessionBytes(Self.sharedFootprints),
            nativeMaxContext: Self.neverCalledNativeMaxContext
        )
        let standard = Self.resolution(result, for: .standard)
        let flash = Self.resolution(result, for: .flash)

        // The router already holds the container, so the first generation slot
        // costs the budget nothing more.
        #expect(standard.considered[0].chargedBytes == 0)
        // The second slot opens a session of its own, and that session
        // materializes a KV cache of its own. The pool holds no such cache, so
        // the second slot pays for it.
        #expect(flash.considered[0].chargedBytes == JointFit.withMargin(Self.sharedSessionRawBytes))
    }

    @Test("a pool-resident reference in two generation slots needs budget for the second KV cache")
    func residentSharedReferenceNeedsBudgetForTheSecondSession() throws {
        // One byte below the second session's own KV cache, the trio cannot
        // co-fit — so the resident path really does charge that cache.
        #expect(throws: ResolutionFailure.self) {
            try JointFit.resolve(
                profile: Self.sharedProfile(standard: Self.sharedGeneration, flash: Self.sharedGeneration),
                budgetBytes: Self.sharedResidentBudget - 1,
                footprint: Self.poolResidentFootprint(
                    Self.sharedFootprints,
                    resident: [Self.sharedGeneration],
                    residentContext: Self.sharedContext
                ),
                sessionBytes: Self.sizedSessionBytes(Self.sharedFootprints),
                nativeMaxContext: Self.neverCalledNativeMaxContext
            )
        }
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
    /// two containers: `(12_000 × 1.2) × 2 + (100 × 1.2)`.
    private static let crossRoleSeparateBudget: Int64 = 28_920

    /// The footprint table the cross-role profile is sized against.
    private static let crossRoleFootprints: [ModelRef: Footprint] = [
        crossRoleShared: sharedGenerationFootprint,
        crossRoleFlash: Footprint(weightBytes: crossRoleFlashRawBytes, layers: 0, kvHeads: 0, headDim: 0),
    ]

    /// A profile that names one reference in the embedding slot and in the
    /// standard slot, sized at ``sharedContext``.
    private static func crossRoleProfile() -> ProfileDefinition {
        ProfileDefinition(
            name: "cross-role",
            description: "one reference serves the embedding slot and a generation slot",
            standard: [crossRoleShared],
            flash: [crossRoleFlash],
            embedding: [crossRoleShared],
            context: sharedContext
        )
    }

    @Test("one reference in an embedding slot and a generation slot pays for two containers")
    func crossRoleReferenceIsChargedForTwoContainers() throws {
        let result = try JointFit.resolve(
            profile: Self.crossRoleProfile(),
            budgetBytes: Self.crossRoleSeparateBudget,
            footprint: Self.sizedFootprint(Self.crossRoleFootprints),
            sessionBytes: Self.neverCalledSessionBytes,
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
        #expect(embeddingCharge == JointFit.withMargin(Self.sharedGenerationRawBytes))
        #expect(standardCharge == JointFit.withMargin(Self.sharedGenerationRawBytes))
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
                sessionBytes: Self.neverCalledSessionBytes,
                nativeMaxContext: Self.neverCalledNativeMaxContext
            )
        }
    }

    // MARK: - The profile the field report failed on

    /// The `multitool-cli-demo` generation model, named in both the `standard`
    /// and the `flash` slot.
    private static let multitoolGeneration: ModelRef = "org/Qwen3.8-27B-mxfp4"

    /// The `multitool-cli-demo` embedding model.
    private static let multitoolEmbedding: ModelRef = "org/Qwen3-Embedding-0.6B-4bit-DWQ"

    /// The generation model's architecture, reconstructed from the report the
    /// field printed. It reproduces every figure of that report to the byte:
    /// 38872712722 at 262144 tokens down to 18578992248 at 4096.
    private static let multitoolGenerationFootprint = Footprint(
        weightBytes: 15_214_058_084, layers: 64, kvHeads: 8, headDim: 32
    )

    /// The embedding model's raw weight bytes, which margin to the 402356108
    /// the field report printed.
    private static let multitoolEmbeddingWeightBytes: Int64 = 335_296_756

    /// The host budget the field report failed against.
    private static let multitoolBudgetBytes: Int64 = 26_800_603_136

    /// The generation model's native max context.
    private static let multitoolNativeMaxContext = 262_144

    /// The largest window at which the trio co-fits: the standard slot pays
    /// the weights and one KV cache, and the flash slot pays a second KV
    /// cache on the same container.
    private static let multitoolResolvedContext = 51_761

    /// The footprint table the `multitool-cli-demo` profile is sized against.
    private static let multitoolFootprints: [ModelRef: Footprint] = [
        multitoolGeneration: multitoolGenerationFootprint,
        multitoolEmbedding: Footprint.embedder(weightBytes: multitoolEmbeddingWeightBytes),
    ]

    /// The reported profile: one generation model in both generation slots,
    /// one embedding model, and `context` (`nil` to derive it).
    private static func multitoolProfile(context: Int? = nil) -> ProfileDefinition {
        ProfileDefinition(
            name: "multitool-cli-demo",
            description: "one generation model serves both generation slots",
            standard: [multitoolGeneration],
            flash: [multitoolGeneration],
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
            sessionBytes: sizedSessionBytes(multitoolFootprints),
            nativeMaxContext: nativeMaxTable([multitoolGeneration: multitoolNativeMaxContext])
        )
    }

    @Test("the reported multitool-cli-demo profile co-fits the budget it failed against")
    func multitoolProfileCoFitsItsReportedBudget() throws {
        let result = try Self.resolveMultitool(context: nil)
        #expect(result.standard == Self.multitoolGeneration)
        #expect(result.flash == Self.multitoolGeneration)
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

    /// The raw footprint of ``oversizedEmbedding``, which margins to 1_200_000.
    private static let oversizedEmbeddingRawBytes: Int64 = 1_000_000

    /// A budget the generation model fits comfortably and the embedding model
    /// does not.
    private static let blockedByEmbeddingBudget: Int64 = 500_000

    /// The generation candidate's native max context.
    private static let blockedByEmbeddingNativeMax = 8_192

    /// The footprint table for the embedding-blocked profile.
    private static let blockedByEmbeddingFootprints: [ModelRef: Footprint] = [
        sharedGeneration: sharedGenerationFootprint,
        oversizedEmbedding: Footprint.embedder(weightBytes: oversizedEmbeddingRawBytes),
    ]

    /// A profile whose embedding slot cannot fit, while the one reference both
    /// generation slots name fits at every window.
    private static func blockedByEmbeddingProfile() -> ProfileDefinition {
        ProfileDefinition(
            name: "blocked-by-embedding",
            description: "the embedding slot is what blocks the trio",
            standard: [sharedGeneration],
            flash: [sharedGeneration],
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
                sessionBytes: sizedSessionBytes(blockedByEmbeddingFootprints),
                nativeMaxContext: nativeMaxTable([sharedGeneration: blockedByEmbeddingNativeMax])
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
        #expect(!text.contains("\(Self.sharedGeneration.stringValue) — unsized: too large"))
    }
}
