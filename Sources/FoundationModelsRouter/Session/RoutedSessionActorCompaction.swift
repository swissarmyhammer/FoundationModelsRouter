import Foundation
import FoundationModels
import os

/// The logger an abandoned fold's discarded summarizer failure is reported to
/// (see ``RoutedSessionActor/noteAbandonedFold(discarding:tier:)``).
private let sessionCompactionLogger = makeModuleLogger(category: "Compaction")

/// Adapts a ``LanguageModelSessionBackend`` to ``CompactionSummarizer``.
///
/// Each ``summarize(_:maxTokens:)`` call runs on a fresh, blank-slate backend
/// (``LanguageModelSessionBackend/replacingTranscript(_:)`` with an empty
/// transcript), never on the live backend. The live backend can be near its
/// context limit, and a summarizer call must not enter the conversation
/// history or leak from one chunk into the next.
private struct BackendCompactionSummarizer: CompactionSummarizer {
    /// The backend each blank-slate summarizer call is built from.
    let backend: any LanguageModelSessionBackend

    func summarize(_ prompt: String, maxTokens: Int) async throws -> String {
        // The fold's own ceiling, passed down to the generation path rather
        // than left to resolve to its generic per-turn default — see
        // ``CompactionSummarizer/summarize(_:maxTokens:)``.
        try await backend.replacingTranscript(Transcript(entries: [])).respond(to: prompt, maxTokens: maxTokens)
    }
}

/// Wraps another ``CompactionSummarizer`` so every model call it makes runs
/// inside the owning session's turn-cancellation boundary
/// (``RoutedSessionActor/runCancellableModelCall(composedPrompt:_:)``). This
/// lets ``RoutedSession/cancelCurrentTurn()`` and task cancellation stop a
/// fold's summarizer call.
private struct CancellableCompactionSummarizer: CompactionSummarizer {
    /// The summarizer whose calls are made cancellable.
    let base: any CompactionSummarizer

    /// The session whose in-flight turn those calls belong to.
    let session: RoutedSessionActor

    func summarize(_ prompt: String, maxTokens: Int) async throws -> String {
        // Each of a map-reduce fold's several calls is registered, and cancellable,
        // on its own — so a cancellation landing between two chunks is honored by
        // the next chunk's pre-flight check rather than waiting out the rest of the
        // fold.
        //
        // Sound only because ``Summarization`` makes those calls *serially*:
        // ``RoutedSessionActor/inFlightModelCall`` holds one call at a time, so
        // chunks summarized concurrently would leave only the last-registered one
        // reachable by ``RoutedSession/cancelCurrentTurn()`` — the caller-cancels
        // route would still reach each of them through its own
        // `withTaskCancellationHandler`, so the exposure is to that primitive
        // specifically. Parallelizing either of ``Summarization``'s summarizeOnce
        // loops therefore means registering a *set* of in-flight calls, not one —
        // see the matching note in Sources/FoundationModelsRouter/Compaction/Summarization.swift.
        try await session.runCancellableModelCall(composedPrompt: prompt) { [base] promptText in
            try await base.summarize(promptText, maxTokens: maxTokens)
        }
    }
}

/// ``RoutedSessionActor``'s context accounting and compaction: the measured
/// fill, the caller-driven fold, and the automatic fold.
extension RoutedSessionActor {
    /// See ``RoutedSession/contextFill``. Synchronous and actor-isolated, which
    /// satisfies the protocol's `{ get async }` requirement.
    var contextFill: Double {
        usageState.fill(contextTokens: contextTokens)
    }

    /// See ``RoutedSession/compact(prompt:budget:)``.
    ///
    /// Summarizes with a fresh backend over this session's own model. Takes the
    /// turn lock and a generation permit for the duration (``beginTurn()``),
    /// then runs ``fold(prompt:budget:summarizer:summarizerModel:)``.
    @discardableResult
    func compact(
        prompt: CompactionPrompt = .default,
        budget: TokenBudget? = nil
    ) async throws -> CompactionResult {
        try await beginTurn()
        defer { endTurn() }
        return try await fold(
            prompt: prompt, budget: budget,
            summarizer: BackendCompactionSummarizer(backend: backend), summarizerModel: model)
    }

