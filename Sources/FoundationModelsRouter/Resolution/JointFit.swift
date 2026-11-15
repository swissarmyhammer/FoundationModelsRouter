import Foundation

/// The successful result of joint fit: the chosen model for each slot and the
/// per-slot reasoning.
struct JointResolution: Sendable, Equatable {
    /// The chosen embedding model.
    let embedding: ModelRef

    /// The chosen standard (primary generation) model.
    let standard: ModelRef

    /// The chosen flash (latency-sensitive generation) model.
    let flash: ModelRef

    /// The model of the decision slot. It can be the model of another slot
    /// when the profile names that model as a decision candidate.
    let decision: ModelRef

    /// Each slot's resolution, in allocation order (embedding, standard,
    /// flash, decision).
    let slots: [SlotResolution]
}

/// The pure joint allocation that picks the highest-preference combination of
/// the four slot models that co-fits one shared memory budget.
///
/// Allocation runs in order against the shared budget: embedding, then
/// standard, then flash, then decision. Each slot sees only what earlier slots
/// left. In a slot, the candidates are tried in the author's preference order.
/// The first candidate that fits wins. A candidate fits when its raw footprint
/// estimate, the `charge`, is not more than the bytes that remain:
/// `charge <= remaining`.
///
/// The standard and flash slots can use the same model (task ^t4zn88x). A
/// model call holds the lock of its model only for the call into the model,
/// and a tool body holds nothing (task ^qhgfajc), so a flash call inside an
/// open submission on the same model does not wait on itself. The flash slot
/// is sized with the pool key of the standard winner, so the standard model
/// costs it only one session of KV cache (the provider prices it), and the
/// resolve loads the model once.
///
/// The decision slot is required, as each other slot is (task ^ybx7vvn). It
/// never uses the model of another slot in place of its own candidates: when
/// no decision candidate fits, the resolve fails, and the failure names the
/// decision slot. The slot is sized in the same attempt as the other three,
/// so a derived window leaves room for the decision model, and the window is
/// smaller by its bytes. The decision slot is sized at a context of its own,
/// ``ProfileDefinition/decisionContext`` (task ^fmhvrme), so its charge does
/// not grow with the window: the window search gives each token of the
/// window to the other slots. A decision candidate that the pool key of an earlier
/// winner serves is the same model, so it costs 0 more bytes: the provider
/// gets the pool keys of the embedding, standard and flash winners.
///
/// When ``ProfileDefinition/context`` is explicit, every candidate is sized at
/// that one context. When it is `nil`, the context is the largest window that
/// fits: standard-slot candidates are tried in preference order, and each one
/// gets the largest window, from one token up to its native max context, at
/// which all four slots co-fit the budget. The first candidate with a window
/// wins at that window. The window comes from the model and the budget, not
/// from a list of steps.
///
/// The allocation is pure. Footprints and native max contexts are injected as
/// closures, so it does no I/O.
enum JointFit {
    /// The smallest window a model can run at: one token. The window search
    /// looks for a fit in `smallestWindow...nativeMaxContext`.
    private static let smallestWindow = 1

    /// The raw footprint of a candidate in a slot at a context, as the
    /// caller injects it. The second argument is the slot that sizes the
    /// candidate. The fourth argument is the pool keys of the models that
    /// this resolve allocated before it sizes the candidate: the flash slot
    /// passes the key of the standard winner, and the decision slot the keys
    /// of the winners of the embedding, standard and flash slots. A candidate
    /// that one of these keys serves (``ModelPoolKey/canServe(_:)``) is a
    /// model that this resolve loads already, so it costs only what its slot
    /// adds to that model.
    typealias FootprintProvider = (ModelRef, ModelSlot, Int, Set<ModelPoolKey>) -> Result<Int64, RepoMetadataError>

    /// The shared budget as the slots consume it, in allocation order.
    private struct SharedBudget {
        /// The bytes still available to the next slot.
        private(set) var remainingBytes: Int64

        /// Creates a budget with nothing charged yet.
        init(totalBytes: Int64) {
            remainingBytes = totalBytes
        }

        /// Charges a resolved slot's chosen candidate. A slot that chose
        /// nothing charges nothing.
        mutating func charge(_ resolution: SlotResolution) {
            remainingBytes -= chosenReport(resolution)?.chargedBytes ?? 0
        }
    }

