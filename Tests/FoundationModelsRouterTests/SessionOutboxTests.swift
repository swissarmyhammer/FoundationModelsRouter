import FoundationModels
import Testing

@testable import FoundationModelsRouter

/// Exercises task 8cwwvaj: the ``SessionOutbox`` actor's storage, kinds, ids,
/// coalescing policy, and drain primitive — in isolation from any
/// ``RoutedSession``/``LanguageModelSession`` wiring (that wiring is exercised
/// separately in ``SessionOutboxToolWiringTests``).
@Suite("SessionOutbox: storage, coalescing, drain, wakeup")
struct SessionOutboxTests {
    /// Builds a canned ``OperationEvent`` for a given tool/correlation/kind, so
    /// tests can focus on the outbox's own bookkeeping rather than restating
    /// event field boilerplate.
    private static func event(
        tool: String = "shell",
        op: String = "run command",
        correlationID: String = "1",
        kind: OperationEventKind,
        detail: String = "detail"
    ) -> OperationEvent {
        OperationEvent(tool: tool, op: op, correlationID: correlationID, kind: kind, detail: detail)
    }

    // MARK: - Coalescing

    @Test("N .progress posts for one correlationID pend as exactly 1 — the latest")
    func progressCoalescesToLatestPerCorrelation() async {
        let outbox = SessionOutbox()
        await outbox.post(event: Self.event(correlationID: "c1", kind: .progress, detail: "10%"))
        await outbox.post(event: Self.event(correlationID: "c1", kind: .progress, detail: "50%"))
        await outbox.post(event: Self.event(correlationID: "c1", kind: .progress, detail: "90%"))

        let pending = await outbox.pending()
        #expect(pending.events.count == 1)
        #expect(pending.events.first?.event.detail == "90%")
    }

    @Test("progress coalescing is scoped per (tool, correlationID) — distinct correlations pend separately")
    func progressCoalescesOnlyWithinSameCorrelation() async {
        let outbox = SessionOutbox()
        await outbox.post(event: Self.event(correlationID: "c1", kind: .progress, detail: "c1-a"))
        await outbox.post(event: Self.event(correlationID: "c2", kind: .progress, detail: "c2-a"))
        await outbox.post(event: Self.event(correlationID: "c1", kind: .progress, detail: "c1-b"))

        let pending = await outbox.pending()
        #expect(pending.events.count == 2)
        let details = Set(pending.events.map(\.event.detail))
        #expect(details == ["c1-b", "c2-a"])
    }

    @Test("progress coalescing is scoped per tool — same correlationID, different tool, pend separately")
    func progressCoalescesOnlyWithinSameTool() async {
        let outbox = SessionOutbox()
        await outbox.post(event: Self.event(tool: "shell", correlationID: "c1", kind: .progress, detail: "shell-a"))
        await outbox.post(event: Self.event(tool: "notes", correlationID: "c1", kind: .progress, detail: "notes-a"))

        let pending = await outbox.pending()
        #expect(pending.events.count == 2)
    }

    @Test("interleaved .completed events all survive, in post order")
    func completedEventsAllSurviveInOrder() async {
        let outbox = SessionOutbox()
        await outbox.post(event: Self.event(correlationID: "c1", kind: .progress, detail: "c1-progress"))
        await outbox.post(event: Self.event(correlationID: "c1", kind: .completed, detail: "c1-done"))
        await outbox.post(event: Self.event(correlationID: "c2", kind: .progress, detail: "c2-progress"))
        await outbox.post(event: Self.event(correlationID: "c2", kind: .completed, detail: "c2-done"))

        let pending = await outbox.pending()
        // Every .completed is kept, plus each correlation's still-pending
        // .progress collapses to its own single latest entry — none of the
        // completed events are coalesced away or reordered.
        #expect(pending.events.map(\.event.detail) == ["c1-progress", "c1-done", "c2-progress", "c2-done"])
    }

    @Test("a .completed after a coalesced .progress for the same correlation does not replace it")
    func completedDoesNotCoalesceWithPriorProgress() async {
        let outbox = SessionOutbox()
        await outbox.post(event: Self.event(correlationID: "c1", kind: .progress, detail: "in flight"))
        await outbox.post(event: Self.event(correlationID: "c1", kind: .completed, detail: "finished"))

        let pending = await outbox.pending()
        #expect(pending.events.count == 2)
        #expect(pending.events.map(\.event.kind) == [.progress, .completed])
    }

