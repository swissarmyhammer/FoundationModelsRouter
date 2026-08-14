import Foundation
import FoundationModels
import os

/// The logger ``RoutedSessionActor`` reports an abandoned fold's discarded
/// summarizer failure to (see
/// ``RoutedSessionActor/noteAbandonedFold(discarding:tier:)``).
///
/// Its own category rather than ``sessionRecordingLogger``'s: what it reports is a
/// compaction outcome, not a recording one.
private let sessionCompactionLogger = makeModuleLogger(category: "Compaction")

/// Adapts a ``LanguageModelSessionBackend`` to ``CompactionSummarizer``, so
/// ``RoutedSessionActor/compact(prompt:budget:)`` can hand
/// ``Compactor/compact(_:prompt:budget:summarizer:summarization:pendingRuns:)`` a summarizer without
/// spinning up a separate model handle — "summarizer defaults to the
/// session's own model" (compaction_plan.md §1.4).
///
/// Deliberately wraps a **fresh, blank-slate** backend
/// (``LanguageModelSessionBackend/replacingTranscript(_:)`` seeded with an
/// empty transcript) built fresh for every ``summarize(_:maxTokens:)`` call, rather
/// than the session's own live, accumulating backend:
///
/// - The live backend may already be at or near the context limit — that is
///   *why* compaction is running — so asking it to also answer the
///   summarization prompt (which embeds the rendered old span's own text)
///   would pile more content on top of an already-oversized context, and
///   could itself throw a context-overflow failure.
/// - Reusing the *same* live backend would additionally append the
///   summarization call's own prompt/response pair into the real
///   conversation history being folded away — corrupting it with a turn the
///   user never had.
/// - A single shared blank backend reused across ``Summarization``'s
///   map-reduce calls would leak one chunk's summarization prompt/response
///   into the next chunk's context, when each chunk must be summarized
///   independently.
///
/// A fresh blank-slate backend per call avoids all three: it is a genuine
/// one-shot text-in/text-out call over the same resident model, with no
/// accumulated history of its own.
private struct BackendCompactionSummarizer: CompactionSummarizer {
    /// The session's own backend, over the same resident model every
    /// blank-slate summarizer call is built from.
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
/// (``RoutedSessionActor/runCancellableModelCall(composedPrompt:_:)``), rather
/// than as work only the fold's own caller could ever interrupt.
///
/// This is what makes a client stop land during a **fold**. A fold's
/// model-assisted ``Summarization`` stage is the expensive part of compaction —
/// a real generation, map-reduced over the whole folded span — and a turn
/// folding its own transcript has no `body(composedPrompt)` outstanding for
/// ``RoutedSession/cancelCurrentTurn()`` to cancel, so before this a stop
/// arriving mid-fold was remembered but the fold was waited out. Routing each
/// `summarize(_:maxTokens:)` through the same boundary a turn's own model call uses gives
/// the whole contract at once: the pre-flight check on both cancellation routes,
/// registration as the turn's ``RoutedSessionActor/inFlightModelCall`` so
/// `cancelCurrentTurn()` reaches a summarizer call already in flight, and the
/// `withTaskCancellationHandler` that keeps a caller able to cancel the fold by
/// cancelling its own enclosing `Task`.
///
/// Only ever wrapped around a summarizer that exists: a deterministic-only fold
/// makes no model call, so it gains no check and stays exactly as fast and as
/// deterministic as it was.
private struct CancellableCompactionSummarizer: CompactionSummarizer {
    /// The summarizer whose calls are being made cancellable.
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
/// fill it reports, the caller-driven fold, and the automatic fold a turn takes
/// when its own measured usage has reached its budget's trigger.
extension RoutedSessionActor {
    /// See ``RoutedSession/contextFill``.
    ///
    /// Synchronous here even though the protocol declares `{ get async }`:
    /// this getter runs on the actor's own executor and reads only
    /// actor-isolated state (``usageState``, ``contextTokens``), so it needs
    /// no `await` from inside the actor. A synchronous actor-isolated getter
    /// satisfies an `async` protocol requirement — every access from outside
    /// this actor still goes through an implicit `await` at the call site
    /// (see the `await session.contextFill` example on
    /// ``RoutedSession/contextFill``), so isolation is never bypassed. There
    /// is no data race: every read or write of ``usageState`` — `init`, here,
    /// ``compact(prompt:budget:)``, ``fork(workingDirectory:)``, the trigger and ceiling checks in ``runTurn(grammar:turnId:promptId:pendingEvents:ownPrompt:onEvent:_:)``,
    /// and ``finishTurn(grammar:since:usageBefore:pendingEvents:onEvent:)`` — executes
    /// inside this actor's isolation domain.
    var contextFill: Double {
        usageState.fill(contextTokens: contextTokens)
    }

