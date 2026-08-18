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
/// `remaining` iff `charge × 1.2 <= remaining`. The `× 1.2` is applied exactly
/// once, at the conversion from the raw bytes a candidate charges to the figure
/// recorded in ``CandidateReport/chargedBytes`` and used for both the fit test
/// and the budget reservation.
///
/// ## One resident container, one reservation
///
/// The router pools a loaded model on `(ModelRef, role)`, and `standard` and
/// `flash` load the same role, so two slots naming one reference share one
/// resident container. Charging that reference twice sizes the box for a copy
/// the router never allocates, and rejects profiles the box can comfortably run.
///
/// So the **weights** are charged one time. What a repeated slot still pays for
/// is its **KV cache**, which is per session rather than per container: two
/// slots on one resident model open their own sessions, and each materializes
/// its own cache. The dedupe covers the weights and nothing else — see
/// `SharedBudget` for the reservation, `ReservationKey` for what makes two
/// candidates one container, and
/// ``sessionBytes(_:context:residentBytes:footprint:)`` for the half that is
/// still charged again.
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

    /// The context step-down rungs a standard-slot candidate's ladder tries
    /// below its own native max context, in descending order.
    private static let ladderStepDowns: [Int] = [131_072, 65_536, 32_768, 16_384, 8_192, 4_096]

    /// The context a candidate is sized at to read its weights alone.
    ///
    /// ``Footprint/footprint(context:)`` is `weightBytes + kvBytes(context:)`,
    /// and ``Footprint/kvBytes(context:)`` scales linearly with the context, so
    /// the KV term is exactly zero here and what comes back is the weights.
    private static let weightsOnlyContext = 0

    /// Applies the `× 1.2` overhead margin to a raw footprint, rounding up so the
    /// budgeted figure is never an under-estimate.
    ///
    /// - Parameter rawBytes: The raw footprint in bytes.
    /// - Returns: `ceil(rawBytes × 1.2)`.
    static func withMargin(_ rawBytes: Int64) -> Int64 {
        (rawBytes * marginNumerator + marginDenominator - 1) / marginDenominator
    }

    // MARK: - Reserving one resident container once

    /// The role a slot loads its chosen model under, which is the axis that
    /// decides whether two slots share one resident container.
    ///
    /// `standard` and `flash` both load a generation container, so they share
    /// one. The embedding slot loads an embedder — a different container type,
    /// under a different pool key — so it shares nothing with a generation slot
    /// even when both slots name the identical reference.
    private enum ResidentRole: Hashable {
        /// Loaded as a generation model, for the `standard` and `flash` slots.
        case generation

        /// Loaded as an embedder, for the `embedding` slot.
        case embedding

        /// The role `slot` loads its chosen model under.
        ///
        /// - Parameter slot: The slot doing the loading.
        init(slot: ModelSlot) {
            switch slot {
            case .standard, .flash:
                self = .generation
            case .embedding:
                self = .embedding
            }
        }
    }

    /// The unit a model's weights are reserved on, exactly once.
    ///
    /// It is the reference **as the author wrote it** — the repository plus the
    /// optional pinned revision — beside the role it is loaded under, because
    /// that pair is what the router keys its resident pool on.
    ///
    /// Two references spelled differently are two keys even when the two would
    /// resolve to one commit: the pool never resolves the spelling, so it loads
    /// two containers. Deduping on a resolved identity would reserve for one of
    /// them and let a box accept a profile it cannot hold.
    private struct ReservationKey: Hashable {
        /// The candidate reference, exactly as the profile spells it.
        let ref: ModelRef

        /// The role the slot loads that reference under.
        let role: ResidentRole
    }

    /// The shared budget as the slots consume it, in allocation order.
    ///
    /// A chosen candidate is charged one time. A later slot naming a key an
    /// earlier slot already charged is charged its per-session KV cache alone,
    /// because the router loads one container for both — see
    /// ``sessionBytes(_:context:residentBytes:footprint:)``.
    private struct SharedBudget {
        /// The bytes still available to the next slot.
        private(set) var remainingBytes: Int64

        /// Every key whose weights an earlier slot already charged.
        private(set) var chargedKeys: Set<ReservationKey> = []

        /// Creates a budget with nothing charged yet.
        ///
        /// - Parameter totalBytes: The whole shared budget the trio must co-fit.
        init(totalBytes: Int64) {
            remainingBytes = totalBytes
        }

        /// Charges a resolved slot's chosen candidate, and records its weights
        /// as reserved. A slot that chose nothing charges nothing.
        ///
        /// - Parameter resolution: The slot resolution to charge.
        mutating func charge(_ resolution: SlotResolution) {
            guard let report = chosenReport(resolution) else { return }
            remainingBytes -= report.chargedBytes ?? 0
            chargedKeys.insert(
                ReservationKey(ref: report.ref, role: ResidentRole(slot: resolution.slot))
            )
        }
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
        let attempt = attemptTrio(
            profile: profile,
            standardCandidates: profile.standard,
            budgetBytes: budgetBytes,
            context: context,
            footprint: footprint
        )

        guard
            let embedding = attempt.embedding.chosen,
            let standard = attempt.standard.chosen,
            let flash = attempt.flash.chosen
        else {
            throw ResolutionFailure(
                profileName: profile.name,
                budgetBytes: budgetBytes,
                slots: attempt.slots
            )
        }

        return JointResolution(
            embedding: embedding,
            standard: standard,
            flash: flash,
            slots: attempt.slots
        )
    }

    /// Resolves a single slot against the remaining budget, choosing the first
    /// viable candidate in preference order and recording a verdict for each.
    ///
    /// - Parameters:
    ///   - slot: The slot being resolved.
    ///   - candidates: The slot's candidates, in author preference order.
    ///   - budget: The shared budget as earlier slots left it, carrying both
    ///     what remains and which keys they already reserved.
    ///   - context: The working context to size every candidate at.
    ///   - footprint: The injected per-candidate raw footprint at `context`.
    /// - Returns: The slot's resolution, with one ``CandidateReport`` per
    ///   candidate.
    private static func resolveSlot(
        _ slot: ModelSlot,
        candidates: [ModelRef],
        budget: SharedBudget,
        context: Int,
        footprint: (ModelRef, Int) -> Result<Int64, RepoMetadataError>
    ) -> SlotResolution {
        var chosen: ModelRef?
        var considered: [CandidateReport] = []

        for ref in candidates {
            // Once a higher-preference candidate has won, lower-preference ones
            // are recorded as skipped and never sized.
            guard chosen == nil else {
                considered.append(
                    CandidateReport(
                        ref: ref,
                        estimatedFootprintBytes: nil,
                        chargedBytes: nil,
                        verdict: .skippedHigherPreferenceChosen
                    )
                )
                continue
            }

            let report = evaluateCandidate(
                ref,
                role: ResidentRole(slot: slot),
                context: context,
                budget: budget,
                footprint: footprint
            )
            considered.append(report)
            if report.verdict == .chosen {
                chosen = ref
            }
        }

        return SlotResolution(
            slot: slot,
            remainingBudgetBytes: budget.remainingBytes,
            chosen: chosen,
            considered: considered,
            contextTokens: context
        )
    }

    /// Sizes one candidate against the remaining budget at a given context,
    /// producing its verdict.
    ///
    /// This is the success-case logic factored out of ``resolveSlot(_:candidates:budget:context:footprint:)``:
    /// a candidate is `.chosen` when the bytes it charges fit what remains,
    /// `.tooLarge` when they don't, and `.metadataUnavailable` when it could
    /// not be sized at all.
    ///
    /// A candidate whose key an earlier slot already reserved charges its
    /// per-session KV cache alone, because the router loads one container for
    /// both slots. Its report still carries the whole footprint, so a reader
    /// sees both the size of the model and what it cost.
    ///
    /// - Parameters:
    ///   - ref: The candidate being sized.
    ///   - role: The role the slot loads the candidate under.
    ///   - context: The working context to size the candidate at.
    ///   - budget: The shared budget as earlier slots left it.
    ///   - footprint: The injected per-candidate raw footprint at `context`.
    /// - Returns: The candidate's report, with its verdict and (when sized) its
    ///   `× 1.2` footprint and charge.
    private static func evaluateCandidate(
        _ ref: ModelRef,
        role: ResidentRole,
        context: Int,
        budget: SharedBudget,
        footprint: (ModelRef, Int) -> Result<Int64, RepoMetadataError>
    ) -> CandidateReport {
        switch footprint(ref, context) {
        case .failure(.metadataUnavailable(let reason)):
            return CandidateReport(
                ref: ref,
                estimatedFootprintBytes: nil,
                chargedBytes: nil,
                verdict: .metadataUnavailable(reason)
            )
        case .success(let rawBytes):
            let sharesWeights = budget.chargedKeys.contains(ReservationKey(ref: ref, role: role))
            let rawCharge = sharesWeights
                ? sessionBytes(ref, context: context, residentBytes: rawBytes, footprint: footprint)
                : rawBytes
            let charged = withMargin(rawCharge)
            let verdict: Verdict = charged <= budget.remainingBytes ? .chosen : .tooLarge
            return CandidateReport(
                ref: ref,
                estimatedFootprintBytes: withMargin(rawBytes),
                chargedBytes: charged,
                verdict: verdict
            )
        }
    }

    /// The per-session part of a candidate's raw footprint at `context` — its KV
    /// cache — which a slot pays for even when an earlier slot already reserved
    /// the same container's weights.
    ///
    /// Sizing the same reference at ``weightsOnlyContext`` yields its weights
    /// alone, so the difference is the KV term. The injected closure answers
    /// both questions, which is why the dedupe needs no second closure and no
    /// change to ``resolve(profile:budgetBytes:footprint:nativeMaxContext:)``.
    ///
    /// The result is clamped at zero because the injected closure is free to
    /// report a *marginal* cost rather than an absolute one — the router charges
    /// nothing for a model already resident in its pool — which makes the figure
    /// at `context` smaller than the figure at a context of zero. Zero is the
    /// right charge there as well: reusing a resident model costs nothing.
    ///
    /// - Parameters:
    ///   - ref: The candidate sharing an already-reserved container.
    ///   - context: The working context the candidate is sized at.
    ///   - residentBytes: The candidate's whole raw footprint at `context`.
    ///   - footprint: The injected per-candidate raw footprint at a context.
    /// - Returns: The raw KV bytes, or the whole footprint when the candidate
    ///   cannot be sized at a context of zero.
    private static func sessionBytes(
        _ ref: ModelRef,
        context: Int,
        residentBytes: Int64,
        footprint: (ModelRef, Int) -> Result<Int64, RepoMetadataError>
    ) -> Int64 {
        guard case .success(let weightBytes) = footprint(ref, weightsOnlyContext) else {
            // Sizable at `context` and not at zero is not a shape the router
            // produces. Charge the whole footprint rather than guess a share.
            return residentBytes
        }
        return max(0, residentBytes - weightBytes)
    }

    /// The report for the candidate a slot chose, or `nil` when it chose none.
    ///
    /// - Parameter resolution: The slot resolution to read.
    /// - Returns: The chosen candidate's report, if there is one.
    private static func chosenReport(_ resolution: SlotResolution) -> CandidateReport? {
        resolution.considered.first { $0.verdict == .chosen }
    }

    // MARK: - Derived context (ladder)

    /// One attempt at resolving the full trio — embedding, the standard
    /// candidates on offer, and flash — at one working context.
    ///
    /// Kept as full ``SlotResolution``s (not just a pass/fail bit) so a
    /// failing attempt still yields the standard candidate's own footprint at
    /// this rung for a ``LadderAttempt`` even when a *different* slot is what
    /// actually blocked the trio.
    private struct TrioAttempt {
        let embedding: SlotResolution
        let standard: SlotResolution
        let flash: SlotResolution

        /// The three resolutions in allocation order: embedding reserves first,
        /// then standard, then flash sees what is left.
        var slots: [SlotResolution] { [embedding, standard, flash] }

        /// Whether every slot found a viable candidate at this rung.
        var isSucceeded: Bool { blockedSlot == nil }

        /// The slot that stopped this rung, or `nil` when the whole trio co-fit.
        ///
        /// The standard slot answers first, ahead of allocation order. A rung
        /// prints the standard candidate's own footprint, so "this candidate
        /// did not fit" is the fact a reader needs before any other slot's.
        /// Only when this candidate did fit does another slot's failure become
        /// the reason the rung failed.
        var blockedSlot: ModelSlot? {
            if standard.chosen == nil {
                return .standard
            }
            return slots.first { $0.chosen == nil }?.slot
        }
    }

    /// Resolves the full trio at one working context against one shared budget,
    /// charging each slot's choice before the next slot sees what is left.
    ///
    /// Every path through joint fit runs through here: the explicit-context path
    /// offers the profile's whole standard list, and each ladder rung offers the
    /// one candidate its outer loop is currently trying. One body keeps the
    /// deduped reservation in one place.
    ///
    /// - Parameters:
    ///   - profile: The authored profile supplying embedding/flash candidates.
    ///   - standardCandidates: The standard-slot candidates on offer here.
    ///   - budgetBytes: The shared memory budget the trio must co-fit.
    ///   - context: The working context to size every candidate at.
    ///   - footprint: The injected per-candidate raw footprint at `context`.
    /// - Returns: The three slot resolutions, in allocation order.
    private static func attemptTrio(
        profile: ProfileDefinition,
        standardCandidates: [ModelRef],
        budgetBytes: Int64,
        context: Int,
        footprint: (ModelRef, Int) -> Result<Int64, RepoMetadataError>
    ) -> TrioAttempt {
        var budget = SharedBudget(totalBytes: budgetBytes)
        let embedding = resolveSlot(
            .embedding,
            candidates: profile.embedding,
            budget: budget,
            context: context,
            footprint: footprint
        )
        budget.charge(embedding)
        let standard = resolveSlot(
            .standard,
            candidates: standardCandidates,
            budget: budget,
            context: context,
            footprint: footprint
        )
        budget.charge(standard)
        let flash = resolveSlot(
            .flash,
            candidates: profile.flash,
            budget: budget,
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

    /// A standard-slot candidate's winning ``TrioAttempt``, with the
    /// embedding and flash choices already unwrapped from it.
    ///
    /// Only ever constructed once ``TrioAttempt/isSucceeded`` is known `true`,
    /// so `embedding`/`flash` are always the trio's chosen references at that
    /// rung — never re-derived or re-checked by callers.
    private struct LadderWinner {
        let attempt: TrioAttempt
        let embedding: ModelRef
        let flash: ModelRef
    }

    /// The outcome of walking one standard-slot candidate's descending
    /// context ladder: every rung attempted, plus the winning rung (if any).
    private struct LadderWalkResult {
        /// Every rung tried, largest first, in the order attempted.
        let attempts: [LadderAttempt]

        /// The rung the candidate won at, or `nil` when no rung co-fit the
        /// trio.
        let winner: LadderWinner?
    }

    /// Walks one standard-slot candidate's descending context ladder (see
    /// ``contextLadder(nativeMaxContext:)``), trying each rung's full-trio
    /// attempt largest-first, and stopping at the first rung where the whole
    /// trio — embedding, this candidate, and flash — co-fits the budget.
    ///
    /// - Parameters:
    ///   - candidate: The standard-slot candidate being tried.
    ///   - profile: The authored profile supplying embedding/flash candidates.
    ///   - budgetBytes: The shared memory budget the trio must co-fit.
    ///   - native: The candidate's own native max context, anchoring the ladder.
    ///   - footprint: The injected per-candidate raw footprint at a context.
    /// - Returns: Every rung attempted and the winning rung, if any.
    private static func walkLadder(
        candidate: ModelRef,
        profile: ProfileDefinition,
        budgetBytes: Int64,
        native: Int,
        footprint: (ModelRef, Int) -> Result<Int64, RepoMetadataError>
    ) -> LadderWalkResult {
        var attempts: [LadderAttempt] = []

        for context in contextLadder(nativeMaxContext: native) {
            let attempt = attemptTrio(
                profile: profile,
                standardCandidates: [candidate],
                budgetBytes: budgetBytes,
                context: context,
                footprint: footprint
            )
            attempts.append(
                LadderAttempt(
                    contextTokens: context,
                    estimatedFootprintBytes: attempt.standard.considered.first?.estimatedFootprintBytes,
                    blockedSlot: attempt.blockedSlot
                )
            )

            if attempt.isSucceeded, let embeddingChosen = attempt.embedding.chosen, let flashChosen = attempt.flash.chosen {
                return LadderWalkResult(
                    attempts: attempts,
                    winner: LadderWinner(attempt: attempt, embedding: embeddingChosen, flash: flashChosen)
                )
            }
        }

        return LadderWalkResult(attempts: attempts, winner: nil)
    }

    /// Builds the successful ``JointResolution`` once a standard-slot
    /// candidate has won at some ladder rung.
    ///
    /// This is the success-case logic factored out of ``resolveViaLadder``:
    /// it assembles the standard slot's ``SlotResolution`` from the
    /// candidates considered before this one, the winning candidate's own
    /// report (carrying every rung it tried), and the remaining
    /// lower-preference candidates — recorded as skipped, since a
    /// higher-preference candidate already won and they were never sized.
    ///
    /// - Parameters:
    ///   - candidate: The winning standard-slot candidate.
    ///   - index: The candidate's position in ``ProfileDefinition/standard``,
    ///     so lower-preference candidates after it can be recorded as skipped.
    ///   - profile: The authored profile supplying the full standard list.
    ///   - standardConsidered: The reports for standard candidates tried
    ///     before this one (all `.metadataUnavailable`, `.tooLarge`, or
    ///     `.trioBlocked`).
    ///   - ladderAttempts: Every rung tried for the winning candidate.
    ///   - winner: The winning rung's trio attempt.
    /// - Returns: The resolved trio and per-slot reasoning.
    private static func makeLadderSuccess(
        candidate: ModelRef,
        index: Int,
        profile: ProfileDefinition,
        standardConsidered: [CandidateReport],
        ladderAttempts: [LadderAttempt],
        winner: LadderWinner
    ) -> JointResolution {
        let winningReport = chosenReport(winner.attempt.standard)
        let report = CandidateReport(
            ref: candidate,
            estimatedFootprintBytes: winningReport?.estimatedFootprintBytes,
            chargedBytes: winningReport?.chargedBytes,
            verdict: .chosen,
            ladderAttempts: ladderAttempts
        )
        let skipped = profile.standard[(index + 1)...].map {
            CandidateReport(
                ref: $0,
                estimatedFootprintBytes: nil,
                chargedBytes: nil,
                verdict: .skippedHigherPreferenceChosen
            )
        }
        let standardResolution = SlotResolution(
            slot: .standard,
            remainingBudgetBytes: winner.attempt.standard.remainingBudgetBytes,
            chosen: candidate,
            considered: standardConsidered + [report] + skipped,
            contextTokens: winner.attempt.standard.contextTokens
        )

        return JointResolution(
            embedding: winner.embedding,
            standard: candidate,
            flash: winner.flash,
            slots: [winner.attempt.embedding, standardResolution, winner.attempt.flash]
        )
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
                    CandidateReport(
                        ref: candidate,
                        estimatedFootprintBytes: nil,
                        chargedBytes: nil,
                        verdict: .metadataUnavailable(reason)
                    )
                )
            case .success(let native):
                let walk = walkLadder(
                    candidate: candidate,
                    profile: profile,
                    budgetBytes: budgetBytes,
                    native: native,
                    footprint: footprint
                )
                if let mostRecentRung = walk.attempts.last?.contextTokens {
                    lastTriedContext = mostRecentRung
                }

                guard let winner = walk.winner else {
                    standardConsidered.append(
                        CandidateReport(
                            ref: candidate,
                            estimatedFootprintBytes: nil,
                            chargedBytes: nil,
                            verdict: exhaustedLadderVerdict(walk.attempts),
                            ladderAttempts: walk.attempts
                        )
                    )
                    continue
                }

                return makeLadderSuccess(
                    candidate: candidate,
                    index: index,
                    profile: profile,
                    standardConsidered: standardConsidered,
                    ladderAttempts: walk.attempts,
                    winner: winner
                )
            }
        }

        // Every standard candidate exhausted its ladder with nothing fitting.
        // Re-resolve embedding/flash once more at the smallest context
        // actually tried, so the failure's diagnostics show what those slots
        // looked like at the context resolution gave up at.
        var budget = SharedBudget(totalBytes: budgetBytes)
        let embeddingResolution = resolveSlot(
            .embedding,
            candidates: profile.embedding,
            budget: budget,
            context: lastTriedContext,
            footprint: footprint
        )
        budget.charge(embeddingResolution)
        let standardResolution = SlotResolution(
            slot: .standard,
            remainingBudgetBytes: budget.remainingBytes,
            chosen: nil,
            considered: standardConsidered,
            contextTokens: lastTriedContext
        )
        let flashResolution = resolveSlot(
            .flash,
            candidates: profile.flash,
            budget: budget,
            context: lastTriedContext,
            footprint: footprint
        )
        throw ResolutionFailure(
            profileName: profile.name,
            budgetBytes: budgetBytes,
            slots: [embeddingResolution, standardResolution, flashResolution]
        )
    }

    /// The verdict for a standard-slot candidate whose whole context ladder
    /// failed.
    ///
    /// The candidate is ``Verdict/tooLarge`` only when it is what blocked the
    /// smallest rung tried — the rung it had the most budget at, and so its best
    /// chance. When a different slot blocked that rung the candidate itself fit,
    /// and the verdict names the slot that ran out instead. Reporting `tooLarge`
    /// there would put that word against a candidate a later slot can accept.
    ///
    /// - Parameter attempts: Every rung the candidate tried, largest first.
    /// - Returns: ``Verdict/tooLarge``, or ``Verdict/trioBlocked(_:)`` naming
    ///   the slot that had no viable candidate.
    private static func exhaustedLadderVerdict(_ attempts: [LadderAttempt]) -> Verdict {
        guard
            let smallestRung = attempts.last,
            let blocked = smallestRung.blockedSlot,
            blocked != .standard
        else {
            return .tooLarge
        }
        return .trioBlocked(blocked)
    }
}