    /// Resolves a profile's four slots against one shared budget.
    ///
    /// - Parameters:
    ///   - profile: The authored profile whose slots supply candidates in preference order.
    ///   - budgetBytes: The shared memory budget, in bytes.
    ///   - footprint: The raw footprint of a candidate at a context. May be a marginal cost for a resident model.
    ///   - nativeMaxContext: The native max context of a candidate. Read only when ``ProfileDefinition/context`` is `nil`.
    /// - Returns: The chosen model of each slot and per-slot reasoning.
    /// - Throws: ``ResolutionFailure`` when any slot, the decision slot
    ///   included, has no viable candidate,
    ///   or ``NoWindowFailure`` when the context is derived and no standard
    ///   candidate's window could be read.
    static func resolve(
        profile: ProfileDefinition,
        budgetBytes: Int64,
        footprint: FootprintProvider,
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
        return try resolveAtLargestWindow(
            profile: profile,
            budgetBytes: budgetBytes,
            footprint: footprint,
            nativeMaxContext: nativeMaxContext
        )
    }

    // MARK: - Explicit context

    /// Resolves the four slots at one fixed working context. Every slot resolution it
    /// returns carries this one `context`.
    ///
    /// - Throws: ``ResolutionFailure`` when any slot has no viable candidate.
    private static func resolveAtFixedContext(
        profile: ProfileDefinition,
        budgetBytes: Int64,
        context: Int,
        footprint: FootprintProvider
    ) throws -> JointResolution {
        let attempt = attemptSlots(
            SlotCandidates(profile: profile, standard: profile.standard),
            budgetBytes: budgetBytes,
            context: context,
            footprint: footprint
        )

        guard case .cofit(let winner) = attempt.outcome else {
            throw ResolutionFailure(
                profileName: profile.name,
                budgetBytes: budgetBytes,
                slots: attempt.slots
            )
        }

        return makeResolution(winner: winner, standard: winner.attempt.standard)
    }

    /// The joint resolution of an attempt in which every slot chose a model.
    ///
    /// - Parameters:
    ///   - winner: The attempt that co-fit.
    ///   - standard: The resolution of the standard slot to record.
    /// - Returns: The joint resolution.
    private static func makeResolution(winner: SlotsWinner, standard: SlotResolution) -> JointResolution {
        JointResolution(
            embedding: winner.embedding,
            standard: winner.standard,
            flash: winner.flash,
            decision: winner.decision,
            slots: [winner.attempt.embedding, standard, winner.attempt.flash, winner.attempt.decision]
        )
    }

    /// The pool keys of the models that the embedding, standard and flash
    /// slots chose, each under the key that its slot asks the pool for at
    /// `context` (``ModelSlot/poolKey(of:context:)``). A slot that chose no
    /// model gives no key.
    private static func allocatedKeys(
        embedding: ModelRef?, standard: ModelRef?, flash: ModelRef?, context: Int
    ) -> Set<ModelPoolKey> {
        let chosen: [(ModelSlot, ModelRef?)] = [(.embedding, embedding), (.standard, standard), (.flash, flash)]
        return Set(chosen.compactMap { slot, ref in ref.map { slot.poolKey(of: $0, context: context) } })
    }

    /// Resolves one slot against the remaining budget. The first viable
    /// candidate in preference order wins. Each candidate gets a verdict.
    ///
    /// - Parameters:
    ///   - allocatedKeys: The pool keys of the models that this resolve
    ///     allocated before this slot. The embedding and standard slots pass
    ///     none (the default). The flash slot passes the key of the standard
    ///     winner, and the decision slot the keys of the three winners.
    private static func resolveSlot(
        _ slot: ModelSlot,
        candidates: [ModelRef],
        budget: SharedBudget,
        context: Int,
        allocatedKeys: Set<ModelPoolKey> = [],
        footprint: FootprintProvider
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
                ref, slot: slot, context: context, budget: budget, allocatedKeys: allocatedKeys, footprint: footprint)
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

