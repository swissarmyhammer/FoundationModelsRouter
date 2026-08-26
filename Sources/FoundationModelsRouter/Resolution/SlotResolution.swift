import Foundation

/// Why a candidate ``ModelRef`` did or did not win its slot during joint fit.
public enum Verdict: Sendable, Equatable {
    /// This candidate fit the remaining budget and was selected for the slot.
    case chosen

    /// The bytes this candidate charges exceeded the remaining budget. For a
    /// laddered candidate, the candidate itself blocked the smallest rung tried.
    case tooLarge

    /// This standard-slot candidate fit at every rung, but another slot had no
    /// viable candidate at the smallest rung. The associated value is that slot.
    case trioBlocked(ModelSlot)

    /// A higher-preference candidate was already chosen, so this one was not sized.
    case skippedHigherPreferenceChosen

    /// This candidate could not be sized. The associated value is the reason.
    case metadataUnavailable(String)
}

/// One context rung tried for a standard-slot candidate while the working
/// context was derived by the ladder. See ``JointFit``.
public struct LadderAttempt: Sendable, Equatable {
    /// The context size in tokens tried at this rung.
    public let contextTokens: Int

    /// This candidate's own `× 1.2` footprint at this rung, or `nil` when it
    /// could not be sized.
    public let estimatedFootprintBytes: Int64?

    /// The slot that found no viable candidate at this rung, or `nil` when the
    /// whole trio co-fit.
    public let blockedSlot: ModelSlot?

    /// Whether the full trio co-fit the budget at this rung.
    public var fits: Bool { blockedSlot == nil }

    /// Creates a ladder attempt record.
    public init(contextTokens: Int, estimatedFootprintBytes: Int64?, blockedSlot: ModelSlot?) {
        self.contextTokens = contextTokens
        self.estimatedFootprintBytes = estimatedFootprintBytes
        self.blockedSlot = blockedSlot
    }
}

/// One candidate's contribution to a slot's resolution: the reference, its
/// cost, and the verdict. The byte figures are `nil` when the candidate was
/// not sized.
public struct CandidateReport: Sendable, Equatable {
    /// The candidate model reference.
    public let ref: ModelRef

    /// The candidate's whole resident footprint with the `× 1.2` margin
    /// applied, or `nil` when the candidate was not sized.
    public let estimatedFootprintBytes: Int64?

    /// The bytes this candidate charged the shared budget, with the `× 1.2`
    /// margin applied, or `nil` when not sized. Smaller than
    /// ``estimatedFootprintBytes`` when an earlier slot reserved the same container.
    public let chargedBytes: Int64?

    /// Why this candidate was or was not chosen.
    public let verdict: Verdict

    /// The context rungs tried for this candidate. Non-empty only for a
    /// standard-slot candidate sized by the ladder.
    public let ladderAttempts: [LadderAttempt]

    /// Creates a candidate report.
    public init(
        ref: ModelRef,
        estimatedFootprintBytes: Int64?,
        chargedBytes: Int64?,
        verdict: Verdict,
        ladderAttempts: [LadderAttempt] = []
    ) {
        self.ref = ref
        self.estimatedFootprintBytes = estimatedFootprintBytes
        self.chargedBytes = chargedBytes
        self.verdict = verdict
        self.ladderAttempts = ladderAttempts
    }
}

/// The resolution of one slot during joint fit: the winning candidate, the
/// budget available, the working context, and the per-candidate reasoning.
public struct SlotResolution: Sendable, Equatable {
    /// The slot this resolution is for.
    public let slot: ModelSlot

    /// The budget available to this slot, less earlier slots' reservations.
    public let remainingBudgetBytes: Int64

    /// The candidate selected for the slot, or `nil` when none fit.
    public let chosen: ModelRef?

    /// Every candidate considered, in author preference order, with its verdict.
    public let considered: [CandidateReport]

    /// The working context, in tokens, this slot's candidates were sized at.
    /// Every slot in one ``JointResolution`` shares the same value.
    public let contextTokens: Int