    /// See ``RoutedSession/compact(prompt:budget:)``.
    ///
    /// The manual, caller-driven entry point — "explicit `compact()` remains
    /// for manual `/compact` binding upstairs" (task 8213x39): always
    /// summarizes with a fresh, disposable backend over this session's own
    /// model (``BackendCompactionSummarizer``), unchanged from before
    /// auto-compaction existed. Takes this session's turn lock and a generation
    /// permit for the duration (``beginTurn()``) since a caller can invoke this
    /// at any time — folding reads and swaps ``backend`` and runs real model
    /// work, so it is a turn as far as both gates are concerned — then runs the shared fold
    /// mechanics in ``fold(prompt:budget:summarizer:)``. See that method's
    /// doc comment for what folding does.
    @discardableResult
    func compact(
        prompt: CompactionPrompt = .default,
        budget: TokenBudget? = nil
    ) async throws -> CompactionResult {
        await beginTurn()
        defer { endTurn() }
        return try await fold(prompt: prompt, budget: budget, summarizer: BackendCompactionSummarizer(backend: backend))
    }

    /// Auto-compaction's own fold entry point (task 8213x39,
    /// ``autoCompactionBudget``): called from inside
    /// ``runTurn(grammar:turnId:promptId:pendingEvents:ownPrompt:onEvent:_:)``, which already
    /// holds ``turnLock`` and a ``generationGate`` permit for the whole turn, so
    /// this deliberately never acquires either itself — unlike
    /// ``compact(prompt:budget:)``, doing so here would deadlock against the
    /// very turn driving it.
    ///
    /// Chooses its summarizer by preference rather than always this
    /// session's own model: the profile's ``LanguageModelProfile/flash`` slot
    /// first (compaction_plan.md §1.4's documented override — a
    /// smaller/cheaper model dedicated to work like this, so the session's
    /// own model — possibly already near capacity, which is why auto-fold is
    /// running at all — isn't also asked to produce the summary), skipping
    /// straight to this session's own model when this session already *is*
    /// the flash slot (asking flash to summarize itself would be pointless
    /// indirection through another handle over the identical resident
    /// model) or when the flash attempt's summarizer call fails, and finally
    /// falling back to the deterministic-only pipeline (no summarizer —
    /// ``ToolOutputElision``/``TurnTruncation`` alone, which never throws)
    /// if the own-model attempt fails too — so a broken summarizer model can
    /// never block an automatic mid-turn fold outright.
    ///
    /// - Parameters:
    ///   - prompt: The compaction prompt sent to whichever summarizer tier
    ///     actually runs.
    ///   - budget: The token budget to fold against.
    /// - Returns: What the fold did.
    /// - Throws: `CancellationError`, and nothing else, when a tier fails *and* a
    ///   cancellation is outstanding against this turn (``isTurnCancelled``) — the
    ///   one case not degraded to the next tier, because degrading a cancelled fold
    ///   would answer a stop by making more model calls, and would then apply a
    ///   cheaper fold to a turn that is unwinding anyway. The condition is that
    ///   cancellation, never the failure's own type: a summarizer that raises
    ///   `CancellationError` out of its own internals with nothing cancelled here
    ///   is an ordinary failure and degrades like any other. So the guarantee above
    ///   still holds unqualified — a broken summarizer model cannot block an
    ///   automatic fold — and only ``Compactor/compact(_:prompt:budget:summarizer:summarization:pendingRuns:)``'s
    ///   own non-summarizer failure modes (none today) would otherwise propagate.
    ///   Whatever the abandoned tier threw, unless it is itself a `CancellationError`,
    ///   is reported to the log on the way out
    ///   (``noteAbandonedFold(discarding:tier:)``) rather than lost, since the
    ///   `CancellationError` this throws instead carries none of it.
    func performAutoCompaction(
        prompt: CompactionPrompt,
        budget: TokenBudget
    ) async throws -> CompactionResult {
        if slot != .flash {
            do {
                return try await fold(
                    prompt: prompt, budget: budget,
                    summarizer: BackendCompactionSummarizer(backend: profile.flash.container.makeSession(instructions: nil))
                )
            } catch {
                try abandonFoldIfCancelled(discarding: error, tier: .flash)
                // Fall through to the own-model tier below.
            }
        }
        do {
            return try await fold(prompt: prompt, budget: budget, summarizer: BackendCompactionSummarizer(backend: backend))
        } catch {
            // The *only* abandon guard on this path for a session that already is the
            // flash slot and so skipped the tier above.
            try abandonFoldIfCancelled(discarding: error, tier: .ownModel)
            return try await fold(prompt: prompt, budget: budget, summarizer: nil)
        }
    }

