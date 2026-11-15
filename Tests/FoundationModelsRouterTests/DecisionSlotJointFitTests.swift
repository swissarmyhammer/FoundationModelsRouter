import Foundation
import FoundationModelsRouterTestSupport
import Testing

@testable import FoundationModelsRouter

/// Tests of the decision slot as a required slot of the pure joint fit (task
/// ^ybx7vvn). The decision slot never uses the flash model in place of its
/// own: a decision candidate that fits no budget fails the resolve, and a
/// derived window leaves room for the decision model. `JointFitTests` tests
/// the choice among decision candidates. No network and no I/O: the
/// footprints are injected.
@Suite("The decision slot of the joint fit")
struct DecisionSlotJointFitTests {
    // MARK: - Fixed values

    /// The one standard candidate.
    private static let standardRef: ModelRef = "org/standard"

    /// The one flash candidate.
    private static let flashRef: ModelRef = "org/flash"

    /// The one embedding candidate.
    private static let embeddingRef: ModelRef = "org/embedding"

    /// A decision candidate with a footprint.
    private static let deciderRef: ModelRef = "org/decider"

    /// The decision candidates that cannot be sized, in preference order.
    /// ``footprints`` has no entry for them.
    private static let unsizableDeciders: [ModelRef] = ["org/decider-a", "org/decider-b"]

    /// The native window of each candidate, for the derived-window tests.
    private static let nativeWindow = 4096

    /// The bytes of KV cache that the standard model adds for each token.
    private static let standardBytesPerToken: Int64 = 2

    /// The bytes of the decision model: weights only, no KV cache.
    private static let deciderBytes: Int64 = 1_500

    /// The raw footprint of each candidate at `context`.
    ///
    /// - Parameters:
    ///   - ref: The candidate.
    ///   - context: The working context.
    /// - Returns: The bytes, or `nil` for a candidate with no footprint.
    private static func footprint(of ref: ModelRef, context: Int) -> Int64? {
        switch ref {
        case standardRef: 1_000 + standardBytesPerToken * Int64(context)
        case flashRef: 2_000
        case embeddingRef: 500
        case deciderRef: deciderBytes
        default: nil
        }
    }

    /// A budget in which the trio fits at the native window with no byte to
    /// spare, so a decision model fits only at a smaller window.
    private static let fullBudgetBytes: Int64 = 1_000 + 2 * 4096 + 2_000 + 500

    // MARK: - Helpers

    /// The test profile: one candidate for each trio slot, and `decision`
    /// for the decision slot.
    ///
    /// - Parameters:
    ///   - decision: The decision candidates.
    ///   - context: The working context, or `nil` to derive it.
    /// - Returns: The profile.
    private static func profile(decision: [ModelRef], context: Int? = nil) -> ProfileDefinition {
        ProfileDefinition(
            name: "decision-fit",
            description: "one candidate for each trio slot",
            standard: [standardRef],
            flash: [flashRef],
            embedding: [embeddingRef],
            decision: decision,
            context: context
        )
    }

    /// The reason that the footprint provider gives for a ref with no
    /// footprint.
    ///
    /// - Parameter ref: The ref with no footprint.
    /// - Returns: The reason.
    private static func noFootprintReason(for ref: ModelRef) -> String {
        "no footprint for \(ref.stringValue)"
    }

    /// Runs the joint fit over ``footprint(of:context:)``.
    ///
    /// - Parameters:
    ///   - profile: The profile to resolve.
    ///   - budgetBytes: The shared budget.
    /// - Returns: The joint resolution.
    /// - Throws: The error of the joint fit.
    private static func resolve(_ profile: ProfileDefinition, budgetBytes: Int64) throws -> JointResolution {
        try JointFit.resolve(
            profile: profile,
            budgetBytes: budgetBytes,
            footprint: { ref, context, _ in
                footprint(of: ref, context: context).map { .success($0) }
                    ?? .failure(.metadataUnavailable(noFootprintReason(for: ref)))
            },
            nativeMaxContext: { _ in .success(nativeWindow) }
        )
    }