    /// Creates a slot resolution.
    public init(
        slot: ModelSlot,
        remainingBudgetBytes: Int64,
        chosen: ModelRef?,
        considered: [CandidateReport],
        contextTokens: Int = ProfileDefinition.defaultContext
    ) {
        self.slot = slot
        self.remainingBudgetBytes = remainingBudgetBytes
        self.chosen = chosen
        self.considered = considered
        self.contextTokens = contextTokens
    }
}

/// The error thrown when a profile's three slots cannot co-fit one budget. It
/// carries every slot's ``SlotResolution``. A slot with no viable candidate has `chosen == nil`.
public struct ResolutionFailure: Error, Equatable, CustomStringConvertible {
    /// The name of the profile that could not be resolved.
    public let profileName: String

    /// The shared memory budget, in bytes, the slots had to co-fit.
    public let budgetBytes: Int64

    /// Every slot's resolution, in allocation order (embedding, standard, flash).
    public let slots: [SlotResolution]

    /// Creates a resolution failure.
    public init(profileName: String, budgetBytes: Int64, slots: [SlotResolution]) {
        self.profileName = profileName
        self.budgetBytes = budgetBytes
        self.slots = slots
    }

    /// A multi-line rendering of the failure: each slot, its candidates, and
    /// their footprints.
    public var description: String {
        var lines = [
            "ResolutionFailure: profile \"\(profileName)\" cannot co-fit a budget of \(budgetBytes) bytes."
        ]
        for slot in slots {
            let outcome = slot.chosen.map { "chose \($0.stringValue)" } ?? "no viable candidate"
            lines.append(
                "  \(slot.slot.rawValue) (remaining \(slot.remainingBudgetBytes) bytes, "
                    + "context \(slot.contextTokens) tokens): \(outcome)"
            )
            for candidate in slot.considered {
                lines.append("    - \(Self.line(for: candidate))")
                for attempt in candidate.ladderAttempts {
                    lines.append("        \(Self.line(for: attempt))")
                }
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Renders one candidate as `<ref> — <footprint> bytes: <verdict>`.
    private static func line(for candidate: CandidateReport) -> String {
        let footprint = candidate.estimatedFootprintBytes
            .map { "\($0) bytes" } ?? "unsized"
        return "\(candidate.ref.stringValue) — \(footprint)\(sharedWeightsNote(for: candidate)): "
            + verdictText(candidate.verdict)
    }

    /// Names the smaller figure the shared budget was charged, or the empty
    /// string when the candidate paid its whole footprint.
    private static func sharedWeightsNote(for candidate: CandidateReport) -> String {
        guard
            let footprint = candidate.estimatedFootprintBytes,
            let charged = candidate.chargedBytes,
            charged < footprint
        else {
            return ""
        }
        return " (\(charged) bytes charged; an earlier slot already reserved the weights)"
    }

    /// Renders one ladder rung as `context <n> tokens — <footprint> bytes: <outcome>`.
    private static func line(for attempt: LadderAttempt) -> String {
        let footprint = attempt.estimatedFootprintBytes
            .map { "\($0) bytes" } ?? "unsized"
        return "context \(attempt.contextTokens) tokens — \(footprint): "
            + blockedText(attempt.blockedSlot)
    }

    /// A short human-readable label for a verdict.
    private static func verdictText(_ verdict: Verdict) -> String {
        switch verdict {
        case .chosen:
            return "chosen"
        case .tooLarge:
            return "too large"
        case .trioBlocked(let slot):
            return "trio blocked by \(slot.rawValue)"
        case .skippedHigherPreferenceChosen:
            return "skipped (higher-preference candidate chosen)"
        case .metadataUnavailable(let reason):
            return "metadata unavailable (\(reason))"
        }
    }

    /// A short label for what stopped a ladder rung: `fit`, `too large`, or
    /// `trio blocked by <slot>`.
    private static func blockedText(_ blockedSlot: ModelSlot?) -> String {
        switch blockedSlot {
        case nil:
            return "fit"
        case .standard:
            return "too large"
        case .some(let slot):
            return "trio blocked by \(slot.rawValue)"
        }
    }
}
