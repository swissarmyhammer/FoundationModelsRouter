import FoundationModels

/// A per-``RoutedSession`` staging area for material that enters the
/// conversation at a future turn boundary.
///
/// The outbox stages two kinds of item, never mixed:
///
/// - Turn-riding events (``PendingEvent``): ``OperationEvent``s posted through
///   the ``OperationEventSink`` conformance. The next turn drains them into its
///   prompt preamble. Only ``OperationEventKind/progress`` coalesces, to the
///   latest pending one per `(tool, correlationID)`, in place. Every posted
///   event is also recorded in the transcript through the attached
///   ``OperationEventJournal``, uncoalesced.
/// - Turn-starting prompts (``PendingPrompt``): queued `Transcript.Prompt`s,
///   never coalesced, dispatched in FIFO order, one turn each.
///
/// A queued prompt gets a stable ``PromptID`` and a staged event a stable
/// ``EventID``, both at enqueue. ``drainForDispatch()`` is the commit boundary.
/// ``nextEvent()`` suspends while the outbox is empty.
///
/// The actor itself is internal. The vocabulary its prompt queue speaks —
/// ``PromptID``, ``PromptQueueMutationResult`` and ``PromptQueueDepth`` — is
/// public and stands on its own, because ``RoutedSession``'s public methods
/// carry those three types in their signatures. An app drives the queue
/// through ``RoutedSession``'s methods; a session never exposes its outbox.
///
/// The outbox is also the session's ``ToolCallReportSink``: a tool decorator
/// finds it through a dynamic cast when a call closes with attachments, and
/// ``post(report:)`` forwards the report to the attached observer.
actor SessionOutbox: OperationEventSink, ToolCallReportSink {
    /// A stable identifier the outbox assigns to a staged event at post time.
    ///
    /// The id stays the same across a coalesced event's in-place updates.
    struct EventID: Hashable, Sendable {
        /// The generated value that carries this id's identity.
        ///
        /// Read by the synthesized `Hashable` conformance; periphery sees no caller.
        // periphery:ignore
        private let value: ULID

        /// Mints a fresh event id.
        fileprivate init() {
            self.value = ULID.generate()
        }
    }

    /// One pending turn-riding event with its stable id.
    struct PendingEvent: Sendable {
        /// This event's stable id.
        let id: EventID

        /// The posted event, or the latest coalesced `.progress` event.
        let event: OperationEvent
    }

    /// One pending queued prompt with its stable id.
    struct PendingPrompt: Sendable {
        /// This prompt's stable id.
        let id: PromptID

        /// The queued prompt.
        let prompt: Transcript.Prompt
    }

    /// A snapshot of everything currently pending, per kind.
    struct Pending: Sendable {
        /// Every pending turn-riding event, in outbox order.
        let events: [PendingEvent]

        /// Every pending turn-starting prompt, in enqueue (FIFO) order.
        let prompts: [PendingPrompt]
    }

    /// What ``drainForDispatch()`` returns: every pending event, plus the next
    /// queued prompt when one was queued.
    internal struct Drained: Sendable {
        /// Every event that was pending at drain time, in outbox order.
        let events: [PendingEvent]

        /// The next queued prompt, or `nil` when none was queued.
        let prompt: PendingPrompt?
    }

    /// Pending turn-riding events, in outbox order.
    private var events: [PendingEvent] = []

    /// Pending queued prompts, in FIFO order.
    private var prompts: [PendingPrompt] = []

    /// The prompt ``drainForDispatch()`` last committed, until ``finishDispatch()``.
    private var dispatched: PendingPrompt?

    /// Continuations suspended by ``nextEvent()`` while the outbox is empty.
    private var wakeups: [CheckedContinuation<Void, Never>] = []

    /// The journal every posted event is recorded into, or `nil` before
    /// ``attach(journal:)``. Weak to avoid a reference cycle.
    private weak var journal: (any OperationEventJournal)?

    /// The observer every posted invocation record and tool call report goes
    /// to, or `nil` before ``attach(invocationObserver:)``. Weak to avoid a
    /// reference cycle.
    private weak var invocationObserver: (any ToolInvocationObserver)?

    /// The FIFO chain every journal write is enqueued onto.
    private var journalChain = SerialAsyncChain()

    /// Creates an empty outbox. Only session construction calls this.
    init() {}

    /// Posts one ``OperationEvent``.
    ///
    /// The event is staged for the next prompt under the coalescing policy,
    /// and recorded uncoalesced in the attached journal, in post order.
    ///
    /// - Parameter event: The event to post.
    func post(event: OperationEvent) async {
        // Enqueued before the staging decision and before any suspension, so
        // the journal's order is exactly this outbox's post order.
        let journalWrite = enqueueJournalWrite(event: event)
        stage(event: event)
        wakeUp()
        await journalWrite?.value
    }

    /// Records one event in the journal without staging it for a future
    /// prompt. The write joins the same ordered ``journalChain``.
    ///
    /// - Parameter event: The event to record.
    internal func journalWithoutStaging(event: OperationEvent) async {
        await enqueueJournalWrite(event: event)?.value
    }

    /// Restages an event a turn drained but did not deliver, without a second
    /// journal write.
    ///
    /// - Parameter event: The event to restage.
    internal func requeue(event: OperationEvent) {
        stage(event: event)
        wakeUp()
    }

    /// Stages one event as pending under the coalescing policy.
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

    /// Installs the journal that records every event posted from now on.
    ///
    /// Events staged before this call reach the transcript on the turn that
    /// drains them.
    ///
    /// - Parameter journal: The journal to install.
    internal func attach(journal: any OperationEventJournal) {
        self.journal = journal
    }

    /// Installs the observer that receives every ``ToolInvocationRecord`` and
    /// ``ToolCallReport`` posted from now on.
    ///
    /// - Parameter invocationObserver: The observer to install.
    internal func attach(invocationObserver: any ToolInvocationObserver) {
        self.invocationObserver = invocationObserver
    }

    /// Posts one ``ToolInvocationRecord`` to the attached observer.
    ///
    /// The record is not staged and not journaled. Before an observer is
    /// attached, the record is dropped.
    ///
    /// - Parameter record: The record to forward.
    func post(invocation record: ToolInvocationRecord) async {
        await invocationObserver?.deliver(invocation: record)
    }

    /// Posts one ``ToolCallReport`` to the attached observer.
    ///
    /// The report is not staged and not journaled. Before an observer is
    /// attached, the report is dropped.
    ///
    /// - Parameter report: The report to forward.
    func post(report: ToolCallReport) async {
        await invocationObserver?.deliver(report: report)
    }

    /// Chains one journal write onto ``journalChain``.
    ///
    /// - Parameter event: The event to record.
    /// - Returns: The chained write, or `nil` when no journal is attached.
    private func enqueueJournalWrite(event: OperationEvent) -> Task<Void, Never>? {
        guard let journal else { return nil }
        return journalChain.enqueue { await journal.record(event: event) }
    }

    /// Appends `event` as a new pending item with a fresh ``EventID``.
    ///
    /// - Parameter event: The event to append.
    private func appendNewPendingEvent(event: OperationEvent) {
        events.append(PendingEvent(id: EventID(), event: event))
    }

    /// Stages a queued user prompt for a future turn, in FIFO order.
    ///
    /// - Parameter prompt: The prompt to stage.
    /// - Returns: The stable id assigned to this queued prompt.
    @discardableResult
    func enqueue(prompt: Transcript.Prompt) -> PromptID {
        let id = PromptID()
        prompts.append(PendingPrompt(id: id, prompt: prompt))
        wakeUp()
        return id
    }

    /// Cancels a still-pending queued prompt by its stable id.
    ///
    /// - Parameter id: The id ``enqueue(prompt:)`` returned.
    /// - Returns: ``PromptQueueMutationResult/applied`` if the prompt was
    ///   removed; ``PromptQueueMutationResult/alreadySent`` otherwise.
    @discardableResult
    func cancel(id: PromptID) -> PromptQueueMutationResult {
        mutatingPendingPrompt(id: id) { index in
            prompts.remove(at: index)
        }
    }

    /// Replaces a still-pending queued prompt's content in place, keeping its
    /// FIFO position.
    ///
    /// - Parameters:
    ///   - id: The id ``enqueue(prompt:)`` returned.
    ///   - prompt: The prompt's new content.
    /// - Returns: ``PromptQueueMutationResult/applied`` if the prompt was
    ///   updated; ``PromptQueueMutationResult/alreadySent`` otherwise.
    @discardableResult
    func replace(id: PromptID, prompt: Transcript.Prompt) -> PromptQueueMutationResult {
        mutatingPendingPrompt(id: id) { index in
            prompts[index] = PendingPrompt(id: id, prompt: prompt)
        }
    }

    /// Finds the pending prompt for `id` and runs `mutate` with its index.
    ///
    /// - Parameters:
    ///   - id: The id of the prompt to mutate.
    ///   - mutate: Applied with the found index.
    /// - Returns: ``PromptQueueMutationResult/applied`` if `id` was pending;
    ///   ``PromptQueueMutationResult/alreadySent`` otherwise.
    private func mutatingPendingPrompt(
        id: PromptID, _ mutate: (Int) -> Void
    ) -> PromptQueueMutationResult {
        guard let index = prompts.firstIndex(where: { $0.id == id }) else {
            return .alreadySent
        }
        mutate(index)
        return .applied
    }

    /// A snapshot of everything currently pending, per kind.
    func pending() -> Pending {
        Pending(events: events, prompts: prompts)
    }

    /// Drains every pending event and leaves the prompt queue unchanged.
    ///
    /// Call this from inside the session's serial-gated chokepoint.
    ///
    /// - Returns: Every event that was pending, now committed.
    func drainPendingEvents() -> [PendingEvent] {
        let drainedEvents = events
        events = []
        return drainedEvents
    }

    /// Drains every pending event and the next queued prompt, and commits
    /// exactly what it returns.
    ///
    /// Call this from inside the session's serial-gated chokepoint, inside a
    /// turn bracket. Each call must be released by one ``finishDispatch()``.
    ///
    /// - Returns: Every pending event, plus the next queued prompt or `nil`.
    ///   The prompt stays in ``queueDepth()`` until ``finishDispatch()``.
    internal func drainForDispatch() -> Drained {
        let drainedEvents = events
        events = []
        let drainedPrompt = prompts.isEmpty ? nil : prompts.removeFirst()
        dispatched = drainedPrompt
        return Drained(events: drainedEvents, prompt: drainedPrompt)
    }

    /// Empties the dispatched slot ``drainForDispatch()`` filled. Call it on
    /// every exit of the dispatching turn.
    internal func finishDispatch() {
        dispatched = nil
    }

    /// A snapshot of this outbox's prompt-queue depth.
    func queueDepth() -> PromptQueueDepth {
        PromptQueueDepth(queued: prompts.count, dispatched: dispatched?.id)
    }

    /// Suspends while the outbox is empty. Returns at once when an item is
    /// already pending.
    func nextEvent() async {
        guard events.isEmpty, prompts.isEmpty else { return }
        await withCheckedContinuation { continuation in
            wakeups.append(continuation)
        }
    }

    /// Resumes every continuation suspended by ``nextEvent()``.
    private func wakeUp() {
        guard !wakeups.isEmpty else { return }
        let suspended = wakeups
        wakeups = []
        for continuation in suspended {
            continuation.resume()
        }
    }
}