    /// Auto-compaction's fold entry point. The caller must already hold
    /// ``turnLock`` and a ``generationGate`` permit; this method acquires
    /// neither.
    ///
    /// Tries the summarizer tiers in order: the profile's
    /// ``LanguageModelProfile/flash`` slot (skipped when this session is the
    /// flash slot), then this session's own model, then the deterministic-only
    /// pipeline, which never throws. The flash slot must hold a model that can
    /// summarize; the fold applies no quality check on the summary text.
    ///
    /// - Parameters:
    ///   - prompt: The compaction prompt sent to the summarizer tier that runs.
    ///   - budget: The token budget to fold against.
    /// - Returns: What the fold did. ``CompactionResult/summarizerModel`` names
    ///   the tier that wrote the applied summary, or `nil` for a
    ///   deterministic-only fold.
    /// - Throws: `CancellationError` when a tier fails and a cancellation is
    ///   outstanding against this turn (``isTurnCancelled``). That case does not
    ///   degrade to the next tier. The abandoned tier's own failure is logged
    ///   (``noteAbandonedFold(discarding:tier:)``).
    func performAutoCompaction(
        prompt: CompactionPrompt,
        budget: TokenBudget
    ) async throws -> CompactionResult {
        if slot != .flash {
            do {
                return try await fold(
                    prompt: prompt, budget: budget,
                    summarizer: BackendCompactionSummarizer(backend: profile.flash.container.makeSession(instructions: nil)),
                    summarizerModel: profile.flash.chosen
                )
            } catch {
                try abandonFoldIfCancelled(discarding: error, tier: .flash)
                // Fall through to the own-model tier below.
            }
        }
        do {
            return try await fold(
                prompt: prompt, budget: budget,
                summarizer: BackendCompactionSummarizer(backend: backend), summarizerModel: model)
        } catch {
            // The *only* abandon guard on this path for a session that already is the
            // flash slot and so skipped the tier above.
            try abandonFoldIfCancelled(discarding: error, tier: .ownModel)
            return try await fold(prompt: prompt, budget: budget, summarizer: nil, summarizerModel: nil)
        }
    }

    /// Which of ``performAutoCompaction(prompt:budget:)``'s model-assisted
    /// tiers a fold ran on.
    private enum FoldSummarizerTier: String {
        /// The profile's ``LanguageModelProfile/flash`` slot.
        case flash

        /// This session's own model.
        case ownModel = "own-model"
    }

    /// Abandons the fold a model-assisted tier just failed when a stop is
    /// outstanding against this turn. Otherwise returns so that tier can
    /// degrade. Keyed on ``isTurnCancelled``, never on the failure's type.
    ///
    /// - Parameters:
    ///   - error: The failure the tier threw.
    ///   - tier: The tier that threw it.
    /// - Throws: `CancellationError` when a cancellation is outstanding against
    ///   this turn.
    private func abandonFoldIfCancelled(discarding error: Error, tier: FoldSummarizerTier) throws {
        guard isTurnCancelled else { return }
        noteAbandonedFold(discarding: error, tier: tier)
        throw CancellationError()
    }

    /// Logs the summarizer failure an abandoned fold discards, unless it is a
    /// `CancellationError`. Only the tier, the session id, and the error's type
    /// are public in the log; the description can contain transcript content.
    ///
    /// - Parameters:
    ///   - error: The failure the abandoned tier threw.
    ///   - tier: The tier that threw it.
    private func noteAbandonedFold(discarding error: Error, tier: FoldSummarizerTier) {
        guard !(error is CancellationError) else { return }
        sessionCompactionLogger.warning(
            """
            abandoning the \(tier.rawValue, privacy: .public) summarizer tier's fold for session \
            \(self.id.description, privacy: .public) because a stop is outstanding against its turn; \
            discarding the \(String(describing: type(of: error)), privacy: .public) it raised: \
            \(error.localizedDescription)
            """
        )
    }

