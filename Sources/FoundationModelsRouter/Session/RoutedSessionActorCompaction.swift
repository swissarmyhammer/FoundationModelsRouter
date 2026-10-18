import Foundation
import Tracing
import FoundationModels
import FoundationModelsExtras
import Logging

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
///
/// The blank-slate backend keeps no prompt cache (task ^ptev9yy,
/// `generation-queue.md`, section 3). Its passes bind the `.uncached` scope,
/// so the call takes no cache and leaves none: a compaction adds no key to
/// the cache of the model and pushes out no cache of a real session. Both
/// tiers (the flash tier and the own-model tier) make their calls here.
private struct BackendCompactionSummarizer: CompactionSummarizer {
    /// The backend each blank-slate summarizer call is built from.
    let backend: any LanguageModelSessionBackend

    func summarize(_ prompt: String, maxTokens: Int) async throws -> String {
        let blank = backend.replacingTranscript(Transcript(entries: []))
        // Before the call: the executor of the blank backend reads the scope
        // at each pass. A backend with no executor seam keeps no cache of
        // the fork, so it has nothing to set.
        (blank as? any SessionPromptCacheScoping)?.keepNoPromptCache()
        // The compaction's own ceiling, passed down to the generation path rather
        // than left to resolve to its generic default for each submission — see
        // ``CompactionSummarizer/summarize(_:maxTokens:)``.
        return try await blank.respondWithoutReasoning(to: prompt, maxTokens: maxTokens)
    }
}

/// Wraps another ``CompactionSummarizer`` so every model call it makes is one
/// submission to the queue of the model that runs it
/// (``RoutedSessionActor/runSummarizerCall(composedPrompt:submittingTo:_:)``).
/// The call cannot run at the same time as a submission of another session,
/// or of the same session, on that model.
///
/// The call belongs to the task of the compaction, not to the work of the
/// pump. Only a cancel of that task stops it, and only
/// ``RoutedSession/close()`` cancels it.
private struct QueuedCompactionSummarizer: CompactionSummarizer {
    /// The summarizer whose calls are queued.
    let base: any CompactionSummarizer

    /// The session that compacts.
    let session: RoutedSessionActor

    /// The queue each call is one submission to, and its model, or `nil` when
    /// the backend of the summarizer names no queue.
    let target: SubmissionTarget?