    /// Sizes one candidate of `slot` against the remaining budget at
    /// `context` and gives its verdict. The candidate is charged its whole
    /// raw footprint estimate, as `footprint` gives it for `allocatedKeys`.
    private static func evaluateCandidate(
        _ ref: ModelRef,
        slot: ModelSlot,
        context: Int,
        budget: SharedBudget,
        allocatedKeys: Set<ModelPoolKey>,
        footprint: FootprintProvider
    ) -> CandidateReport {
        switch footprint(ref, slot, context, allocatedKeys) {
        case .failure(.metadataUnavailable(let reason)):
            return CandidateReport(
                ref: ref,
                estimatedFootprintBytes: nil,
                chargedBytes: nil,
                verdict: .metadataUnavailable(reason)
            )
        case .success(let bytes):
            return CandidateReport(
                ref: ref,
                estimatedFootprintBytes: bytes,
                chargedBytes: bytes,
                verdict: bytes <= budget.remainingBytes ? .chosen : .tooLarge
            )
        }
    }

    /// The report for the candidate a slot chose, or `nil` when it chose none.
    private static func chosenReport(_ resolution: SlotResolution) -> CandidateReport? {
        resolution.considered.first { $0.verdict == .chosen }
    }

    // MARK: - The four slots at one context

    /// The candidates each slot tries in one attempt, in preference order.
    private struct SlotCandidates {
        /// The embedding-slot candidates.
        let embedding: [ModelRef]

        /// The standard-slot candidates.
        let standard: [ModelRef]

        /// The flash-slot candidates.
        let flash: [ModelRef]

        /// The decision-slot candidates.
        let decision: [ModelRef]

        /// The context of the decision slot (``ProfileDefinition/decisionContext``).
        let decisionContext: Int

        /// The profile's embedding, flash and decision candidates, with
        /// `standard` as the standard-slot candidates.
        init(profile: ProfileDefinition, standard: [ModelRef]) {
            embedding = profile.embedding
            self.standard = standard
            flash = profile.flash
            decision = profile.decision
            decisionContext = profile.decisionContext
        }

        /// The four models `winner` chose, one for each slot.
        init(chosenBy winner: SlotsWinner) {
            embedding = [winner.embedding]
            standard = [winner.standard]
            flash = [winner.flash]
            decision = [winner.decision]
            decisionContext = winner.attempt.decision.contextTokens
        }
    }

    /// One attempt at resolving the four slots at one working context.
    private struct SlotsAttempt {
        /// The embedding slot's resolution.
        let embedding: SlotResolution

        /// The standard slot's resolution.
        let standard: SlotResolution

        /// The flash slot's resolution.
        let flash: SlotResolution

        /// The decision slot's resolution.
        let decision: SlotResolution

        /// The four resolutions in allocation order.
        var slots: [SlotResolution] { [embedding, standard, flash, decision] }

        /// Whether every slot co-fit, or the slot that stopped this attempt.
        /// The standard slot is reported first, ahead of allocation order.
        var outcome: SlotsOutcome {
            guard let standardModel = standard.chosen else { return .blocked(by: .standard) }
            guard let embeddingModel = embedding.chosen else { return .blocked(by: .embedding) }
            guard let flashModel = flash.chosen else { return .blocked(by: .flash) }
            guard let decisionModel = decision.chosen else { return .blocked(by: .decision) }
            return .cofit(
                SlotsWinner(
                    attempt: self, embedding: embeddingModel, standard: standardModel, flash: flashModel,
                    decision: decisionModel)
            )
        }

        /// The standard-slot candidate's own raw footprint estimate in this
        /// attempt, or `nil` when it could not be sized.
        var standardFootprintBytes: Int64? {
            standard.considered.first?.estimatedFootprintBytes
        }
    }

    /// The outcome of one ``SlotsAttempt``.
    private enum SlotsOutcome {
        /// Every slot chose a model.
        case cofit(SlotsWinner)

        /// The slot found no viable candidate.
        case blocked(by: ModelSlot)
    }

    /// A ``SlotsAttempt`` in which every slot chose a model, with the four
    /// choices unwrapped from it.
    private struct SlotsWinner {
        /// The attempt that co-fit the budget.
        let attempt: SlotsAttempt

        /// The chosen embedding model.
        let embedding: ModelRef

        /// The chosen standard model.
        let standard: ModelRef

        /// The chosen flash model.
        let flash: ModelRef

        /// The chosen decision model.
        let decision: ModelRef
    }

