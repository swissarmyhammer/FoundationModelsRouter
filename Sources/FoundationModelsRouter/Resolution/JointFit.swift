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
/// ## Deriving the working context
///
/// ``ProfileDefinition/context`` is the working context every slot's footprint
/// is sized at. When the author sets it explicitly, that one figure is used
/// for every candidate in every slot — a single implicit rung, exactly as
/// before context derivation existed (see ``resolveAtFixedContext``).
///
/// When it is `nil`, the working context is *derived* via a ladder, under one
/// policy: **model choice is the outer loop, context is the inner loop**.
/// Standard-slot candidates are walked biggest/best-first exactly as the
/// fixed-context path always has; for *each* candidate, a descending ladder of
/// context rungs — anchored on that candidate's own native max context — is
/// tried until one fits the whole trio (embedding, this candidate, flash) or
/// the ladder is exhausted. The **first candidate with any fitting rung wins,
/// at its largest fitting rung** — a smaller model that could reach a bigger
/// context never displaces a bigger, higher-preference model that fits at a
/// smaller one; there is no minimum context floor beyond wherever the ladder
/// ends. See ``resolveViaLadder``.
///
/// The allocation is pure: per-candidate footprints and native max contexts are
/// injected as closures, so it is unit-testable with injected values and never
/// performs I/O. The real wiring to ``RepoMetadata`` happens in the router's
/// resolve step.
public enum JointFit {
    /// The overhead margin numerator: footprints are scaled by `6 / 5` (`× 1.2`).
    private static let marginNumerator: Int64 = 6

    /// The overhead margin denominator.
    private static let marginDenominator: Int64 = 5

    /// The order slots are allocated in: embedding reserves first, then standard,
    /// then flash sees what remains.
    private static let allocationOrder: [ModelSlot] = [.embedding, .standard, .flash]

    /// The context step-down rungs a standard-slot candidate's ladder tries
    /// below its own native max context, in descending order.
    private static let ladderStepDowns: [Int] = [131_072, 65_536, 32_768, 16_384, 8_192, 4_096]

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
    ///   - footprint: The injected per-candidate raw footprint at a given
    ///     working context, or ``RepoMetadataError/metadataUnavailable(_:)``
    ///     when a candidate cannot be sized.
    ///   - nativeMaxContext: The injected per-candidate native max context,
    ///     used only to build the ladder for standard-slot candidates when
    ///     ``ProfileDefinition/context`` is `nil`; never invoked when it is
    ///     explicit.
    /// - Returns: The chosen trio and per-slot reasoning.
    /// - Throws: ``ResolutionFailure`` when any slot has no viable candidate in
    ///   the budget that remains; the failure carries every slot's reasoning.
    public static func resolve(
        profile: ProfileDefinition,
        budgetBytes: Int64,
        footprint: (ModelRef, Int) -> Result<Int64, RepoMetadataError>,
        nativeMaxContext: (ModelRef) -> Result<Int, RepoMetadataError>
    ) throws -> JointResolution {
        if let explicitContext = profile.context {
            return try resolveAtFixedContext(
                profile: profile,
                budgetBytes: budgetBytes,
                context: explicitContext,
                footprint: footprint
            )
        }
        return try resolveViaLadder(
            profile: profile,
            budgetBytes: budgetBytes,
            footprint: footprint,
            nativeMaxContext: nativeMaxContext
        )
    }

    // MARK: - Explicit context (single rung)

