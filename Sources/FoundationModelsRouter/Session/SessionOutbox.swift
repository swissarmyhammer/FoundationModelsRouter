import FoundationModels

/// A staging area, owned per ``RoutedSession``, for everything that wants to
/// enter the conversation at a future turn boundary — tool events posted by
/// long-running work, and queued user prompts.
///
/// This is deliberately **not** a queue of `Transcript.Entry`: entries are the
/// durable record of turns the model has already run; this outbox holds only
/// *prompt-side material* that becomes an entry by being sent, at the next
/// turn boundary. Two independent kinds are staged here, never mixed:
///
/// - **Turn-riding events** (``PendingEvent``) — ``OperationEvent``s posted
///   through this actor's ``OperationEventSink`` conformance (the ambient
///   ``ToolContext`` route both per-call binding layers — ``DetachingTool``
///   and ``ContextBindingTool`` — post through). They fold into whichever
///   prompt
///   dispatches next: ``RoutedSessionActor``'s turn chokepoint drains them
///   into a plain-text preamble the model reads and persists each as an
///   ``OperationEventSegment`` on the turn's recorded `.prompt` entry (see
///   ``OperationEventSegment/renderedLine(for:)``). Coalescing policy: only
///   ``OperationEventKind/progress`` coalesces — to the single latest
///   pending one per `(tool, correlationID)`, replacing in place so the
///   coalesced item keeps the stable id it was first assigned. Every
///   ``OperationEventKind/completed`` and every
///   ``OperationEventKind/elicitation`` event is kept, in post order — each
///   elicitation is its own question, never a newer revision of an older
///   one. Independently of all that staging, every posted event is also
///   recorded in the session's transcript as it arrives, through the
///   ``OperationEventJournal`` ``attach(journal:)`` installs — see
///   ``post(_:)`` for why the transcript keeps what the prompt coalesces
///   away.
/// - **Turn-starting prompts** (``PendingPrompt``) — full `Transcript.Prompt`s
///   (queued user messages), never coalesced, dispatched strictly in enqueue
///   order, one turn each. This actor owns the storage, kinds, ids, and the
///   ``cancel(id:)``/``replace(id:prompt:)`` mutation primitives (both
///   racing ``drainForDispatch()``'s commit boundary safely — see
///   ``PromptQueueMutationResult``); the friendlier ``RoutedSession`` surface
///   a caller actually drives (a `String` convenience over ``enqueue(prompt:)``,
///   a `(id, prompt)`-tuple snapshot, and ``RoutedSession/dispatchNextPrompt()``
///   driver dispatch) lives on ``RoutedSession``/``RoutedSessionActor``
///   instead, forwarding here.
///
/// Every item — of either kind — is assigned a stable ``ItemID`` at enqueue,
/// so a caller (a UI, a driver loop) can track one across ``pending()``
/// snapshots even as it coalesces or waits to be drained.
///
/// ``drainForDispatch()`` is the commit boundary: it hands back everything
/// currently pending (every event, plus at most the one next-in-line prompt)
/// and atomically empties exactly what it returned — the drain and any
/// concurrent ``post(_:)``/``enqueue(prompt:)`` never interleave, because this
/// is an actor. Meant to be called from inside the session's serial-gated
/// chokepoint, so drains never race a concurrent turn.
///
/// ``nextEvent()`` is the driver-wakeup surface: it suspends while the outbox
/// is empty (no pending events, no pending prompts) and resumes as soon as
/// either kind gains an item, so an idle app loop can `await` it instead of
/// polling ``pending()`` in a spin loop.
///
/// **Non-goal (recorded):** durable on-disk persistence of the outbox itself.
/// Queued prompts are plain SDK `Transcript.Prompt` values and posted events
/// are `Codable`, so both are round-trippable through the same
/// `TranscriptEntryMapper`/`CustomSegmentRegistry` machinery the recorder
/// already uses — a natural later extension, not built here.
///
/// **Audience (task ^j0pp9yp).** The public surface of this actor is its
/// vocabulary — ``ItemID``, ``PromptQueueMutationResult``, and
/// ``QueueDepth`` — plus the ``OperationEventSink`` conformance the
/// binding layers post through. The staging and queue mechanics are
/// internal: an app drives the queue through ``RoutedSession``'s typed
/// methods (`enqueue`, `pendingPrompts`, `cancel`, `replace`,
/// `promptQueueDepth`, `awaitQueuedWork`, `dispatchNextPrompt`) alone,
/// and a session never exposes its own outbox instance.
public actor SessionOutbox: OperationEventSink {
    /// A stable identifier assigned to a pending item at enqueue time.
    ///
    /// Distinct from any id the payload itself carries (e.g. `OperationEvent`
    /// has none; `Transcript.Prompt` has its own SDK-assigned `id`) — this is
    /// the outbox's own bookkeeping id, stable across a coalesced event's
    /// in-place updates so a caller tracking one across ``pending()``
    /// snapshots sees an update, not a delete-then-add.
    public struct ItemID: Hashable, Sendable, CustomStringConvertible {
        private let value: ULID

        fileprivate init() {
            self.value = ULID.generate()
        }

        public var description: String { value.description }
    }

    /// One pending turn-riding event, with the stable id it was assigned when
    /// it (or the coalesced predecessor it replaced) first entered the
    /// outbox.
    struct PendingEvent: Sendable {
        /// This item's stable id.
        let id: ItemID

        /// The posted event, or — for a coalesced `.progress` — the latest
        /// one posted for this `(tool, correlationID)`.
        let event: OperationEvent
    }

    /// One pending turn-starting queued prompt, with the stable id it was
    /// assigned at ``enqueue(prompt:)``.
    struct PendingPrompt: Sendable {
        /// This item's stable id.
        let id: ItemID

        /// The queued prompt.
        let prompt: Transcript.Prompt
    }

    /// A snapshot of everything currently pending, per kind, returned by
    /// ``pending()``.
    struct Pending: Sendable {
        /// Every pending turn-riding event, in outbox order.
        let events: [PendingEvent]

        /// Every pending turn-starting prompt, in enqueue (FIFO) order.
        let prompts: [PendingPrompt]
    }

    /// What ``drainForDispatch()`` hands to the injection task: every pending
    /// event (now committed and removed from the outbox), plus — when at
    /// least one was queued — the single next prompt in FIFO order.
    ///
    /// Internal like ``drainForDispatch()``, its only producer: it exists for
    /// the dispatch machinery alone, so it is not part of the outbox's public
    /// surface.
    internal struct Drained: Sendable {
        /// Every event that was pending at drain time, in outbox order. Empty
        /// when nothing was pending.
        let events: [PendingEvent]

        /// The next queued prompt in FIFO order, or `nil` when none was
        /// queued.
        let prompt: PendingPrompt?
    }

    /// Pending turn-riding events, in outbox order (post order, with
    /// `.progress` entries updated in place on coalescing).
    private var events: [PendingEvent] = []

    /// Pending turn-starting prompts, in enqueue (FIFO) order.
    private var prompts: [PendingPrompt] = []

    /// The prompt ``drainForDispatch()`` last committed, for as long as its turn
    /// is still running — the queue's drained-but-not-finished slot.
    ///
    /// Filled by ``drainForDispatch()`` and emptied by ``finishDispatch()``, so
    /// ``queueDepth()`` can report the work a session still owes a turn *and*
    /// the work whose turn is already under way. Without it that second prompt
    /// is invisible: it has left ``prompts`` and no other surface names it.
    private var dispatched: PendingPrompt?

    /// Continuations parked by ``nextEvent()`` while the outbox is empty,
    /// resumed the next time either kind gains an item.
    private var wakeups: [CheckedContinuation<Void, Never>] = []

    /// Where every ``post(_:)`` also records its event as it arrives, or `nil`
    /// until ``attach(journal:)`` installs one — see ``OperationEventJournal``
    /// for why this reference is weak.
    private weak var journal: (any OperationEventJournal)?

    /// Where every ``post(invocation:)`` forwards its record, or `nil` until
    /// ``attach(invocationObserver:)`` installs one — weak for the same
    /// reference-cycle reason ``journal`` is.
    private weak var invocationObserver: (any ToolInvocationObserver)?

    /// The FIFO chain every journal write is enqueued onto — see
    /// ``enqueueJournalWrite(event:)``.
    private var journalChain = SerialAsyncChain()

    /// Creates an empty outbox — internal, because only session construction
    /// (vend, fork, restore) mints one; see the audience note above.
    init() {}

    /// Posts one ``OperationEvent`` — the ``OperationEventSink`` conformance
    /// the session's tool-side event route posts through.
    ///
    /// Two things happen to every posted event, and they are independent: it
    /// is staged for the next prompt under ``stage(event:)``'s coalescing policy,
    /// and it is recorded in this session's transcript through the attached
    /// ``OperationEventJournal`` — so a run that finishes long after its own
    /// turn ended has a recorded outcome the moment it reports one, instead
    /// of only once some later prompt drains it.
    ///
    /// Coalescing is a *prompt-composition* policy, and it applies only to
    /// what is still pending. The ``journal`` sees every posted event,
    /// uncoalesced, in post order: the transcript is the record of what the
    /// run reported, so dropping a superseded `.progress` there would delete
    /// history rather than shorten a prompt. Both statements stay true at
    /// once — the transcript holds every progress report, and the next prompt
    /// carries only the latest one per run — and neither ever rewrites what
    /// has already been appended.
    ///
    /// - Parameter event: The event to post.
    public func post(_ event: OperationEvent) async {
        // Enqueued before the staging decision and before any suspension, so
        // the journal's order is exactly this outbox's post order.
        let journalWrite = enqueueJournalWrite(event: event)
        stage(event: event)
        wakeUp()
        await journalWrite?.value
    }

    /// Records one event in the session's transcript without staging it for a
    /// future prompt.
    ///
    /// ``RoutedSessionActor/close()``'s route in. A terminal the mailbox sweep
    /// synthesized at teardown is a report that must be recorded, but there is
    /// no next turn for it to ride, so staging it would leave an item pending
    /// on an outbox nothing will ever drain.
    ///
    /// It reaches the journal through this outbox rather than the session
    /// directly so it takes its place on the one ``journalChain`` every other
    /// journal write is ordered by. Position in the transcript is the record:
    /// appending a teardown terminal outside that chain lets it land ahead of
    /// an earlier posted event still draining on it, which would state that a
    /// run ended before it reported the progress it reported first.
    ///
    /// - Parameter event: The event to record.
    internal func journalWithoutStaging(event: OperationEvent) async {
        await enqueueJournalWrite(event: event)?.value
    }

    /// Restages an event a turn drained but never delivered, without
    /// journaling it a second time.
    ///
    /// ``RoutedSessionActor/requeueUnattachedPendingEvents(events:)`` reaches here
    /// rather than ``post(_:)`` because a re-stage is not a new report: the
    /// run reported once, the journal already recorded that one report at the
    /// moment it happened, and recording it again would claim the run
    /// reported twice. An event that was never journaled at all — one posted
    /// before this outbox had a journal — is likewise unaffected, and still
    /// reaches the transcript on the turn it eventually rides.
    ///
    /// - Parameter event: The event to restage, under the same coalescing
    ///   policy ``post(_:)`` applies.
    internal func requeue(event: OperationEvent) {
        stage(event: event)
        wakeUp()
    }

    /// Stages one event as pending, applying this outbox's coalescing policy.
    ///
    /// A `.completed` or `.elicitation` event is always appended, never
    /// coalesced — each elicitation is its own question, so a newer one never
    /// replaces an older still-pending one. Only `.progress` coalesces: a
    /// `.progress` event replaces the latest still-pending `.progress` event
    /// for the same `(tool, correlationID)` in place (keeping that pending
    /// item's original id and position), or is appended as a new pending item
    /// when none is pending yet for that pair.
    ///
    /// - Parameter event: The event to stage.
    private func stage(event: OperationEvent) {
        switch event.kind {
        case .completed, .elicitation:
            appendNewPendingEvent(event: event)
        case .progress:
            if let index = events.firstIndex(where: {
                $0.event.kind == .progress && $0.event.tool == event.tool
                    && $0.event.correlationID == event.correlationID
            }) {
                events[index] = PendingEvent(id: events[index].id, event: event)
            } else {
                appendNewPendingEvent(event: event)
            }
        }
    }

    /// Installs `journal` as the destination every subsequently posted event
    /// is recorded into.
    ///
    /// Called from ``RoutedSessionActor/attachOutboxJournalIfNeeded()`` at the
    /// top of every turn, which is the earliest moment the owning session
    /// exists *and* a tool of its own could post: a tool only ever runs inside
    /// a turn, so no run's own event can be posted before its journal is in
    /// place. Events staged before then — the `.lost` terminals a restore
    /// manufactures onto a fresh outbox — deliberately keep the behavior they
    /// have always had, reaching the transcript on the turn that drains them.
    ///
    /// - Parameter journal: The journal to install.
    internal func attach(journal: any OperationEventJournal) {
        self.journal = journal
    }

    /// Installs `invocationObserver` as the live destination every
    /// subsequently posted ``ToolInvocationRecord`` is forwarded to.
    ///
    /// Called from ``RoutedSessionActor/attachOutboxJournalIfNeeded()``,
    /// beside ``attach(journal:)`` — the same top-of-turn attach point, for
    /// the same reason: a tool only ever runs inside a turn, so no run's own
    /// record can be posted before its observer is in place.
    ///
    /// - Parameter invocationObserver: The observer to install.
    internal func attach(invocationObserver: any ToolInvocationObserver) {
        self.invocationObserver = invocationObserver
    }

    /// Posts one ``ToolInvocationRecord`` — the ``OperationEventSink``
    /// invocation route the per-call binding layers post through.
    ///
    /// Delivery-only, and deliberately nothing like ``post(_:)``: the record
    /// is forwarded to the attached ``ToolInvocationObserver`` for live
    /// ``SessionEvent/toolInvocation(_:)`` delivery, and to nothing else. It
    /// is never staged as a pending item and never journaled, so the
    /// post-turn diff stays the one authority for what is recorded. Before an
    /// observer is attached — no turn has ever begun, so no tool of this
    /// session's own can be running — the record is dropped.
    ///
    /// - Parameter record: The record to forward.
    public func post(invocation record: ToolInvocationRecord) async {
        await invocationObserver?.deliver(invocation: record)
    }

    /// Chains one journal write onto ``journalChain`` and returns it for the
    /// caller to await.
    ///
    /// The chain is what makes the transcript's order of journaled events
    /// exactly this outbox's post order. Awaiting the journal inline instead
    /// would suspend ``post(_:)`` on this actor, letting a concurrent post of
    /// another run overtake it, and position in the transcript is the record.
    ///
    /// - Parameter event: The event to record.
    /// - Returns: The chained write, or `nil` when no journal is attached —
    ///   the pre-first-turn case, which stays exactly as costly as it was
    ///   before a journal existed.
    private func enqueueJournalWrite(event: OperationEvent) -> Task<Void, Never>? {
        guard let journal else { return nil }
        return journalChain.enqueue { await journal.record(event: event) }
    }

    /// Appends `event` onto ``events`` as a brand-new pending item with a
    /// fresh ``ItemID`` — shared by every ``post(_:)`` branch that adds a
    /// pending event rather than coalescing into an existing one (a
    /// `.completed` or `.elicitation` event, always appended; a `.progress`
    /// event with no still-pending entry for its `(tool, correlationID)`
    /// yet).
    ///
    /// - Parameter event: The event to append as a new pending item.
    private func appendNewPendingEvent(event: OperationEvent) {
        events.append(PendingEvent(id: ItemID(), event: event))
    }

    /// Stages a queued user prompt for a future turn.
    ///
    /// Never coalesced: every call appends a new pending item with its own
    /// distinct id, in FIFO order.
    ///
    /// - Parameter prompt: The prompt to stage.
    /// - Returns: The stable id assigned to this queued prompt.
    @discardableResult
    func enqueue(prompt: Transcript.Prompt) -> ItemID {
        let id = ItemID()
        prompts.append(PendingPrompt(id: id, prompt: prompt))
        wakeUp()
        return id
    }

    /// The outcome of ``cancel(id:)`` or ``replace(id:prompt:)`` against a
    /// queued prompt's stable id.
    public enum PromptQueueMutationResult: Sendable, Equatable {
        /// The prompt was still pending in the queue and the mutation
        /// applied.
        case applied

        /// No pending prompt with this id exists: ``drainForDispatch()``
        /// already committed it (its turn is underway or already recorded),
        /// or the id never named a queued prompt at all. The mutation was
        /// not — and cannot be — applied.
        case alreadySent
    }

    /// Cancels a still-pending queued prompt by its stable id.
    ///
    /// Races ``drainForDispatch()``'s commit boundary safely: once an id's
    /// prompt has been drained, its turn is already underway (or already
    /// recorded), so cancelling that id is a no-op reporting
    /// ``PromptQueueMutationResult/alreadySent`` rather than mutating a turn
    /// out from under it. Being an actor method, this never interleaves with
    /// a concurrent ``drainForDispatch()``/``post(_:)``/``enqueue(prompt:)``.
    ///
    /// - Parameter id: The id ``enqueue(prompt:)`` returned for the prompt to
    ///   cancel.
    /// - Returns: ``PromptQueueMutationResult/applied`` if the prompt was
    ///   still pending and was removed; ``PromptQueueMutationResult/alreadySent``
    ///   otherwise.
    @discardableResult
    func cancel(id: ItemID) -> PromptQueueMutationResult {
        mutatingPendingPrompt(id: id) { index in
            prompts.remove(at: index)
        }
    }

    /// Replaces a still-pending queued prompt's content by its stable id, in
    /// place — preserving its FIFO position.
    ///
    /// Same commit-boundary race as ``cancel(id:)``: an id already drained by
    /// ``drainForDispatch()`` reports ``PromptQueueMutationResult/alreadySent``
    /// rather than mutating the drained (in-flight or already-recorded) turn.
    ///
    /// - Parameters:
    ///   - id: The id ``enqueue(prompt:)`` returned for the prompt to
    ///     replace.
    ///   - prompt: The prompt's new content.
    /// - Returns: ``PromptQueueMutationResult/applied`` if the prompt was
    ///   still pending and was updated; ``PromptQueueMutationResult/alreadySent``
    ///   otherwise.
    @discardableResult
    func replace(id: ItemID, prompt: Transcript.Prompt) -> PromptQueueMutationResult {
        mutatingPendingPrompt(id: id) { index in
            prompts[index] = PendingPrompt(id: id, prompt: prompt)
        }
    }

    /// Finds `id`'s still-pending queued prompt by index and, if found, runs
    /// `mutate` on it — the find-or-report-already-sent pattern ``cancel(id:)``
    /// and ``replace(id:prompt:)`` both need, differing only in what they do
    /// once the index is in hand (remove vs. overwrite). Shared here so that
    /// lookup — and its ``PromptQueueMutationResult/alreadySent`` commit-boundary
    /// race handling — lives in exactly one place.
    ///
    /// - Parameters:
    ///   - id: The id ``enqueue(prompt:)`` returned for the prompt to mutate.
    ///   - mutate: Applied to `prompts` with the found index, once `id` is
    ///     confirmed still pending.
    /// - Returns: ``PromptQueueMutationResult/applied`` if `id` was still
    ///   pending (and `mutate` ran); ``PromptQueueMutationResult/alreadySent``
    ///   otherwise.
    private func mutatingPendingPrompt(
        id: ItemID, _ mutate: (Int) -> Void
    ) -> PromptQueueMutationResult {
        guard let index = prompts.firstIndex(where: { $0.id == id }) else {
            return .alreadySent
        }
        mutate(index)
        return .applied
    }

    /// A snapshot of everything currently pending, per kind.
    ///
    /// - Returns: The current ``Pending`` snapshot.
    func pending() -> Pending {
        Pending(events: events, prompts: prompts)
    }

    /// Drains every pending event without touching the queued-prompt FIFO —
    /// the commit boundary for a turn whose own prompt comes directly from
    /// its caller (``RoutedSession/respond(to:maxTokens:)``,
    /// ``RoutedSession/streamResponse(to:maxTokens:)``), as opposed to
    /// ``drainForDispatch()``'s prompt-inclusive drain, which only
    /// ``RoutedSession/dispatchNextPrompt()`` uses.
    ///
    /// Keeping these two drains separate is what makes a direct
    /// `respond`/`streamResponse` turn safe to run alongside a queue a
    /// driver hasn't dispatched yet: it never incidentally dequeues (and
    /// silently drops) the next queued prompt just because one happens to be
    /// waiting when an unrelated ad hoc turn starts.
    ///
    /// Meant to be called from inside the session's serial-gated chokepoint,
    /// exactly like ``drainForDispatch()`` — atomic, and never interleaves
    /// with a concurrent ``post(_:)``/``enqueue(prompt:)`` from a background
    /// tool.
    ///
    /// - Returns: Every event pending at the moment of the call, now
    ///   committed and no longer reported by ``pending()``. Any prompt
    ///   waiting in the queue is left exactly where it is.
    func drainPendingEvents() -> [PendingEvent] {
        let drainedEvents = events
        events = []
        return drainedEvents
    }

    /// Drains every pending event and, when at least one is queued, the next
    /// pending prompt — atomically committing (removing) exactly what is
    /// returned.
    ///
    /// Called only from inside the session's serial-gated chokepoint,
    /// so a drain never races a concurrent turn; being an actor method, it
    /// also never interleaves with a concurrent ``post(_:)``/
    /// ``enqueue(prompt:)`` from a background tool.
    ///
    /// **The contract that binds a drain to a turn.** Every drain happens
    /// inside ``RoutedSession/dispatchNextPrompt()``'s turn bracket — after
    /// ``RoutedSessionActor/beginTurn()`` and before its matching
    /// ``RoutedSessionActor/endTurn()`` — and is released by exactly one
    /// ``finishDispatch()`` on every exit that bracket has. `internal`,
    /// symmetric with ``finishDispatch()``, deliberately: were this public
    /// while its releasing partner is not, an external caller could drain a
    /// prompt with no turn in flight and strand it — gone from ``pending()``
    /// so ``cancel(id:)`` reports already-sent, owned by no turn so
    /// ``RoutedSession/cancelCurrentTurn()`` reports nothing in flight, and
    /// counted by ``queueDepth()`` forever with no way to release the slot.
    /// Keeping the pair internal is what makes that drained-but-not-started
    /// state unreachable from outside the package.
    ///
    /// - Returns: Every event pending at the moment of the call, plus the
    ///   next queued prompt (or `nil` if none was queued) — both now
    ///   committed and no longer reported by ``pending()`` but, for the
    ///   prompt, still reported by ``queueDepth()`` until
    ///   ``finishDispatch()``.
    internal func drainForDispatch() -> Drained {
        let drainedEvents = events
        events = []
        let drainedPrompt = prompts.isEmpty ? nil : prompts.removeFirst()
        dispatched = drainedPrompt
        return Drained(events: drainedEvents, prompt: drainedPrompt)
    }

    /// Empties the drained-but-not-finished slot ``drainForDispatch()`` filled.
    ///
    /// Called by ``RoutedSession/dispatchNextPrompt()`` on every exit its turn
    /// has — returned response, thrown error, cancellation — so a prompt is
    /// counted by ``queueDepth()`` for exactly as long as this session still
    /// owes it a turn, and never after. `internal`, symmetric with
    /// ``drainForDispatch()`` — see the drain-to-turn contract stated there.
    internal func finishDispatch() {
        dispatched = nil
    }

    /// How much queued user-prompt work a session is carrying, counting the
    /// prompt whose turn is already running.
    ///
    /// ``pending()`` reports only what is still waiting; between
    /// ``drainForDispatch()`` and ``finishDispatch()`` a prompt is in neither
    /// place, and this is what names it there.
    public struct QueueDepth: Sendable, Equatable {
        /// How many prompts are still waiting in the queue.
        public let queued: Int

        /// The prompt ``drainForDispatch()`` committed whose turn has not
        /// finished, or `nil` when no dispatched prompt is outstanding.
        public let dispatched: ItemID?

        /// Every prompt this session still owes a turn, waiting and dispatched
        /// together.
        public var total: Int { queued + (dispatched == nil ? 0 : 1) }

        /// Creates a queue-depth snapshot.
        ///
        /// - Parameters:
        ///   - queued: How many prompts are still waiting in the queue.
        ///   - dispatched: The dispatched prompt's id, or `nil` when none is
        ///     outstanding.
        public init(queued: Int, dispatched: ItemID?) {
            self.queued = queued
            self.dispatched = dispatched
        }
    }

    /// A snapshot of this outbox's prompt-queue depth, including the prompt
    /// whose turn is already running.
    ///
    /// - Returns: The current ``QueueDepth``.
    func queueDepth() -> QueueDepth {
        QueueDepth(queued: prompts.count, dispatched: dispatched?.id)
    }

    /// Suspends while the outbox is empty (no pending events, no pending
    /// prompts), resuming as soon as either kind gains an item — the
    /// driver-wakeup surface an idle app loop awaits instead of polling
    /// ``pending()`` in a spin loop.
    ///
    /// Returns immediately if the outbox is already non-empty at the time of
    /// the call.
    func nextEvent() async {
        guard events.isEmpty, prompts.isEmpty else { return }
        await withCheckedContinuation { continuation in
            wakeups.append(continuation)
        }
    }

    /// Resumes every continuation parked by ``nextEvent()``, called after any
    /// mutation that adds an item to either ``events`` or ``prompts``.
    private func wakeUp() {
        guard !wakeups.isEmpty else { return }
        let parked = wakeups
        wakeups = []
        for continuation in parked {
            continuation.resume()
        }
    }
}