    /// Resolves the four slots against one shared budget: the embedding,
    /// standard and flash slots at the working context, and the decision
    /// slot at its own context. Each slot's choice is charged before the next slot is
    /// resolved. The flash slot is sized with the pool key of the standard
    /// winner, and the decision slot with the pool keys of the three winners
    /// before it, so a candidate that one of them serves costs only what its
    /// slot adds to that model: one session of KV cache in the flash slot,
    /// and 0 bytes in the decision slot.
    ///
    /// - Parameter candidates: The candidates each slot tries here.
    private static func attemptSlots(
        _ candidates: SlotCandidates,
        budgetBytes: Int64,
        context: Int,
        footprint: FootprintProvider
    ) -> SlotsAttempt {
        var budget = SharedBudget(totalBytes: budgetBytes)
        let embedding = resolveSlot(
            .embedding,
            candidates: candidates.embedding,
            budget: budget,
            context: context,
            footprint: footprint
        )
        budget.charge(embedding)
        let standard = resolveSlot(
            .standard,
            candidates: candidates.standard,
            budget: budget,
            context: context,
            footprint: footprint
        )
        budget.charge(standard)
        let flash = resolveSlot(
            .flash,
            candidates: candidates.flash,
            budget: budget,
            context: context,
            allocatedKeys: allocatedKeys(embedding: nil, standard: standard.chosen, flash: nil, context: context),
            footprint: footprint
        )
        budget.charge(flash)
        let decision = resolveSlot(
            .decision,
            candidates: candidates.decision,
            budget: budget,
            context: candidates.decisionContext,
            allocatedKeys: allocatedKeys(
                embedding: embedding.chosen, standard: standard.chosen, flash: flash.chosen, context: context),
            footprint: footprint
        )
        return SlotsAttempt(embedding: embedding, standard: standard, flash: flash, decision: decision)
    }

    // MARK: - Derived context (the largest window that fits)

    /// The outcome of one standard-slot candidate's window search.
    private enum WindowSearchResult {
        /// The four slots co-fit at the window that `fit` records. `winner` is the
        /// attempt at that window.
        case found(fit: WindowFit, winner: SlotsWinner)

        /// No window fits. `fit` records the slot that blocked the smallest
        /// window, and `verdict` is the candidate's verdict for that slot.
        case unfit(fit: WindowFit, verdict: Verdict)
    }

    /// Finds the largest window in `1...native` at which one standard-slot
    /// candidate and the other three slots co-fit the budget.
    ///
    /// The native window is tried first. When it does not fit, a window of
    /// one token is tried. When that does not fit either, no window fits.
    /// Otherwise the window is computed from the bytes the four slots charge,
    /// which grow linearly with the window, and confirmed with one attempt.
    ///
    /// - Parameter native: The candidate's native max context.
    private static func searchWindow(
        candidate: ModelRef,
        profile: ProfileDefinition,
        budgetBytes: Int64,
        native: Int,
        footprint: FootprintProvider
    ) -> WindowSearchResult {
        let candidates = SlotCandidates(profile: profile, standard: [candidate])
        let atNative = attemptSlots(candidates, budgetBytes: budgetBytes, context: native, footprint: footprint)
        if case .cofit(let winner) = atNative.outcome {
            return makeFoundResult(winner: winner, native: native, window: native)
        }

        let atSmallest = attemptSlots(
            candidates, budgetBytes: budgetBytes, context: smallestWindow, footprint: footprint
        )
        let smallestWinner: SlotsWinner
        switch atSmallest.outcome {
        case .cofit(let winner):
            smallestWinner = winner
        case .blocked(by: let slot):
            let fit = WindowFit(
                nativeContextTokens: native,
                outcome: .blocked(by: slot, estimatedFootprintBytes: atSmallest.standardFootprintBytes)
            )
            return .unfit(fit: fit, verdict: verdict(blockedBy: slot))
        }

        let largest = largestConfirmedWindow(
            smallestWinner: smallestWinner,
            candidates: candidates,
            failedWindow: native,
            budgetBytes: budgetBytes,
            footprint: footprint
        )
        return makeFoundResult(winner: largest.winner, native: native, window: largest.window)
    }

    /// The search result for a window at which the four slots co-fit.
    private static func makeFoundResult(winner: SlotsWinner, native: Int, window: Int) -> WindowSearchResult {
        let fit = WindowFit(
            nativeContextTokens: native,
            outcome: .fits(
                contextTokens: window,
                estimatedFootprintBytes: winner.attempt.standardFootprintBytes
            )
        )
        return .found(fit: fit, winner: winner)
    }