    // MARK: - Room for the decision model

    @Test("a derived window leaves room for the decision model")
    func derivedWindowLeavesRoomForTheDecisionModel() throws {
        let resolution = try Self.resolve(Self.profile(decision: [Self.deciderRef]), budgetBytes: Self.fullBudgetBytes)

        #expect(resolution.decision == Self.deciderRef)
    }

    @Test("the decision model makes the derived window smaller by its own bytes")
    func decisionModelShrinksTheDerivedWindow() throws {
        let resolution = try Self.resolve(Self.profile(decision: [Self.deciderRef]), budgetBytes: Self.fullBudgetBytes)
        let decisionSlot = try #require(resolution.slots.first { $0.slot == .decision })

        #expect(
            decisionSlot.contextTokens == Self.nativeWindow - Int(Self.deciderBytes / Self.standardBytesPerToken))
    }

    @Test("the decision slot comes after the flash slot in allocation order")
    func decisionSlotIsLastInAllocationOrder() throws {
        let resolution = try Self.resolve(Self.profile(decision: [Self.deciderRef]), budgetBytes: Self.fullBudgetBytes)

        #expect(resolution.slots.map(\.slot) == [.embedding, .standard, .flash, .decision])
    }

    // MARK: - No decision model

    @Test(
        "a decision model that fits at no window fails the resolve, and the failure names the decision slot",
        arguments: [nil, ScriptedSessionContext.tokens])
    func unfitDecisionModelFailsTheResolve(context: Int?) throws {
        let failure = try #require(throws: ResolutionFailure.self) {
            try Self.resolve(Self.profile(decision: Self.unsizableDeciders, context: context), budgetBytes: 1_000_000)
        }
        let decisionSlot = try #require(failure.slots.first { $0.slot == .decision })

        #expect(decisionSlot.chosen == nil)
        #expect(
            decisionSlot.considered.map(\.verdict)
                == Self.unsizableDeciders.map { .metadataUnavailable(Self.noFootprintReason(for: $0)) })
    }

    @Test("a decision model too large for the budget fails the resolve with its footprint")
    func tooLargeDecisionModelFailsTheResolve() throws {
        let failure = try #require(throws: ResolutionFailure.self) {
            try Self.resolve(
                Self.profile(decision: [Self.deciderRef], context: Self.nativeWindow),
                budgetBytes: Self.fullBudgetBytes)
        }
        let decisionSlot = try #require(failure.slots.first { $0.slot == .decision })

        #expect(
            decisionSlot.considered
                == [
                    CandidateReport(
                        ref: Self.deciderRef, estimatedFootprintBytes: Self.deciderBytes,
                        chargedBytes: Self.deciderBytes, verdict: .tooLarge)
                ])
        #expect(failure.description.contains(Self.deciderRef.stringValue))
    }

    @Test("a profile with no decision candidate fails the resolve", arguments: [nil, ScriptedSessionContext.tokens])
    func emptyDecisionListFailsTheResolve(context: Int?) throws {
        let failure = try #require(throws: ResolutionFailure.self) {
            try Self.resolve(Self.profile(decision: [], context: context), budgetBytes: 1_000_000)
        }

        #expect(failure.slots.contains { $0.slot == .decision && $0.chosen == nil })
    }

    @Test("the standard candidate of a derived window that the decision slot blocks records the decision slot")
    func standardCandidateRecordsTheBlockingDecisionSlot() throws {
        let failure = try #require(throws: ResolutionFailure.self) {
            try Self.resolve(Self.profile(decision: Self.unsizableDeciders), budgetBytes: 1_000_000)
        }
        let standardSlot = try #require(failure.slots.first { $0.slot == .standard })

        #expect(standardSlot.considered.map(\.verdict) == [.trioBlocked(.decision)])
    }
}
