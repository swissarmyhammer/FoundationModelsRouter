import FoundationModels

/// ``RoutedSessionActor``'s run journal: how one long-running operation's own
/// reports — progress, elicitation, completion — become transcript entries
/// at the moment they are made, rather than only when some later turn folds
/// them into its prompt.
///
/// Router exists so a long tool does not block the session, and
/// ``DetachingTool`` delivers that by backgrounding a run and handing the model
/// `{"pending":true,"completionToken":…}`. Until this journal existed, the
/// background run's ending had no way back into the record: it waited in
/// ``outbox`` for a prompt that might never come, so a transcript could show
/// a run starting and never show it finishing. This closes that hole, and
/// closes it in the transcript rather than in a channel beside it.
extension RoutedSessionActor: OperationEventJournal {
    /// Records one posted ``OperationEvent`` as its own recorded entry.
    ///
    /// Called by ``SessionOutbox/post(event:)`` for every event it accepts, in
    /// post order, so the transcript gains the run's report when the run made
    /// it — no further prompt required.
    ///
    /// **Interleaving is the point, not a defect.** A background run reports
    /// whenever its work reaches a milestone, so its entries land between the
    /// entries of whatever turn happened to be running, and a run's own
    /// entries need not be contiguous. Position in the transcript states when
    /// something happened; buffering these to keep one run's entries together
    /// would falsify that order to flatter a renderer. A view that wants them
    /// grouped groups by the parent id every one of them carries.
    ///
    /// - Parameter event: The event the outbox has just accepted.
    func record(event: OperationEvent) async {
        guard claimJournalWrite(for: event) else { return }
        await recordSessionMetaIfNeeded()
        await append(partial: makeRunEventPartial(for: event))
    }

    /// Whether `event` may be journaled, claiming a run's one recorded ending
    /// when it is a terminal.
    ///
    /// **Two writers, one ending.** A run's ending reaches this journal by two
    /// independent routes, and both can fire for the same run:
    ///
    /// 1. The run settles on its own and ``RunEventFunnel`` posts its terminal
    ///    through ``SessionOutbox/post(event:)``, which journals it live.
    /// 2. ``close()`` sweeps the mailbox and journals what
    ///    ``SessionMailbox/sweep()`` hands back.
    ///
    /// They collide two ways. `sweep()` awaits each run's canceler, which
    /// suspends the mailbox actor; a run that settles naturally inside that
    /// window journals its own terminal through route 1, and the sweep then
    /// returns that same retained event through route 2. And because
    /// cancelling a ``SessionMailbox/RunKind/swiftTask`` run is only
    /// *cooperative*, a run whose terminal the sweep already synthesized can
    /// still finish afterwards and post its own — with a **different
    /// outcome**, so the transcript would hold two contradictory endings for
    /// one call and a parent-grouping view would draw both.
    /// ``RunEventFunnel``'s own single-terminal guard cannot help: it sees only
    /// what one run posts, never what the sweep synthesized beside it.
    ///
    /// First write wins, and nothing already appended is ever rewritten or
    /// removed. The record is append-only, so hiding a contradiction by
    /// editing history would be worse than the contradiction; refusing the
    /// second write is the only resolution that keeps the log truthful.
    ///
    /// Only `.completed` is claimed, because only `.completed` is terminal
    /// (see ``OperationEventKind``). Progress and elicitation events are a
    /// run's running commentary — many per run, by design — so they are always
    /// admitted.
    ///
    /// The claim is taken synchronously, before this method returns and so
    /// before any suspension, which is what makes it safe against the two
    /// routes racing on this actor.
    ///
    /// The claimed set grows by one token per run that ever reported an
    /// ending, and is deliberately unbounded: the transcript it guards already
    /// holds at least one entry per such run, so the guard is strictly smaller
    /// than the record it protects, and bounding it would trade the guarantee
    /// away for no measurable saving.
    ///
    /// - Parameter event: The event about to be journaled.
    /// - Returns: `false` when `event` is a terminal for a run whose ending is
    ///   already recorded; `true` otherwise.
    func claimJournalWrite(for event: OperationEvent) -> Bool {
        guard event.kind == .completed else { return true }
        return journaledTerminalCorrelationIDs.insert(event.correlationID).inserted
    }