    /// Which of ``performAutoCompaction(prompt:budget:)``'s model-assisted tiers a
    /// fold ran on, so a report about one names it from a single place rather than
    /// from a string literal at each tier's `catch`.
    private enum FoldSummarizerTier: String {
        /// The profile's ``LanguageModelProfile/flash`` slot.
        case flash

        /// This session's own model.
        case ownModel = "own-model"
    }

    /// Abandons the fold a model-assisted tier just failed when a stop is outstanding
    /// against this turn, and otherwise returns so that tier can degrade.
    ///
    /// Shared by both of ``performAutoCompaction(prompt:budget:)``'s model-assisted
    /// tiers — the two ``FoldSummarizerTier`` cases, since the deterministic fold
    /// beneath them makes no model call to abandon — so the one decision they make
    /// identically cannot drift apart between them. What differs per tier is what
    /// happens on the way out of it — the flash tier falls through to the own-model
    /// tier, the own-model tier to that deterministic (`nil`-summarizer) fold — so
    /// returning normally is all this does when nothing is cancelled, and each
    /// fall-through stays at its own call site.
    ///
    /// Keyed on ``isTurnCancelled``, never on the failure's own type: a
    /// ``LanguageModelSessionBackend`` conformer is free to surface
    /// `CancellationError` from internals of its own with nothing cancelled here,
    /// which is an ordinary summarizer failure and the next tier's business exactly
    /// as before. See ``performAutoCompaction(prompt:budget:)``'s `- Throws:` for why
    /// a fold under an outstanding stop is abandoned rather than degraded.
    ///
    /// - Parameters:
    ///   - error: The failure the tier threw. When the fold is abandoned it is
    ///     reported by ``noteAbandonedFold(discarding:tier:)`` — unless it is itself
    ///     a `CancellationError`, the usual case and the one with nothing to say —
    ///     since the `CancellationError` thrown in its place carries none of it.
    ///   - tier: The tier that threw it.
    /// - Throws: `CancellationError` when a cancellation is outstanding against this
    ///   turn, and nothing at all otherwise.
    private func abandonFoldIfCancelled(discarding error: Error, tier: FoldSummarizerTier) throws {
        guard isTurnCancelled else { return }
        noteAbandonedFold(discarding: error, tier: tier)
        throw CancellationError()
    }

