import Foundation
import FoundationModels

/// ``RoutedSessionActor``'s session-lifetime boundaries: forking a child session
/// over the same resident model, and closing a session down.
extension RoutedSessionActor {
    /// Forks a child session over the same resident model, inside one
    /// ``RouterTracing/SpanName/fork`` span. See
    /// ``RoutedSession/fork(workingDirectory:)`` for the full contract,
    /// ``withForkSpan(_:)`` for what the span covers, and
    /// ``performFork(workingDirectory:)`` for the mechanics.
    ///
    /// - Parameter workingDirectory: The child's working directory, or `nil` to
    ///   default to its recording directory.
    /// - Returns: The forked child session.
    /// - Throws: Nothing now: ``performFork(workingDirectory:)`` does not
    ///   throw. The protocol requirement keeps `throws`, and an error of a
    ///   later fork step would be recorded on the span.
    func fork(workingDirectory: URL?) async throws -> RoutedSession {
        try await withForkSpan {
            await performFork(workingDirectory: workingDirectory)
        }
    }

    /// Opens one ``RouterTracing/SpanName/fork`` span around a whole fork and
    /// writes the child it produced onto it.
    ///
    /// The span opens before `body` runs, so it covers every part of the call.
    /// A fork that throws still leaves a span carrying its error.
    ///
    /// The child's id is written only once the child exists, so a fork that
    /// threw names no child.
    ///
    /// - Parameter body: The fork work, producing the child session.
    /// - Returns: The forked child session.
    /// - Throws: Whatever `body` throws. `withSpan` records the error on the
    ///   span and raises it again.
    private func withForkSpan(
        _ body: () async throws -> RoutedSession
    ) async throws -> RoutedSession {
        try await RouterTracing.tracer(explicit: tracer)
            .withSpan(RouterTracing.SpanName.fork, ofKind: .internal) { span in
                span.attributes[RouterTracing.AttributeKey.routerId] = routerId.description
                span.attributes[RouterTracing.AttributeKey.sessionId] = id.description
                span.attributes[RouterTracing.AttributeKey.modelRef] = model.stringValue
                let child = try await body()
                span.attributes[RouterTracing.AttributeKey.forkChildSessionId] = child.id.description
                return child
            }
    }