    func summarize(_ prompt: String, maxTokens: Int) async throws -> String {
        // A compaction makes one call on each tier it tries, one tier after
        // the other. A cancel that lands between two tiers stops the next
        // tier at its pre-flight check.
        try await session.runSummarizerCall(composedPrompt: prompt, submittingTo: target) { [base] promptText in
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
    /// submission of `session` to the queue of ``backend``.
    ///
    /// - Parameter session: The session that compacts.
    /// - Returns: The slot.
    func slot(for session: RoutedSessionActor) -> CompactionSummarizerSlot {
        let target = backend.generationQueue.map { SubmissionTarget(queue: $0, model: model) }
        return CompactionSummarizerSlot(
            tier: tier,
            summarizer: QueuedCompactionSummarizer(
                base: BackendCompactionSummarizer(backend: backend), session: session, target: target),
            windowTokens: windowTokens, model: model.stringValue)
    }
}

/// What one compaction does and why: the input of the one compaction
/// handler (``RoutedSessionActor/performCompaction(_:_:)``).
struct CompactionOrder: Sendable {
    /// The compaction prompt sent to the summarizer tier that runs.
    let prompt: CompactionPrompt

    /// The token budget to compact against, or `nil` for the resolved working
    /// context of the session.
    let budget: TokenBudget?

    /// Why the compaction runs.
    let reason: CompactionReason

    /// The target the retry after a context overflow computed, or `nil`. The
    /// result carries it.
    let overflowRetryTarget: OverflowRetryTarget?

    /// Whether a budget trigger of an answer started the compaction. The
    /// answer waits for the result, and the readers of the mail of that
    /// answer also get the events of the compaction.
    var isAutomatic: Bool {
        reason != .requested
    }

    /// The value of the `compaction.trigger` span attribute and of the
    /// dimension of the compaction metric: ``RouterTelemetry/CompactionTrigger/caller``
    /// for a requested compaction, and ``RouterTelemetry/CompactionTrigger/auto``
    /// for the four automatic reasons.
    var trigger: RouterTelemetry.CompactionTrigger {
        RouterTelemetry.CompactionTrigger(reason: reason)
    }
}

/// The failure of a compaction whose new snapshot could not apply.
enum CompactionApplyError: Error, Equatable, CustomStringConvertible {
    /// The live transcript changed under the compaction in a way that is not
    /// an append, so the summary does not describe the start of the live
    /// transcript. The session stays as it was.
    case transcriptChanged

    var description: String {
        switch self {
        case .transcriptChanged:
            "the live transcript changed under the compaction, so the compaction did not apply"
        }
    }
}

/// ``RoutedSessionActor``'s context accounting and compaction: the measured
/// fill, and the one compaction handler (`mailbox.md`, section 3).
///
/// A compaction is a signal. ``compact(prompt:budget:)`` (a requested
/// compaction) and ``compactInsideAnswer(prompt:budget:reason:overflowRetryTarget:)``
/// (an automatic compaction) both give the work of one compaction to
/// ``signals``, with a new ``SignalID``. The work is
/// ``performCompaction(_:_:)``: it pauses the mail queue, sends
/// ``SessionEvent/compactionStarted(_:)``, compacts, sends
/// ``SessionEvent/compaction(_:)`` or ``SessionEvent/compactionFailed(_:)``
/// (the terminal event of the signal), resumes the mail queue and wakes the
/// pump. No signal affects a running compaction. Only ``close()`` cancels it.
extension RoutedSessionActor {
    /// See ``RoutedSession/contextFill``. Synchronous and actor-isolated, which
    /// satisfies the protocol's `{ get async }` requirement.
    var contextFill: Double {
        usageState.fill(contextTokens: contextTokens)
    }

    /// See ``RoutedSession/compact(prompt:budget:)``.
    ///
    /// A requested compaction is work of the session from the call on: it
    /// holds one `WorkKind.compaction` lease (``beginWork(_:id:)``) from
    /// before the call returns, thus before each event of the compaction,
    /// to the end of the compaction, after its terminal event. A compaction
    /// that the close skips ends its lease in the skip.
    ///
    /// - Parameters:
    ///   - prompt: The compaction prompt sent to the summarizer.
    ///   - budget: The token budget to compact against, or `nil` for this
    ///     session's resolved working context.
    /// - Returns: The id of the signal.
    @discardableResult
    nonisolated func compact(prompt: CompactionPrompt = .default, budget: TokenBudget? = nil) -> SignalID {
        let id = SignalID()
        let order = CompactionOrder(prompt: prompt, budget: budget, reason: .requested, overflowRetryTarget: nil)
        let lease = beginWork(.compaction, id: id.description)
        submitSignal(
            id,
            { session in
                defer { lease.end() }
                _ = await session.performCompaction(id, order)
                session.signalWorkChange()
            },
            skipped: {
                lease.end()
            })
        return id
    }

    /// Compacts inside the running answer and waits for the result. Only the
    /// work of an answer calls it, at a budget trigger: before the first
    /// submission (``CompactionReason/triggerReached``), before the retry
    /// after a context overflow (``CompactionReason/contextOverflow``), after
    /// a tool result that moved the context to the trigger
    /// (``CompactionReason/toolResultYield``), and after a stop at the output
    /// ceiling (``CompactionReason/outputCeilingStop``).
    ///
    /// The compaction is a signal with a new ``SignalID``. It runs the same
    /// handler as a requested compaction (``performCompaction(_:_:)``), in
    /// the order of the signals. The answer waits for the end of that
    /// handler. The handler waits for no work of the pump and for no answer,
    /// and the answer holds no open submission while it waits, so the wait
    /// cannot deadlock.
    ///
    /// - Parameters:
    ///   - prompt: The compaction prompt sent to the summarizer tier that runs.
    ///   - budget: The token budget to compact against.
    ///   - reason: Why the compaction runs.
    ///   - overflowRetryTarget: The target the retry after a context overflow
    ///     computed, or `nil` (the default). The result carries it.
    /// - Returns: What the compaction did.
    /// - Throws: What the compaction throws, or `CancellationError` when the
    ///   answer was stopped before the compaction started, or when
    ///   ``close()`` came first.
    @discardableResult
    func compactInsideAnswer(
        prompt: CompactionPrompt,
        budget: TokenBudget,
        reason: CompactionReason,
        overflowRetryTarget: OverflowRetryTarget? = nil
    ) async throws -> CompactionResult {
        let id = SignalID()
        let order = CompactionOrder(
            prompt: prompt, budget: budget, reason: reason, overflowRetryTarget: overflowRetryTarget)
        return try await withCheckedThrowingContinuation { continuation in
            submitSignal(
                id,
                { session in
                    continuation.resume(with: await session.performCompaction(id, order))
                },
                skipped: {
                    continuation.resume(throwing: CancellationError())
                })
        }
    }

    /// The one compaction handler: the work of the compaction signal `id`,
    /// for both kinds. ``signals`` runs it with the origin
    /// ``Origin/signal(_:)`` of `id`, so each event of the compaction has
    /// that origin.
    ///
    /// The steps, in this order:
    ///
    /// 1. The mail queue pauses (``MailQueue/pause()``). While it is paused,
    ///    the pump takes no mail, so new mail waits; output still flows.
    /// 2. ``SessionEvent/compactionStarted(_:)``.
    /// 3. The compaction runs in a task of its own (``activeCompaction``),
    ///    which only ``close()`` cancels. It does not wait for a safe point
    ///    and does not stop a running answer: the next submission of an
    ///    answer waits for its end (``awaitActiveCompaction()``), and the
    ///    compaction applies its snapshot when no submission is open.
    /// 4. ``SessionEvent/compaction(_:)`` or
    ///    ``SessionEvent/compactionFailed(_:)``, the terminal event of the
    ///    signal. The output ledger keeps it, so
    ///    ``RoutedSession/awaitTerminal(of:)-(SignalID)`` gives it, also after
    ///    the end.
    /// 5. The mail queue resumes (``MailQueue/resume()``), and the pump wakes.
    ///    When signals came while the compaction ran, the resume comes after
    ///    their work (``SignalExecutor/whenNoSignalWaits(_:)``): a
    ///    ``RoutedSession/cancelAll()`` that came during the compaction thus
    ///    cancels the mail that waits, and the pump takes none of it first.
    ///
    /// A compaction does not start after ``close()`` began. Only the work of
    /// a compaction signal calls this handler, and that work comes to this
    /// actor only through ``runSignalWork(_:skipped:)``, which checks
    /// ``isClosed``. From that check to the registration of
    /// ``activeCompaction`` there is no suspension point. Close sets
    /// ``isClosed`` and cancels the running compaction with no suspension
    /// point between. Thus each compaction that starts is the one that close
    /// cancels, or it does not start.
    ///
    /// An automatic compaction whose answer a stop reached before the
    /// compaction started does not run: it sends no event, and the answer
    /// gets `CancellationError`. The events of an automatic compaction go
    /// through the event sink of its answer, so the readers of the mail of
    /// that answer get them too. A requested compaction has no audience: only
    /// the feeds of the session and the ledger get its events.
    ///
    /// - Parameters:
    ///   - id: The id of the compaction signal.
    ///   - order: What the compaction does and why.
    /// - Returns: The result of the compaction, or its error.
    func performCompaction(_ id: SignalID, _ order: CompactionOrder) async -> Result<CompactionResult, any Error> {
        if order.isAutomatic, isWorkCancelled {
            return .failure(CancellationError())
        }
        outbox.queue.pause()
        let pausedAt = ContinuousClock.now
        emitCompactionEvent(.compactionStarted(CompactionStart(id: id.description, reason: order.reason)), of: order)
        // The task inherits the origin of the signal and the tracing context
        // of the caller. It is in no model call: a mark of the model call of
        // a caller (a tool that asked for the compaction) would refuse its
        // summarizer submission.
        let compaction = Task {
            await ModelCallMark.$current.withValue(nil) {
                await runCompaction(id, order)
            }
        }
        activeCompaction = compaction
        let result = await compaction.value
        activeCompaction = nil
        compactionEnds.signal()
        // The queue resumes only after each signal that came while the
        // compaction ran, so that mail never overtakes such a signal (for
        // example a cancelAll() that must cancel the mail that waits). The
        // wake of the pump is a helper task, so the drain of close() waits
        // until it ended.
        signals.whenNoSignalWaits { [self] in
            outbox.queue.resume()
            sessionMetrics.recordMailQueuePause(ContinuousClock.now - pausedAt)
            _ = helperTasks.start { await self.wakePump() }
        }
        return result
    }

    /// Runs one compaction inside its span, and sends its terminal event.
    ///
    /// - Parameters:
    ///   - id: The id of the compaction signal.
    ///   - order: What the compaction does and why.
    /// - Returns: The result of the compaction, or its error.
    private func runCompaction(_ id: SignalID, _ order: CompactionOrder) async -> Result<CompactionResult, any Error> {
        do {
            var result = try await withCompactionSpan(reason: order.reason, signal: id) {
                try await compactTranscript(id: id, prompt: order.prompt, budget: order.budget)
            }
            if let overflowRetryTarget = order.overflowRetryTarget {
                result = result.withOverflowRetryTarget(overflowRetryTarget)
            }
            emitCompactionEvent(.compaction(result), of: order)
            return .success(result)
        } catch {
            let outcome: CompactionFailure.Outcome =
                Task.isCancelled || error is CancellationError ? .cancelled : .failed(String(describing: error))
            emitCompactionEvent(
                .compactionFailed(CompactionFailure(id: id.description, reason: order.reason, outcome: outcome)),
                of: order)
            return .failure(error)
        }
    }

    /// Sends one event of a compaction. The event of an automatic compaction
    /// goes through the event sink of its answer (``currentAnswerEventSink``),
    /// so the answer reduces it and the readers of the mail of the answer get
    /// it. The event of a requested compaction goes to the output of the
    /// session only.
    ///
    /// - Parameters:
    ///   - event: The event.
    ///   - order: The order of the compaction.
    private func emitCompactionEvent(_ event: SessionEvent, of order: CompactionOrder) {
        guard order.isAutomatic, let answerSink = currentAnswerEventSink else {
            emitSessionScopedEvent(event)
            return
        }
        answerSink(event)
    }

    /// Cancels the running compaction, and waits until its task sent its
    /// terminal event. Only ``close()`` calls it: it is the one exception to
    /// the rule that no signal affects a running compaction.
    ///
    /// A compaction that the cancel reaches before it applies ends with
    /// ``SessionEvent/compactionFailed(_:)`` (``CompactionFailure/Outcome/cancelled``),
    /// and the transcript keeps no compacted value. A compaction that already
    /// applies its snapshot goes on to its end, because that step is local
    /// and short.
    ///
    /// The cancel is a change of ``stateChanges``.
    func cancelActiveCompaction() async {
        guard let activeCompaction else { return }
        activeCompaction.cancel()
        stateChanges.signal()
        _ = await activeCompaction.value
    }

    /// Waits until no compaction runs. The work of an answer calls it before
    /// each submission, so the next render of the answer uses the compacted
    /// value. A compaction never waits for the work of an answer that waits
    /// here: the answer holds no open submission.
    ///
    /// The wait ends early when the waiting task is cancelled.
    func awaitActiveCompaction() async {
        _ = await compactionEnds.waitUntil { activeCompaction == nil }
    }

    /// The summarizer tiers of a compaction, in the order of preference: the
    /// profile's ``LanguageModelProfile/flash`` slot (not offered when this
    /// session is the flash slot), then this session's own model.
    ///
    /// The flash slot runs when its window holds the call and the summary.
    /// When the flash slot fails or its window is too small, the own model
    /// runs. The flash slot must hold a model that can summarize; the
    /// compaction applies no quality check on the summary text.
    private func summarizerTiers() -> [BackendSummarizerTier] {
        var tiers: [BackendSummarizerTier] = []
        if slot != .flash {
            tiers.append(
                BackendSummarizerTier(
                    tier: .flash,
                    backend: profile.flash.container.makeSession(
                        instructions: nil, samplingMode: profile.flash.samplingMode),
                    windowTokens: profile.flash.contextTokens,
                    model: profile.flash.chosen
                ))
        }
        tiers.append(BackendSummarizerTier(tier: .ownModel, backend: backend, windowTokens: contextTokens, model: model))
        return tiers
    }

    /// Runs one summarizer call as one submission to the queue of `target`,
    /// and waits for its result. With no `target`, the call runs directly.
    ///
    /// The call is not a submission of an answer: it opens no submission,
    /// sends no event of its own, holds no ``inFlightModelCall``, and reads
    /// no state of the running answer. Thus it can run while an answer runs.
    /// A cancel of the task of the compaction removes a submission that
    /// waits for the worker, or cancels the running call. The worker of the
    /// queue inherits no task-local, so the submission binds the origin, the
    /// tracing context and the ``ModelCallMark`` of the call itself.
    ///
    /// - Parameters:
    ///   - composedPrompt: The prompt of the summarizer call.
    ///   - target: The queue the call is one submission to, and its model, or
    ///     `nil` to run the call directly.
    ///   - body: The summarizer call.
    /// - Returns: The summary text.
    /// - Throws: What `body` throws, or `CancellationError` when the task of
    ///   the compaction was cancelled before the call started or while its
    ///   submission waited.
    nonisolated func runSummarizerCall(
        composedPrompt: String,
        submittingTo target: SubmissionTarget?,
        _ body: @escaping @Sendable (String) async throws -> String
    ) async throws -> String {
        try Task.checkCancellation()
        let mark = ModelCallMark(sessionID: id, submission: target)
        defer { mark.close() }
        let origin = OriginContext.current
        let serviceContext = ServiceContext.current
        let call: @Sendable () async throws -> String = {
            try await OriginContext.$current.withValue(origin) {
                try await ServiceContext.$current.withValue(serviceContext) {
                    try await ModelCallMark.$current.withValue(mark) {
                        try await body(composedPrompt)
                    }
                }
            }
        }
        guard let target else {
            return try await call()
        }
        return try await target.queue.submit(call)
    }

    /// Opens one ``RouterTelemetry/SpanName/compact`` span around a whole
    /// compaction and writes what the compaction did onto it.
    ///
    /// The one span site of the compaction handler. The tier written is the
    /// tier that wrote the applied summary. A compaction that applied no
    /// summary writes no tier. The site also counts the compaction by its
    /// trigger (``RouterTelemetry/MetricName/compactionCount``), before the
    /// work starts, so a compaction that throws counts too.
    ///
    /// The span also carries the reason of the compaction
    /// (``RouterTelemetry/AttributeKey/compactionReason``) and the id of its
    /// signal (``RouterTelemetry/AttributeKey/signalId``), `mailbox.md`,
    /// section 5, problem 18. The trigger
    /// (``RouterTelemetry/CompactionTrigger/init(reason:)``) stays the
    /// bounded dimension of the metric.
    ///
    /// - Parameters:
    ///   - reason: Why this compaction runs.
    ///   - signal: The id of the compaction signal.
    ///   - body: The compaction work.
    /// - Returns: What the compaction did.
    /// - Throws: Whatever `body` throws, after the span records the error
    ///   status and the type of the error, never its description
    ///   (``RouterTelemetry/withSpan(_:ofKind:tracer:isolation:_:)``).
    func withCompactionSpan(
        reason: CompactionReason,
        signal: SignalID,
        _ body: () async throws -> CompactionResult
    ) async throws -> CompactionResult {
        let trigger = RouterTelemetry.CompactionTrigger(reason: reason)
        sessionMetrics.recordCompaction(trigger: trigger)
        return try await RouterTelemetry
            .withSpan(RouterTelemetry.SpanName.compact, ofKind: .internal, tracer: tracer) { span in
                span.attributes[RouterTelemetry.AttributeKey.sessionId] = id.description
                span.attributes[RouterTelemetry.AttributeKey.modelRef] = model.stringValue
                span.attributes[RouterTelemetry.AttributeKey.compactionTrigger] = trigger.rawValue
                span.attributes[RouterTelemetry.AttributeKey.compactionReason] = reason.rawValue
                span.attributes[RouterTelemetry.AttributeKey.signalId] = signal.description
                let result = try await body()
                if let tier = result.summarizerTier {
                    span.attributes[RouterTelemetry.AttributeKey.compactionTier] = tier.rawValue
                }
                span.attributes[RouterTelemetry.AttributeKey.tokensBefore] = result.tokensBefore
                span.attributes[RouterTelemetry.AttributeKey.tokensAfter] = result.tokensAfter
                return result
            }
    }

    /// Abandons the compaction a summarizer tier just failed when its task is
    /// cancelled (only ``close()`` cancels it). Otherwise returns, so the
    /// compaction goes on to the next tier or throws the failure. Keyed on
    /// the cancel of the task, never on the failure's type.
    ///
    /// - Parameters:
    ///   - error: The failure the tier threw.
    ///   - tier: The tier that threw it.
    /// - Throws: `CancellationError` when the task of the compaction is
    ///   cancelled.
    private func abandonCompactionIfCancelled(discarding error: Error, tier: CompactionSummarizerTier) throws {
        // With it always `false`, a fault of the first tier that coincides
        // with a close degrades to the next tier. With it always `true`, a
        // failed tier never degrades
        // (AnswerCancellationTests.summarizerCancellationErrorWithNoStopOutstandingStillDegrades).
        guard Task.isCancelled else { return }
        noteAbandonedCompaction(discarding: error, tier: tier)
        throw CancellationError()
    }

    /// Logs the summarizer failure an abandoned compaction discards, unless it is a
    /// `CancellationError`. The log holds the tier, the session id, and the
    /// type and code of the error, never its description, which can contain
    /// transcript content.
    ///
    /// - Parameters:
    ///   - error: The failure the abandoned tier threw.
    ///   - tier: The tier that threw it.
    private func noteAbandonedCompaction(discarding error: Error, tier: CompactionSummarizerTier) {
        guard !(error is CancellationError) else { return }
        sessionLogger(.compaction).warning(
            """
            abandoning the compaction of a summarizer tier because its task is \
            cancelled; discarding the error it raised
            """,
            metadata: RouterTelemetry.errorMetadata(error).merging([
                RouterTelemetry.LogMetadataKey.sessionId: "\(id.description)",
                RouterTelemetry.LogMetadataKey.summarizerTier: "\(tier.rawValue)",
            ]) { _, new in new })
    }

    /// The live context a compaction reads when it starts.
    ///
    /// With no open submission, it is the whole transcript of ``backend``.
    /// While a submission is open, the compaction does not read ``backend``
    /// (a read during the tool loop of a model call is not safe): it reads
    /// the recorded entries of the last settled point
    /// (``settledTranscript``). The entries that the open submission writes
    /// come after the compacted value when the compaction applies.
    private var compactionSnapshot: [Transcript.Entry] {
        guard runningSubmission != nil else { return backend.transcriptEntries() }
        return Array(settledTranscript.entries.prefix(settledTranscript.recordedEntryCount))
    }

    /// The compaction mechanics of the handler. Runs
    /// ``Compactor/compact(_:prompt:budget:counter:summarizers:pendingRuns:protection:explicitLogger:abandoning:id:)``
    /// over the live context (``compactionSnapshot``), counted by this
    /// session's ``tokenCounter``. When a summary applied, waits until no
    /// submission is open, puts the new snapshot (and each entry written
    /// after the read) into a new ``backend``, and records the new entries
    /// by id. Otherwise leaves the session unchanged.
    ///
    /// - Parameters:
    ///   - id: The id of the compaction signal, which the result carries.
    ///   - prompt: The compaction prompt sent to the summarizer.
    ///   - budget: The token budget to compact against, or `nil` for this
    ///     session's resolved working context.
    /// - Returns: What the compaction did.
    /// - Throws: What the last tier throws, ``CompactionApplyError``, or
    ///   `CancellationError`. A compaction that throws leaves this session
    ///   unchanged.
    private func compactTranscript(id: SignalID, prompt: CompactionPrompt, budget: TokenBudget?) async throws
        -> CompactionResult
    {
        let entries = compactionSnapshot
        let resolvedBudget = budget ?? TokenBudget(limit: contextTokens)

        // Read at the moment the compaction boundary is written: the runs
        // still running in this session's run plane, as run-plane summaries
        // (token, op, latest progress — never output content), so a
        // post-compaction model keeps the tokens of its in-flight work
        // until the session reports each run's settlement.
        let pendingRuns = await runPlane.backgroundRuns().map { run in
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
            // Wrapped, never handed over bare: each summarizer call is one
            // submission to the queue of its model (see
            // ``QueuedCompactionSummarizer``).
            summarizers: summarizerTiers().map { $0.slot(for: self) },
            pendingRuns: pendingRuns,
            // The host rule this session was vended, forked or restored with,
            // so no compaction removes a protected tool output.
            protection: toolOutputProtection,
            // This session's explicit logger, so the record of a shortfall
            // goes where each other record of the session goes.
            explicitLogger: explicitLogger,
            abandoning: { [self] error, tier in try await abandonCompactionIfCancelled(discarding: error, tier: tier) },
            id: id
        )

        // Nothing to compact (already under target), or a shortfall: `compacted`
        // is the live context as it was, so there is nothing new to record
        // and no reason to swap `backend`.
        guard result.summaryEntryId != nil else { return result }

        await recordSessionMetaIfNeeded()
        // The snapshot replaces the backend, and a backend of an open
        // submission must not change. The answer holds no open submission
        // while it waits for a compaction, so this wait ends.
        try await awaitNoOpenSubmission()
        // Close cancels the compaction: then the transcript keeps no
        // compacted value, and a restore uses the full transcript.
        try Task.checkCancellation()
        let partials = try applySnapshot(compacted, of: entries, result: result)
        for partial in partials {
            await append(partial: partial)
        }
        // The new backend runs no call yet: the compacted window is the new
        // settled transcript, so a read after the compaction sees it.
        settleTranscript()
        return result
    }

    /// Waits until no submission of the running answer is open.
    ///
    /// - Throws: `CancellationError` when the task of the compaction is
    ///   cancelled first.
    private func awaitNoOpenSubmission() async throws {
        guard await submissionCloses.waitUntil({ runningSubmission == nil }) else { throw CancellationError() }
    }

    /// Puts the new snapshot into a new ``backend``, with no suspension
    /// point, and gives the partial events that record it.
    ///
    /// The entries that the session wrote after the compaction read
    /// `snapshot` (the entries of a submission that ran meanwhile) come after
    /// the compacted value, in their order.
    ///
    /// - Parameters:
    ///   - compacted: The new snapshot of `snapshot`.
    ///   - snapshot: The live context that the compaction read.
    ///   - result: What the compaction did.
    /// - Returns: The partial events that record the new entries.
    /// - Throws: ``CompactionApplyError/transcriptChanged`` when the live
    ///   transcript does not start with `snapshot`.
    private func applySnapshot(
        _ compacted: Transcript, of snapshot: [Transcript.Entry], result: CompactionResult
    ) throws -> [TranscriptEvent.Partial] {
        let current = backend.transcriptEntries()
        guard current.prefix(snapshot.count).map(\.id) == snapshot.map(\.id) else {
            throw CompactionApplyError.transcriptChanged
        }
        let laterEntries = current.dropFirst(snapshot.count)

        // What `backend` will hold, reported as `contextFill`'s numerator
        // immediately — the same way a restored session whose newest event is
        // a compaction checkpoint reports its segment's own `tokensAfter`.
        // `result.tokensAfter` is the tokenizer's
        // count, made before any call ran on the snapshot; the engine's
        // `usage.input` of the next live submission replaces it. Rescaled onto the
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
            } + laterEntries)

        // `current.prefix(persistedEntryCount)` is exactly what this
        // session has already recorded to `transcript.jsonl` — the same
        // baseline `recordTranscriptDelta(grammar:since:usage:deliveredMail:onEvent:)`
        // diffs the positional growth of an ordinary submission against. A compaction is not
        // a mere extension of it (`applied` is shorter and reorders entries
        // relative to it), so the diff here is by entry id rather than
        // position — see ``TranscriptDiffer/diffByEntryId(lastSeen:current:routerId:sessionId:parentId:slot:model:)``.
        let alreadyRecorded = Transcript(entries: current.prefix(persistedEntryCount))
        let partials = TranscriptDiffer.diffByEntryId(
            lastSeen: alreadyRecorded,
            current: applied,
            routerId: routerId,
            sessionId: self.id,
            parentId: parentId,
            slot: slot,
            model: model
        ).map { diffPartial in
            makePartialEvent(kind: diffPartial.kind, grammar: grammar, text: diffPartial.text, entry: diffPartial.entry)
        }

        // Swap the inner session in place: same actor, same nonisolated
        // `id`, same `recorder`, same `recordingDirectory` — only the
        // backend driving generation changes. Seeded with the summary entry
        // included, so what
        // the model sees live is exactly what a restore rebuilds from the
        // checkpoint's live window.
        backend = backend.replacingTranscript(applied)
        // Only the positional backend baseline rewinds to the new snapshot.
        // `historyOrdinal` advances when the session records the partial
        // events, and never rewinds: the compaction changed the *context*,
        // not the session's position in its own append-only history.
        persistedEntryCount = applied.count
        // The new snapshot is what the backend now holds, so its identity is
        // what the non-append-divergence checks of later submissions verify
        // against — see ``persistedBaseline``.
        persistedBaseline = TranscriptDiffer.Baseline(transcript: applied)
        usageState = .measured(input: measuredTokensAfter, output: 0)
        return partials
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