    /// Reports the summarizer failure an abandoned fold is discarding, so a genuine
    /// fault that merely coincided with a stop does not vanish without trace.
    ///
    /// A fold abandoned for a cancellation throws `CancellationError` whatever its
    /// tier actually threw — that is what the caller of a stopped turn has to see,
    /// and `CancellationError` carries no underlying failure — so the tier's own
    /// error is otherwise dropped on the floor. Nearly always it *is* that
    /// cancellation and there is nothing to say; anything else is a summarizer fault
    /// that a stop happened to race, and it is logged here. Reported the way
    /// ``recordTranscriptDelta(grammar:since:usage:pendingEvents:onEvent:)``'s
    /// shrink guard reports its own swallowed anomaly, which is the session's other
    /// "dropped, so say so" case.
    ///
    /// The type test is about log noise alone. What abandons a fold is
    /// ``isTurnCancelled`` and never an error's type — keying that decision on
    /// `CancellationError` is the defect this method must not reintroduce.
    ///
    /// It is a heuristic in both directions, and neither miss costs more than a log
    /// line: a conformer raising `CancellationError` out of internals of its own —
    /// the case ``LanguageModelSessionBackend`` explicitly allows, and the reason the
    /// abandon decision is not keyed on the type — goes unreported when a stop
    /// happens to be outstanding, and a conformer that wraps a real cancellation in
    /// an error type of its own is reported as a fault. So "logged" does not prove
    /// "genuine", nor "unlogged" prove "routine".
    ///
    /// Only the tier, the session, and the error's *type* are logged publicly. The
    /// description is left at `os.Logger`'s redacted default: this error comes out of
    /// a summarizer call whose prompt is the rendered folded span, so a conformer that
    /// echoes its request or partial output into the description would otherwise write
    /// transcript content to the unified log. The shrink guard above marks only counts
    /// and ids public for the same reason.
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
    /// ``performAutoCompaction(prompt:budget:)`` share: runs
    /// ``Compactor/compact(_:prompt:budget:summarizer:summarization:pendingRuns:)`` over ``backend``'s
    /// current transcript with `summarizer`. When folding actually changed
    /// anything (`result.stagesApplied` non-empty), the fold's
    /// never-before-recorded entries are persisted — identified by id,
    /// mirroring ``RecordingLanguageModel/noteCompaction(_:)``'s own
    /// id-based diff, since a fold's live window is typically *shorter* than
    /// what came before it and a positional diff cannot say what is new —
    /// and ``backend`` is swapped for a fresh one seeded from the folded
    /// transcript (``LanguageModelSessionBackend/replacingTranscript(_:)``).
    /// Every applied fold records exactly one boundary entry carrying its
    /// ``CompactionSegment`` checkpoint: ``Summarization``'s own summary
    /// entry when that stage ran, or the synthesized deterministic boundary
    /// (``appendingDeterministicBoundary(to:preFoldEntries:result:measuredTokensAfter:pendingRuns:)``)
    /// when the deterministic stages alone landed the fold.
    /// When the transcript was already under target, or every stage ran and
    /// still couldn't land it (the oversized-tail case), the pipeline
    /// returns the original transcript unchanged and this method leaves
    /// ``backend`` exactly as it was.
    ///
    /// Assumes both gates are already held by the caller — this method never
    /// acquires or releases either, so it is safe to call from inside the turn
    /// chokepoint (``runTurn(grammar:turnId:promptId:pendingEvents:ownPrompt:onEvent:_:)``),
    /// which holds them for the whole turn, as well as from
    /// ``compact(prompt:budget:)``, which takes them itself first.
    ///
    /// - Parameters:
    ///   - prompt: The compaction prompt sent to `summarizer` when the
    ///     model-assisted stage runs.
    ///   - budget: The token budget to fold against, or `nil` to use this
    ///     session's own resolved working context at the default
    ///     trigger/target.
    ///   - summarizer: The model to summarize with, or `nil` to degrade to
    ///     the deterministic-only pipeline. A non-`nil` summarizer is wrapped in
    ///     ``CancellableCompactionSummarizer`` before the pipeline sees it, so
    ///     each of its model calls is cancellable as this turn's own.
    /// - Returns: What the fold did.
    /// - Throws: Whatever `summarizer.summarize(_:maxTokens:)` throws, unmodified, when
    ///   the model-assisted stage runs and fails — including `CancellationError`
    ///   when this turn was cancelled before or during a summarizer call. A fold
    ///   that throws leaves this session exactly as it was: the fold's own
    ///   entries are recorded, ``backend`` swapped, and ``usageState`` updated
    ///   only after the pipeline has returned, so an abandoned fold is never a
    ///   half-applied one.
    private func fold(
        prompt: CompactionPrompt,
        budget: TokenBudget?,
        summarizer: (any CompactionSummarizer)?
    ) async throws -> CompactionResult {
        let entries = backend.transcriptEntries()
        let resolvedBudget = budget ?? TokenBudget(limit: contextTokens)

        // Read at the moment the compaction boundary is written: the runs
        // still parked in this session's mailbox, as run-plane summaries
        // (token, op, latest progress — never output content), so a
        // post-compaction model can rediscover its in-flight work from the
        // boundary and call status() for the live view.
        let pendingRuns = await mailbox.parkedRuns().map { run in
            CompactionSegment.PendingRunSummary(
                completionToken: run.completionToken,
                op: run.op,
                latestProgressDetail: run.latestProgressDetail
            )
        }

        let (folded, result) = try await Compactor.compact(
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

    /// Returns `folded` with one synthesized boundary entry appended — the
    /// checkpoint a deterministic-only fold must still leave (task ^h1008kb).
    ///
    /// Compaction is append-only: every applied fold appends exactly one
    /// boundary entry to the conversation history, and the engine rebuilds a
    /// restored context "from" the newest checkpoint. ``Summarization``'s
    /// summary entry is that boundary for a model-assisted fold; this is its
    /// deterministic counterpart, built by the shared construction —
    /// ``CompactionSegment/appendingDeterministicBoundary(to:preFoldEntryIds:tokensBefore:tokensAfter:stagesApplied:pendingRuns:)``,
    /// which the bare-recipe
    /// ``RecordingLanguageModel/noteCompaction(_:result:)`` also calls — so
    /// the two boundary shapes cannot drift apart. Recording it through the
    /// ordinary id-diff is what puts the checkpoint on disk, since the
    /// deterministic stages themselves add no new entry ids
    /// (``ToolOutputElision`` rewrites in place, ``TurnTruncation`` only
    /// removes).
    ///
    /// Unlike ``Summarization``'s checkpoint, whose token counts are the
    /// pipeline's character-ratio estimates, this one is written where the
    /// session's measured usage is in hand, so it carries measured-scale
    /// counts: ``TranscriptTree/restoredUsageState(in:)`` reads
    /// ``CompactionSegment/Content/tokensAfter`` straight into a restored
    /// session's ``ContextUsageState``, and this fold has just computed the
    /// same number for its own live ``RoutedSession/contextFill``.
    ///
    /// - Parameters:
    ///   - folded: The transcript the deterministic pipeline produced.
    ///   - preFoldEntries: The backend's entries before the fold ran, used to
    ///     name what the fold removed
    ///     (``CompactionSegment/Content/foldedEntryIds``).
    ///   - result: What the fold did — its stages and estimate-scale counts.
    ///   - measuredTokensAfter: The fold's post-fold size on the measured
    ///     scale (see `foldedUsage(tokensBefore:tokensAfter:)`), written to
    ///     the checkpoint and to ``usageState`` as one value so live and
    ///     restored fill cannot drift.
    ///   - pendingRuns: The run-plane summaries of the runs still parked in
    ///     this session's mailbox, in park order — carried on the manifest
    ///     and rendered model-visibly exactly as a summarized boundary
    ///     carries them.
    /// - Returns: `folded` plus the boundary entry, in that order — the
    ///   boundary names itself last in its own live window.
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

    /// A fold's post-fold size, in the same unit ``usageState`` is denominated
    /// in everywhere else: real tokenizer counts read off
    /// `LanguageModelSessionBackend.usageTokenCounts()`.
    ///
    /// ``CompactionResult/tokensAfter`` is not one of those. It is
    /// ``Compactor/estimatedTokenCount(of:)``'s character-ratio estimate, and
    /// ``Compactor`` has no session or backend to ask for a real count. Writing
    /// it straight into ``usageState`` put an estimate where every other writer
    /// puts a measurement, which made ``RoutedSession/contextFill`` — and every
    /// budget threshold compared against it — mix two units: a fold whose real
    /// saving was smaller than the estimator's own overcount *raised* reported
    /// fill, and a caller comparing fill across a fold was comparing
    /// incommensurable numbers.
    ///
    /// The pre-fold state carries exactly what is needed to convert between
    /// them. This session has just measured `usageState` over the same
    /// transcript ``Compactor`` estimated at `tokensBefore`, so their ratio is
    /// this transcript's own measured-per-estimated-token rate, and the folded
    /// transcript — the same prose, minus an old span, plus a summary written
    /// in it — is tokenized by the same tokenizer at close to the same rate.
    /// Rescaling by that ratio cancels the estimator's systematic bias instead
    /// of leaving it to be compared against measurements.
    ///
    /// Falls back to `tokensAfter` unchanged when there is nothing to calibrate
    /// against — a session with no measurement yet (``ContextUsageState/none``,
    /// ``ContextUsageState/unknown``) or a transcript the estimator sized at
    /// zero — which is the previous behavior, and still the best available
    /// number until the next live turn re-measures.
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
