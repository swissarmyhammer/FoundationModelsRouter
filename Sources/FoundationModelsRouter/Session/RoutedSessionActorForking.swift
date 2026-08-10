import Foundation
import FoundationModels

/// ``RoutedSessionActor``'s session-lifetime boundaries: forking a child session
/// over the same resident model, and closing a session down.
extension RoutedSessionActor {
    /// Forks a child session over the same resident model. See
    /// ``RoutedSession/fork(workingDirectory:)`` for the full contract.
    ///
    /// Waits on ``forkAdmissionGate`` for a free slot, then builds the child's
    /// tools from ``originalTools`` (never this session's own already-instanced
    /// ``tools``) so a ``ForkableTool`` conformer forks exactly once from its
    /// pristine state before being wrapped in the child's own detachment
    /// layer — this site's full chain is fork → detach → cap (task ^k4nygqa),
    /// so the child's detached runs park in the child's own mailbox. Acquires
    /// ``turnLock`` just long enough to read `backend`'s conversation state
    /// and entry count together, closing the race against a concurrent
    /// in-flight turn mutating that same state. The child's
    /// ``recordingDirectory`` nests directly under this session's, and it
    /// inherits this session's ``contextTokens``/``usageState`` so its fill
    /// reporting starts from the parent's fill at fork time rather than zero.
    ///
    /// - Parameter workingDirectory: The child's working directory, or `nil` to
    ///   default to its recording directory.
    /// - Returns: The forked child session.
    /// - Throws: Nothing in the current implementation — see the protocol
    ///   doc's ``RoutedSession/fork(workingDirectory:)`` `Throws:` note.
    func fork(workingDirectory: URL?) async throws -> RoutedSession {
        // Admission: at most the router's `maxConcurrentForks` fork sessions over
        // this model may be in flight at once. Past the ceiling this suspends
        // (FIFO) until an outstanding fork is released and frees its slot. The
        // permit is held for the child's lifetime and released in its `deinit`.
        await forkAdmissionGate.wait()

        // Fresh-per-session outbox plus fork-then-detach tool composition
        // (see ``outbox``'s doc comment): built from ``originalTools`` — the
        // true originals, never this session's own already-instanced
        // ``tools`` — so a ``ForkableTool`` conformer is forked exactly once,
        // from its pristine state, rather than from a copy already wrapped
        // for this session. This site's chain is fork →
        // detach → cap (task ^k4nygqa; the root and restore sites each
        // have their own deliberately distinct chain — see
        // ``RoutedModel/makeSession(grammar:instructions:workingDirectory:recordingRoot:tools:budget:compactionPrompt:summarization:agentSpawn:discoveryPriming:)``
        // and `restoreSessionTree`). Composition order matters: a tool is
        // forked first via its own `forked()` (falling back to sharing the
        // original unchanged when it doesn't conform to `ForkableTool`),
        // *then* the forked result is wrapped in the child's own binding
        // layer — `DetachingTool` for a String-output tool,
        // `ContextBindingTool` for a non-String-output one — whose ambient
        // `ToolContext` posts to `childOutbox`. This
        // session's own already-instanced
        // `tools` are entirely untouched by this and keep posting to this
        // session's own `outbox` — including any detached work that
        // captured this session's sink before the fork — so event delivery
        // never migrates to the child. Computed before the turn-lock window
        // below purely because it has no dependency on `backend`'s state;
        // `childTools` is then threaded into `backend.makeFork(tools:)`
        // itself, so the live model backing the fork actually calls these
        // child-instanced tools rather than silently carrying forward
        // whatever this session's backend was built with (see
        // ``LanguageModelSessionBackend/makeFork(tools:)``).
        // Detachment and capping arrive through the shared per-tool
        // composition
        // ``ToolDetachment/sessionMounted(tool:sessionID:mailbox:sink:cappedToTokenLimit:)``
        // (tasks ^k4nygqa, 1334fk3): the forked copy is detached with the
        // child's own identity, mailbox, and outbox — so the fork's parked
        // runs live in the fork's own mailbox, never the parent's — and,
        // when the fork inherits ``autoCompactionBudget``, capped outermost
        // to its ``TokenBudget/toolOutputLimit``, exactly as
        // ``RoutedModel/makeSessionToolWiring(_:sessionID:cappedToTokenLimit:)``
        // caps a root session's tools.
        let childOutbox = SessionOutbox()
        // The child's mailbox is fresh for the same reason its outbox is:
        // parked runs and pending elicitations never migrate between
        // sessions (see ``RoutedSession/mailbox``).
        let childMailbox = SessionMailbox()
        // Minted before the tool composition below, deliberately: the
        // child's binding layers (`DetachingTool` and `ContextBindingTool`)
        // stamp this id — the fork's own session identity — into every
        // composed run's ``ToolContext``.
        let childId = ULID.generate()
        let childTools = originalTools.map { tool -> any Tool in
            let forked = (tool as? any ForkableTool)?.forked() ?? tool
            return ToolDetachment.sessionMounted(
                tool: forked,
                sessionID: childId,
                mailbox: childMailbox,
                sink: childOutbox,
                cappedToTokenLimit: autoCompactionBudget?.toolOutputLimit
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
        // a turn parked in ``awaitingUser(_:)`` has handed the generation gate
        // back to let other sessions generate, but it is still very much in
        // flight and its `backend` is still mid-turn.
        await turnLock.wait()
        // Captured in the same gate window as `makeFork(tools:)`, so it names
        // exactly the entry count the child's seeded backend starts holding —
        // the child's own `persistedEntryCount` baseline, so the parent's history
        // inherited into the fork is never re-persisted into the child's
        // transcript (see ``persistedEntryCount``).
        let entryCountAtFork = backend.transcriptEntries().count
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
            // A fork is a brand-new session wherever its parent could record
            // one — including a fork of a restored session.
            sidecarOrigin: sidecarOrigin.forFork,
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
            discoveryPriming: discoveryPriming
        )
    }

    /// See ``RoutedSession/close()``.
    ///
    /// Runs ``mailbox``'s ``SessionMailbox/sweep()``, then journals each
    /// terminal event it produced as a `.toolOutput`-kind recorded event
    /// whose entry is a real `Transcript.Entry.toolOutput` carrying the
    /// event as a typed ``OperationEventSegment`` — the same durable shape a
    /// turn-drained event takes on a recorded `.prompt` entry (see
    /// ``appendingOperationEventSegments(_:to:)``). The journal is complete
    /// before this method returns: exactly one terminal event per parked
    /// run, no orphans, no holes.
    ///
    /// **Restore-time decision, stated deliberately:** these `.toolOutput`
    /// events are entry-kind, so ``TranscriptTree/effectiveTranscript(forSession:registry:view:)``
    /// rebuilds each one into the restored transcript as a
    /// `Transcript.Entry.toolOutput` (with no paired `.toolCalls` — the run
    /// was detached, not model-invoked). That is intended: a restored
    /// session's model sees how the detached runs it left behind actually
    /// ended. ``OperationEventSegment`` is registered in
    /// ``CustomSegmentRegistry/routerDefault``, so a default-registry
    /// restore of a closed session succeeds with no caller setup.
    ///
    /// Journaling brings the session meta line with it: a close that
    /// journals anything first records the `.session` meta event (exactly as
    /// every turn path does via `recordSessionMetaIfNeeded()`), so the
    /// journal never opens with a bare `.toolOutput` line. A close with
    /// nothing swept journals nothing at all — a session that never
    /// generated and never parked a run still writes no file, preserving
    /// `generate(grammar:prompt:_:)`'s "writes no file at all until it
    /// generates" invariant.
    func close() async {
        // Before anything that can return early: a consumer looping over
        // ``streamSessionEvents()`` must end when the session does, whether or
        // not this close has anything to journal.
        finishSessionEventSubscriptions()

        let terminalEvents = await mailbox.sweep()
        guard !terminalEvents.isEmpty else { return }
        await recordSessionMetaIfNeeded()
        for event in terminalEvents {
            let entry = Transcript.Entry.toolOutput(
                Transcript.ToolOutput(
                    id: event.correlationID,
                    toolName: event.tool,
                    segments: [.custom(OperationEventSegment(content: event))]
                )
            )
            let (kind, payload, text) = TranscriptEntryMapper.event(from: entry)
            await append(partial: makePartialEvent(kind: kind, text: text, entry: payload))
        }
    }
}