    /// Resolves the trio at one fixed working context: every slot's full
    /// candidate list is tried in preference order at that one context, first
    /// fit wins. This is the whole of resolution when
    /// ``ProfileDefinition/context`` is explicit, and is also the ladder's
    /// building block for a single rung.
    private static func resolveAtFixedContext(
        profile: ProfileDefinition,
        budgetBytes: Int64,
        context: Int,
        footprint: (ModelRef, Int) -> Result<Int64, RepoMetadataError>
    ) throws -> JointResolution {
        var remaining = budgetBytes
        var resolutions: [SlotResolution] = []

        for slot in allocationOrder {
            let candidates = profile.candidatesBySlot[slot] ?? []
            let resolution = resolveSlot(
                slot,
                candidates: candidates,
                remaining: remaining,
                context: context,
                footprint: footprint
            )
            resolutions.append(resolution)
            // Reserve the chosen candidate's margined footprint so later slots
            // see a smaller budget. Nothing chosen reserves nothing.
            remaining -= reservedBytes(resolution)
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
    ///   - candidates: The slot's candidates, in author preference order.
    ///   - remaining: The budget available to this slot.
    ///   - context: The working context to size every candidate at.
    ///   - footprint: The injected per-candidate raw footprint at `context`.
    /// - Returns: The slot's resolution, with one ``CandidateReport`` per
    ///   candidate.
    private static func resolveSlot(
        _ slot: ModelSlot,
        candidates: [ModelRef],
        remaining: Int64,
        context: Int,
        footprint: (ModelRef, Int) -> Result<Int64, RepoMetadataError>
    ) -> SlotResolution {
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

            switch footprint(ref, context) {
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
            considered: considered,
            contextTokens: context
        )
    }

    /// The chosen candidate's margined footprint reserved from the shared
    /// budget, or `0` when nothing was chosen.
    private static func reservedBytes(_ resolution: SlotResolution) -> Int64 {
        resolution.considered.first(where: { $0.verdict == .chosen })?.estimatedFootprintBytes ?? 0
    }

    /// The chosen reference for a slot among resolved slots, if any.
    private static func chosen(in resolutions: [SlotResolution], for slot: ModelSlot) -> ModelRef? {
        resolutions.first { $0.slot == slot }?.chosen
    }

    // MARK: - Derived context (ladder)

    /// One attempt at resolving the full trio — embedding, one specific
    /// standard candidate, and flash — at one context rung.
    ///
    /// Kept as full ``SlotResolution``s (not just a pass/fail bit) so a
    /// failing attempt still yields the standard candidate's own footprint at
    /// this rung for a ``LadderAttempt`` even when a *different* slot is what
    /// actually blocked the trio.
    private struct TrioAttempt {
        let embedding: SlotResolution
        let standard: SlotResolution
        let flash: SlotResolution

        /// Whether every slot found a viable candidate at this rung.
        var succeeded: Bool {
            embedding.chosen != nil && standard.chosen != nil && flash.chosen != nil
        }
    }

    /// Resolves the full trio at one context rung, with the standard slot
    /// restricted to a single candidate — the one the ladder's outer loop is
    /// currently trying — rather than the profile's full standard list.
    private static func attemptTrio(
        profile: ProfileDefinition,
        standardCandidate: ModelRef,
        budgetBytes: Int64,
        context: Int,
        footprint: (ModelRef, Int) -> Result<Int64, RepoMetadataError>
    ) -> TrioAttempt {
        let embedding = resolveSlot(
            .embedding,
            candidates: profile.embedding,
            remaining: budgetBytes,
            context: context,
            footprint: footprint
        )
        let afterEmbedding = budgetBytes - reservedBytes(embedding)
        let standard = resolveSlot(
            .standard,
            candidates: [standardCandidate],
            remaining: afterEmbedding,
            context: context,
            footprint: footprint
        )
        let afterStandard = afterEmbedding - reservedBytes(standard)
        let flash = resolveSlot(
            .flash,
            candidates: profile.flash,
            remaining: afterStandard,
            context: context,
            footprint: footprint
        )
        return TrioAttempt(embedding: embedding, standard: standard, flash: flash)
    }

    /// Builds the descending context ladder for one standard-slot candidate:
    /// its own native max context (capped defensively — ``RepoMetadata``
    /// already clamps to ``RepoMetadata/nativeMaxContextCap``, but an injected
    /// test double need not), followed by every step-down rung strictly below
    /// that top rung.
    ///
    /// - Parameter nativeMaxContext: The candidate's own native max context.
    /// - Returns: The descending rungs to try, largest first.
    private static func contextLadder(nativeMaxContext: Int) -> [Int] {
        let topRung = min(nativeMaxContext, RepoMetadata.nativeMaxContextCap)
        return [topRung] + ladderStepDowns.filter { $0 < topRung }
    }

    /// Resolves a profile whose ``ProfileDefinition/context`` is `nil` by
    /// deriving the working context via the ladder.
    ///
    /// **Model choice is the outer loop**: standard-slot candidates are walked
    /// biggest/best-first, exactly as ``resolveAtFixedContext``. **Context is
    /// the inner loop**: for each candidate, the descending ladder built from
    /// its own native max context (see ``contextLadder(nativeMaxContext:)``) is
    /// tried until the whole trio (embedding, this candidate, flash) co-fits
    /// the budget, or the ladder is exhausted. The first candidate with *any*
    /// fitting rung wins, at its largest fitting rung — a smaller model that
    /// could reach a bigger context never displaces a bigger, higher-preference
    /// model that fits at a smaller one.
    ///
    /// - Parameters:
    ///   - profile: The authored profile; ``ProfileDefinition/context`` must be
    ///     `nil` (callers dispatch on this in ``resolve(profile:budgetBytes:footprint:nativeMaxContext:)``).
    ///   - budgetBytes: The shared memory budget the trio must co-fit.
    ///   - footprint: The injected per-candidate raw footprint at a context.
    ///   - nativeMaxContext: The injected per-candidate native max context,
    ///     queried once per standard candidate to build its ladder.
    /// - Returns: The chosen trio and per-slot reasoning, with the winning
    ///   context recorded on every slot's ``SlotResolution/contextTokens``.
    /// - Throws: ``ResolutionFailure`` when no standard candidate has any
    ///   fitting rung; the failure's standard slot enumerates every candidate's
    ///   ladder attempts.
    private static func resolveViaLadder(
        profile: ProfileDefinition,
        budgetBytes: Int64,
        footprint: (ModelRef, Int) -> Result<Int64, RepoMetadataError>,
        nativeMaxContext: (ModelRef) -> Result<Int, RepoMetadataError>
    ) throws -> JointResolution {
        // No standard candidate to anchor a ladder on — a degenerate authored
        // profile. Fall back to one fixed rung at the ordinary default so this
        // still fails informatively through the ordinary path instead of
        // having nothing to loop over.
        guard !profile.standard.isEmpty else {
            return try resolveAtFixedContext(
                profile: profile,
                budgetBytes: budgetBytes,
                context: ProfileDefinition.defaultContext,
                footprint: footprint
            )
        }

        var standardConsidered: [CandidateReport] = []
        // The smallest context rung actually tried, so the failure path below
        // can size embedding/flash's diagnostics at a real, tried context
        // rather than an arbitrary one. Starts at the ordinary default in case
        // no candidate's ladder could even be built (every native max context
        // lookup failed).
        var lastTriedContext = ProfileDefinition.defaultContext

        for (index, candidate) in profile.standard.enumerated() {
            switch nativeMaxContext(candidate) {
            case .failure(.metadataUnavailable(let reason)):
                standardConsidered.append(
                    CandidateReport(ref: candidate, estimatedFootprintBytes: nil, verdict: .metadataUnavailable(reason))
                )
            case .success(let native):
                var attempts: [LadderAttempt] = []
                for context in contextLadder(nativeMaxContext: native) {
                    lastTriedContext = context
                    let attempt = attemptTrio(
                        profile: profile,
                        standardCandidate: candidate,
                        budgetBytes: budgetBytes,
                        context: context,
                        footprint: footprint
                    )
                    attempts.append(
                        LadderAttempt(
                            contextTokens: context,
                            estimatedFootprintBytes: attempt.standard.considered.first?.estimatedFootprintBytes,
                            fits: attempt.succeeded
                        )
                    )

                    guard
                        attempt.succeeded,
                        let embeddingChosen = attempt.embedding.chosen,
                        let flashChosen = attempt.flash.chosen
                    else {
                        continue
                    }

                    let chosenReport = CandidateReport(
                        ref: candidate,
                        estimatedFootprintBytes: reservedBytes(attempt.standard),
                        verdict: .chosen,
                        ladderAttempts: attempts
                    )
                    let skipped = profile.standard[(index + 1)...].map {
                        CandidateReport(ref: $0, estimatedFootprintBytes: nil, verdict: .skippedHigherPreferenceChosen)
                    }
                    let standardResolution = SlotResolution(
                        slot: .standard,
                        remainingBudgetBytes: attempt.standard.remainingBudgetBytes,
                        chosen: candidate,
                        considered: standardConsidered + [chosenReport] + skipped,
                        contextTokens: context
                    )
                    return JointResolution(
                        embedding: embeddingChosen,
                        standard: candidate,
                        flash: flashChosen,
                        slots: [attempt.embedding, standardResolution, attempt.flash]
                    )
                }
                standardConsidered.append(
                    CandidateReport(ref: candidate, estimatedFootprintBytes: nil, verdict: .tooLarge, ladderAttempts: attempts)
                )
            }
        }

        // Every standard candidate exhausted its ladder with nothing fitting.
        // Re-resolve embedding/flash once more at the smallest context
        // actually tried, so the failure's diagnostics show what those slots
        // looked like at the context resolution gave up at.
        let embeddingResolution = resolveSlot(
            .embedding,
            candidates: profile.embedding,
            remaining: budgetBytes,
            context: lastTriedContext,
            footprint: footprint
        )
        let afterEmbedding = budgetBytes - reservedBytes(embeddingResolution)
        let standardResolution = SlotResolution(
            slot: .standard,
            remainingBudgetBytes: afterEmbedding,
            chosen: nil,
            considered: standardConsidered,
            contextTokens: lastTriedContext
        )
        let flashResolution = resolveSlot(
            .flash,
            candidates: profile.flash,
            remaining: afterEmbedding,
            context: lastTriedContext,
            footprint: footprint
        )
        throw ResolutionFailure(
            profileName: profile.name,
            budgetBytes: budgetBytes,
            slots: [embeddingResolution, standardResolution, flashResolution]
        )
    }
}