    @Test("two .elicitation events for the same (tool, correlationID) both survive a drain")
    func elicitationEventsNeverCoalesce() async {
        let outbox = SessionOutbox()
        await outbox.post(event: Self.event(correlationID: "c1", kind: .elicitation, detail: "first question"))
        await outbox.post(event: Self.event(correlationID: "c1", kind: .elicitation, detail: "second question"))

        let drained = await outbox.drainForDispatch()
        #expect(drained.events.map(\.event.detail) == ["first question", "second question"])
    }

    @Test("interleaved .progress still coalesces while .elicitation events are all kept, in post order")
    func progressCoalescesAroundElicitationEvents() async {
        let outbox = SessionOutbox()
        await outbox.post(event: Self.event(correlationID: "c1", kind: .progress, detail: "10%"))
        await outbox.post(event: Self.event(correlationID: "c1", kind: .elicitation, detail: "question A"))
        await outbox.post(event: Self.event(correlationID: "c1", kind: .progress, detail: "50%"))
        await outbox.post(event: Self.event(correlationID: "c1", kind: .elicitation, detail: "question B"))

        let pending = await outbox.pending()
        // The two .progress posts coalesce into the first one's slot; both
        // elicitations are kept in post order, never replaced.
        #expect(pending.events.map(\.event.detail) == ["50%", "question A", "question B"])
        #expect(pending.events.map(\.event.kind) == [.progress, .elicitation, .elicitation])
    }

    @Test("an .elicitation never replaces a pending .progress for the same (tool, correlationID)")
    func elicitationDoesNotCoalesceWithPriorProgress() async {
        let outbox = SessionOutbox()
        await outbox.post(event: Self.event(correlationID: "c1", kind: .progress, detail: "in flight"))
        await outbox.post(event: Self.event(correlationID: "c1", kind: .elicitation, detail: "question"))

        let pending = await outbox.pending()
        #expect(pending.events.count == 2)
        #expect(pending.events.map(\.event.kind) == [.progress, .elicitation])
    }

    // MARK: - Stable ids

    @Test("pending() reports items with stable ids and kinds")
    func pendingReportsStableIdsAndKinds() async {
        let outbox = SessionOutbox()
        await outbox.post(event: Self.event(correlationID: "c1", kind: .progress, detail: "first"))
        let firstPending = await outbox.pending()
        let idAfterFirstPost = try! #require(firstPending.events.first?.id)

        // A second .progress for the same correlation coalesces in place — the
        // stable id assigned at first enqueue does not change.
        await outbox.post(event: Self.event(correlationID: "c1", kind: .progress, detail: "second"))
        let secondPending = await outbox.pending()
        #expect(secondPending.events.first?.id == idAfterFirstPost)
        #expect(secondPending.events.first?.event.detail == "second")
    }

    @Test("every posted event gets a distinct id from every other pending item")
    func distinctEventsGetDistinctIds() async {
        let outbox = SessionOutbox()
        await outbox.post(event: Self.event(correlationID: "c1", kind: .completed, detail: "one"))
        await outbox.post(event: Self.event(correlationID: "c2", kind: .completed, detail: "two"))

        let pending = await outbox.pending()
        let ids = Set(pending.events.map(\.id))
        #expect(ids.count == 2)
    }

    // MARK: - Queued prompts: never coalesced, FIFO

    @Test("queued prompts never coalesce and preserve enqueue order")
    func queuedPromptsPreserveEnqueueOrderAndNeverCoalesce() async {
        let outbox = SessionOutbox()
        _ = await outbox.enqueue(prompt: Self.prompt("first"))
        _ = await outbox.enqueue(prompt: Self.prompt("second"))
        _ = await outbox.enqueue(prompt: Self.prompt("third"))

        let pending = await outbox.pending()
        #expect(pending.prompts.count == 3)
        #expect(pending.prompts.map { Self.text(of: $0.prompt) } == ["first", "second", "third"])
    }

    @Test("each enqueued prompt gets its own distinct, stable id")
    func enqueuedPromptsGetDistinctIds() async {
        let outbox = SessionOutbox()
        let id1 = await outbox.enqueue(prompt: Self.prompt("first"))
        let id2 = await outbox.enqueue(prompt: Self.prompt("second"))
        #expect(id1 != id2)

        let pending = await outbox.pending()
        #expect(pending.prompts.map(\.id) == [id1, id2])
    }

