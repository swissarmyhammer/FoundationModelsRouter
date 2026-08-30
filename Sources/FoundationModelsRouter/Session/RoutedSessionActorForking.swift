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
    /// - Throws: Whatever ``performFork(workingDirectory:)`` throws, with the
    ///   error recorded on the span.
    func fork(workingDirectory: URL?) async throws -> RoutedSession {
        try await withForkSpan {
            try await performFork(workingDirectory: workingDirectory)
        }
    }

    /// Opens one ``RouterTracing/SpanName/fork`` span around a whole fork and
    /// writes the child it produced onto it.
    ///
    /// The span opens before `body` runs, so it covers every part of the call
    /// that can refuse or suspend: the reentry guard, which throws before any
    /// gate is touched, and ``forkAdmissionGate``'s wait for a free slot. A
    /// refused fork therefore still leaves a span carrying its refusal, and a
    /// queued fork's wait for a slot is time its own span covers.
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
    /// Waits on ``forkAdmissionGate`` for a free slot, then builds the child's
    /// tools from ``originalTools`` (never this session's own already-instanced
    /// ``tools``) so a ``ForkableTool`` conformer forks exactly once from its
    /// pristine state before being wrapped in the child's own mount
    /// layer — the chain is fork → mount → cap, so the child's background
    /// runs are tracked in the child's own mailbox. Acquires
    /// ``turnLock`` just long enough to read `backend`'s conversation state
    /// and entry count together, closing the race against a concurrent
    /// in-flight turn mutating that same state. The child's
    /// ``recordingDirectory`` nests directly under this session's, and it
    /// inherits this session's ``contextTokens``/``usageState`` so its fill
    /// reporting starts from the parent's fill at fork time rather than zero.
    ///
    /// A fork asked for from inside a tool call of this session's own turn is
    /// refused rather than served (see ``isInsideOwnTurnToolCall``). That turn
    /// holds ``turnLock`` until the tool returns, so the wait below could never
    /// end; and the state the fork would read is half-written mid-turn — the
    /// tool call has landed, its output and the answer that follows it have
    /// not — so the child would carry a conversation the model never finished,
    /// from a history position the parent goes on writing past. Fork before
    /// the turn starts, or fork another session over the same model.
    ///
    /// - Parameter workingDirectory: The child's working directory, or `nil` to
    ///   default to its recording directory.
    /// - Returns: The forked child session.
    /// - Throws: ``SessionReentryError/forkDuringSameSessionTurn(sessionID:)``
    ///   when this call came from inside a tool call of this same session's own
    ///   turn — refused before any gate is touched, so nothing is acquired and
    ///   nothing has to be unwound. Otherwise nothing — see the protocol doc's
    ///   ``RoutedSession/fork(workingDirectory:)`` `Throws:` note.
    private func performFork(workingDirectory: URL?) async throws -> RoutedSession {
        // Before the admission gate, so a refused fork takes no slot. The span
        // is already open around this, so the refusal is recorded on it.
        guard !isInsideOwnTurnToolCall else {
            throw SessionReentryError.forkDuringSameSessionTurn(sessionID: id)
        }

        // Admission: at most the router's `maxConcurrentForks` fork sessions over
        // this model may be in flight at once. Past the ceiling this suspends
        // (FIFO) until an outstanding fork is released and frees its slot. The
        // permit is held for the child's lifetime and released in its `deinit`.
        await forkAdmissionGate.wait()

        // Fresh-per-session outbox plus fork-then-mount tool composition
        // (see ``outbox``'s doc comment): built from ``originalTools`` — the
        // true originals, never this session's own already-instanced
        // ``tools`` — so a ``ForkableTool`` conformer is forked exactly once,
        // from its pristine state, rather than from a copy already wrapped
        // for this session. This site's chain is fork →
        // mount → cap (task ^k4nygqa; the root and restore sites each
        // have their own deliberately distinct chain — see
        // ``RoutedModel/makeSession(grammar:instructions:workingDirectory:recordingRoot:tools:budget:compactionPrompt:summarization:agentSpawn:discoveryPriming:)``
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
        // never migrates to the child. Computed before the turn-lock window
        // below purely because it has no dependency on `backend`'s state;
        // `childTools` is then threaded into `backend.makeFork(tools:)`
        // itself, so the live model backing the fork actually calls these
        // child-instanced tools rather than silently carrying forward
        // whatever this session's backend was built with (see
        // ``LanguageModelSessionBackend/makeFork(tools:)``).
        // Mounting and capping arrive through the shared per-tool
        // composition
        // ``ToolMounting/makeSessionMounted(tool:sessionID:mailbox:sink:cappedToTokenLimit:tracer:)``
        // (tasks ^k4nygqa, 1334fk3): the forked copy is mounted with the
        // child's own identity, mailbox, and outbox — so the fork's background
        // runs live in the fork's own mailbox, never the parent's — and,
        // when the fork inherits ``autoCompactionBudget``, capped outermost
        // to its ``TokenBudget/toolOutputLimit``, exactly as
        // ``RoutedModel/makeSessionToolWiring(_:sessionID:cappedToTokenLimit:)``
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
                tracer: tracer
            )
        }

        // Acquire this session's turn lock before reading `backend`'s
        // conversation state to fork it. `generate(grammar:_:)` releases that
        // same lock only *after* `body()` returns, but `body()` itself suspends
        // across an await while the model generates — so a concurrent turn can be
        // mid-flight, outside the lock's protection window as far as `backend`
        // internals are concerned, mutating the underlying
        // `LanguageModelSession.transcript` at the exact moment
        // `makeFork(tools:)` would otherwise read it. Taking the lock here
        // serializes the fork's read against any in-flight turn, closing that
        // data race; releasing it immediately after capturing the forked backend
        // keeps the hold no longer than necessary.
        //
        // The turn lock rather than the per-model generation gate, deliberately:
        // a turn suspended in ``awaitingUser(_:)`` has handed the generation gate
        // back to let other sessions generate, but it is still very much in
        // flight and its `backend` is still mid-turn.
        await turnLock.wait()
        // Captured in the same gate window as `makeFork(tools:)`, so it names
        // exactly the entry count the child's seeded backend starts holding —
        // the child's own `persistedEntryCount` baseline, so the parent's history
        // inherited into the fork is never re-persisted into the child's
        // transcript (see ``persistedEntryCount``).
        let entryCountAtFork = backend.transcriptEntries().count
        // The cut in append-only history coordinates, captured in the same
        // synchronous window as `entryCountAtFork` so the two describe one
        // moment: this session's position in its own recorded history —
        // unlike the positional backend count above, a fold never rewinds it,
        // so a fork taken after a fold restores the fold's live window rather
        // than the discarded pre-fold span (see ``historyOrdinal`` and
        // ``SessionSidecar/forkedAtHistoryOrdinal``).
        let historyOrdinalAtFork = historyOrdinal
        let forkedBackend = backend.makeFork(tools: childTools)
        turnLock.signal()

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

        return makeRoutedSessionActor(
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
            generationGate: generationGate,
            forkAdmissionGate: forkAdmissionGate,
            holdsAdmissionPermit: true,
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
            // backend is seeded from this session's accumulated transcript
            // (``LanguageModelSessionBackend/makeFork(tools:)``), so it also
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
            // A fold on a fork condenses exactly like a fold on its parent:
            // same recency window, same chunk ceiling, same compression ratio.
            summarization: summarization,
            // Priming travels with the session for the same reason the
            // auto-compaction opt-in does: a fork continues its parent's
            // conversation, so it primes its turns exactly like its parent.
            discoveryPriming: discoveryPriming,
            // The parent's own tracer: a fork continues its parent's
            // conversation, so its spans belong in the same trace and must
            // reach the same backend.
            tracer: tracer
        )
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
    /// nothing, because there is no next turn for a teardown terminal to
    /// ride.
    ///
    /// **A run's ending is recorded once, even though two writers can produce
    /// it.** A sweep synthesizes a terminal only for runs still running, but
    /// that does not make one writer per run: `sweep()` suspends across each
    /// run's canceler, so a run can settle naturally in that window and
    /// journal its own terminal live before the sweep hands the same retained
    /// event back; and cancelling a ``RunKind/swiftTask`` run
    /// is cooperative, so a run swept here can still finish afterwards and
    /// post its own terminal with a *different* outcome. Both are refused by
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
    /// every turn path does via `recordSessionMetaIfNeeded()`), so the
    /// journal never opens with a bare `.toolOutput` line. A close with
    /// nothing swept journals nothing at all — a session that never
    /// generated and never backgrounded a run still writes no file, preserving
    /// `generate(grammar:prompt:_:)`'s "writes no file at all until it
    /// generates" invariant.
    func close() async {
        // Before anything that can return early: a consumer looping over
        // ``streamSessionEvents()`` must end when the session does, whether or
        // not this close has anything to journal.
        finishSessionEventSubscriptions()

        let terminalEvents = await mailbox.sweep()
        guard !terminalEvents.isEmpty else { return }
        // A run can only be backgrounded from inside a turn, so by here the journal
        // is normally attached already; attaching is idempotent, and doing it
        // unconditionally means this path never depends on that reasoning
        // holding for every future caller.
        await attachOutboxJournalIfNeeded()
        for event in terminalEvents {
            await outbox.journalWithoutStaging(event: event)
        }
    }
}
