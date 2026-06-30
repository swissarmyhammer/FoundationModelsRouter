import Foundation

/// The successful result of joint fit: the chosen model for each slot plus the
/// per-slot reasoning that produced it.
///
/// The `embedding`, `standard`, and `flash` references are the resolved trio —
/// always present on success. `slots` carries the full ``SlotResolution`` for
/// each, including the candidates that were skipped, too large, or unsizable.
public struct JointResolution: Sendable, Equatable {
    /// The chosen embedding model.
    public let embedding: ModelRef

    /// The chosen standard (primary generation) model.
    public let standard: ModelRef

    /// The chosen flash (latency-sensitive generation) model.
    public let flash: ModelRef

    /// Each slot's resolution, in allocation order (embedding, standard, flash).
    public let slots: [SlotResolution]

    /// Creates a joint resolution.
    ///
    /// - Parameters:
    ///   - embedding: The chosen embedding model.
    ///   - standard: The chosen standard model.
    ///   - flash: The chosen flash model.
    ///   - slots: Each slot's resolution, in allocation order.
    public init(embedding: ModelRef, standard: ModelRef, flash: ModelRef, slots: [SlotResolution]) {
        self.embedding = embedding
        self.standard = standard
        self.flash = flash
        self.slots = slots
    }
}

/// The pure joint allocation that picks the highest-preference combination of
/// three slot models that co-fits one shared memory budget.
///
/// Allocation runs in preference order against the shared budget — **embedding**
/// first (its footprint is reserved), then **standard**, then **flash** — so
/// later slots see only what earlier slots left behind. Within a slot the
/// candidates are tried in the author's preference order (biggest/best first)
/// and the first that fits wins; the author's quant choices are never
/// substituted, only accepted or skipped.
///
/// The fit margin lives here, not in ``Footprint``: a candidate is viable in
/// `remaining` iff `footprint × 1.2 <= remaining`. The `× 1.2` is applied
/// exactly once, at the conversion from raw footprint to the figure recorded in
/// ``CandidateReport/estimatedFootprintBytes`` and used for both the fit test
/// and the budget reservation.
///
/// The allocation is pure: the per-candidate footprint is injected as a closure
/// `(ModelRef) -> Result<Int64, RepoMetadataError>`, so it is unit-testable with
/// injected values and never performs I/O. The real wiring to ``RepoMetadata``
/// happens in the router's resolve step.
public enum JointFit {
    /// The overhead margin numerator: footprints are scaled by `6 / 5` (`× 1.2`).
    private static let marginNumerator: Int64 = 6

    /// The overhead margin denominator.
    private static let marginDenominator: Int64 = 5

    /// The order slots are allocated in: embedding reserves first, then standard,
    /// then flash sees what remains.
    private static let allocationOrder: [ModelSlot] = [.embedding, .standard, .flash]

    /// Applies the `× 1.2` overhead margin to a raw footprint, rounding up so the
    /// budgeted figure is never an under-estimate.
    ///
    /// - Parameter rawBytes: The raw footprint in bytes.
    /// - Returns: `ceil(rawBytes × 1.2)`.
    static func withMargin(_ rawBytes: Int64) -> Int64 {
        (rawBytes * marginNumerator + marginDenominator - 1) / marginDenominator
    }

    /// Resolves a profile's three slots against one shared budget.
    ///
    /// - Parameters:
    ///   - profile: The authored profile whose slots supply candidates in
    ///     preference order.
    ///   - budgetBytes: The shared memory budget, in bytes, the three slots must
    ///     co-fit.
    ///   - footprint: The injected per-candidate raw footprint, or
    ///     ``RepoMetadataError/metadataUnavailable(_:)`` when a candidate cannot
    ///     be sized.
    /// - Returns: The chosen trio and per-slot reasoning.
    /// - Throws: ``ResolutionFailure`` when any slot has no viable candidate in
    ///   the budget that remains; the failure carries every slot's reasoning.
    public static func resolve(
        profile: ProfileDefinition,
        budgetBytes: Int64,
        footprint: (ModelRef) -> Result<Int64, RepoMetadataError>
    ) throws -> JointResolution {
        var remaining = budgetBytes
        var resolutions: [SlotResolution] = []

        for slot in allocationOrder {
            let resolution = resolveSlot(
                slot,
                profile: profile,
                remaining: remaining,
                footprint: footprint
            )
            resolutions.append(resolution)
            // Reserve the chosen candidate's margined footprint so later slots
            // see a smaller budget. Nothing chosen reserves nothing.
            if let report = resolution.considered.first(where: { $0.verdict == .chosen }),
               let reserved = report.estimatedFootprintBytes {
                remaining -= reserved
            }
        }

        guard
            let embedding = chosen(in: resolutions, for: .embedding),
            let standard = chosen(in: resolutions, for: .standard),
            let flash = chosen(in: resolutions, for: .flash)
        else {
            throw ResolutionFailure(
                profileName: profile.name,
                budgetBytes: budgetBytes,
                slots: resolutions
            )
        }

        return JointResolution(
            embedding: embedding,
            standard: standard,
            flash: flash,
            slots: resolutions
        )
    }

    /// Resolves a single slot against the remaining budget, choosing the first
    /// viable candidate in preference order and recording a verdict for each.
    ///
    /// - Parameters:
    ///   - slot: The slot being resolved.
    ///   - profile: The authored profile supplying the slot's candidates in
    ///     preference order.
    ///   - remaining: The budget available to this slot.
    ///   - footprint: The injected per-candidate raw footprint.
    /// - Returns: The slot's resolution, with one ``CandidateReport`` per
    ///   candidate.
    private static func resolveSlot(
        _ slot: ModelSlot,
        profile: ProfileDefinition,
        remaining: Int64,
        footprint: (ModelRef) -> Result<Int64, RepoMetadataError>
    ) -> SlotResolution {
        let candidates: [ModelRef] = switch slot {
        case .embedding: profile.embedding
        case .standard: profile.standard
        case .flash: profile.flash
        }

        var chosen: ModelRef?
        var considered: [CandidateReport] = []

        for ref in candidates {
            // Once a higher-preference candidate has won, lower-preference ones
            // are recorded as skipped and never sized.
            if chosen != nil {
                considered.append(
                    CandidateReport(ref: ref, estimatedFootprintBytes: nil, verdict: .skippedHigherPreferenceChosen)
                )
                continue
            }

            switch footprint(ref) {
            case .failure(.metadataUnavailable(let reason)):
                considered.append(
                    CandidateReport(ref: ref, estimatedFootprintBytes: nil, verdict: .metadataUnavailable(reason))
                )
            case .success(let rawBytes):
                let scaled = withMargin(rawBytes)
                if scaled <= remaining {
                    chosen = ref
                    considered.append(
                        CandidateReport(ref: ref, estimatedFootprintBytes: scaled, verdict: .chosen)
                    )
                } else {
                    considered.append(
                        CandidateReport(ref: ref, estimatedFootprintBytes: scaled, verdict: .tooLarge)
                    )
                }
            }
        }

        return SlotResolution(
            slot: slot,
            remainingBudgetBytes: remaining,
            chosen: chosen,
            considered: considered
        )
    }

    /// The chosen reference for a slot among resolved slots, if any.
    private static func chosen(in resolutions: [SlotResolution], for slot: ModelSlot) -> ModelRef? {
        resolutions.first { $0.slot == slot }?.chosen
    }
}
