import Foundation
import Tracing
import FoundationModels
import os

/// The logger an abandoned compaction's discarded summarizer failure is reported to
/// (see ``RoutedSessionActor/noteAbandonedCompaction(discarding:tier:)``).
private let sessionCompactionLogger = makeModuleLogger(category: "Compaction")

/// Adapts a ``LanguageModelSessionBackend`` to ``CompactionSummarizer``.
///
/// Each ``summarize(_:maxTokens:)`` call runs on a fresh, blank-slate backend
/// (``LanguageModelSessionBackend/replacingTranscript(_:)`` with an empty
/// transcript), never on the live backend. The live backend holds the live
/// context that the call summarizes, and the call must not enter the
/// conversation history.
///
/// The call turns the model's reasoning off
/// (``LanguageModelSessionBackend/respondWithoutReasoning(to:maxTokens:)``).
/// Task ^dvyt1dx measured Qwen3.8-27B with its reasoning on: in all four
/// continuity tasks the model spent the whole ceiling of the call on its
/// reasoning and wrote no summary. The ceiling stays as it is.
private struct BackendCompactionSummarizer: CompactionSummarizer {
    /// The backend each blank-slate summarizer call is built from.
    let backend: any LanguageModelSessionBackend

    func summarize(_ prompt: String, maxTokens: Int) async throws -> String {
        // The compaction's own ceiling, passed down to the generation path rather
        // than left to resolve to its generic per-turn default — see
        // ``CompactionSummarizer/summarize(_:maxTokens:)``.
        try await backend.replacingTranscript(Transcript(entries: []))
            .respondWithoutReasoning(to: prompt, maxTokens: maxTokens)
    }
}

/// Wraps another ``CompactionSummarizer`` so every model call it makes runs
/// inside the owning session's turn-cancellation boundary
/// (``RoutedSessionActor/runCancellableModelCall(composedPrompt:submittingTo:_:)``),
/// as one submission to the queue of the container that runs it. This lets
/// ``RoutedSession/cancelCurrentTurn()`` and task cancellation stop a
/// compaction's summarizer call, and keeps the call from running at the same
/// time as a submission of another session on that model.
private struct CancellableCompactionSummarizer: CompactionSummarizer {
    /// The summarizer whose calls are made cancellable.
    let base: any CompactionSummarizer

    /// The session whose in-flight turn those calls belong to.
    let session: RoutedSessionActor

    /// The queue each call is one submission to, and its model, or `nil` when
    /// the backend of the summarizer names no queue.
    let target: SubmissionTarget?

    func summarize(_ prompt: String, maxTokens: Int) async throws -> String {
        // A compaction makes one call on each tier it tries, one tier after the
        // other. ``RoutedSessionActor/inFlightModelCall`` holds one call at a
        // time, and the tiers never run at the same time, so
        // ``RoutedSession/cancelCurrentTurn()`` reaches each call. A cancellation
        // that lands between two tiers stops the next tier at its pre-flight check.
        // A compaction runs between two submissions of its session, so the
        // own-model tier never waits for a submission of its own session.
        try await session.runCancellableModelCall(composedPrompt: prompt, submittingTo: target) { [base] promptText in
            try await base.summarize(promptText, maxTokens: maxTokens)
        }
    }
}

/// One summarizer tier that a compaction of a session offers: the backend
/// each call of the tier is built from, and the model of that backend.
private struct BackendSummarizerTier {
    /// The tier this summarizer fills.
    let tier: CompactionSummarizerTier

    /// The backend each blank-slate summarizer call is built from. Its queue
    /// is the queue each call is one submission to.
    let backend: any LanguageModelSessionBackend

    /// The context window of the model of ``backend``, in tokens.
    let windowTokens: Int

    /// The model of ``backend``.
    let model: ModelRef

