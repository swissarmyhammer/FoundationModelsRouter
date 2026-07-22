import FoundationModels
import Operations
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
        await outbox.post(Self.event(correlationID: "c1", kind: .progress, detail: "10%"))
        await outbox.post(Self.event(correlationID: "c1", kind: .progress, detail: "50%"))
        await outbox.post(Self.event(correlationID: "c1", kind: .progress, detail: "90%"))

        let pending = await outbox.pending()
        #expect(pending.events.count == 1)
        #expect(pending.events.first?.event.detail == "90%")
    }

    @Test("progress coalescing is scoped per (tool, correlationID) — distinct correlations pend separately")
    func progressCoalescesOnlyWithinSameCorrelation() async {
        let outbox = SessionOutbox()
        await outbox.post(Self.event(correlationID: "c1", kind: .progress, detail: "c1-a"))
        await outbox.post(Self.event(correlationID: "c2", kind: .progress, detail: "c2-a"))
        await outbox.post(Self.event(correlationID: "c1", kind: .progress, detail: "c1-b"))

        let pending = await outbox.pending()
        #expect(pending.events.count == 2)
        let details = Set(pending.events.map(\.event.detail))
        #expect(details == ["c1-b", "c2-a"])
    }

    @Test("progress coalescing is scoped per tool — same correlationID, different tool, pend separately")
    func progressCoalescesOnlyWithinSameTool() async {
        let outbox = SessionOutbox()
        await outbox.post(Self.event(tool: "shell", correlationID: "c1", kind: .progress, detail: "shell-a"))
        await outbox.post(Self.event(tool: "notes", correlationID: "c1", kind: .progress, detail: "notes-a"))

        let pending = await outbox.pending()
        #expect(pending.events.count == 2)
    }

    @Test("interleaved .completed events all survive, in post order")
    func completedEventsAllSurviveInOrder() async {
        let outbox = SessionOutbox()
        await outbox.post(Self.event(correlationID: "c1", kind: .progress, detail: "c1-progress"))
        await outbox.post(Self.event(correlationID: "c1", kind: .completed, detail: "c1-done"))
        await outbox.post(Self.event(correlationID: "c2", kind: .progress, detail: "c2-progress"))
        await outbox.post(Self.event(correlationID: "c2", kind: .completed, detail: "c2-done"))

        let pending = await outbox.pending()
        // Every .completed is kept, plus each correlation's still-pending
        // .progress collapses to its own single latest entry — none of the
        // completed events are coalesced away or reordered.
        #expect(pending.events.map(\.event.detail) == ["c1-progress", "c1-done", "c2-progress", "c2-done"])
    }

    @Test("a .completed after a coalesced .progress for the same correlation does not replace it")
    func completedDoesNotCoalesceWithPriorProgress() async {
        let outbox = SessionOutbox()
        await outbox.post(Self.event(correlationID: "c1", kind: .progress, detail: "in flight"))
        await outbox.post(Self.event(correlationID: "c1", kind: .completed, detail: "finished"))

        let pending = await outbox.pending()
        #expect(pending.events.count == 2)
        #expect(pending.events.map(\.event.kind) == [.progress, .completed])
    }

    // MARK: - Stable ids

    @Test("pending() reports items with stable ids and kinds")
    func pendingReportsStableIdsAndKinds() async {
        let outbox = SessionOutbox()
        await outbox.post(Self.event(correlationID: "c1", kind: .progress, detail: "first"))
        let firstPending = await outbox.pending()
        let idAfterFirstPost = try! #require(firstPending.events.first?.id)

        // A second .progress for the same correlation coalesces in place — the
        // stable id assigned at first enqueue does not change.
        await outbox.post(Self.event(correlationID: "c1", kind: .progress, detail: "second"))
        let secondPending = await outbox.pending()
        #expect(secondPending.events.first?.id == idAfterFirstPost)
        #expect(secondPending.events.first?.event.detail == "second")
    }

    @Test("every posted event gets a distinct id from every other pending item")
    func distinctEventsGetDistinctIds() async {
        let outbox = SessionOutbox()
        await outbox.post(Self.event(correlationID: "c1", kind: .completed, detail: "one"))
        await outbox.post(Self.event(correlationID: "c2", kind: .completed, detail: "two"))

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
        await outbox.post(Self.event(correlationID: "c1", kind: .completed, detail: "one"))
        await outbox.post(Self.event(correlationID: "c2", kind: .completed, detail: "two"))

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
        await outbox.post(Self.event(correlationID: "c1", kind: .completed, detail: "one"))

        let drained = await outbox.drainForDispatch()
        #expect(drained.prompt == nil)
        #expect(drained.events.count == 1)
    }

    @Test("a second drainForDispatch with nothing new pending returns empty")
    func secondDrainWithNothingNewReturnsEmpty() async {
        let outbox = SessionOutbox()
        await outbox.post(Self.event(correlationID: "c1", kind: .completed, detail: "one"))
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
                    await outbox.post(Self.event(correlationID: "c\(i)", kind: .completed, detail: "e\(i)"))
                }
            }
        }

        // Drain repeatedly (simulating repeated turn boundaries) until nothing
        // new is pending; every event must show up in exactly one drain, with
        // no duplication and no loss.
        var seen: Set<String> = []
        while true {
            let drained = await outbox.drainForDispatch()
            if drained.events.isEmpty { break }
            for pendingEvent in drained.events {
                #expect(!seen.contains(pendingEvent.event.detail), "duplicate drain of \(pendingEvent.event.detail)")
                seen.insert(pendingEvent.event.detail)
            }
        }
        #expect(seen.count == totalEvents)

        let finalPending = await outbox.pending()
        #expect(finalPending.events.isEmpty)
    }

    // MARK: - nextEvent(): driver wakeup

    @Test("nextEvent() suspends while the outbox is empty and resumes on the next post")
    func nextEventSuspendsUntilPost() async {
        let outbox = SessionOutbox()

        let waiter = Task {
            await outbox.nextEvent()
        }

        // Give the waiter a chance to actually start suspending before posting.
        try? await Task.sleep(nanoseconds: 20_000_000)
        #expect(!waiter.isCancelled)

        await outbox.post(Self.event(correlationID: "c1", kind: .completed, detail: "woke"))

        // The waiter must complete promptly once posted.
        await waiter.value
    }

    @Test("nextEvent() returns immediately when the outbox is already non-empty")
    func nextEventReturnsImmediatelyWhenNonEmpty() async {
        let outbox = SessionOutbox()
        await outbox.post(Self.event(correlationID: "c1", kind: .completed, detail: "already here"))

        // Must not hang: the outbox is already non-empty.
        await outbox.nextEvent()
    }

    @Test("nextEvent() also resumes on an enqueued prompt")
    func nextEventResumesOnEnqueuedPrompt() async {
        let outbox = SessionOutbox()

        let waiter = Task {
            await outbox.nextEvent()
        }
        try? await Task.sleep(nanoseconds: 20_000_000)

        _ = await outbox.enqueue(prompt: Self.prompt("hello"))

        await waiter.value
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
