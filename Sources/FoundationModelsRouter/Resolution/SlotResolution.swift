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
    ///
    /// For a standard-slot candidate resolved via the context ladder (see
    /// ``CandidateReport/ladderAttempts``), this means *every* rung the ladder
    /// tried was too large — the per-rung detail lives in `ladderAttempts`,
    /// not in a single ``CandidateReport/estimatedFootprintBytes`` figure.
    case tooLarge

    /// A higher-preference candidate was already chosen for this slot, so this
    /// lower-preference candidate was not sized or selected.
    case skippedHigherPreferenceChosen

    /// This candidate could not be sized; the associated value is the
    /// human-readable reason (from ``RepoMetadataError/metadataUnavailable(_:)``).
    case metadataUnavailable(String)
}

/// One context rung tried while deriving the working context for a
/// standard-slot candidate via the ladder (see ``JointFit``'s type
/// documentation for the ladder policy).
///
/// Recorded only for a standard-slot candidate considered while
/// ``ProfileDefinition/context`` was `nil` — an explicit profile context
/// bypasses the ladder entirely, so no ``LadderAttempt``s exist for that
/// resolution. `estimatedFootprintBytes` is this *one* candidate's own `× 1.2`
/// footprint at this rung; `fits` is whether the **whole trio** — embedding,
/// this standard candidate, and flash — co-fit the budget at this context, not
/// just this candidate alone, since a rung can fail because a different slot
/// didn't fit even when this candidate itself did.
public struct LadderAttempt: Sendable, Equatable {
    /// The context size in tokens tried at this rung.
    public let contextTokens: Int

    /// This candidate's own `× 1.2` footprint at this rung, or `nil` when it
    /// could not be sized.
    public let estimatedFootprintBytes: Int64?

    /// Whether the full trio (embedding, this candidate, flash) co-fit the
    /// budget at this rung.
    public let fits: Bool

    /// Creates a ladder attempt record.
    ///
    /// - Parameters:
    ///   - contextTokens: The context size in tokens tried at this rung.
    ///   - estimatedFootprintBytes: This candidate's own `× 1.2` footprint at
    ///     this rung, or `nil` when unsized.
    ///   - fits: Whether the full trio co-fit the budget at this rung.
    public init(contextTokens: Int, estimatedFootprintBytes: Int64?, fits: Bool) {
        self.contextTokens = contextTokens
        self.estimatedFootprintBytes = estimatedFootprintBytes
        self.fits = fits
    }
}

/// One candidate's contribution to a slot's resolution: the reference, its
/// `× 1.2` footprint estimate, and the verdict explaining its fate.
///
/// `estimatedFootprintBytes` is the conservative figure used at the fit
/// comparison — already multiplied by the `1.2` overhead margin — so it can be
/// rendered against the budget directly. It is `nil` when the candidate was
/// never sized: either because its metadata was unavailable, because a
/// higher-preference candidate had already won the slot, or because it is a
/// standard-slot candidate resolved via the context ladder whose every rung
/// was too large (see ``ladderAttempts`` for the per-rung figures instead).
public struct CandidateReport: Sendable, Equatable {
    /// The candidate model reference.
    public let ref: ModelRef

    /// The candidate's footprint with the `× 1.2` margin already applied, or
    /// `nil` when the candidate was not sized.
    public let estimatedFootprintBytes: Int64?

    /// Why this candidate was or was not chosen.
    public let verdict: Verdict

    /// The per-context-rung attempts made while deriving the working context
    /// for this candidate via the ladder.
    ///
    /// Non-empty only for a standard-slot candidate considered while
    /// ``ProfileDefinition/context`` was `nil` (ladder derivation); empty for
    /// every other candidate — an explicit context bypasses the ladder
    /// entirely (a single implicit rung, exactly as before this existed), and
    /// embedding/flash candidates are always sized at whatever context the
    /// ladder already settled on for standard, never laddered themselves.
    public let ladderAttempts: [LadderAttempt]

    /// Creates a candidate report.
    ///
    /// - Parameters:
    ///   - ref: The candidate model reference.
    ///   - estimatedFootprintBytes: The `× 1.2` footprint, or `nil` when unsized.
    ///   - verdict: Why the candidate was or was not chosen.
    ///   - ladderAttempts: The per-rung ladder attempts for this candidate, or
    ///     `[]` when the ladder was not used (the default).
    public init(
        ref: ModelRef,
        estimatedFootprintBytes: Int64?,
        verdict: Verdict,
        ladderAttempts: [LadderAttempt] = []
    ) {
        self.ref = ref
        self.estimatedFootprintBytes = estimatedFootprintBytes
        self.verdict = verdict
        self.ladderAttempts = ladderAttempts
    }
}

/// The resolution of one slot during joint fit: which candidate won (if any),
/// the budget that was available when the slot was resolved, the working
/// context it was sized at, and the per-candidate reasoning.
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

    /// The working context, in tokens, this slot's candidates were sized at.
    ///
    /// Every slot in one ``JointResolution`` shares the same value — context is
    /// one profile-wide parameter, not a per-slot one — either the profile's
    /// explicit ``ProfileDefinition/context``, or (when it was `nil`) the rung
    /// the context ladder settled on. Recorded per slot, alongside
    /// `remainingBudgetBytes`, so a consumer never has to re-thread a separate
    /// value to know what context a slot's candidates were actually measured
    /// against.
    public let contextTokens: Int

    /// Creates a slot resolution.
    ///
    /// - Parameters:
    ///   - slot: The slot this resolution is for.
    ///   - remainingBudgetBytes: The budget available to this slot.
    ///   - chosen: The selected candidate, or `nil` when none fit.
    ///   - considered: Every candidate considered, with its verdict.
    ///   - contextTokens: The working context, in tokens, this slot was sized
    ///     at. Defaults to ``ProfileDefinition/defaultContext`` for call sites
    ///     built before context derivation existed.
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
        return "\(candidate.ref.stringValue) — \(footprint): \(verdictText(candidate.verdict))"
    }

    /// Renders one ladder rung as `context <n> tokens — <footprint> bytes: <fit|too large>`.
    private static func line(for attempt: LadderAttempt) -> String {
        let footprint = attempt.estimatedFootprintBytes
            .map { "\($0) bytes" } ?? "unsized"
        let fit = attempt.fits ? "fit" : "too large"
        return "context \(attempt.contextTokens) tokens — \(footprint): \(fit)"
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