    /// The fork mechanics ``fork(workingDirectory:)`` opens its span around.
    ///
    /// Builds the child's tools from ``originalTools`` (never this session's
    /// own already-instanced
    /// ``tools``) so a ``ForkableTool`` conformer forks exactly once from its
    /// pristine state before being wrapped in the child's own mount
    /// layer — the chain is fork → mount → cap, so the child's background
    /// runs are tracked in the child's own mailbox. The child's
    /// ``recordingDirectory`` nests directly under this session's, and it
    /// inherits this session's ``contextTokens``/``usageState`` so its fill
    /// reporting starts from the parent's fill at fork time rather than zero.
    ///
    /// The child is seeded from ``settledTranscript``, with the calls of an
    /// open round that have no output removed
    /// (``SettledTranscript/removingUnansweredCalls()``), at once and from any
    /// task (`generation-queue.md`, section 5.8). The fork waits for no
    /// submission and reads nothing of `backend`'s live transcript, so a fork
    /// from a tool of this session's own submission is served too.
    ///
    /// - Parameter workingDirectory: The child's working directory, or `nil` to
    ///   default to its recording directory.
    /// - Returns: The forked child session.
    private func performFork(workingDirectory: URL?) async -> RoutedSession {
        // Fresh-per-session outbox plus fork-then-mount tool composition
        // (see ``outbox``'s doc comment): built from ``originalTools`` — the
        // true originals, never this session's own already-instanced
        // ``tools`` — so a ``ForkableTool`` conformer is forked exactly once,
        // from its pristine state, rather than from a copy already wrapped
        // for this session. This site's chain is fork →
        // mount → cap (task ^k4nygqa; the root and restore sites each
        // have their own deliberately distinct chain — see
        // ``RoutedModel/makeSession(grammar:instructions:workingDirectory:recordingRoot:tools:budget:compactionPrompt:summarization:agentSpawn:discoveryPriming:toolOutputProtection:repetitionDetection:mailOnlyAnswerLimit:)``
        // and `restoreSessionTree`). Composition order matters: a tool is
        // forked first via its own `forked()` (falling back to sharing the
        // original unchanged when it doesn't conform to `ForkableTool`),
        // *then* the forked result is wrapped in the child's own binding
        // layer — `RunToCompletionRunner` or `BackgroundToolRunner` for a String-output tool,
        // `ContextBindingTool` for a non-String-output one — whose ambient
        // `ToolContext` posts to `childOutbox`. This
        // session's own already-instanced
        // `tools` are entirely untouched by this and keep posting to this
        // session's own `outbox` — including any background work that
        // captured this session's sink before the fork — so event delivery
        // never migrates to the child. `childTools` is then threaded into
        // `backend.makeFork(tools:seededFrom:)` itself, so the live model
        // backing the fork actually calls these child-instanced tools rather
        // than silently carrying forward whatever this session's backend was
        // built with (see
        // ``LanguageModelSessionBackend/makeFork(tools:seededFrom:)``).
        // Mounting and capping arrive through the shared per-tool
        // composition
        // ``ToolMounting/makeSessionMounted(tool:sessionID:mailbox:sink:cappedToTokenLimit:tokenCounter:tracer:)``
        // (tasks ^k4nygqa, 1334fk3): the forked copy is mounted with the
        // child's own identity, mailbox, and outbox — so the fork's background
        // runs live in the fork's own mailbox, never the parent's — and,
        // when the fork inherits ``autoCompactionBudget``, capped outermost
        // to its ``TokenBudget/toolOutputLimit``, exactly as
        // ``RoutedModel/makeSessionToolWiring(_:sessionID:cappedToTokenLimit:tokenCounter:)``
        // caps a root session's tools. The child's mounts carry this session's
        // tracer, which the child actor is constructed with too, so a tool span
        // the fork opens reports to the same backend as the parent's.
        let childOutbox = SessionOutbox()
        // The child's mailbox is fresh for the same reason its outbox is:
        // background runs and pending elicitations never migrate between
        // sessions (see ``RoutedSessionActor/mailbox``).
        let childMailbox = SessionMailbox()
        // Minted before the tool composition below, deliberately: the
        // child's binding layers (`RunToCompletionRunner`, `BackgroundToolRunner`,
        // and `ContextBindingTool`)
        // stamp this id — the fork's own session identity — into every
        // composed run's ``ToolContext``.
        let childId = ULID.generate()
        let childTools = originalTools.map { tool -> any Tool in
            let forked = (tool as? any ForkableTool)?.forked() ?? tool
            return ToolMounting.makeSessionMounted(
                tool: forked,
                sessionID: childId,
                mailbox: childMailbox,
                sink: childOutbox,
                cappedToTokenLimit: autoCompactionBudget?.toolOutputLimit,
                tokenCounter: tokenCounter,
                tracer: tracer
            )
        }

        // The settled transcript, not the live one: a submission of this
        // session can run now, and the SDK writes the live transcript on its
        // own task (`generation-queue.md`, section 5.8). One value holds the
        // entries and the recording cut of one settled point, so the three
        // facts below describe one moment. No wait, and no lock.
        let seed = settledTranscript.removingUnansweredCalls()
        // The child's own `persistedEntryCount` baseline: the prefix of its
        // seed that this session had already recorded, so the parent's history
        // inherited into the fork is never re-persisted into the child's
        // transcript (see ``persistedEntryCount``). At a tool-result boundary,
        // the entries of the running submission come after it, and the child
        // records them itself.
        let entryCountAtFork = seed.recordedEntryCount
        // The cut in append-only history coordinates, of the same settled
        // point: this session's position in its own recorded history. Unlike
        // the positional count above, a compaction never rewinds it, so a fork
        // taken after a compaction restores the compaction's live window
        // rather than the discarded pre-compaction span (see
        // ``historyOrdinal`` and ``SessionSidecar/forkedAtHistoryOrdinal``).
        let historyOrdinalAtFork = seed.historyOrdinal
        let forkedBackend = backend.makeFork(tools: childTools, seededFrom: seed.transcript)

        // The child's transcript nests directly *under this session's* directory,
        // so the on-disk tree mirrors the fork lineage: a root session lives at
        // `<base>/<routerId>/<rootId>/`, its fork at `.../<rootId>/<childId>/`, a
        // grandfork one level deeper again. Nesting is derived purely from the
        // parent chain — the child's `workingDirectory` override never moves it.
        let childRecordingDirectory = recordingDirectory
            .appendingPathComponent(childId.description, isDirectory: true)
        // The child lands its own sidecar as it is constructed, from the
        // `entryCountAtFork` baseline passed below — so `fork()` never returns a
        // durable child directory a transcript can land in with no sidecar
        // beside it, and needs no sidecar call of its own to say so (see
        // ``SessionSidecarOrigin``).

        let child = makeRoutedSessionActor(
            profile: profile,
            routerId: routerId,
            id: childId,
            parentId: id,
            recordingDirectory: childRecordingDirectory,
            workingDirectory: workingDirectory ?? childRecordingDirectory,
            backend: forkedBackend,
            slot: slot,
            model: model,
            recorder: recorder,
            instructions: instructions,
            grammar: grammar,
            tools: childTools,
            originalTools: originalTools,
            outbox: childOutbox,
            mailbox: childMailbox,
            persistedEntryCount: entryCountAtFork,
            // The child's history starts where the parent's recorded history
            // stood at fork time — this initial ordinal is also the cut point
            // the child's sidecar records.
            historyOrdinal: historyOrdinalAtFork,
            // A fork is a brand-new session wherever its parent could record
            // one — including a fork of a restored session.
            sidecarOrigin: sidecarOrigin.forFork,
            // Taken from a live session, so the child's own session span says
            // `forked` and names this session as its parent. That span nests
            // inside the fork span opened above, so the two never read as two
            // costs (see `makeRoutedSessionActor`).
            origin: .forked,
            // Same profile/slot, so the same resolved context; the child's
            // backend is seeded from this session's settled transcript
            // (``LanguageModelSessionBackend/makeFork(tools:seededFrom:)``), so it also
            // inherits this session's own fill state as of fork time rather
            // than starting from a misleading "nothing sent yet" zero.
            contextTokens: contextTokens,
            usageState: usageState,
            // A fork manages its own window exactly like its parent: same
            // opt-in budget and compaction prompt, so a long-running forked
            // task auto-compacts too rather than silently losing the
            // opt-in at fork time.
            autoCompactionBudget: autoCompactionBudget,
            autoCompactionPrompt: autoCompactionPrompt,
            // A compaction on a fork runs the same summarization stage as a
            // compaction on its parent.
            summarization: summarization,
            // A fork carries no spawn context, the same rule as its sidecar
            // (``SessionSidecar/agentSpawn``): its lineage is stated by the
            // parent link and the directory nesting, not by a spawn fact.
            agentSpawn: nil,
            // Priming travels with the session for the same reason the
            // auto-compaction opt-in does: a fork continues its parent's
            // conversation, so it primes its answers exactly like its parent.
            discoveryPriming: discoveryPriming,
            // A compaction on a fork keeps what a compaction on its parent keeps: the
            // same host rule protects the same tool outputs.
            toolOutputProtection: toolOutputProtection,
            // A fork continues its parent's conversation, so the same watch
            // stops a call of the fork that repeats itself.
            repetitionDetection: repetitionDetection,
            // A fork continues its parent's conversation, so the same bound
            // holds a chain of answers that mail alone starts. Its count
            // starts at zero, because the fork has no answer yet.
            mailOnlyAnswerLimit: mailOnlyAnswerLimit,
            // Same model, so the same tokenizer counts for the child.
            tokenCounter: tokenCounter,
            // The parent's own tracer: a fork continues its parent's
            // conversation, so its spans belong in the same trace and must
            // reach the same backend.
            tracer: tracer
        )
        // The stall report interval is a host setting, as the other settings
        // above are, so the child starts with the interval of this session.
        await child.setGenerationStallReportInterval(generationStallReportInterval)
        return child
    }