    /// The fold mechanics ``compact(prompt:budget:)`` and
    /// ``performAutoCompaction(prompt:budget:)`` share. Runs
    /// ``Compactor/compact(_:prompt:budget:summarizer:summarization:pendingRuns:)``
    /// over ``backend``'s transcript. When a stage applied, records the fold's
    /// new entries by id, appends one boundary entry, and replaces ``backend``
    /// with one seeded from the folded transcript. Otherwise leaves the
    /// session unchanged. The caller must hold both gates.
    ///
    /// - Parameters:
    ///   - prompt: The compaction prompt sent to `summarizer`.
    ///   - budget: The token budget to fold against, or `nil` for this
    ///     session's resolved working context.
    ///   - summarizer: The summarizer, or `nil` for the deterministic-only
    ///     pipeline. Wrapped in ``CancellableCompactionSummarizer``.
    ///   - summarizerModel: The model `summarizer` runs on, or `nil`. Written
    ///     to ``CompactionResult/summarizerModel`` when a summary applies.
    /// - Returns: What the fold did.
    /// - Throws: Whatever `summarizer.summarize(_:maxTokens:)` throws. A fold
    ///   that throws leaves this session unchanged.
    private func fold(
        prompt: CompactionPrompt,
        budget: TokenBudget?,
        summarizer: (any CompactionSummarizer)?,
        summarizerModel: ModelRef?
    ) async throws -> CompactionResult {
        let entries = backend.transcriptEntries()
        let resolvedBudget = budget ?? TokenBudget(limit: contextTokens)

        // Read at the moment the compaction boundary is written: the runs
        // still running in this session's mailbox, as run-plane summaries
        // (token, op, latest progress — never output content), so a
        // post-compaction model keeps the tokens of its in-flight work
        // until the session reports each run's settlement.
        let pendingRuns = await mailbox.backgroundRuns().map { run in
            CompactionSegment.PendingRunSummary(
                completionToken: run.completionToken,
                op: run.op,
                latestProgressDetail: run.latestProgressDetail
            )
        }

        let (folded, pipelineResult) = try await Compactor.compact(
            Transcript(entries: entries),
            prompt: prompt,
            budget: resolvedBudget,
            // Wrapped, never handed over bare: a fold's summarizer call is a model
            // call this session's turn owns, and must be cancellable as one (see
            // ``CancellableCompactionSummarizer``). A `nil` summarizer stays `nil`,
            // so a deterministic-only fold is untouched.
            summarizer: summarizer.map { CancellableCompactionSummarizer(base: $0, session: self) },
            // This session's own stage, not the pipeline's defaults — and read
            // here, in the one place both folds share, so a caller-driven fold
            // and an automatic one condense the same way (see
            // ``RoutedSessionActor/summarization``).
            summarization: summarization,
            pendingRuns: pendingRuns
        )

        // The report names the model that wrote its summary — the signal task
        // ^59fd9rt adds, applied in the one place both entry points share. A
        // result with no summary returns unchanged, so a deterministic-only
        // fold, and a fold whose summary was discarded, name nothing.
        let result = pipelineResult.withSummarizerModel(summarizerModel?.stringValue)

        // Nothing to fold (already under target) or every stage ran and
        // still couldn't land it (the oversized-tail case): `folded` is
        // `currentTranscript` verbatim, so there is nothing new to record and
        // no reason to swap `backend`.
        guard !result.stagesApplied.isEmpty else { return result }

        await recordSessionMetaIfNeeded()

        // What `backend` will hold, reported as `contextFill`'s numerator
        // immediately — the same way a restored session whose newest event is
        // a compaction checkpoint reports its segment's own `tokensAfter`
        // (compaction_plan.md §1.5); the next live turn re-measures exactly
        // and replaces it, same as any other measured state. Rescaled onto the
        // measured scale first, because `result.tokensAfter` is not measured at
        // all — see `foldedUsage(tokensBefore:tokensAfter:)`. Computed before
        // `usageState` is overwritten below, since the rescale calibrates
        // against the pre-fold measurement.
        let measuredTokensAfter = foldedUsage(tokensBefore: result.tokensBefore, tokensAfter: result.tokensAfter)

        // Every applied fold appends exactly one boundary entry carrying its
        // ``CompactionSegment`` checkpoint (task ^h1008kb). ``Summarization``
        // synthesizes its own (the summary entry, identified by
        // `result.summaryEntryId`); a deterministic-only fold produces none —
        // ``ToolOutputElision`` rewrites segments under the entry's original
        // id and ``TurnTruncation`` only removes entries, so the id-diff
        // below would otherwise see nothing new, record no checkpoint, and a
        // restore would rebuild the whole pre-fold history — so one is
        // synthesized here, carrying the fold's *measured* token counts so a
        // restore reports this fold's own post-fold fill.
        let applied: Transcript
        if result.summaryEntryId == nil {
            applied = appendingDeterministicBoundary(
                to: folded,
                preFoldEntries: entries,
                result: result,
                measuredTokensAfter: measuredTokensAfter,
                pendingRuns: pendingRuns
            )
        } else {
            applied = folded
        }

        // `entries.prefix(persistedEntryCount)` is exactly what this
        // session has already recorded to `transcript.jsonl` — the same
        // baseline `recordTranscriptDelta(grammar:since:usage:pendingEvents:)`
        // diffs an ordinary turn's positional growth against. A fold is not
        // a mere extension of it (`applied` is typically shorter and
        // reorders entries relative to it), so the diff here is by entry id
        // rather than position — see ``TranscriptDiffer/diffByEntryId(lastSeen:current:routerId:sessionId:parentId:slot:model:)``.
        let alreadyRecorded = Transcript(entries: entries.prefix(persistedEntryCount))
        let diffPartials = TranscriptDiffer.diffByEntryId(
            lastSeen: alreadyRecorded,
            current: applied,
            routerId: routerId,
            sessionId: id,
            parentId: parentId,
            slot: slot,
            model: model
        )
        for diffPartial in diffPartials {
            await append(
                partial: makePartialEvent(
                    kind: diffPartial.kind,
                    grammar: grammar,
                    text: diffPartial.text,
                    entry: diffPartial.entry
                )
            )
        }

        // Swap the inner session in place: same actor, same nonisolated
        // `id`, same `recorder`, same `recordingDirectory` — only the
        // backend driving generation changes (compaction_plan.md
        // requirement 4). Seeded with the boundary entry included, so what
        // the model sees live is exactly what a restore rebuilds from the
        // checkpoint's live window.
        backend = backend.replacingTranscript(applied)
        // Only the positional backend baseline rewinds to the folded window.
        // `historyOrdinal` already advanced when the diff above recorded the
        // boundary entry, and never rewinds: the fold changed the *context*,
        // not the session's position in its own append-only history.
        persistedEntryCount = applied.count
        // The folded window is what the backend now holds, so its identity is
        // what later turns' non-append-divergence checks verify against — see
        // ``persistedBaseline``.
        persistedBaseline = TranscriptDiffer.Baseline(transcript: applied)
        usageState = .measured(input: measuredTokensAfter, output: 0)

        return result
    }

