import Foundation

/// The successful result of joint fit: the chosen model for each slot and the
/// per-slot reasoning.
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
/// Allocation runs in order against the shared budget: embedding, then
/// standard, then flash. Each slot sees only what earlier slots left. In a slot,
/// the candidates are tried in the author's preference order. The first
/// candidate that fits wins. A candidate fits when `charge × 1.2 <= remaining`.
///
/// Two slots that name one reference in one role share one resident container.
/// The weights are charged one time. A later slot on the same container is
/// charged only its per-session KV cache, read from `sessionBytes`.
///
/// When ``ProfileDefinition/context`` is explicit, every candidate is sized at
/// that one context. When it is `nil`, the context is derived by a ladder:
/// standard-slot candidates are the outer loop, and a descending ladder of
/// context rungs, anchored on each candidate's native max context, is the
/// inner loop. The first candidate with a fitting rung wins at its largest
/// fitting rung.
///
/// The allocation is pure. Footprints and native max contexts are injected as
/// closures, so it does no I/O.
public enum JointFit {
    /// The overhead margin numerator: footprints are scaled by `6 / 5` (`× 1.2`).
    private static let marginNumerator: Int64 = 6

    /// The overhead margin denominator.
    private static let marginDenominator: Int64 = 5

    /// The context step-down rungs a ladder tries below the native max
    /// context, in descending order.
    private static let ladderStepDowns: [Int] = [131_072, 65_536, 32_768, 16_384, 8_192, 4_096]

    /// Applies the `× 1.2` overhead margin to a raw footprint. Rounds up.
    ///
    /// - Parameter rawBytes: The raw footprint in bytes.
    /// - Returns: `ceil(rawBytes × 1.2)`.
    static func withMargin(_ rawBytes: Int64) -> Int64 {
        (rawBytes * marginNumerator + marginDenominator - 1) / marginDenominator
    }

    // MARK: - Reserving one resident container once

    /// The role a slot loads its chosen model under. Two slots share one
    /// resident container only when they load one reference in one role.
    private enum ResidentRole: Hashable {
        /// Loaded as a generation model, for the `standard` and `flash` slots.
        case generation

        /// Loaded as an embedder, for the `embedding` slot.
        case embedding

        /// The role `slot` loads its chosen model under.
        init(slot: ModelSlot) {
            switch slot {
            case .standard, .flash:
                self = .generation
            case .embedding:
                self = .embedding
            }
        }
    }

    /// The unit a model's weights are reserved on, one time: the reference as
    /// the profile spells it, and the role it is loaded under. The key carries
    /// no context because one resolution gives one context to every slot. If
    /// per-slot contexts are added, add the context to this key.
    private struct ReservationKey: Hashable {
        /// The candidate reference, exactly as the profile spells it.
        // periphery:ignore
        let ref: ModelRef

        /// The role the slot loads that reference under.
        // periphery:ignore
        let role: ResidentRole
    }

    /// The shared budget as the slots consume it, in allocation order.
    private struct SharedBudget {
        /// The bytes still available to the next slot.
        private(set) var remainingBytes: Int64

        /// Every key whose weights an earlier slot already charged.
        private(set) var chargedKeys: Set<ReservationKey> = []

        /// Creates a budget with nothing charged yet.
        init(totalBytes: Int64) {
            remainingBytes = totalBytes
        }

        /// Charges a resolved slot's chosen candidate and records its key as
        /// reserved. A slot that chose nothing charges nothing.
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
    ///   - profile: The authored profile whose slots supply candidates in preference order.
    ///   - budgetBytes: The shared memory budget, in bytes.
    ///   - footprint: The raw footprint of a candidate at a context. May be a marginal cost for a resident model.
    ///   - sessionBytes: The absolute KV cache bytes of one session at a context. Read only for a slot that reuses an earlier slot's container.
    ///   - nativeMaxContext: The native max context of a candidate. Read only when ``ProfileDefinition/context`` is `nil`.
    /// - Returns: The chosen trio and per-slot reasoning.
    /// - Throws: ``ResolutionFailure`` when any slot has no viable candidate.
    public static func resolve(
        profile: ProfileDefinition,
        budgetBytes: Int64,
        footprint: (ModelRef, Int) -> Result<Int64, RepoMetadataError>,
        sessionBytes: (ModelRef, Int) -> Result<Int64, RepoMetadataError>,
        nativeMaxContext: (ModelRef) -> Result<Int, RepoMetadataError>
    ) throws -> JointResolution {
        if let explicitContext = profile.context {
            return try resolveAtFixedContext(
                profile: profile,
                budgetBytes: budgetBytes,
                context: explicitContext,
                footprint: footprint,
                sessionBytes: sessionBytes
            )
        }
        return try resolveViaLadder(
            profile: profile,
            budgetBytes: budgetBytes,
            footprint: footprint,
            sessionBytes: sessionBytes,
            nativeMaxContext: nativeMaxContext
        )
    }