    /// See ``RoutedSession/close()``.
    ///
    /// Runs ``mailbox``'s `SessionMailbox.sweep()`, then journals each
    /// terminal event it produced through
    /// `SessionOutbox.journalWithoutStaging(event:)` — reaching the same
    /// ``record(event:)``, and so the same ``makeRunEventPartial(for:)``, a
    /// run's own reports take when they are journaled live. The journal is
    /// complete before this method returns: exactly one terminal event per
    /// background run, no orphans, no holes.
    ///
    /// **Why through the outbox rather than straight to the recorder.**
    /// Every other journal write is ordered by `SessionOutbox`'s one FIFO
    /// chain, and position in the transcript is the record. Appending a swept
    /// terminal directly would put it outside that order, so it could land
    /// ahead of an earlier posted event still draining on the chain — the
    /// transcript would then say a run ended before it reported the progress
    /// it in fact reported first. Routing through the outbox puts the
    /// teardown write in the same queue as everything else; it stages
    /// nothing, because there is no next submission for a teardown terminal to
    /// ride.
    ///
    /// **A run's ending is recorded once, even though three writers can
    /// produce it.** The run's own funnel writes its terminal live through the
    /// outbox. The mailbox forwards the same terminal at settlement, through
    /// ``deliver(settledTerminal:)``; that is the write that reaches the
    /// journal for a run mounted inside another run, whose funnel copy is
    /// dropped. The sweep's write here is the third. A sweep synthesizes a
    /// terminal only for runs still running, but that does not make one
    /// writer per run: `sweep()` suspends across each run's canceler, so a run
    /// can settle naturally in that window and reach the journal through the
    /// two earlier writers before the sweep hands the same retained event
    /// back; and cancelling a ``RunKind/swiftTask`` run is cooperative, so a
    /// run swept here can still finish afterwards and post its own terminal
    /// with a *different* outcome. Every later write is refused by
    /// ``claimJournalWrite(for:)``, which lets the first write of a run's
    /// ending stand and appends no second one — the record is append-only, so
    /// nothing already written is ever revised away.
    ///
    /// **Restore-time decision, stated deliberately:** these `.toolOutput`
    /// events are entry-kind, so ``TranscriptTree/effectiveTranscript(forSession:view:)``
    /// rebuilds each one into the restored transcript as a
    /// `Transcript.Entry.toolOutput` (with no paired `.toolCalls` — the run
    /// was backgrounded, not model-invoked). That is intended: a restored
    /// session's model sees how the background runs it left behind actually
    /// ended. ``OperationEventSegment`` rebuilds from its own persisted
    /// schema name, so restoring a closed session succeeds with no caller
    /// setup.
    ///
    /// Journaling brings the session meta line with it: a close that
    /// journals anything first records the `.session` meta event (exactly as
    /// every answer path does via `recordSessionMetaIfNeeded()`), so the
    /// journal never opens with a bare `.toolOutput` line. A close with
    /// nothing swept journals nothing at all — a session that never
    /// generated and never backgrounded a run still writes no file, preserving
    /// `generate(grammar:prompt:_:)`'s "writes no file at all until it
    /// generates" invariant.
    ///
    /// **The prompt cache of the session** (task ^cc2tezn). Each close
    /// releases the key of this session on its model
    /// (``releasePromptCache()``), whether or not the sweep gave a terminal
    /// event. The close of a fork releases the key of the fork only: the
    /// fork has its own ULID, so the key of its open parent stays. A session
    /// that is dropped with no close keeps its entry in the cache of the
    /// model until the byte LRU and the disk budget of the cache remove it,
    /// so the cache stays in its limits. A pass that ends after the close
    /// can write the entry again, and the same limits remove it.
    func close() async {
        // Before anything that can return early: a consumer looping over
        // ``streamSessionEvents()`` must end when the session does, whether or
        // not this close has anything to journal.
        finishSessionEventSubscriptions()

        let terminalEvents = await mailbox.sweep()
        // Before the early return below: most sessions close with no terminal
        // event, and each of them must release its key too.
        await releasePromptCache()
        guard !terminalEvents.isEmpty else { return }
        // A run can only be backgrounded from inside an answer, so by here the journal
        // is normally attached already; attaching is idempotent, and doing it
        // unconditionally means this path never depends on that reasoning
        // holding for every future caller.
        await attachOutboxJournalIfNeeded()
        for event in terminalEvents {
            await outbox.journalWithoutStaging(event: event)
        }
    }
}
