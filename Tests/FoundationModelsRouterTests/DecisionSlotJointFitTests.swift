import Foundation
import FoundationModelsRouterTestSupport
import Synchronization
import Testing

@testable import FoundationModelsRouter

/// Tests of the decision slot in the pure joint fit: the slot always uses the
/// flash winner, records each of its candidates, and records the flash
/// fallback. The decision fit of its own candidates is a later task. No
/// network and no I/O: the footprints are injected.
@Suite("The decision slot of the joint fit")
struct DecisionSlotJointFitTests {
    // MARK: - Fixed values

    /// The one standard candidate.
    private static let standardRef: ModelRef = "org/standard"

    /// The one flash candidate.
    private static let flashRef: ModelRef = "org/flash"

    /// The one embedding candidate.
    private static let embeddingRef: ModelRef = "org/embedding"

    /// The decision candidates, in preference order.
    private static let decisionRefs: [ModelRef] = ["org/decider-a", "org/decider-b"]

    /// The native window of each candidate, for the derived-window test.
    private static let nativeWindow = 4096

    /// The raw footprint of each trio candidate.
    private static let footprints: [ModelRef: Int64] = [
        standardRef: 9_000,
        flashRef: 2_000,
        embeddingRef: 500,
    ]

    /// The shared budget: enough for the trio.
    private static let budgetBytes: Int64 = 20_000

    /// A record of each candidate the joint fit sized.
    private final class SizedRefs: Sendable {
        /// The refs, in the order of the calls.
        private let refs = Mutex<[ModelRef]>([])

        /// The refs that the footprint provider got.
        var sized: [ModelRef] { refs.withLock { $0 } }

        /// Records one call.
        ///
        /// - Parameter ref: The candidate of the call.
        func record(_ ref: ModelRef) {
            refs.withLock { $0.append(ref) }
        }
    }

    // MARK: - Helpers

    /// The test profile: one candidate for each trio slot, and
    /// ``decisionRefs`` for the decision slot.
    ///
    /// - Parameter context: The working context, or `nil` to derive it.
    /// - Returns: The profile.
    private static func profile(context: Int? = ScriptedSessionContext.tokens) -> ProfileDefinition {
        ProfileDefinition(
            name: "decision-fit",
            description: "one candidate for each trio slot",
            standard: [standardRef],
            flash: [flashRef],
            embedding: [embeddingRef],
            decision: decisionRefs,
            context: context
        )
    }

    /// Runs the joint fit over ``footprints``, and records each sized ref in
    /// `sizedRefs`.
    ///
    /// - Parameters:
    ///   - profile: The profile to resolve.
    ///   - sizedRefs: The record of each sized candidate.
    /// - Returns: The joint resolution.
    /// - Throws: The error of the joint fit.
    private static func resolve(
        _ profile: ProfileDefinition = profile(), sizedRefs: SizedRefs = SizedRefs()
    ) throws -> JointResolution {
        try JointFit.resolve(
            profile: profile,
            budgetBytes: budgetBytes,
            footprint: { ref, _ in
                sizedRefs.record(ref)
                return footprints[ref].map { .success($0) }
                    ?? .failure(.metadataUnavailable("no footprint for \(ref.stringValue)"))
            },
            nativeMaxContext: { _ in .success(nativeWindow) }
        )
    }

    /// The resolution of the decision slot.
    ///
    /// - Parameter resolution: The joint resolution.
    /// - Returns: The resolution of the decision slot.
    /// - Throws: When the joint resolution has no decision slot.
    private static func decisionSlot(of resolution: JointResolution) throws -> SlotResolution {
        try #require(resolution.slots.first { $0.slot == .decision })
    }

    // MARK: - The flash winner

    @Test("the decision model is the flash winner")
    func decisionIsTheFlashWinner() throws {
        let resolution = try Self.resolve()

        #expect(resolution.decision == resolution.flash)
    }

    @Test("the decision model is the flash winner when the window is derived")
    func decisionIsTheFlashWinnerAtADerivedWindow() throws {
        let resolution = try Self.resolve(Self.profile(context: nil))

        #expect(resolution.decision == resolution.flash)
    }

    @Test("the decision slot chooses the flash winner")
    func decisionSlotChoosesTheFlashWinner() throws {
        let slot = try Self.decisionSlot(of: Self.resolve())

        #expect(slot.chosen == Self.flashRef)
    }

    @Test("the decision slot comes after the flash slot in allocation order")
    func decisionSlotIsLastInAllocationOrder() throws {
        let resolution = try Self.resolve()

        #expect(resolution.slots.map(\.slot) == [.embedding, .standard, .flash, .decision])
    }

    @Test("the decision slot gets the budget that the flash slot left")
    func decisionSlotGetsTheBudgetAfterFlash() throws {
        let slot = try Self.decisionSlot(of: Self.resolve())
        let trioBytes = Self.footprints.values.reduce(0, +)

        #expect(slot.remainingBudgetBytes == Self.budgetBytes - trioBytes)
    }

    // MARK: - The record of the slot

    @Test("the decision slot records the flash fallback")
    func decisionSlotRecordsTheFlashFallback() throws {
        let slot = try Self.decisionSlot(of: Self.resolve())

        #expect(slot.fallback == .flashModel)
    }

    @Test("the decision slot records each candidate, in preference order, as not fitted")
    func decisionSlotRecordsEachCandidateAsNotFitted() throws {
        let slot = try Self.decisionSlot(of: Self.resolve())

        #expect(slot.considered.map(\.ref) == Self.decisionRefs)
        #expect(slot.considered.allSatisfy { $0.verdict == .notFitted })
    }

    @Test("the joint fit sizes no decision candidate")
    func jointFitSizesNoDecisionCandidate() throws {
        let sizedRefs = SizedRefs()
        _ = try Self.resolve(sizedRefs: sizedRefs)

        #expect(Set(sizedRefs.sized).isDisjoint(with: Self.decisionRefs))
    }

    @Test("the fallback of a slot renders as \"fallback: flash model\"")
    func fallbackRendersItsText() {
        #expect(SlotFallback.flashModel.description == "fallback: flash model")
    }

    @Test("a failure report shows the fallback of a slot that has one")
    func failureReportShowsTheFallback() {
        let decisionSlot = SlotResolution(
            slot: .decision, remainingBudgetBytes: 0, chosen: Self.flashRef, considered: [],
            contextTokens: ScriptedSessionContext.tokens, fallback: .flashModel)
        let failure = ResolutionFailure(profileName: "decision-fit", budgetBytes: 0, slots: [decisionSlot])

        #expect(failure.description.contains(SlotFallback.flashModel.description))
    }
}
