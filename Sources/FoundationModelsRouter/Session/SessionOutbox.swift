import FoundationModels
import Operations

/// A staging area, owned per ``RoutedSession``, for everything that wants to
/// enter the conversation at a future turn boundary — tool events posted by
/// long-running work, and queued user prompts.
///
/// This is deliberately **not** a queue of `Transcript.Entry`: entries are the
/// durable record of turns the model has already run; this outbox holds only
/// *prompt-side material* that becomes an entry by being sent, at the next
/// turn boundary. Two independent kinds are staged here, never mixed:
///
/// - **Turn-riding events** (``PendingEvent``) — ``OperationEvent``s posted by
///   a connected ``EventEmittingTool`` through this actor's
///   ``OperationEventSink`` conformance. They fold into whichever prompt
///   dispatches next: ``RoutedSessionActor``'s turn chokepoint drains them
///   into a plain-text preamble the model reads and persists each as an
///   ``OperationEventSegment`` on the turn's recorded `.prompt` entry (see
///   ``OperationEventSegment/renderedLine(for:)``). Coalescing policy: every
///   ``OperationEventKind/completed`` event is kept, in post order;
///   ``OperationEventKind/progress`` events coalesce to the single latest
///   pending one per `(tool, correlationID)`, replacing in place so the
///   coalesced item keeps the stable id it was first assigned.
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
    public struct PendingEvent: Sendable {
        /// This item's stable id.
        public let id: ItemID

        /// The posted event, or — for a coalesced `.progress` — the latest
        /// one posted for this `(tool, correlationID)`.
        public let event: OperationEvent
    }

    /// One pending turn-starting queued prompt, with the stable id it was
    /// assigned at ``enqueue(prompt:)``.
    public struct PendingPrompt: Sendable {
        /// This item's stable id.
        public let id: ItemID

        /// The queued prompt.
        public let prompt: Transcript.Prompt
    }

    /// A snapshot of everything currently pending, per kind, returned by
    /// ``pending()``.
    public struct Pending: Sendable {
        /// Every pending turn-riding event, in outbox order.
        public let events: [PendingEvent]

        /// Every pending turn-starting prompt, in enqueue (FIFO) order.
        public let prompts: [PendingPrompt]
    }

    /// What ``drainForDispatch()`` hands to the injection task: every pending
    /// event (now committed and removed from the outbox), plus — when at
    /// least one was queued — the single next prompt in FIFO order.
    public struct Drained: Sendable {
        /// Every event that was pending at drain time, in outbox order. Empty
        /// when nothing was pending.
        public let events: [PendingEvent]

        /// The next queued prompt in FIFO order, or `nil` when none was
        /// queued.
        public let prompt: PendingPrompt?
    }

    /// Pending turn-riding events, in outbox order (post order, with
    /// `.progress` entries updated in place on coalescing).
    private var events: [PendingEvent] = []

    /// Pending turn-starting prompts, in enqueue (FIFO) order.
    private var prompts: [PendingPrompt] = []

    /// Continuations parked by ``nextEvent()`` while the outbox is empty,
    /// resumed the next time either kind gains an item.
    private var wakeups: [CheckedContinuation<Void, Never>] = []

    /// Creates an empty outbox.
    public init() {}

    /// Posts one ``OperationEvent`` — the ``OperationEventSink`` conformance a
    /// connected ``EventEmittingTool`` posts through.
    ///
    /// A `.completed` event is always appended, never coalesced. A `.progress`
    /// event replaces the latest still-pending `.progress` event for the same
    /// `(tool, correlationID)` in place (keeping that pending item's original
    /// id and position), or is appended as a new pending item when none is
    /// pending yet for that pair.
    ///
    /// - Parameter event: The event to post.
    public func post(_ event: OperationEvent) async {
        switch event.kind {
        case .completed:
            appendNewPendingEvent(event)
        case .progress:
            if let index = events.firstIndex(where: {
                $0.event.kind == .progress && $0.event.tool == event.tool
                    && $0.event.correlationID == event.correlationID
            }) {
                events[index] = PendingEvent(id: events[index].id, event: event)
            } else {
                appendNewPendingEvent(event)
            }
        }
        wakeUp()
    }

    /// Appends `event` onto ``events`` as a brand-new pending item with a
    /// fresh ``ItemID`` — shared by both ``post(_:)`` branches that add a
    /// pending event rather than coalescing into an existing one (a
    /// `.completed` event, always appended; a `.progress` event with no
    /// still-pending entry for its `(tool, correlationID)` yet).
    ///
    /// - Parameter event: The event to append as a new pending item.
    private func appendNewPendingEvent(_ event: OperationEvent) {
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
    public func enqueue(prompt: Transcript.Prompt) -> ItemID {
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
    public func cancel(id: ItemID) -> PromptQueueMutationResult {
        guard let index = prompts.firstIndex(where: { $0.id == id }) else {
            return .alreadySent
        }
        prompts.remove(at: index)
        return .applied
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
    public func replace(id: ItemID, prompt: Transcript.Prompt) -> PromptQueueMutationResult {
        guard let index = prompts.firstIndex(where: { $0.id == id }) else {
            return .alreadySent
        }
        prompts[index] = PendingPrompt(id: id, prompt: prompt)
        return .applied
    }

    /// A snapshot of everything currently pending, per kind.
    ///
    /// - Returns: The current ``Pending`` snapshot.
    public func pending() -> Pending {
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
    public func drainPendingEvents() -> [PendingEvent] {
        let drainedEvents = events
        events = []
        return drainedEvents
    }

    /// Drains every pending event and, when at least one is queued, the next
    /// pending prompt — atomically committing (removing) exactly what is
    /// returned.
    ///
    /// Meant to be called from inside the session's serial-gated chokepoint,
    /// so a drain never races a concurrent turn; being an actor method, it
    /// also never interleaves with a concurrent ``post(_:)``/
    /// ``enqueue(prompt:)`` from a background tool.
    ///
    /// - Returns: Every event pending at the moment of the call, plus the
    ///   next queued prompt (or `nil` if none was queued) — both now
    ///   committed and no longer reported by ``pending()``.
    public func drainForDispatch() -> Drained {
        let drainedEvents = events
        events = []
        let drainedPrompt = prompts.isEmpty ? nil : prompts.removeFirst()
        return Drained(events: drainedEvents, prompt: drainedPrompt)
    }

    /// Suspends while the outbox is empty (no pending events, no pending
    /// prompts), resuming as soon as either kind gains an item — the
    /// driver-wakeup surface an idle app loop awaits instead of polling
    /// ``pending()`` in a spin loop.
    ///
    /// Returns immediately if the outbox is already non-empty at the time of
    /// the call.
    public func nextEvent() async {
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