    // MARK: - drainForDispatch(): commits and empties exactly what it returns

    @Test("drainForDispatch commits and empties every pending event")
    func drainForDispatchEmptiesEvents() async {
        let outbox = SessionOutbox()
        await outbox.post(event: Self.event(correlationID: "c1", kind: .completed, detail: "one"))
        await outbox.post(event: Self.event(correlationID: "c2", kind: .completed, detail: "two"))

        let drained = await outbox.drainForDispatch()
        #expect(drained.events.map(\.event.detail) == ["one", "two"])

        // Committed items are gone.
        let pending = await outbox.pending()
        #expect(pending.events.isEmpty)
    }

    @Test("drainForDispatch drains exactly one queued prompt, FIFO")
    func drainForDispatchDrainsOneQueuedPromptFIFO() async {
        let outbox = SessionOutbox()
        let firstID = await outbox.enqueue(prompt: Self.prompt("first"))
        _ = await outbox.enqueue(prompt: Self.prompt("second"))

        let drained = await outbox.drainForDispatch()
        #expect(drained.prompt?.id == firstID)
        #expect(Self.text(of: drained.prompt!.prompt) == "first")

        // Only the one drained prompt is committed; the rest remain pending.
        let pending = await outbox.pending()
        #expect(pending.prompts.count == 1)
        #expect(Self.text(of: pending.prompts[0].prompt) == "second")
    }

    @Test("drainForDispatch with no queued prompts returns nil for the prompt")
    func drainForDispatchWithNoPromptsReturnsNil() async {
        let outbox = SessionOutbox()
        await outbox.post(event: Self.event(correlationID: "c1", kind: .completed, detail: "one"))

        let drained = await outbox.drainForDispatch()
        #expect(drained.prompt == nil)
        #expect(drained.events.count == 1)
    }

    @Test("a second drainForDispatch with nothing new pending returns empty")
    func secondDrainWithNothingNewReturnsEmpty() async {
        let outbox = SessionOutbox()
        await outbox.post(event: Self.event(correlationID: "c1", kind: .completed, detail: "one"))
        _ = await outbox.drainForDispatch()

        let secondDrain = await outbox.drainForDispatch()
        #expect(secondDrain.events.isEmpty)
        #expect(secondDrain.prompt == nil)
    }

    @Test("drain is race-free with a concurrent post: every event lands in exactly one drain")
    func drainIsRaceFreeWithConcurrentPost() async {
        let outbox = SessionOutbox()
        let totalEvents = 200

        await withTaskGroup(of: Void.self) { group in
            for i in 0..<totalEvents {
                group.addTask {
                    await outbox.post(event: Self.event(correlationID: "c\(i)", kind: .completed, detail: "e\(i)"))
                }
            }
        }

        // Drain repeatedly (simulating repeated turn boundaries) until nothing
        // new is pending; every event must show up in exactly one drain, with
        // no duplication and no loss.
        //
        // The iteration cap is what keeps a broken drain from hanging the whole
        // `swift test` run — this target sets no `.timeLimit` trait. Every drain
        // that does not end the loop takes at least one event, so `totalEvents`
        // drains empty the outbox and one further drain sees nothing; a drain
        // that never empties would otherwise spin here forever.
        let drainLimit = totalEvents + 1
        var seen: Set<String> = []
        var emptied = false
        for _ in 0..<drainLimit {
            let drained = await outbox.drainForDispatch()
            if drained.events.isEmpty {
                emptied = true
                break
            }
            for pendingEvent in drained.events {
                #expect(!seen.contains(pendingEvent.event.detail), "duplicate drain of \(pendingEvent.event.detail)")
                seen.insert(pendingEvent.event.detail)
            }
        }
        #expect(emptied, "drainForDispatch never emptied the outbox in \(drainLimit) drains")
        #expect(seen.count == totalEvents)

        let finalPending = await outbox.pending()
        #expect(finalPending.events.isEmpty)
    }

    // MARK: - nextEvent(): driver wakeup

