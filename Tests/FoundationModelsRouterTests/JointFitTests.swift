import Foundation
import Testing

@testable import FoundationModelsRouter

/// Tests the pure joint-fit allocation and its diagnostic types with injected
/// footprints — no network, no MLX, no I/O.
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

    // MARK: Raw footprints (multiples of 5 so the ×1.2 margin is exact)

    private static let raw: [ModelRef: Int64] = [
        std32b8: 32_000,   // ×1.2 = 38_400
        std32b4: 18_000,   // ×1.2 = 21_600
        std14b4: 9_000,    // ×1.2 = 10_800
        flash3b: 2_000,    // ×1.2 =  2_400
        embBge: 500,       // ×1.2 =    600
    ]

    /// A footprint provider over an injected raw-byte table, surfacing
    /// `metadataUnavailable` for refs flagged unsizable or absent from the table.
    private static func provider(
        _ table: [ModelRef: Int64] = raw,
        unavailable: [ModelRef: String] = [:]
    ) -> (ModelRef) -> Result<Int64, RepoMetadataError> {
        { ref in
            if let reason = unavailable[ref] {
                return .failure(.metadataUnavailable(reason))
            }
            if let bytes = table[ref] {
                return .success(bytes)
            }
            return .failure(.metadataUnavailable("no footprint injected for \(ref.stringValue)"))
        }
    }

    /// The portability profile: a standard ladder (32B-8bit → 32B-4bit → 14B),
    /// one flash, one embedding.
    private static func ladderProfile() -> ProfileDefinition {
        ProfileDefinition(
            name: "coder",
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
            footprint: Self.provider()
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
            footprint: Self.provider()
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
            footprint: Self.provider()
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
            footprint: Self.provider()
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
            footprint: Self.provider()
        )
        #expect(exact.flash == Self.flash3b)

        // One byte short, the last slot (flash) cannot fit.
        #expect(throws: ResolutionFailure.self) {
            try JointFit.resolve(
                profile: profile,
                budgetBytes: 13_799,
                footprint: Self.provider()
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
                footprint: Self.provider()
            )
        }
        #expect(error.profileName == "coder")
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
                footprint: Self.provider()
            )
        }
        let text = error.description
        #expect(text.contains("coder"))
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
            footprint: Self.provider(unavailable: [Self.unsizable: "config.json is not present in the repo"])
        )
        #expect(result.standard == Self.std14b4)

        let std = Self.resolution(result, for: .standard)
        #expect(std.considered[0].ref == Self.unsizable)
        #expect(std.considered[0].estimatedFootprintBytes == nil)
        #expect(std.considered[0].verdict == .metadataUnavailable("config.json is not present in the repo"))
        #expect(std.considered[1].ref == Self.std14b4)
        #expect(std.considered[1].verdict == .chosen)
    }
}
