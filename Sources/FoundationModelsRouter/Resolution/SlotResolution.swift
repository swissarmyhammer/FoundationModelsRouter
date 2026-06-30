import Foundation

/// Why a single candidate ``ModelRef`` did or did not win its slot during joint
/// fit.
///
/// One verdict is attached to every candidate the resolver looks at, so a
/// ``SlotResolution`` records the full reasoning — what was chosen, what was too
/// large, what was skipped because a better candidate already won, and what
/// could not be sized at all.
public enum Verdict: Sendable, Equatable {
    /// This candidate fit the remaining budget and was selected for the slot.
    case chosen

    /// This candidate's `× 1.2` footprint exceeded the budget remaining when it
    /// was considered.
    case tooLarge

    /// A higher-preference candidate was already chosen for this slot, so this
    /// lower-preference candidate was not sized or selected.
    case skippedHigherPreferenceChosen

    /// This candidate could not be sized; the associated value is the
    /// human-readable reason (from ``RepoMetadataError/metadataUnavailable(_:)``).
    case metadataUnavailable(String)
}

/// One candidate's contribution to a slot's resolution: the reference, its
/// `× 1.2` footprint estimate, and the verdict explaining its fate.
///
/// `estimatedFootprintBytes` is the conservative figure used at the fit
/// comparison — already multiplied by the `1.2` overhead margin — so it can be
/// rendered against the budget directly. It is `nil` when the candidate was
/// never sized: either because its metadata was unavailable or because a
/// higher-preference candidate had already won the slot.
public struct CandidateReport: Sendable, Equatable {
    /// The candidate model reference.
    public let ref: ModelRef

    /// The candidate's footprint with the `× 1.2` margin already applied, or
    /// `nil` when the candidate was not sized.
    public let estimatedFootprintBytes: Int64?

    /// Why this candidate was or was not chosen.
    public let verdict: Verdict

    /// Creates a candidate report.
    ///
    /// - Parameters:
    ///   - ref: The candidate model reference.
    ///   - estimatedFootprintBytes: The `× 1.2` footprint, or `nil` when unsized.
    ///   - verdict: Why the candidate was or was not chosen.
    public init(ref: ModelRef, estimatedFootprintBytes: Int64?, verdict: Verdict) {
        self.ref = ref
        self.estimatedFootprintBytes = estimatedFootprintBytes
        self.verdict = verdict
    }
}

/// The resolution of one slot during joint fit: which candidate won (if any),
/// the budget that was available when the slot was resolved, and the per-
/// candidate reasoning.
///
/// `remainingBudgetBytes` is the budget the slot saw — the shared budget less
/// whatever earlier slots reserved — so later slots record a smaller figure than
/// earlier ones. `chosen` is `nil` only when no candidate fit, which makes the
/// slot the unsatisfiable one in a ``ResolutionFailure``.
public struct SlotResolution: Sendable, Equatable {
    /// The slot this resolution is for.
    public let slot: ModelSlot

    /// The budget available to this slot — the shared budget less earlier slots'
    /// reservations.
    public let remainingBudgetBytes: Int64

    /// The candidate selected for the slot, or `nil` when none fit.
    public let chosen: ModelRef?

    /// Every candidate considered, in author preference order, with its verdict.
    public let considered: [CandidateReport]

    /// Creates a slot resolution.
    ///
    /// - Parameters:
    ///   - slot: The slot this resolution is for.
    ///   - remainingBudgetBytes: The budget available to this slot.
    ///   - chosen: The selected candidate, or `nil` when none fit.
    ///   - considered: Every candidate considered, with its verdict.
    public init(
        slot: ModelSlot,
        remainingBudgetBytes: Int64,
        chosen: ModelRef?,
        considered: [CandidateReport]
    ) {
        self.slot = slot
        self.remainingBudgetBytes = remainingBudgetBytes
        self.chosen = chosen
        self.considered = considered
    }
}

/// The error thrown when a profile's three slots cannot co-fit one budget.
///
/// It carries the full diagnostic picture — the profile name, the budget, and
/// every slot's ``SlotResolution`` (candidates, footprints, verdicts) — so the
/// `description` can show exactly why resolution failed: which slot had no
/// viable candidate, and how each candidate's `× 1.2` footprint compared to the
/// budget that remained. The unsatisfiable slot(s) have `chosen == nil`.
public struct ResolutionFailure: Error, Equatable, CustomStringConvertible {
    /// The name of the profile that could not be resolved.
    public let profileName: String

    /// The shared memory budget, in bytes, the slots had to co-fit.
    public let budgetBytes: Int64

    /// Every slot's resolution, in allocation order (embedding, standard, flash).
    public let slots: [SlotResolution]

    /// Creates a resolution failure.
    ///
    /// - Parameters:
    ///   - profileName: The name of the profile that could not be resolved.
    ///   - budgetBytes: The shared budget the slots had to co-fit.
    ///   - slots: Every slot's resolution, in allocation order.
    public init(profileName: String, budgetBytes: Int64, slots: [SlotResolution]) {
        self.profileName = profileName
        self.budgetBytes = budgetBytes
        self.slots = slots
    }

    /// A multi-line rendering of the failure: each slot, its candidates, their
    /// `× 1.2` footprints, and the budget they were measured against.
    public var description: String {
        var lines = [
            "ResolutionFailure: profile \"\(profileName)\" cannot co-fit a budget of \(budgetBytes) bytes."
        ]
        for slot in slots {
            let outcome = slot.chosen.map { "chose \($0.stringValue)" } ?? "no viable candidate"
            lines.append(
                "  \(slot.slot.rawValue) (remaining \(slot.remainingBudgetBytes) bytes): \(outcome)"
            )
            for candidate in slot.considered {
                lines.append("    - \(Self.line(for: candidate))")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Renders one candidate as `<ref> — <footprint> bytes: <verdict>`.
    private static func line(for candidate: CandidateReport) -> String {
        let footprint = candidate.estimatedFootprintBytes
            .map { "\($0) bytes" } ?? "unsized"
        return "\(candidate.ref.stringValue) — \(footprint): \(verdictText(candidate.verdict))"
    }

    /// A short human-readable label for a verdict.
    private static func verdictText(_ verdict: Verdict) -> String {
        switch verdict {
        case .chosen:
            return "chosen"
        case .tooLarge:
            return "too large"
        case .skippedHigherPreferenceChosen:
            return "skipped (higher-preference candidate chosen)"
        case .metadataUnavailable(let reason):
            return "metadata unavailable (\(reason))"
        }
    }
}