    /// Computes the largest window below `failedWindow` from the charges of
    /// the four slots, and confirms it with one attempt. When the attempt does not
    /// co-fit, the computation runs again with that window as the new failed
    /// window, so each step is smaller and the search ends at the smallest
    /// window, which `smallestWinner` already confirms.
    ///
    /// - Parameters:
    ///   - smallestWinner: The attempt that co-fit at the smallest window.
    ///   - failedWindow: A window at which the four slots did not co-fit.
    private static func largestConfirmedWindow(
        smallestWinner: SlotsWinner,
        candidates: SlotCandidates,
        failedWindow: Int,
        budgetBytes: Int64,
        footprint: FootprintProvider
    ) -> (window: Int, winner: SlotsWinner) {
        guard
            let window = computedWindow(
                plan: SlotCandidates(chosenBy: smallestWinner),
                below: failedWindow,
                budgetBytes: budgetBytes,
                footprint: footprint
            ),
            window > smallestWindow
        else {
            return (smallestWindow, smallestWinner)
        }
        let attempt = attemptSlots(candidates, budgetBytes: budgetBytes, context: window, footprint: footprint)
        if case .cofit(let winner) = attempt.outcome {
            return (window, winner)
        }
        return largestConfirmedWindow(
            smallestWinner: smallestWinner,
            candidates: candidates,
            failedWindow: window,
            budgetBytes: budgetBytes,
            footprint: footprint
        )
    }

    /// The largest window below `failedWindow` at which the bytes `plan`
    /// charges stay in the budget.
    ///
    /// The charge is measured at the smallest window and at `failedWindow`.
    /// The difference, divided by the tokens between the two, is the bytes
    /// each token adds. The budget left after the charge at the smallest
    /// window, divided by the bytes for each token, floored, is the number of
    /// tokens the window can add. The decision slot is sized at its own
    /// context in both measures, so its charge is in the budget it leaves
    /// and not in the bytes for each token.
    ///
    /// - Returns: The window, or `nil` when a charge cannot be sized or the
    ///   charge does not grow with the window.
    private static func computedWindow(
        plan: SlotCandidates,
        below failedWindow: Int,
        budgetBytes: Int64,
        footprint: FootprintProvider
    ) -> Int? {
        guard
            let smallestCharge = planChargeBytes(plan, context: smallestWindow, footprint: footprint),
            let failedCharge = planChargeBytes(plan, context: failedWindow, footprint: footprint)
        else {
            return nil
        }
        let bytesPerToken = (failedCharge - smallestCharge) / Int64(failedWindow - smallestWindow)
        guard bytesPerToken > 0 else { return nil }
        let addedTokens = (budgetBytes - smallestCharge) / bytesPerToken
        return min(failedWindow - 1, smallestWindow + Int(addedTokens))
    }

    /// The bytes `plan` charges at `context` when every slot keeps its one
    /// model. The attempt runs against an unlimited budget, so every slot
    /// chooses its model, as in a real attempt.
    ///
    /// - Returns: The sum of the four charges, or `nil` when one cannot be sized.
    private static func planChargeBytes(
        _ plan: SlotCandidates,
        context: Int,
        footprint: FootprintProvider
    ) -> Int64? {
        let attempt = attemptSlots(plan, budgetBytes: .max, context: context, footprint: footprint)
        let charges = attempt.slots.map { chosenReport($0)?.chargedBytes }
        guard charges.allSatisfy({ $0 != nil }) else { return nil }
        return charges.compactMap { $0 }.reduce(0, +)
    }

    /// Builds the ``JointResolution`` after a standard-slot candidate found a
    /// window. Later candidates are recorded as skipped.
    ///
    /// - Parameters:
    ///   - index: The candidate's position in ``ProfileDefinition/standard``.
    ///   - standardConsidered: The reports for standard candidates tried before this one.
    private static func makeWindowSuccess(
        index: Int,
        profile: ProfileDefinition,
        standardConsidered: [CandidateReport],
        fit: WindowFit,
        winner: SlotsWinner
    ) -> JointResolution {
        let winningReport = chosenReport(winner.attempt.standard)
        let report = CandidateReport(
            ref: winner.standard,
            estimatedFootprintBytes: winningReport?.estimatedFootprintBytes,
            chargedBytes: winningReport?.chargedBytes,
            verdict: .chosen,
            windowFit: fit
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
            chosen: winner.standard,
            considered: standardConsidered + [report] + skipped,
            contextTokens: winner.attempt.standard.contextTokens
        )

        return makeResolution(winner: winner, standard: standardResolution)
    }