    /// Builds the recorded partial one ``OperationEvent`` is journaled as: a
    /// `.toolOutput`-kind event whose entry is a real
    /// `Transcript.Entry.toolOutput` carrying the event as a typed
    /// ``OperationEventSegment``.
    ///
    /// **Why `.toolOutput`, and not a router-only entry kind.** A renderer
    /// already draws a tool's output grouped under the call it answers, so a
    /// detached run's report drawn this way needs no special case at all. A
    /// kind of its own would need one everywhere, and would be worse than
    /// cosmetic: ``TranscriptEvent/Kind``'s two router-only kinds
    /// (``TranscriptEvent/Kind/session``, ``TranscriptEvent/Kind/embedding``)
    /// are rejected by ``TranscriptEntryMapper/entry(from:kind:)``,
    /// so a third would journal but never rebuild — a parallel layer wearing
    /// a transcript's clothes, which is the shape this design exists to
    /// avoid. The entry has no paired `.toolCalls`, exactly as
    /// ``close()``'s swept terminals do not: the run was detached, not
    /// model-invoked at this instant.
    ///
    /// **Identity and parent reference are two different things, in two
    /// different places.** The entry's `id` is the entry's *own* identity, and
    /// nothing else: Apple documents `Transcript.ToolOutput.id` as "A unique
    /// id for this tool output", so a fresh ULID is minted per entry. The
    /// *parent* reference — the `completionToken` ``DetachingTool`` handed the
    /// model, which ``ToolContext`` stamps as the same run's `correlationID`
    /// — travels in the typed payload, where the whole ``OperationEvent``
    /// already carries it. A view groups a run's entries by that
    /// `correlationID`.
    ///
    /// Writing the token into the `id` instead would put one identity space's
    /// value into a field that names another's — the ``SessionEvent`` trap
    /// this design already refuses elsewhere, one field over. It is also what
    /// made the id unusable *as* an identity: every report of one run would
    /// share the entry id of every other, so a lifecycle of many entries would
    /// be indistinguishable from one entry appended repeatedly.
    ///
    /// A model-invoked `.toolOutput`'s id does arrive equal to the id of the
    /// call it answers, but that is the SDK's own undocumented and unenforced
    /// behaviour, and this router does not rely on it anywhere — see
    /// ``ToolCallOutputPairing/completedToolCallId(forOutputEntryId:dispatched:completed:)``,
    /// which resolves a completion's call id from the calls the same diff
    /// announced rather than from the entry.
    ///
    /// **Nothing is mutated.** Every report of a run — each progress update,
    /// each elicitation, the one terminal — is appended as its own entry, with
    /// its own id, carrying that same parent reference. A lifecycle is many
    /// entries, never one entry rewritten, which is what keeps the record
    /// replayable and diffable.
    ///
    /// **The body text.** The entry's only segment is the typed one, so the
    /// mapper's own flattening has nothing to flatten and would leave the
    /// recorded event bodyless — a client rendering the transcript would draw
    /// an empty tool output. The body is therefore stated directly as
    /// ``OperationEventSegment/renderedLine(for:)``, the same string the
    /// segment's own `description` carries and the same line a drained event
    /// contributes to a turn's preamble, so no two textual views of one
    /// report can drift.
    ///
    /// - Parameter event: The event to journal.
    /// - Returns: The partial for the recorder to stamp and append.
    func makeRunEventPartial(for event: OperationEvent) -> TranscriptEvent.Partial {
        let entry = Transcript.Entry.toolOutput(
            Transcript.ToolOutput(
                id: ULID.generate().description,
                toolName: event.tool,
                segments: [OperationEventSegment(content: event).transcriptSegment]
            )
        )
        let (kind, payload, _) = TranscriptEntryMapper.event(from: entry)
        return makePartialEvent(
            kind: kind, text: OperationEventSegment.renderedLine(for: event), entry: payload)
    }

    /// Installs this session as ``outbox``'s ``OperationEventJournal``, once.
    ///
    /// Called from ``beginTurn()``, which is both late enough that this
    /// session exists and early enough that no tool of its own can have run:
    /// a tool is only ever invoked from inside a turn's model call, so every
    /// event a run of this session posts is journaled. Idempotent, so the
    /// second and every later turn costs one flag read.
    func attachOutboxJournalIfNeeded() async {
        guard !didAttachOutboxJournal else { return }
        didAttachOutboxJournal = true
        await outbox.attach(journal: self)
        await outbox.attach(invocationObserver: self)
    }
}

/// ``RoutedSessionActor``'s live invocation delivery: how a per-call binding
/// layer's ``ToolInvocationRecord`` becomes a
/// ``SessionEvent/toolInvocation(_:)`` on the current turn's stream the moment
/// it is posted — during the turn, not after it (task ^zfd8e69).
///
/// Delivery-only, the deliberate opposite of the ``OperationEventJournal``
/// conformance above: a record is never staged and never journaled, so the
/// post-turn diff stays the one authority for what is recorded.
extension RoutedSessionActor: ToolInvocationObserver {
    /// Delivers one live ``ToolInvocationRecord`` as
    /// ``SessionEvent/toolInvocation(_:)``.
    ///
    /// During a turn the record goes through ``currentTurnEventSink`` — the
    /// turn's composed sink, which reaches the turn's own stream and every
    /// session-scoped subscription. Between turns — a detached run's late
    /// close, self-attributed by the record's `correlationID` — it reaches
    /// the session-scoped feed alone.
    ///
    /// - Parameter record: The record the outbox forwarded.
    func deliver(invocation record: ToolInvocationRecord) {
        let event = SessionEvent.toolInvocation(record)
        if let currentTurnEventSink {
            currentTurnEventSink(event)
        } else {
            emitSessionScopedEvent(event)
        }
    }
}