    /// The slot of this tier, whose summarizer runs each call as one
    /// cancellable submission of `session` to the queue of ``backend``.
    ///
    /// - Parameter session: The session whose turn owns the calls.
    /// - Returns: The slot.
    func slot(for session: RoutedSessionActor) -> CompactionSummarizerSlot {
        let target = backend.generationQueue.map { SubmissionTarget(queue: $0, model: model) }
        return CompactionSummarizerSlot(
            tier: tier,
            summarizer: CancellableCompactionSummarizer(
                base: BackendCompactionSummarizer(backend: backend), session: session, target: target),
            windowTokens: windowTokens, model: model.stringValue)
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
    /// Asks the pump for one compaction and waits for its result. The pump
    /// runs it between two submissions (``compactOwnModel(prompt:budget:)``),
    /// so it never runs beside a submission of this session. A cancel of the
    /// caller withdraws a request that waits, or stops the compaction that
    /// runs (``cancel(compaction:)``).
    ///
    /// This compaction offers the own model only, so a summarizer failure
    /// reaches the caller — and the span records it.
    @discardableResult
    func compact(
        prompt: CompactionPrompt = .default,
        budget: TokenBudget? = nil
    ) async throws -> CompactionResult {
        try refuseWaitInsideOpenSubmission()
        let request = CompactionRequest(prompt: prompt, budget: budget, serviceContext: ServiceContext.current)
        pendingCompactions.append(request)
        wakePump()
        return try await withTaskCancellationHandler {
            try await request.answer.value()
        } onCancel: {
            request.answer.requestCancel()
            // `cancel(compaction:)` is defined in RoutedSessionActorPump.swift
            // (`func cancel(compaction request: CompactionRequest)`). It takes a
            // waiting request out of `pendingCompactions`, or stops the running
            // compaction. TurnCancellationTests proves both paths:
            // `cancellingAWaitingCallerCompactWithdrawsIt` and
            // `cancellingACallerDrivenCompactStopsIt(route: .callerTask)`.
            Task { await self.cancel(compaction: request) }
        }
    }

    /// Runs one caller compaction over this session's own model, inside the
    /// span ``withCompactionSpan(trigger:_:)`` opens. Only the pump calls it.
    ///
    /// - Parameters:
    ///   - prompt: The compaction prompt sent to the summarizer.
    ///   - budget: The token budget to compact against, or `nil` for this
    ///     session's resolved working context.
    /// - Returns: What the compaction did.
    /// - Throws: The summarizer's error, or `CancellationError`.
    func compactOwnModel(prompt: CompactionPrompt, budget: TokenBudget?) async throws -> CompactionResult {
        try await withCompactionSpan(trigger: .caller) {
            try await runCompaction(prompt: prompt, budget: budget, summarizers: [ownModelSummarizerTier()])
        }
    }

    /// Auto-compaction's entry point. Only the pump calls it, between two
    /// submissions of this session.
    ///
    /// Offers two summarizer tiers: the profile's ``LanguageModelProfile/flash``
    /// slot (not offered when this session is the flash slot), then this
    /// session's own model. The flash slot runs when its window holds the call
    /// and the summary. When the flash slot fails, the own model runs. The
    /// flash slot must hold a model that can summarize; the compaction applies
    /// no quality check on the summary text.
    ///
    /// The whole compaction runs inside one span
    /// (``withCompactionSpan(trigger:_:)``), and the span reports the tier that
    /// wrote the summary — see ``RouterTracing/AttributeKey/compactionTier``.
    ///
    /// - Parameters:
    ///   - prompt: The compaction prompt sent to the summarizer tier that runs.
    ///   - budget: The token budget to compact against.
    /// - Returns: What the compaction did. ``CompactionResult/summarizerModel``
    ///   and ``CompactionResult/summarizerTier`` name the tier that wrote the
    ///   applied summary.
    /// - Throws: What the own model throws. `CancellationError` when a tier
    ///   fails and a cancellation is outstanding against this turn
    ///   (``isWorkCancelled``). That case does not go on to the next tier. The
    ///   abandoned tier's own failure is logged
    ///   (``noteAbandonedCompaction(discarding:tier:)``).
    func performAutoCompaction(
        prompt: CompactionPrompt,
        budget: TokenBudget
    ) async throws -> CompactionResult {
        var summarizers: [BackendSummarizerTier] = []
        if slot != .flash {
            summarizers.append(
                BackendSummarizerTier(
                    tier: .flash,
                    backend: profile.flash.container.makeSession(
                        instructions: nil, samplingMode: profile.flash.samplingMode),
                    windowTokens: profile.flash.contextTokens,
                    model: profile.flash.chosen
                ))
        }
        summarizers.append(ownModelSummarizerTier())
        return try await withCompactionSpan(trigger: .auto) {
            try await runCompaction(prompt: prompt, budget: budget, summarizers: summarizers)
        }
    }

    /// The summarizer tier of this session's own model: a fresh backend over
    /// it, in this session's resolved working context.
    private func ownModelSummarizerTier() -> BackendSummarizerTier {
        BackendSummarizerTier(tier: .ownModel, backend: backend, windowTokens: contextTokens, model: model)
    }

    /// Opens one ``RouterTracing/SpanName/compact`` span around a whole
    /// compaction and writes what the compaction did onto it.
    ///
    /// The one span site both compaction paths share. The tier written is the
    /// tier that wrote the applied summary. A compaction that applied no
    /// summary writes no tier.
    ///
    /// - Parameters:
    ///   - trigger: What asked for this compaction.
    ///   - body: The compaction work.
    /// - Returns: What the compaction did.
    /// - Throws: Whatever `body` throws. `withSpan` records the error on the
    ///   span and raises it again.
    private func withCompactionSpan(
        trigger: RouterTracing.CompactionTrigger,
        _ body: () async throws -> CompactionResult
    ) async throws -> CompactionResult {
        try await RouterTracing.tracer(explicit: tracer)
            .withSpan(RouterTracing.SpanName.compact, ofKind: .internal) { span in
                span.attributes[RouterTracing.AttributeKey.sessionId] = id.description
                span.attributes[RouterTracing.AttributeKey.modelRef] = model.stringValue
                span.attributes[RouterTracing.AttributeKey.compactionTrigger] = trigger.rawValue
                let result = try await body()
                if let tier = result.summarizerTier {
                    span.attributes[RouterTracing.AttributeKey.compactionTier] = tier.rawValue
                }
                span.attributes[RouterTracing.AttributeKey.tokensBefore] = result.tokensBefore
                span.attributes[RouterTracing.AttributeKey.tokensAfter] = result.tokensAfter
                return result
            }
    }

    /// Abandons the compaction a summarizer tier just failed when a stop is
    /// outstanding against this turn. Otherwise returns, so the compaction
    /// goes on to the next tier or throws the failure. Keyed on
    /// ``isWorkCancelled``, never on the failure's type.
    ///
    /// - Parameters:
    ///   - error: The failure the tier threw.
    ///   - tier: The tier that threw it.
    /// - Throws: `CancellationError` when a cancellation is outstanding against
    ///   this turn.
    private func abandonCompactionIfCancelled(discarding error: Error, tier: CompactionSummarizerTier) throws {
        // `isWorkCancelled` is defined in RoutedSessionActorTurnExecution.swift
        // (`var isWorkCancelled: Bool`), the one cancel predicate of the work of
        // the pump. With it always `false`, a one-tier caller compaction gives
        // the fault in place of the stop
        // (TurnCancellationTests.callerCompactFaultCoincidingWithAStopIsCancelled).
        // With it always `true`, a failed tier never degrades
        // (TurnCancellationTests.summarizerCancellationErrorWithNoStopOutstandingStillDegrades).
        guard isWorkCancelled else { return }
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
    /// ``Compactor/compact(_:prompt:budget:counter:summarizers:summarization:pendingRuns:protection:abandoning:)``
    /// over ``backend``'s transcript, counted by this session's ``tokenCounter``.
    /// When a summary applied, records the compaction's new entries by id and
    /// replaces ``backend`` with one seeded from the new snapshot. Otherwise
    /// leaves the session unchanged. Only the pump calls it, between two
    /// submissions of this session.
    ///
    /// - Parameters:
    ///   - prompt: The compaction prompt sent to the summarizer.
    ///   - budget: The token budget to compact against, or `nil` for this
    ///     session's resolved working context.
    ///   - summarizers: The summarizer tiers, in the order of preference. Each
    ///     call of a tier is one cancellable submission to the queue of its
    ///     backend (``CancellableCompactionSummarizer``).
    /// - Returns: What the compaction did.
    /// - Throws: What the last tier throws, or `CancellationError`. A
    ///   compaction that throws leaves this session unchanged.
    private func runCompaction(
        prompt: CompactionPrompt,
        budget: TokenBudget?,
        summarizers: [BackendSummarizerTier]
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

        let (compacted, result) = try await Compactor.compact(
            Transcript(entries: entries),
            prompt: prompt,
            budget: resolvedBudget,
            // This session's own counter: every size before the call is the
            // count of the model's tokenizer.
            counter: tokenCounter,
            // Wrapped, never handed over bare: a compaction's summarizer call is a model
            // call this session's turn owns, and must be cancellable as one, and
            // one submission to the queue of its model (see
            // ``CancellableCompactionSummarizer``).
            summarizers: summarizers.map { $0.slot(for: self) },
            summarization: summarization,
            pendingRuns: pendingRuns,
            // The host rule this session was vended, forked or restored with,
            // so no compaction removes a protected tool output.
            protection: toolOutputProtection,
            abandoning: { [self] error, tier in try await abandonCompactionIfCancelled(discarding: error, tier: tier) }
        )

        // Nothing to compact (already under target), or a shortfall: `compacted`
        // is the live context as it was, so there is nothing new to record
        // and no reason to swap `backend`.
        guard result.summaryEntryId != nil else { return result }

        await recordSessionMetaIfNeeded()

        // What `backend` will hold, reported as `contextFill`'s numerator
        // immediately — the same way a restored session whose newest event is
        // a compaction checkpoint reports its segment's own `tokensAfter`
        // (compaction_plan.md §1.5). `result.tokensAfter` is the tokenizer's
        // count, made before any call ran on the snapshot; the engine's
        // `usage.input` of the next live turn replaces it. Rescaled onto the
        // measured scale first — see `compactedUsage(tokensBefore:tokensAfter:)`.
        // Computed before `usageState` is overwritten below, since the rescale
        // calibrates against the pre-compaction measurement.
        let measuredTokensAfter = compactedUsage(tokensBefore: result.tokensBefore, tokensAfter: result.tokensAfter)

        // The checkpoint states the same measured scale the live session now
        // reports, so a restore reads this compaction's own post-compaction
        // fill. The measured size before is the session's own measurement when
        // it has one, else the tokenizer's count.
        let measuredTokensBefore = usageState.measuredTokens ?? result.tokensBefore
        let applied = Transcript(
            entries: compacted.map { entry in
                entry.id == result.summaryEntryId
                    ? CompactionSegment.restatingSizes(
                        of: entry, tokensBefore: measuredTokensBefore, tokensAfter: measuredTokensAfter)
                    : entry
            })

        // `entries.prefix(persistedEntryCount)` is exactly what this
        // session has already recorded to `transcript.jsonl` — the same
        // baseline `recordTranscriptDelta(grammar:since:usage:pendingEvents:)`
        // diffs an ordinary turn's positional growth against. A compaction is not
        // a mere extension of it (`applied` is shorter and reorders entries
        // relative to it), so the diff here is by entry id rather than
        // position — see ``TranscriptDiffer/diffByEntryId(lastSeen:current:routerId:sessionId:parentId:slot:model:)``.
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
        // requirement 4). Seeded with the summary entry included, so what
        // the model sees live is exactly what a restore rebuilds from the
        // checkpoint's live window.
        backend = backend.replacingTranscript(applied)
        // Only the positional backend baseline rewinds to the new snapshot.
        // `historyOrdinal` already advanced when the diff above recorded the
        // summary entry, and never rewinds: the compaction changed the *context*,
        // not the session's position in its own append-only history.
        persistedEntryCount = applied.count
        // The new snapshot is what the backend now holds, so its identity is
        // what later turns' non-append-divergence checks verify against — see
        // ``persistedBaseline``.
        persistedBaseline = TranscriptDiffer.Baseline(transcript: applied)
        usageState = .measured(input: measuredTokensAfter, output: 0)
        // The new backend runs no call yet: the compacted window is the new
        // settled transcript, so a read after the compaction sees it.
        settleTranscript()

        return result
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
    ///   - tokensBefore: The compaction's count of the live context it replaced.
    ///   - tokensAfter: The compaction's count of the snapshot it produced.
    /// - Returns: `tokensAfter` on the measured scale.
    private func compactedUsage(tokensBefore: Int, tokensAfter: Int) -> Int {
        guard let measuredBefore = usageState.measuredTokens, measuredBefore > 0, tokensBefore > 0 else {
            return tokensAfter
        }
        return Int((Double(measuredBefore) * Double(tokensAfter) / Double(tokensBefore)).rounded())
    }
}