    /// Returns `folded` with one synthesized boundary entry appended, the
    /// checkpoint a deterministic-only fold must leave. Built by
    /// ``CompactionSegment/appendingDeterministicBoundary(to:preFoldEntryIds:tokensBefore:tokensAfter:stagesApplied:pendingRuns:)``
    /// with measured-scale token counts.
    ///
    /// - Parameters:
    ///   - folded: The transcript the deterministic pipeline produced.
    ///   - preFoldEntries: The backend's entries before the fold ran.
    ///   - result: What the fold did.
    ///   - measuredTokensAfter: The post-fold size on the measured scale.
    ///   - pendingRuns: The run-plane summaries of the runs still running.
    /// - Returns: `folded` plus the boundary entry, in that order.
    private func appendingDeterministicBoundary(
        to folded: Transcript,
        preFoldEntries: [Transcript.Entry],
        result: CompactionResult,
        measuredTokensAfter: Int,
        pendingRuns: [CompactionSegment.PendingRunSummary]
    ) -> Transcript {
        CompactionSegment.appendingDeterministicBoundary(
            to: folded,
            preFoldEntryIds: preFoldEntries.map(\.id),
            // Measured pre-fold usage when the session has one — the same
            // calibration `foldedUsage(tokensBefore:tokensAfter:)` reads —
            // else the pipeline's estimate, the best available number.
            tokensBefore: usageState.measuredTokens ?? result.tokensBefore,
            tokensAfter: measuredTokensAfter,
            stagesApplied: result.stagesApplied,
            pendingRuns: pendingRuns.isEmpty ? nil : pendingRuns
        )
    }

    /// A fold's post-fold size on the measured scale ``usageState`` uses.
    /// ``CompactionResult/tokensAfter`` is an estimate; this rescales it by the
    /// ratio of the pre-fold measurement to the pre-fold estimate. Returns
    /// `tokensAfter` unchanged when there is no measurement to calibrate
    /// against.
    ///
    /// - Parameters:
    ///   - tokensBefore: The pipeline's estimate of the transcript it folded.
    ///   - tokensAfter: The pipeline's estimate of the transcript it produced.
    /// - Returns: `tokensAfter` on the measured scale.
    private func foldedUsage(tokensBefore: Int, tokensAfter: Int) -> Int {
        guard let measuredBefore = usageState.measuredTokens, measuredBefore > 0, tokensBefore > 0 else {
            return tokensAfter
        }
        return Int((Double(measuredBefore) * Double(tokensAfter) / Double(tokensBefore)).rounded())
    }
}
