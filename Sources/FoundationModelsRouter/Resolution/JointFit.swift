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

    /// Each slot's resolution, in allocation order (embedding, standard, flash).
    let slots: [SlotResolution]

    /// Creates a joint resolution.
    init(embedding: ModelRef, standard: ModelRef, flash: ModelRef, slots: [SlotResolution]) {
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
/// candidate that fits wins. A candidate fits when its raw footprint estimate,
/// the `charge`, is not more than the bytes that remain: `charge <= remaining`.
///
/// Two slots that name one reference in one role share one resident container.
/// The weights are charged one time. A later slot on the same container is
/// charged only its per-session KV cache, read from `sessionBytes`.
///
/// When ``ProfileDefinition/context`` is explicit, every candidate is sized at
/// that one context. When it is `nil`, the context is the largest window that
/// fits: standard-slot candidates are tried in preference order, and each one
/// gets the largest window, from one token up to its native max context, at
/// which the whole trio co-fits the budget. The first candidate with a window
/// wins at that window. The window comes from the model and the budget, not
/// from a list of steps.
///
/// The allocation is pure. Footprints and native max contexts are injected as
/// closures, so it does no I/O.
enum JointFit {
    /// The smallest window a model can run at: one token. The window search
    /// looks for a fit in `smallestWindow...nativeMaxContext`.
    private static let smallestWindow = 1

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
    /// - Throws: ``ResolutionFailure`` when any slot has no viable candidate,
    ///   or ``NoWindowFailure`` when the context is derived and no standard
    ///   candidate's window could be read.
    static func resolve(
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
        return try resolveAtLargestWindow(
            profile: profile,
            budgetBytes: budgetBytes,
            footprint: footprint,
            sessionBytes: sessionBytes,
            nativeMaxContext: nativeMaxContext
        )
    }

    // MARK: - Explicit context

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
            TrioCandidates(profile: profile, standard: profile.standard),
            budgetBytes: budgetBytes,
            context: context,
            footprint: footprint,
            sessionBytes: sessionBytes
        )

        guard case .cofit(let winner) = attempt.outcome else {
            throw ResolutionFailure(
                profileName: profile.name,
                budgetBytes: budgetBytes,
                slots: attempt.slots
            )
        }

        return JointResolution(
            embedding: winner.embedding,
            standard: winner.standard,
            flash: winner.flash,
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
            return makeUnsizedReport(ref: ref, reason: reason)
        case .success(let wholeBytes):
            guard budget.chargedKeys.contains(ReservationKey(ref: ref, role: role)) else {
                return makeSizedReport(ref: ref, wholeBytes: wholeBytes, chargedBytes: wholeBytes, budget: budget)
            }
            switch sessionBytes(ref, context) {
            case .failure(.metadataUnavailable(let reason)):
                return makeUnsizedReport(ref: ref, reason: reason)
            case .success(let cacheBytes):
                return makeSizedReport(ref: ref, wholeBytes: wholeBytes, chargedBytes: cacheBytes, budget: budget)
            }
        }
    }

    /// The report for a candidate the injected closures could not size.
    private static func makeUnsizedReport(ref: ModelRef, reason: String) -> CandidateReport {
        CandidateReport(
            ref: ref,
            estimatedFootprintBytes: nil,
            chargedBytes: nil,
            verdict: .metadataUnavailable(reason)
        )
    }

    /// The report for a sized candidate: its whole raw footprint estimate, the
    /// raw bytes it charges, and whether that charge fits what remains.
    private static func makeSizedReport(
        ref: ModelRef,
        wholeBytes: Int64,
        chargedBytes: Int64,
        budget: SharedBudget
    ) -> CandidateReport {
        CandidateReport(
            ref: ref,
            estimatedFootprintBytes: wholeBytes,
            chargedBytes: chargedBytes,
            verdict: chargedBytes <= budget.remainingBytes ? .chosen : .tooLarge
        )
    }

    /// The report for the candidate a slot chose, or `nil` when it chose none.
    private static func chosenReport(_ resolution: SlotResolution) -> CandidateReport? {
        resolution.considered.first { $0.verdict == .chosen }
    }

    // MARK: - One trio at one context

    /// The candidates each slot tries in one trio attempt, in preference order.
    private struct TrioCandidates {
        /// The embedding-slot candidates.
        let embedding: [ModelRef]

        /// The standard-slot candidates.
        let standard: [ModelRef]

        /// The flash-slot candidates.
        let flash: [ModelRef]

        /// The profile's embedding and flash candidates, with `standard` as
        /// the standard-slot candidates.
        init(profile: ProfileDefinition, standard: [ModelRef]) {
            embedding = profile.embedding
            self.standard = standard
            flash = profile.flash
        }

        /// The three models `winner` chose, one for each slot.
        init(chosenBy winner: TrioWinner) {
            embedding = [winner.embedding]
            standard = [winner.standard]
            flash = [winner.flash]
        }
    }

    /// One attempt at resolving the full trio at one working context.
    private struct TrioAttempt {
        /// The embedding slot's resolution.
        let embedding: SlotResolution

        /// The standard slot's resolution.
        let standard: SlotResolution

        /// The flash slot's resolution.
        let flash: SlotResolution

        /// The three resolutions in allocation order.
        var slots: [SlotResolution] { [embedding, standard, flash] }

        /// Whether the whole trio co-fit, or the slot that stopped this
        /// attempt. The standard slot is reported first, ahead of allocation
        /// order.
        var outcome: TrioOutcome {
            guard let standardModel = standard.chosen else { return .blocked(by: .standard) }
            guard let embeddingModel = embedding.chosen else { return .blocked(by: .embedding) }
            guard let flashModel = flash.chosen else { return .blocked(by: .flash) }
            return .cofit(
                TrioWinner(attempt: self, embedding: embeddingModel, standard: standardModel, flash: flashModel)
            )
        }

        /// The standard-slot candidate's own raw footprint estimate in this
        /// attempt, or `nil` when it could not be sized.
        var standardFootprintBytes: Int64? {
            standard.considered.first?.estimatedFootprintBytes
        }
    }

    /// The outcome of one ``TrioAttempt``.
    private enum TrioOutcome {
        /// Every slot chose a model.
        case cofit(TrioWinner)

        /// The slot found no viable candidate.
        case blocked(by: ModelSlot)
    }

    /// A ``TrioAttempt`` in which every slot chose a model, with the three
    /// choices unwrapped from it.
    private struct TrioWinner {
        /// The attempt that co-fit the budget.
        let attempt: TrioAttempt

        /// The chosen embedding model.
        let embedding: ModelRef

        /// The chosen standard model.
        let standard: ModelRef

        /// The chosen flash model.
        let flash: ModelRef
    }

    /// Resolves the full trio at one working context against one shared budget.
    /// Each slot's choice is charged before the next slot is resolved.
    ///
    /// - Parameter candidates: The candidates each slot tries here.
    private static func attemptTrio(
        _ candidates: TrioCandidates,
        budgetBytes: Int64,
        context: Int,
        footprint: (ModelRef, Int) -> Result<Int64, RepoMetadataError>,
        sessionBytes: (ModelRef, Int) -> Result<Int64, RepoMetadataError>
    ) -> TrioAttempt {
        var budget = SharedBudget(totalBytes: budgetBytes)
        let embedding = resolveSlot(
            .embedding,
            candidates: candidates.embedding,
            budget: budget,
            context: context,
            footprint: footprint,
            sessionBytes: sessionBytes
        )
        budget.charge(embedding)
        let standard = resolveSlot(
            .standard,
            candidates: candidates.standard,
            budget: budget,
            context: context,
            footprint: footprint,
            sessionBytes: sessionBytes
        )
        budget.charge(standard)
        let flash = resolveSlot(
            .flash,
            candidates: candidates.flash,
            budget: budget,
            context: context,
            footprint: footprint,
            sessionBytes: sessionBytes
        )
        return TrioAttempt(embedding: embedding, standard: standard, flash: flash)
    }

    // MARK: - Derived context (the largest window that fits)

    /// The outcome of one standard-slot candidate's window search.
    private enum WindowSearchResult {
        /// The trio co-fit at the window that `fit` records. `winner` is the
        /// attempt at that window.
        case found(fit: WindowFit, winner: TrioWinner)

        /// No window fits. `fit` records the slot that blocked the smallest
        /// window, and `verdict` is the candidate's verdict for that slot.
        case unfit(fit: WindowFit, verdict: Verdict)
    }

    /// Finds the largest window in `1...native` at which one standard-slot
    /// candidate's trio co-fits the budget.
    ///
    /// The native window is tried first. When it does not fit, a window of
    /// one token is tried. When that does not fit either, no window fits.
    /// Otherwise the window is computed from the bytes the trio charges, which
    /// grow linearly with the window, and confirmed with one trio attempt.
    ///
    /// - Parameter native: The candidate's native max context.
    private static func searchWindow(
        candidate: ModelRef,
        profile: ProfileDefinition,
        budgetBytes: Int64,
        native: Int,
        footprint: (ModelRef, Int) -> Result<Int64, RepoMetadataError>,
        sessionBytes: (ModelRef, Int) -> Result<Int64, RepoMetadataError>
    ) -> WindowSearchResult {
        let candidates = TrioCandidates(profile: profile, standard: [candidate])
        let atNative = attemptTrio(
            candidates, budgetBytes: budgetBytes, context: native, footprint: footprint, sessionBytes: sessionBytes
        )
        if case .cofit(let winner) = atNative.outcome {
            return makeFoundResult(winner: winner, native: native, window: native)
        }

        let atSmallest = attemptTrio(
            candidates, budgetBytes: budgetBytes, context: smallestWindow,
            footprint: footprint, sessionBytes: sessionBytes
        )
        let smallestWinner: TrioWinner
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
            footprint: footprint,
            sessionBytes: sessionBytes
        )
        return makeFoundResult(winner: largest.winner, native: native, window: largest.window)
    }

    /// The search result for a window at which the trio co-fit.
    private static func makeFoundResult(winner: TrioWinner, native: Int, window: Int) -> WindowSearchResult {
        let fit = WindowFit(
            nativeContextTokens: native,
            outcome: .fits(
                contextTokens: window,
                estimatedFootprintBytes: winner.attempt.standardFootprintBytes
            )
        )
        return .found(fit: fit, winner: winner)
    }

    /// Computes the largest window below `failedWindow` from the trio charges,
    /// and confirms it with one trio attempt. When the attempt does not
    /// co-fit, the computation runs again with that window as the new failed
    /// window, so each step is smaller and the search ends at the smallest
    /// window, which `smallestWinner` already confirms.
    ///
    /// - Parameters:
    ///   - smallestWinner: The trio that co-fit at the smallest window.
    ///   - failedWindow: A window at which the trio did not co-fit.
    private static func largestConfirmedWindow(
        smallestWinner: TrioWinner,
        candidates: TrioCandidates,
        failedWindow: Int,
        budgetBytes: Int64,
        footprint: (ModelRef, Int) -> Result<Int64, RepoMetadataError>,
        sessionBytes: (ModelRef, Int) -> Result<Int64, RepoMetadataError>
    ) -> (window: Int, winner: TrioWinner) {
        guard
            let window = computedWindow(
                plan: TrioCandidates(chosenBy: smallestWinner),
                below: failedWindow,
                budgetBytes: budgetBytes,
                footprint: footprint,
                sessionBytes: sessionBytes
            ),
            window > smallestWindow
        else {
            return (smallestWindow, smallestWinner)
        }
        let attempt = attemptTrio(
            candidates, budgetBytes: budgetBytes, context: window, footprint: footprint, sessionBytes: sessionBytes
        )
        if case .cofit(let winner) = attempt.outcome {
            return (window, winner)
        }
        return largestConfirmedWindow(
            smallestWinner: smallestWinner,
            candidates: candidates,
            failedWindow: window,
            budgetBytes: budgetBytes,
            footprint: footprint,
            sessionBytes: sessionBytes
        )
    }

    /// The largest window below `failedWindow` at which the bytes `plan`
    /// charges stay in the budget.
    ///
    /// The charge is measured at the smallest window and at `failedWindow`.
    /// The difference, divided by the tokens between the two, is the bytes
    /// each token adds. The budget left after the charge at the smallest
    /// window, divided by the bytes for each token, floored, is the number of
    /// tokens the window can add.
    ///
    /// - Returns: The window, or `nil` when a charge cannot be sized or the
    ///   charge does not grow with the window.
    private static func computedWindow(
        plan: TrioCandidates,
        below failedWindow: Int,
        budgetBytes: Int64,
        footprint: (ModelRef, Int) -> Result<Int64, RepoMetadataError>,
        sessionBytes: (ModelRef, Int) -> Result<Int64, RepoMetadataError>
    ) -> Int? {
        guard
            let smallestCharge = planChargeBytes(
                plan, context: smallestWindow, footprint: footprint, sessionBytes: sessionBytes
            ),
            let failedCharge = planChargeBytes(
                plan, context: failedWindow, footprint: footprint, sessionBytes: sessionBytes
            )
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
    /// chooses its model, and a slot that reuses an earlier slot's container
    /// is charged its KV cache only, as in a real attempt.
    ///
    /// - Returns: The sum of the three charges, or `nil` when one cannot be sized.
    private static func planChargeBytes(
        _ plan: TrioCandidates,
        context: Int,
        footprint: (ModelRef, Int) -> Result<Int64, RepoMetadataError>,
        sessionBytes: (ModelRef, Int) -> Result<Int64, RepoMetadataError>
    ) -> Int64? {
        let attempt = attemptTrio(
            plan, budgetBytes: .max, context: context, footprint: footprint, sessionBytes: sessionBytes
        )
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
        winner: TrioWinner
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

        return JointResolution(
            embedding: winner.embedding,
            standard: winner.standard,
            flash: winner.flash,
            slots: [winner.attempt.embedding, standardResolution, winner.attempt.flash]
        )
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
        footprint: (ModelRef, Int) -> Result<Int64, RepoMetadataError>,
        sessionBytes: (ModelRef, Int) -> Result<Int64, RepoMetadataError>,
        nativeMaxContext: (ModelRef) -> Result<Int, RepoMetadataError>
    ) throws -> JointResolution {
        var standardConsidered: [CandidateReport] = []
        // The smallest window actually tried, so the failure path below can
        // size embedding/flash's diagnostics at a real, tried context. It
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
                    footprint: footprint,
                    sessionBytes: sessionBytes
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
            footprint: footprint,
            sessionBytes: sessionBytes
        )
    }

    /// The failure when no standard candidate has a window that fits.
    /// Embedding and flash are resolved once more at `triedContext`, the
    /// smallest window actually tried, so the diagnostics show those slots at
    /// the context where resolution stopped.
    private static func makeWindowFailure(
        profile: ProfileDefinition,
        budgetBytes: Int64,
        standardConsidered: [CandidateReport],
        triedContext: Int,
        footprint: (ModelRef, Int) -> Result<Int64, RepoMetadataError>,
        sessionBytes: (ModelRef, Int) -> Result<Int64, RepoMetadataError>
    ) -> ResolutionFailure {
        var budget = SharedBudget(totalBytes: budgetBytes)
        let embeddingResolution = resolveSlot(
            .embedding,
            candidates: profile.embedding,
            budget: budget,
            context: triedContext,
            footprint: footprint,
            sessionBytes: sessionBytes
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
            footprint: footprint,
            sessionBytes: sessionBytes
        )
        return ResolutionFailure(
            profileName: profile.name,
            budgetBytes: budgetBytes,
            slots: [embeddingResolution, standardResolution, flashResolution]
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
        case .embedding, .flash:
            return .trioBlocked(slot)
        }
    }
}
