import FoundationModels

/// ``RoutedSessionActor``'s run journal: how one long-running operation's own
/// reports — progress, elicitation, completion — become transcript entries
/// at the moment they are made, rather than only when some later turn folds
/// them into its prompt.
///
/// Router exists so a long tool does not block the session, and
/// ``DetachingTool`` delivers that by parking a run and handing the model
/// `{"pending":true,"completionToken":…}`. Until this journal existed, the
/// parked run's ending had no way back into the record: it waited in
/// ``outbox`` for a prompt that might never come, so a transcript could show
/// a run starting and never show it finishing. This closes that hole, and
/// closes it in the transcript rather than in a channel beside it.
extension RoutedSessionActor: OperationEventJournal {
    /// Records one posted ``OperationEvent`` as its own recorded entry.
    ///
    /// Called by ``SessionOutbox/post(_:)`` for every event it accepts, in
    /// post order, so the transcript gains the run's report when the run made
    /// it — no further prompt required.
    ///
    /// **Interleaving is the point, not a defect.** A parked run reports
    /// whenever its work reaches a milestone, so its entries land between the
    /// entries of whatever turn happened to be running, and a run's own
    /// entries need not be contiguous. Position in the transcript states when
    /// something happened; buffering these to keep one run's entries together
    /// would falsify that order to flatter a renderer. A view that wants them
    /// grouped groups by the parent id every one of them carries.
    ///
    /// - Parameter event: The event the outbox has just accepted.
    func record(_ event: OperationEvent) async {
        await recordSessionMetaIfNeeded()
        await append(partial: makeRunEventPartial(for: event))
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
    /// are rejected by ``TranscriptEntryMapper/entry(from:kind:registry:)``,
    /// so a third would journal but never rebuild — a parallel layer wearing
    /// a transcript's clothes, which is the shape this design exists to
    /// avoid. The entry has no paired `.toolCalls`, exactly as
    /// ``close()``'s swept terminals do not: the run was detached, not
    /// model-invoked at this instant.
    ///
    /// **Parent identity.** The entry's id is the event's `correlationID`,
    /// which for every run this router parks *is* the `completionToken`
    /// ``DetachingTool`` handed the model (``ToolContext`` stamps the two
    /// from one value). Apple's own convention for a `Transcript.ToolOutput`
    /// is that its `id` names the call it answers, so the transcript's parent
    /// reference and the model's own reference are one identity space rather
    /// than two — the distinction that makes a completion attributable
    /// instead of merely present.
    ///
    /// **Nothing is mutated.** Every report of a run — each progress update,
    /// each elicitation, the one terminal — is appended as its own entry
    /// carrying that same parent id. A lifecycle is many entries, never one
    /// entry rewritten, which is what keeps the record replayable and
    /// diffable.
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
                id: event.correlationID,
                toolName: event.tool,
                segments: [.custom(OperationEventSegment(content: event))]
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
    }
}