    /// One ``SessionOutbox/nextEvent()`` wait, started so a test observes
    /// whether it woke instead of awaiting it.
    ///
    /// The indirection is the point: `nextEvent()` parks on a
    /// `CheckedContinuation<Void, Never>` that only a later
    /// ``SessionOutbox/post(event:)`` or ``SessionOutbox/enqueue(prompt:)`` resumes,
    /// and nothing can break such a wait — cancelling it does not unpark it. This
    /// target sets no `.timeLimit` trait, so a regression anywhere on the wakeup
    /// route would hang the whole `swift test` run rather than fail the test that
    /// caught it. ``wokeUp()`` reports through a signal ``BoundedWait`` observes
    /// under a bound, and never awaits the wait on its give-up path.
    private struct OutboxWaiter {
        /// What this wait expects to be woken by, named in the recorded issue
        /// when no wakeup arrives.
        private let label: String

        /// Signalled by ``task`` once `nextEvent()` has returned — how "woken"
        /// is observed without awaiting the wait itself.
        private let woke: AsyncSemaphore

        /// The parked wait.
        private let task: Task<Void, Never>

        /// Starts one ``SessionOutbox/nextEvent()`` wait on `outbox`.
        ///
        /// - Parameters:
        ///   - outbox: The outbox to wait on.
        ///   - label: What the wait expects to be woken by — "a post", say.
        init(on outbox: SessionOutbox, waitingFor label: String) {
            let woke = AsyncSemaphore(value: 0)
            self.label = label
            self.woke = woke
            self.task = Task {
                await outbox.nextEvent()
                woke.signal()
            }
        }

        /// Whether the wait is still suspended, read without awaiting it.
        var isStillParked: Bool { woke.availablePermits == 0 }

        /// Whether the wait woke inside ``BoundedWait``'s bound, recording an
        /// issue and giving up when it did not.
        ///
        /// - Returns: Whether `nextEvent()` returned.
        func wokeUp() async -> Bool {
            guard await BoundedWait.signalArrived(woke, named: "the nextEvent() wait for \(label)") else {
                // Cancelling cannot unpark a wait suspended in
                // `withCheckedContinuation`, but the test must not await that
                // wait either.
                task.cancel()
                return false
            }
            await task.value
            return true
        }
    }

    /// How long a test lets a fresh ``OutboxWaiter`` reach its suspension point
    /// before it posts, so the post lands on a genuinely parked wait rather than
    /// on an outbox the wait has not looked at yet.
    private static let waiterSuspensionNanoseconds: UInt64 = 20_000_000

    @Test("nextEvent() suspends while the outbox is empty and resumes on the next post")
    func nextEventSuspendsUntilPost() async {
        let outbox = SessionOutbox()
        let waiter = OutboxWaiter(on: outbox, waitingFor: "a post")

        // Give the waiter a chance to actually start suspending before posting.
        try? await Task.sleep(nanoseconds: Self.waiterSuspensionNanoseconds)
        #expect(waiter.isStillParked)

        await outbox.post(event: Self.event(correlationID: "c1", kind: .completed, detail: "woke"))

        // The waiter must complete promptly once posted.
        #expect(await waiter.wokeUp())
    }

    @Test("nextEvent() returns immediately when the outbox is already non-empty")
    func nextEventReturnsImmediatelyWhenNonEmpty() async {
        let outbox = SessionOutbox()
        await outbox.post(event: Self.event(correlationID: "c1", kind: .completed, detail: "already here"))

        // Must not hang: the outbox is already non-empty.
        let waiter = OutboxWaiter(on: outbox, waitingFor: "an outbox that is already non-empty")
        #expect(await waiter.wokeUp())
    }

    @Test("nextEvent() also resumes on an enqueued prompt")
    func nextEventResumesOnEnqueuedPrompt() async {
        let outbox = SessionOutbox()
        let waiter = OutboxWaiter(on: outbox, waitingFor: "an enqueued prompt")

        try? await Task.sleep(nanoseconds: Self.waiterSuspensionNanoseconds)
        #expect(waiter.isStillParked)

        _ = await outbox.enqueue(prompt: Self.prompt("hello"))

        #expect(await waiter.wokeUp())
    }

    // MARK: - Helpers

    private static func prompt(_ text: String) -> Transcript.Prompt {
        Transcript.Prompt(segments: [.text(Transcript.TextSegment(content: text))])
    }

    private static func text(of prompt: Transcript.Prompt) -> String {
        for segment in prompt.segments {
            if case .text(let textSegment) = segment {
                return textSegment.content
            }
        }
        return ""
    }
}
