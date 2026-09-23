import Foundation

/// Why a candidate ``ModelRef`` did or did not win its slot during joint fit.
enum Verdict: Sendable, Equatable {
    /// This candidate fit the remaining budget and was selected for the slot.
    case chosen

    /// The bytes this candidate charges exceeded the remaining budget. For a
    /// standard-slot candidate whose window is derived, the candidate itself
    /// did not fit at a window of one token.
    case tooLarge

    /// This standard-slot candidate fit at a window of one token, but another
    /// slot had no viable candidate at that window. The associated value is
    /// that slot.
    case trioBlocked(ModelSlot)

    /// A higher-preference candidate was already chosen, so this one was not sized.
    case skippedHigherPreferenceChosen

    /// This candidate could not be sized. The associated value is the reason.
    case metadataUnavailable(String)
}

/// The record of the window search for one standard-slot candidate while the
/// working context was derived: the candidate's native window, and the
/// largest window that fits or the slot that blocked the smallest window.
/// See ``JointFit``.
struct WindowFit: Sendable, Equatable {
    /// What the window search found.
    enum Outcome: Sendable, Equatable {
        /// The whole trio co-fit at `contextTokens`, the largest window that
        /// fits. `estimatedFootprintBytes` is this candidate's own `× 1.2`
        /// footprint at that window, or `nil` when it could not be sized.
        case fits(contextTokens: Int, estimatedFootprintBytes: Int64?)

        /// No window fits: at a window of one token, `by` found no viable
        /// candidate. `estimatedFootprintBytes` is this candidate's own
        /// `× 1.2` footprint at that window, or `nil` when it could not be sized.
        case blocked(by: ModelSlot, estimatedFootprintBytes: Int64?)
    }

    /// The candidate's native max context, in tokens.
    let nativeContextTokens: Int

    /// What the window search found.
    let outcome: Outcome

    /// Creates a window-search record.
    init(nativeContextTokens: Int, outcome: Outcome) {
        self.nativeContextTokens = nativeContextTokens
        self.outcome = outcome
    }
}

/// One candidate's contribution to a slot's resolution: the reference, its
/// cost, and the verdict. The byte figures are `nil` when the candidate was
/// not sized.
package struct CandidateReport: Sendable, Equatable {
    /// The candidate model reference.
    package let ref: ModelRef

    /// The candidate's whole resident footprint with the `× 1.2` margin
    /// applied, or `nil` when the candidate was not sized.
    let estimatedFootprintBytes: Int64?

    /// The bytes this candidate charged the shared budget, with the `× 1.2`
    /// margin applied, or `nil` when not sized. Smaller than
    /// ``estimatedFootprintBytes`` when an earlier slot reserved the same container.
    package let chargedBytes: Int64?

    /// Why this candidate was or was not chosen.
    let verdict: Verdict

    /// The window search for this candidate. Set only for a standard-slot
    /// candidate whose window was derived; `nil` otherwise.
    let windowFit: WindowFit?

    /// Creates a candidate report.
    init(
        ref: ModelRef,
        estimatedFootprintBytes: Int64?,
        chargedBytes: Int64?,
        verdict: Verdict,
        windowFit: WindowFit? = nil
    ) {
        self.ref = ref
        self.estimatedFootprintBytes = estimatedFootprintBytes
        self.chargedBytes = chargedBytes
        self.verdict = verdict
        self.windowFit = windowFit
    }
}

/// The resolution of one slot during joint fit: the winning candidate, the
/// budget available, the working context, and the per-candidate reasoning.
package struct SlotResolution: Sendable, Equatable {
    /// The slot this resolution is for.
    let slot: ModelSlot

    /// The budget available to this slot, less earlier slots' reservations.
    let remainingBudgetBytes: Int64

    /// The candidate selected for the slot, or `nil` when none fit.
    let chosen: ModelRef?

    /// Every candidate considered, in author preference order, with its verdict.
    package let considered: [CandidateReport]

    /// The working context, in tokens, this slot's candidates were sized at.
    /// Every slot in one ``JointResolution`` shares the same value.
    package let contextTokens: Int

    /// Creates a slot resolution.
    package init(
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
struct ResolutionFailure: Error, Equatable, CustomStringConvertible {
    /// The name of the profile that could not be resolved.
    let profileName: String

    /// The shared memory budget, in bytes, the slots had to co-fit.
    let budgetBytes: Int64

    /// Every slot's resolution, in allocation order (embedding, standard, flash).
    let slots: [SlotResolution]

    /// Creates a resolution failure.
    init(profileName: String, budgetBytes: Int64, slots: [SlotResolution]) {
        self.profileName = profileName
        self.budgetBytes = budgetBytes
        self.slots = slots
    }

    /// A multi-line rendering of the failure: each slot, its candidates, and
    /// their footprints.
    var description: String {
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
                if let fit = candidate.windowFit {
                    lines.append("        \(Self.line(for: fit))")
                }
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Renders one candidate as `<ref> — <footprint> bytes: <verdict>`.
    private static func line(for candidate: CandidateReport) -> String {
        let footprint = footprintText(candidate.estimatedFootprintBytes)
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

    /// Renders one window search as `native window <n> tokens, <result> —
    /// <footprint>: <outcome>`.
    private static func line(for fit: WindowFit) -> String {
        let native = "native window \(fit.nativeContextTokens) tokens"
        switch fit.outcome {
        case .fits(let contextTokens, let footprintBytes):
            return "\(native), fitted window \(contextTokens) tokens — \(footprintText(footprintBytes)): fit"
        case .blocked(let slot, let footprintBytes):
            return "\(native), no window fits — \(footprintText(footprintBytes)) at one token: "
                + blockedText(slot)
        }
    }

    /// Renders a footprint as `<n> bytes`, or `unsized` when it is `nil`.
    private static func footprintText(_ bytes: Int64?) -> String {
        bytes.map { "\($0) bytes" } ?? "unsized"
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

    /// A short label for the slot that blocked the smallest window: `too
    /// large` when it is the standard slot, or `trio blocked by <slot>`.
    private static func blockedText(_ slot: ModelSlot) -> String {
        switch slot {
        case .standard:
            return "too large"
        case .embedding, .flash:
            return "trio blocked by \(slot.rawValue)"
        }
    }
}