    // MARK: - Explicit context (single rung)

    /// Resolves the trio at one fixed working context. Every slot resolution it
    /// returns carries this one `context`.
    ///
    /// - Throws: ``ResolutionFailure`` when any slot has no viable candidate.
    private static func resolveAtFixedContext(
        profile: ProfileDefinition,
        budgetBytes: Int64,
        context: Int,
        footprint: (ModelRef, Int) -> Result<Int64, RepoMetadataError>,
        sessionBytes: (ModelRef, Int) -> Result<Int64, RepoMetadataError>
    ) throws -> JointResolution {
        let attempt = attemptTrio(
            profile: profile,
            standardCandidates: profile.standard,
            budgetBytes: budgetBytes,
            context: context,
            footprint: footprint,
            sessionBytes: sessionBytes
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

    /// Resolves one slot against the remaining budget. The first viable
    /// candidate in preference order wins. Each candidate gets a verdict.
    private static func resolveSlot(
        _ slot: ModelSlot,
        candidates: [ModelRef],
        budget: SharedBudget,
        context: Int,
        footprint: (ModelRef, Int) -> Result<Int64, RepoMetadataError>,
        sessionBytes: (ModelRef, Int) -> Result<Int64, RepoMetadataError>
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
                footprint: footprint,
                sessionBytes: sessionBytes
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

    /// Sizes one candidate against the remaining budget at `context` and gives
    /// its verdict. A candidate whose key an earlier slot reserved is charged
    /// its per-session KV cache from `sessionBytes` only.
    private static func evaluateCandidate(
        _ ref: ModelRef,
        role: ResidentRole,
        context: Int,
        budget: SharedBudget,
        footprint: (ModelRef, Int) -> Result<Int64, RepoMetadataError>,
        sessionBytes: (ModelRef, Int) -> Result<Int64, RepoMetadataError>
    ) -> CandidateReport {
        switch footprint(ref, context) {
        case .failure(.metadataUnavailable(let reason)):
            return unsizedReport(ref, reason: reason)
        case .success(let wholeBytes):
            guard budget.chargedKeys.contains(ReservationKey(ref: ref, role: role)) else {
                return sizedReport(ref, wholeBytes: wholeBytes, rawChargeBytes: wholeBytes, budget: budget)
            }
            switch sessionBytes(ref, context) {
            case .failure(.metadataUnavailable(let reason)):
                return unsizedReport(ref, reason: reason)
            case .success(let cacheBytes):
                return sizedReport(ref, wholeBytes: wholeBytes, rawChargeBytes: cacheBytes, budget: budget)
            }
        }
    }

    /// The report for a candidate the injected closures could not size.
    private static func unsizedReport(_ ref: ModelRef, reason: String) -> CandidateReport {
        CandidateReport(
            ref: ref,
            estimatedFootprintBytes: nil,
            chargedBytes: nil,
            verdict: .metadataUnavailable(reason)
        )
    }

    /// The report for a sized candidate: its whole `× 1.2` footprint, the
    /// `× 1.2` bytes it charges, and whether that charge fits what remains.
    private static func sizedReport(
        _ ref: ModelRef,
        wholeBytes: Int64,
        rawChargeBytes: Int64,
        budget: SharedBudget
    ) -> CandidateReport {
        let charged = withMargin(rawChargeBytes)
        return CandidateReport(
            ref: ref,
            estimatedFootprintBytes: withMargin(wholeBytes),
            chargedBytes: charged,
            verdict: charged <= budget.remainingBytes ? .chosen : .tooLarge
        )
    }

    /// The report for the candidate a slot chose, or `nil` when it chose none.
    private static func chosenReport(_ resolution: SlotResolution) -> CandidateReport? {
        resolution.considered.first { $0.verdict == .chosen }
    }

    // MARK: - Derived context (ladder)

    /// One attempt at resolving the full trio at one working context.
    private struct TrioAttempt {
        let embedding: SlotResolution
        let standard: SlotResolution
        let flash: SlotResolution

        /// The three resolutions in allocation order.
        var slots: [SlotResolution] { [embedding, standard, flash] }

        /// Whether every slot found a viable candidate at this rung.
        var isSucceeded: Bool { blockedSlot == nil }

        /// The slot that stopped this rung, or `nil` when the whole trio co-fit.
        /// The standard slot is reported first, ahead of allocation order.
        var blockedSlot: ModelSlot? {
            if standard.chosen == nil {
                return .standard
            }
            return slots.first { $0.chosen == nil }?.slot
        }
    }

    /// Resolves the full trio at one working context against one shared budget.
    /// Each slot's choice is charged before the next slot is resolved.
    ///
    /// - Parameter standardCandidates: The standard-slot candidates to try here.
    private static func attemptTrio(
        profile: ProfileDefinition,
        standardCandidates: [ModelRef],
        budgetBytes: Int64,
        context: Int,
        footprint: (ModelRef, Int) -> Result<Int64, RepoMetadataError>,
        sessionBytes: (ModelRef, Int) -> Result<Int64, RepoMetadataError>
    ) -> TrioAttempt {
        var budget = SharedBudget(totalBytes: budgetBytes)
        let embedding = resolveSlot(
            .embedding,
            candidates: profile.embedding,
            budget: budget,
            context: context,
            footprint: footprint,
            sessionBytes: sessionBytes
        )
        budget.charge(embedding)
        let standard = resolveSlot(
            .standard,
            candidates: standardCandidates,
            budget: budget,
            context: context,
            footprint: footprint,
            sessionBytes: sessionBytes
        )
        budget.charge(standard)
        let flash = resolveSlot(
            .flash,
            candidates: profile.flash,
            budget: budget,
            context: context,
            footprint: footprint,
            sessionBytes: sessionBytes
        )
        return TrioAttempt(embedding: embedding, standard: standard, flash: flash)
    }

    /// Builds the descending context ladder for one standard-slot candidate:
    /// its native max context, capped at ``RepoMetadata/nativeMaxContextCap``,
    /// then every step-down rung below that top rung.
    private static func contextLadder(nativeMaxContext: Int) -> [Int] {
        let topRung = min(nativeMaxContext, RepoMetadata.nativeMaxContextCap)
        return [topRung] + ladderStepDowns.filter { $0 < topRung }
    }

    /// A standard-slot candidate's winning ``TrioAttempt``, with the embedding
    /// and flash choices unwrapped from it.
    private struct LadderWinner {
        let attempt: TrioAttempt
        let embedding: ModelRef
        let flash: ModelRef
    }

    /// The outcome of one standard-slot candidate's ladder walk.
    private struct LadderWalkResult {
        /// Every rung tried, largest first.
        let attempts: [LadderAttempt]

        /// The rung the candidate won at, or `nil` when no rung co-fit the trio.
        let winner: LadderWinner?
    }

    /// Walks one standard-slot candidate's descending context ladder. Stops at
    /// the first rung where the whole trio co-fits the budget.
    ///
    /// - Parameter native: The candidate's native max context.
    private static func walkLadder(
        candidate: ModelRef,
        profile: ProfileDefinition,
        budgetBytes: Int64,
        native: Int,
        footprint: (ModelRef, Int) -> Result<Int64, RepoMetadataError>,
        sessionBytes: (ModelRef, Int) -> Result<Int64, RepoMetadataError>
    ) -> LadderWalkResult {
        var attempts: [LadderAttempt] = []

        for context in contextLadder(nativeMaxContext: native) {
            let attempt = attemptTrio(
                profile: profile,
                standardCandidates: [candidate],
                budgetBytes: budgetBytes,
                context: context,
                footprint: footprint,
                sessionBytes: sessionBytes
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

    /// Builds the ``JointResolution`` after a standard-slot candidate won at a
    /// ladder rung. Later candidates are recorded as skipped.
    ///
    /// - Parameters:
    ///   - index: The candidate's position in ``ProfileDefinition/standard``.
    ///   - standardConsidered: The reports for standard candidates tried before this one.
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

    /// Resolves a profile whose ``ProfileDefinition/context`` is `nil`. Standard
    /// candidates are the outer loop. Each candidate's context ladder is the
    /// inner loop. The first candidate with a fitting rung wins at its largest
    /// fitting rung.
    ///
    /// - Throws: ``ResolutionFailure`` when no standard candidate has a fitting rung.
    private static func resolveViaLadder(
        profile: ProfileDefinition,
        budgetBytes: Int64,
        footprint: (ModelRef, Int) -> Result<Int64, RepoMetadataError>,
        sessionBytes: (ModelRef, Int) -> Result<Int64, RepoMetadataError>,
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
                footprint: footprint,
                sessionBytes: sessionBytes
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
                    footprint: footprint,
                    sessionBytes: sessionBytes
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
            footprint: footprint,
            sessionBytes: sessionBytes
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
            footprint: footprint,
            sessionBytes: sessionBytes
        )
        throw ResolutionFailure(
            profileName: profile.name,
            budgetBytes: budgetBytes,
            slots: [embeddingResolution, standardResolution, flashResolution]
        )
    }

    /// The verdict for a standard-slot candidate whose whole ladder failed.
    ///
    /// - Returns: ``Verdict/tooLarge`` when the candidate blocked the smallest
    ///   rung, or ``Verdict/trioBlocked(_:)`` naming the slot that blocked it.
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
