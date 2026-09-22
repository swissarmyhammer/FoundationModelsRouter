import Foundation
import FoundationModels
import os

/// The logger an abandoned compaction's discarded summarizer failure is reported to
/// (see ``RoutedSessionActor/noteAbandonedCompaction(discarding:tier:)``).
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
        // The compaction's own ceiling, passed down to the generation path rather
        // than left to resolve to its generic per-turn default — see
        // ``CompactionSummarizer/summarize(_:maxTokens:)``.
        try await backend.replacingTranscript(Transcript(entries: [])).respond(to: prompt, maxTokens: maxTokens)
    }
}

/// Wraps another ``CompactionSummarizer`` so every model call it makes runs
/// inside the owning session's turn-cancellation boundary
/// (``RoutedSessionActor/runCancellableModelCall(composedPrompt:_:)``). This
/// lets ``RoutedSession/cancelCurrentTurn()`` and task cancellation stop a
/// compaction's summarizer call.
private struct CancellableCompactionSummarizer: CompactionSummarizer {
    /// The summarizer whose calls are made cancellable.
    let base: any CompactionSummarizer

    /// The session whose in-flight turn those calls belong to.
    let session: RoutedSessionActor

    func summarize(_ prompt: String, maxTokens: Int) async throws -> String {
        // Each of a map-reduce compaction's several calls is registered, and cancellable,
        // on its own — so a cancellation landing between two chunks is honored by
        // the next chunk's pre-flight check rather than waiting out the rest of the
        // compaction.
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
/// fill, the caller-driven compaction, and the automatic compaction.
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
    /// then runs ``runCompaction(prompt:budget:summarizer:summarizerModel:)`` inside the
    /// span ``withCompactionSpan(trigger:_:)`` opens.
    ///
    /// Unlike the automatic compaction, this one has no next tier to degrade to, so a
    /// summarizer failure reaches the caller — and the span records it.
    @discardableResult
    func compact(
        prompt: CompactionPrompt = .default,
        budget: TokenBudget? = nil
    ) async throws -> CompactionResult {
        try await beginTurn()
        defer { endTurn() }
        return try await withCompactionSpan(trigger: .caller) {
            let result = try await runCompaction(
                prompt: prompt, budget: budget,
                summarizer: BackendCompactionSummarizer(backend: backend), summarizerModel: model)
            return (result, .ownModel)
        }
    }

    /// Auto-compaction's entry point. The caller must already hold
    /// ``turnLock`` and a ``generationGate`` permit; this method acquires
    /// neither.
    ///
    /// Tries the summarizer tiers in order: the profile's
    /// ``LanguageModelProfile/flash`` slot (skipped when this session is the
    /// flash slot), then this session's own model, then the deterministic-only
    /// pipeline, which never throws. The flash slot must hold a model that can
    /// summarize; the compaction applies no quality check on the summary text.
    ///
    /// The whole degrade runs inside one span
    /// (``withCompactionSpan(trigger:_:)``), so a compaction that fell back reports
    /// the tier it settled on rather than a failure — see
    /// ``RouterTracing/AttributeKey/compactionTier``.
    ///
    /// - Parameters:
    ///   - prompt: The compaction prompt sent to the summarizer tier that runs.
    ///   - budget: The token budget to compact against.
    /// - Returns: What the compaction did. ``CompactionResult/summarizerModel`` names
    ///   the tier that wrote the applied summary, or `nil` for a
    ///   deterministic-only compaction.
    /// - Throws: `CancellationError` when a tier fails and a cancellation is
    ///   outstanding against this turn (``isTurnCancelled``). That case does not
    ///   degrade to the next tier. The abandoned tier's own failure is logged
    ///   (``noteAbandonedCompaction(discarding:tier:)``).
    func performAutoCompaction(
        prompt: CompactionPrompt,
        budget: TokenBudget
    ) async throws -> CompactionResult {
        try await withCompactionSpan(trigger: .auto) {
            try await compactThroughTiers(prompt: prompt, budget: budget)
        }
    }

    /// Runs ``performAutoCompaction(prompt:budget:)``'s tier ladder and reports
    /// which rung answered.
    ///
    /// - Parameters:
    ///   - prompt: The compaction prompt sent to the summarizer tier that runs.
    ///   - budget: The token budget to compact against.
    /// - Returns: What the compaction did, and the tier that ran it.
    /// - Throws: `CancellationError` when a tier fails and a cancellation is
    ///   outstanding against this turn.
    private func compactThroughTiers(
        prompt: CompactionPrompt,
        budget: TokenBudget
    ) async throws -> (result: CompactionResult, tier: CompactionSummarizerTier) {
        if slot != .flash {
            do {
                let result = try await runCompaction(
                    prompt: prompt, budget: budget,
                    summarizer: BackendCompactionSummarizer(
                        backend: profile.flash.container.makeSession(
                            instructions: nil, samplingMode: profile.flash.samplingMode)),
                    summarizerModel: profile.flash.chosen
                )
                return (result, .flash)
            } catch {
                try abandonCompactionIfCancelled(discarding: error, tier: .flash)
                // Fall through to the own-model tier below.
            }
        }
        do {
            let result = try await runCompaction(
                prompt: prompt, budget: budget,
                summarizer: BackendCompactionSummarizer(backend: backend), summarizerModel: model)
            return (result, .ownModel)
        } catch {
            // The *only* abandon guard on this path for a session that already is the
            // flash slot and so skipped the tier above.
            try abandonCompactionIfCancelled(discarding: error, tier: .ownModel)
            let result = try await runCompaction(prompt: prompt, budget: budget, summarizer: nil, summarizerModel: nil)
            return (result, .deterministic)
        }
    }

    /// Which summarizer tier a compaction ran on — the value
    /// ``RouterTracing/AttributeKey/compactionTier`` carries.
    private enum CompactionSummarizerTier: String {
        /// The profile's ``LanguageModelProfile/flash`` slot.
        case flash

        /// This session's own model.
        case ownModel = "own-model"

        /// No summarizer at all: the deterministic-only pipeline, which is
        /// what ``performAutoCompaction(prompt:budget:)`` degrades to once
        /// both model-assisted tiers have failed, and what any compaction the
        /// deterministic stages landed on their own reports.
        case deterministic
    }

    /// Opens one ``RouterTracing/SpanName/compact`` span around a whole
    /// compaction and writes what the compaction did onto it.
    ///
    /// The one span site both compaction paths share. It wraps the *whole*
    /// compaction rather than a single ``runCompaction(prompt:budget:summarizer:summarizerModel:)``
    /// call, because ``performAutoCompaction(prompt:budget:)`` runs that call
    /// once per tier as it degrades and one compaction must still be one span.
    ///
    /// The tier written is the tier that actually summarized: a result naming
    /// no summarizer model had no summarizer write its summary, however many
    /// tiers were offered, so it reports ``CompactionSummarizerTier/deterministic``.
    ///
    /// - Parameters:
    ///   - trigger: What asked for this compaction.
    ///   - body: The compaction work, reporting what it did and the tier it ran on.
    /// - Returns: What the compaction did.
    /// - Throws: Whatever `body` throws. `withSpan` records the error on the
    ///   span and raises it again.
    private func withCompactionSpan(
        trigger: RouterTracing.CompactionTrigger,
        _ body: () async throws -> (result: CompactionResult, tier: CompactionSummarizerTier)
    ) async throws -> CompactionResult {
        try await RouterTracing.tracer(explicit: tracer)
            .withSpan(RouterTracing.SpanName.compact, ofKind: .internal) { span in
                span.attributes[RouterTracing.AttributeKey.sessionId] = id.description
                span.attributes[RouterTracing.AttributeKey.modelRef] = model.stringValue
                span.attributes[RouterTracing.AttributeKey.compactionTrigger] = trigger.rawValue
                let (result, tier) = try await body()
                let appliedTier: CompactionSummarizerTier = result.summarizerModel == nil ? .deterministic : tier
                span.attributes[RouterTracing.AttributeKey.compactionTier] = appliedTier.rawValue
                span.attributes[RouterTracing.AttributeKey.tokensBefore] = result.tokensBefore
                span.attributes[RouterTracing.AttributeKey.tokensAfter] = result.tokensAfter
                return result
            }
    }

    /// Abandons the compaction a model-assisted tier just failed when a stop is
    /// outstanding against this turn. Otherwise returns so that tier can
    /// degrade. Keyed on ``isTurnCancelled``, never on the failure's type.
    ///
    /// - Parameters:
    ///   - error: The failure the tier threw.
    ///   - tier: The tier that threw it.
    /// - Throws: `CancellationError` when a cancellation is outstanding against
    ///   this turn.
    private func abandonCompactionIfCancelled(discarding error: Error, tier: CompactionSummarizerTier) throws {
        guard isTurnCancelled else { return }
        noteAbandonedCompaction(discarding: error, tier: tier)
        throw CancellationError()
    }

    /// Logs the summarizer failure an abandoned compaction discards, unless it is a
    /// `CancellationError`. Only the tier, the session id, and the error's type
    /// are public in the log; the description can contain transcript content.
    ///
    /// - Parameters:
    ///   - error: The failure the abandoned tier threw.
    ///   - tier: The tier that threw it.
    private func noteAbandonedCompaction(discarding error: Error, tier: CompactionSummarizerTier) {
        guard !(error is CancellationError) else { return }
        sessionCompactionLogger.warning(
            """
            abandoning the \(tier.rawValue, privacy: .public) summarizer tier's compaction for session \
            \(self.id.description, privacy: .public) because a stop is outstanding against its turn; \
            discarding the \(String(describing: type(of: error)), privacy: .public) it raised: \
            \(error.localizedDescription)
            """
        )
    }

    /// The compaction mechanics ``compact(prompt:budget:)`` and
    /// ``performAutoCompaction(prompt:budget:)`` share. Runs
    /// ``Compactor/compact(_:prompt:budget:counter:summarizer:summarization:pendingRuns:protection:)``
    /// over ``backend``'s transcript, counted by this session's ``tokenCounter``. When a stage applied, records the compaction's
    /// new entries by id, appends one boundary entry, and replaces ``backend``
    /// with one seeded from the compacted transcript. Otherwise leaves the
    /// session unchanged. The caller must hold both gates.
    ///
    /// - Parameters:
    ///   - prompt: The compaction prompt sent to `summarizer`.
    ///   - budget: The token budget to compact against, or `nil` for this
    ///     session's resolved working context.
    ///   - summarizer: The summarizer, or `nil` for the deterministic-only
    ///     pipeline. Wrapped in ``CancellableCompactionSummarizer``.
    ///   - summarizerModel: The model `summarizer` runs on, or `nil`. Written
    ///     to ``CompactionResult/summarizerModel`` when a summary applies.
    /// - Returns: What the compaction did.
    /// - Throws: Whatever `summarizer.summarize(_:maxTokens:)` throws. A compaction
    ///   that throws leaves this session unchanged.
    private func runCompaction(
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

        let (compacted, pipelineResult) = try await Compactor.compact(
            Transcript(entries: entries),
            prompt: prompt,
            budget: resolvedBudget,
            // This session's own counter, so every size the pipeline compares
            // against the budget is the count of the model's tokenizer.
            counter: tokenCounter,
            // Wrapped, never handed over bare: a compaction's summarizer call is a model
            // call this session's turn owns, and must be cancellable as one (see
            // ``CancellableCompactionSummarizer``). A `nil` summarizer stays `nil`,
            // so a deterministic-only compaction is untouched.
            summarizer: summarizer.map { CancellableCompactionSummarizer(base: $0, session: self) },
            // This session's own stage, not the pipeline's defaults — and read
            // here, in the one place both compactions share, so a caller-driven compaction
            // and an automatic one condense the same way (see
            // ``RoutedSessionActor/summarization``).
            summarization: summarization,
            pendingRuns: pendingRuns,
            // The host rule this session was vended, forked or restored with,
            // so no compaction removes a protected tool output.
            protection: toolOutputProtection
        )

        // The report names the model that wrote its summary — the signal task
        // ^59fd9rt adds, applied in the one place both entry points share. A
        // result with no summary returns unchanged, so a deterministic-only
        // compaction, and a compaction whose summary was discarded, name nothing.
        let result = pipelineResult.withSummarizerModel(summarizerModel?.stringValue)

        // Nothing to compact (already under target) or every stage ran and
        // still couldn't land it (the oversized-tail case): `compacted` is
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
        // all — see `compactedUsage(tokensBefore:tokensAfter:)`. Computed before
        // `usageState` is overwritten below, since the rescale calibrates
        // against the pre-compaction measurement.
        let measuredTokensAfter = compactedUsage(tokensBefore: result.tokensBefore, tokensAfter: result.tokensAfter)

        // Every applied compaction appends exactly one boundary entry carrying its
        // ``CompactionSegment`` checkpoint (task ^h1008kb). ``Summarization``
        // synthesizes its own (the summary entry, identified by
        // `result.summaryEntryId`); a deterministic-only compaction produces none —
        // ``ToolOutputElision`` rewrites segments under the entry's original
        // id and ``TurnTruncation`` removes entries (it adds at most a
        // `.toolCalls` entry reduced to its protected calls, under an id of
        // its own), so the id-diff below would otherwise record no
        // checkpoint, and a restore would rebuild the whole pre-compaction
        // history — so one is
        // synthesized here, carrying the compaction's *measured* token counts so a
        // restore reports this compaction's own post-compaction fill.
        let applied: Transcript
        if result.summaryEntryId == nil {
            applied = appendingDeterministicBoundary(
                to: compacted,
                preCompactionEntries: entries,
                result: result,
                measuredTokensAfter: measuredTokensAfter,
                pendingRuns: pendingRuns
            )
        } else {
            applied = compacted
        }

        // `entries.prefix(persistedEntryCount)` is exactly what this
        // session has already recorded to `transcript.jsonl` — the same
        // baseline `recordTranscriptDelta(grammar:since:usage:pendingEvents:)`
        // diffs an ordinary turn's positional growth against. A compaction is not
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
        // Only the positional backend baseline rewinds to the compacted window.
        // `historyOrdinal` already advanced when the diff above recorded the
        // boundary entry, and never rewinds: the compaction changed the *context*,
        // not the session's position in its own append-only history.
        persistedEntryCount = applied.count
        // The compacted window is what the backend now holds, so its identity is
        // what later turns' non-append-divergence checks verify against — see
        // ``persistedBaseline``.
        persistedBaseline = TranscriptDiffer.Baseline(transcript: applied)
        usageState = .measured(input: measuredTokensAfter, output: 0)

        return result
    }

    /// Returns `compacted` with one synthesized boundary entry appended, the
    /// checkpoint a deterministic-only compaction must leave. Built by
    /// ``CompactionSegment/appendingDeterministicBoundary(to:preCompactionEntryIds:tokensBefore:tokensAfter:stagesApplied:pendingRuns:)``
    /// with measured-scale token counts.
    ///
    /// - Parameters:
    ///   - compacted: The transcript the deterministic pipeline produced.
    ///   - preCompactionEntries: The backend's entries before the compaction ran.
    ///   - result: What the compaction did.
    ///   - measuredTokensAfter: The post-compaction size on the measured scale.
    ///   - pendingRuns: The run-plane summaries of the runs still running.
    /// - Returns: `compacted` plus the boundary entry, in that order.
    private func appendingDeterministicBoundary(
        to compacted: Transcript,
        preCompactionEntries: [Transcript.Entry],
        result: CompactionResult,
        measuredTokensAfter: Int,
        pendingRuns: [CompactionSegment.PendingRunSummary]
    ) -> Transcript {
        CompactionSegment.appendingDeterministicBoundary(
            to: compacted,
            preCompactionEntryIds: preCompactionEntries.map(\.id),
            // Measured pre-compaction usage when the session has one — the same
            // calibration `compactedUsage(tokensBefore:tokensAfter:)` reads —
            // else the pipeline's own count.
            tokensBefore: usageState.measuredTokens ?? result.tokensBefore,
            tokensAfter: measuredTokensAfter,
            stagesApplied: result.stagesApplied,
            pendingRuns: pendingRuns.isEmpty ? nil : pendingRuns
        )
    }

    /// A compaction's post-compaction size on the measured scale ``usageState`` uses.
    /// ``CompactionResult/tokensAfter`` is the count of the session's
    /// ``tokenCounter`` over the rendered transcript; the engine's measured
    /// usage can differ from it by what the engine renders around the
    /// transcript. This rescales the count by the ratio of the pre-compaction
    /// measurement to the pre-compaction count. Returns `tokensAfter`
    /// unchanged when there is no measurement to calibrate against.
    ///
    /// - Parameters:
    ///   - tokensBefore: The pipeline's count of the transcript it compacted.
    ///   - tokensAfter: The pipeline's count of the transcript it produced.
    /// - Returns: `tokensAfter` on the measured scale.
    private func compactedUsage(tokensBefore: Int, tokensAfter: Int) -> Int {
        guard let measuredBefore = usageState.measuredTokens, measuredBefore > 0, tokensBefore > 0 else {
            return tokensAfter
        }
        return Int((Double(measuredBefore) * Double(tokensAfter) / Double(tokensBefore)).rounded())
    }
}