    /// Resolves a profile whose ``ProfileDefinition/context`` is `nil`. Standard
    /// candidates are tried in preference order. The first candidate with a
    /// window that fits wins at its largest window.
    ///
    /// - Throws: ``NoWindowFailure`` when no standard candidate's window could
    ///   be read, or ``ResolutionFailure`` when no standard candidate has a
    ///   window that fits.
    private static func resolveAtLargestWindow(
        profile: ProfileDefinition,
        budgetBytes: Int64,
        footprint: FootprintProvider,
        nativeMaxContext: (ModelRef) -> Result<Int, RepoMetadataError>
    ) throws -> JointResolution {
        var standardConsidered: [CandidateReport] = []
        // The smallest window actually tried, so the failure path below can
        // size the diagnostics of the other slots at a real, tried context. It
        // stays `nil` when no candidate's window was searched: the standard
        // slot names no candidate, or each native max context lookup failed.
        var lastTriedContext: Int?

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
                let search = searchWindow(
                    candidate: candidate,
                    profile: profile,
                    budgetBytes: budgetBytes,
                    native: native,
                    footprint: footprint
                )

                switch search {
                case .found(let fit, let winner):
                    return makeWindowSuccess(
                        index: index,
                        profile: profile,
                        standardConsidered: standardConsidered,
                        fit: fit,
                        winner: winner
                    )
                case .unfit(let fit, let verdict):
                    lastTriedContext = smallestWindow
                    standardConsidered.append(
                        CandidateReport(
                            ref: candidate,
                            estimatedFootprintBytes: nil,
                            chargedBytes: nil,
                            verdict: verdict,
                            windowFit: fit
                        )
                    )
                }
            }
        }

        guard let triedContext = lastTriedContext else {
            throw NoWindowFailure(profileName: profile.name, standardConsidered: standardConsidered)
        }
        throw makeWindowFailure(
            profile: profile,
            budgetBytes: budgetBytes,
            standardConsidered: standardConsidered,
            triedContext: triedContext,
            footprint: footprint
        )
    }

    /// The failure when no standard candidate has a window that fits.
    /// Embedding, flash and decision are resolved once more at
    /// `triedContext`, the smallest window actually tried, so the diagnostics
    /// show those slots at the context where resolution stopped.
    private static func makeWindowFailure(
        profile: ProfileDefinition,
        budgetBytes: Int64,
        standardConsidered: [CandidateReport],
        triedContext: Int,
        footprint: FootprintProvider
    ) -> ResolutionFailure {
        var budget = SharedBudget(totalBytes: budgetBytes)
        let embeddingResolution = resolveSlot(
            .embedding,
            candidates: profile.embedding,
            budget: budget,
            context: triedContext,
            footprint: footprint
        )
        budget.charge(embeddingResolution)
        let standardResolution = SlotResolution(
            slot: .standard,
            remainingBudgetBytes: budget.remainingBytes,
            chosen: nil,
            considered: standardConsidered,
            contextTokens: triedContext
        )
        let flashResolution = resolveSlot(
            .flash,
            candidates: profile.flash,
            budget: budget,
            context: triedContext,
            footprint: footprint
        )
        budget.charge(flashResolution)
        let decisionResolution = resolveSlot(
            .decision,
            candidates: profile.decision,
            budget: budget,
            context: profile.decisionContext,
            allocatedKeys: allocatedKeys(
                embedding: embeddingResolution.chosen, standard: nil, flash: flashResolution.chosen,
                context: triedContext),
            footprint: footprint
        )
        return ResolutionFailure(
            profileName: profile.name,
            budgetBytes: budgetBytes,
            slots: [embeddingResolution, standardResolution, flashResolution, decisionResolution]
        )
    }

    /// The verdict for a standard-slot candidate with no window that fits,
    /// when `slot` blocked the smallest window.
    ///
    /// - Returns: ``Verdict/tooLarge`` when the candidate itself blocked the
    ///   smallest window, or ``Verdict/trioBlocked(_:)`` naming the slot that
    ///   blocked it.
    private static func verdict(blockedBy slot: ModelSlot) -> Verdict {
        switch slot {
        case .standard:
            return .tooLarge
        case .embedding, .flash, .decision:
            return .trioBlocked(slot)
        }
    }
}
