import Foundation
import Testing

@testable import FoundationModelsRouter

/// Exercises task ekd82f4: ``SessionProjection``, the `@MainActor`/`@Observable`
/// mirror of one ``RoutedSession``'s live state a SwiftUI view binds to.
/// ``SessionProjection`` never mutates itself off a real session — every test
/// here drives it directly with hand-built ``SessionEvent`` values (via
/// ``SessionProjection/apply(_:)``) or a hand-built
/// `AsyncThrowingStream<SessionEvent, Error>` (via
/// ``SessionProjection/apply(eventsFrom:)``), mirroring exactly what
/// ``RoutedSession/streamEvents(to:maxTokens:)`` would yield — no router,
/// profile, or backend needed.
@Suite("SessionProjection: the @Observable mirror of a session's live state")
struct SessionProjectionTests {
    // MARK: - Initial state

    @Test("a fresh projection starts idle, with an empty transcript and zeroed counters")
    @MainActor
    func freshProjectionStartsIdle() {
        let projection = SessionProjection()
        #expect(projection.phase == .idle)
        #expect(projection.transcript.isEmpty)
        #expect(projection.tokensIn == 0)
        #expect(projection.tokensOut == 0)
        #expect(projection.contextFill == 0)
    }

    // MARK: - textDelta: coalesced into one running entry, phase .generating

    @Test("consecutive textDelta fragments coalesce into a single text entry and set phase .generating")
    @MainActor
    func textDeltaFragmentsCoalesceIntoOneEntry() {
        let projection = SessionProjection()
        projection.apply(.textDelta("hello "))
        projection.apply(.textDelta("world"))

        #expect(projection.phase == .generating)
        #expect(projection.transcript.map(\.kind) == [.text("hello world")])
    }

    @Test("a textDelta after a different entry kind starts a new text entry rather than merging")
    @MainActor
    func textDeltaAfterOtherKindStartsNewEntry() {
        let projection = SessionProjection()
        projection.apply(.reasoningDelta("thinking"))
        projection.apply(.textDelta("hello"))

        #expect(projection.transcript.map(\.kind) == [.reasoning("thinking"), .text("hello")])
    }

    // MARK: - reasoningDelta: coalesced separately from text

    @Test("consecutive reasoningDelta fragments coalesce into a single reasoning entry")
    @MainActor
    func reasoningDeltaFragmentsCoalesceIntoOneEntry() {
        let projection = SessionProjection()
        projection.apply(.reasoningDelta("the user wants "))
        projection.apply(.reasoningDelta("the weather"))

        #expect(projection.transcript.map(\.kind) == [.reasoning("the user wants the weather")])
    }

    // MARK: - toolCall / toolStatus: correlated by id, phase .runningTool

    @Test("a toolCall followed by toolStatus(.running) yields one entry reporting .running")
    @MainActor
    func toolCallThenRunningStatusYieldsRunningEntry() {
        let projection = SessionProjection()
        projection.apply(.toolCall(id: "call-1", name: "search", argumentsJSON: #"{"query":"weather"}"#))
        projection.apply(.toolStatus(id: "call-1", status: .running, summary: nil, output: nil))

        #expect(projection.phase == .runningTool)
        #expect(
            projection.transcript.map(\.kind) == [
                .toolCall(
                    SessionProjection.ToolCallEntry(
                        id: "call-1", name: "search", argumentsJSON: #"{"query":"weather"}"#, status: .running, summary: nil))
            ]
        )
    }

    @Test("a completed toolStatus updates the matching entry's status and summary in place")
    @MainActor
    func completedStatusUpdatesMatchingEntry() {
        let projection = SessionProjection()
        projection.apply(.toolCall(id: "call-1", name: "search", argumentsJSON: "{}"))
        projection.apply(.toolStatus(id: "call-1", status: .running, summary: nil, output: nil))
        projection.apply(.toolStatus(id: "call-1", status: .completed, summary: "72F and sunny", output: nil))

        #expect(
            projection.transcript.map(\.kind) == [
                .toolCall(
                    SessionProjection.ToolCallEntry(
                        id: "call-1", name: "search", argumentsJSON: "{}", status: .completed, summary: "72F and sunny"))
            ]
        )
    }

    @Test("a completed toolStatus's full output segments land on the row — text, structure, and custom — with summary staying the flattened text")
    @MainActor
    func completedStatusCarriesFullOutputSegmentsOnTheRow() {
        let projection = SessionProjection()
        projection.apply(.toolCall(id: "call-1", name: "search", argumentsJSON: "{}"))
        let output: [SegmentPayload] = [
            .text(id: "s-text", content: "72F and sunny"),
            .structure(id: "s-struct", schemaName: "Weather", contentJSON: #"{"tempF":72}"#),
            .custom(
                id: "s-note", typeDiscriminator: "TestNoteSegment", contentJSON: #"{"body":"hello"}"#,
                description: "Note: hello"),
        ]
        projection.apply(.toolStatus(id: "call-1", status: .completed, summary: "72F and sunny", output: output))

        #expect(
            projection.transcript.map(\.kind) == [
                .toolCall(
                    SessionProjection.ToolCallEntry(
                        id: "call-1", name: "search", argumentsJSON: "{}", status: .completed,
                        summary: "72F and sunny", output: output))
            ]
        )
    }

    @Test("two concurrent same-name tool calls are tracked as distinct entries, correlated by id")
    @MainActor
    func twoConcurrentSameNameToolCallsAreDistinctEntries() {
        let projection = SessionProjection()
        projection.apply(.toolCall(id: "call-a", name: "search", argumentsJSON: #"{"city":"NYC"}"#))
        projection.apply(.toolStatus(id: "call-a", status: .running, summary: nil, output: nil))
        projection.apply(.toolCall(id: "call-b", name: "search", argumentsJSON: #"{"city":"SF"}"#))
        projection.apply(.toolStatus(id: "call-b", status: .running, summary: nil, output: nil))
        projection.apply(.toolStatus(id: "call-a", status: .completed, summary: "NYC: sunny", output: nil))
        projection.apply(.toolStatus(id: "call-b", status: .completed, summary: "SF: foggy", output: nil))

        #expect(
            projection.transcript.map(\.kind) == [
                .toolCall(
                    SessionProjection.ToolCallEntry(
                        id: "call-a", name: "search", argumentsJSON: #"{"city":"NYC"}"#, status: .completed, summary: "NYC: sunny")),
                .toolCall(
                    SessionProjection.ToolCallEntry(
                        id: "call-b", name: "search", argumentsJSON: #"{"city":"SF"}"#, status: .completed, summary: "SF: foggy")),
            ]
        )
    }

    @Test("a toolStatus with no matching prior toolCall is a true no-op, not a crash and not even a phase change")
    @MainActor
    func toolStatusWithNoMatchingToolCallIsANoOp() {
        let projection = SessionProjection()
        projection.apply(.toolStatus(id: "unknown", status: .completed, summary: "ignored", output: nil))

        #expect(projection.transcript.isEmpty)
        // Genuinely a no-op: an untracked status update must not even flip
        // `phase` to `.runningTool` — a bound SwiftUI view would otherwise
        // show a "running tool" spinner with no corresponding transcript entry.
        #expect(projection.phase == .idle)
    }

    // MARK: - compaction: appended as its own entry, phase .compacting

    @Test("a compaction event appends its result and sets phase .compacting")
    @MainActor
    func compactionEventAppendsResultAndSetsPhase() {
        let projection = SessionProjection()
        let result = CompactionResult(summary: "folded", tokensBefore: 1000, tokensAfter: 400, stagesApplied: ["ToolOutputElision"])
        projection.apply(.compaction(result))

        #expect(projection.phase == .compacting)
        #expect(projection.transcript.map(\.kind) == [.compaction(result)])
    }

    // MARK: - turnEnded: accumulates tokens, latest contextFill, phase .idle

    @Test("turnEnded accumulates tokensIn/tokensOut across calls and sets phase .idle")
    @MainActor
    func turnEndedAccumulatesTokensAndSetsIdle() {
        let projection = SessionProjection()
        projection.apply(.textDelta("hi"))
        projection.apply(.turnEnded(TokenUsage(tokensIn: 10, tokensOut: 5, contextFill: 0.1)))

        #expect(projection.phase == .idle)
        #expect(projection.tokensIn == 10)
        #expect(projection.tokensOut == 5)
        #expect(projection.contextFill == 0.1)
    }

    @Test("a retried turn's second turnEnded adds to the running token totals and reports the newer contextFill")
    @MainActor
    func secondTurnEndedAddsToRunningTotals() {
        let projection = SessionProjection()
        projection.apply(.turnEnded(TokenUsage(tokensIn: 100, tokensOut: 50, contextFill: 0.9)))
        projection.apply(.compaction(CompactionResult(summary: nil, tokensBefore: 500, tokensAfter: 200, stagesApplied: [])))
        projection.apply(.turnEnded(TokenUsage(tokensIn: 20, tokensOut: 10, contextFill: 0.4)))

        #expect(projection.tokensIn == 120)
        #expect(projection.tokensOut == 60)
        #expect(projection.contextFill == 0.4)
    }

    // MARK: - apply(eventsFrom:): drains a whole stream, resetting to .idle on completion or throw

    @Test("apply(eventsFrom:) applies every event from a stream in order")
    @MainActor
    func applyEventsFromAppliesEveryEventInOrder() async throws {
        let projection = SessionProjection()
        let stream = AsyncThrowingStream<SessionEvent, Error> { continuation in
            continuation.yield(.textDelta("hello "))
            continuation.yield(.textDelta("world"))
            continuation.yield(.turnEnded(TokenUsage(tokensIn: 3, tokensOut: 2, contextFill: 0.05)))
            continuation.finish()
        }

        try await projection.apply(eventsFrom: stream)

        #expect(projection.transcript.map(\.kind) == [.text("hello world")])
        #expect(projection.tokensIn == 3)
        #expect(projection.phase == .idle)
    }

    // MARK: - Source-derived row identity (task ^rt024hy)

    @Test("a toolCall row uses the SDK Transcript.ToolCall.id as its row id")
    @MainActor
    func toolCallRowUsesTheCallIdAsItsRowId() {
        let projection = SessionProjection()
        projection.apply(.toolCall(id: "call-1", name: "search", argumentsJSON: "{}"))

        #expect(projection.transcript.map(\.id) == ["call-1"])
        #expect(projection.transcript.map(\.sourceEntryId) == [nil])
    }

    @Test("an entryRecorded(.toolCalls) stamps sourceEntryId on that entry's call rows, keeping each row's own id")
    @MainActor
    func entryRecordedToolCallsStampsSourceEntryIdOnCallRows() {
        let projection = SessionProjection()
        projection.apply(.toolCall(id: "call-a", name: "search", argumentsJSON: "{}"))
        projection.apply(.toolCall(id: "call-b", name: "search", argumentsJSON: "{}"))
        projection.apply(.entryRecorded(id: "calls-1", kind: .toolCalls))

        #expect(projection.transcript.map(\.id) == ["call-a", "call-b"])
        #expect(projection.transcript.map(\.sourceEntryId) == ["calls-1", "calls-1"])
    }

    @Test("a streaming text row adopts the SDK .response entry id when the entry is recorded")
    @MainActor
    func textRowAdoptsTheResponseEntryIdWhenRecorded() {
        let projection = SessionProjection()
        projection.apply(.textDelta("hello "))
        projection.apply(.textDelta("world"))
        projection.apply(.entryRecorded(id: "resp-1", kind: .response))

        #expect(projection.transcript.map(\.id) == ["resp-1"])
        #expect(projection.transcript.map(\.sourceEntryId) == ["resp-1"])
        #expect(projection.transcript.map(\.kind) == [.text("hello world")])
    }

    @Test("a textDelta after adoption opens a new row instead of growing the adopted one")
    @MainActor
    func textDeltaAfterAdoptionOpensANewRow() {
        let projection = SessionProjection()
        projection.apply(.textDelta("first turn"))
        projection.apply(.entryRecorded(id: "resp-1", kind: .response))
        projection.apply(.textDelta("second turn"))

        #expect(projection.transcript.map(\.kind) == [.text("first turn"), .text("second turn")])
        #expect(projection.transcript[0].id == "resp-1")
        #expect(projection.transcript[1].id != "resp-1")
        #expect(projection.transcript[1].sourceEntryId == nil)
    }

    @Test("a reasoning row adopts the SDK .reasoning entry id when the entry is recorded")
    @MainActor
    func reasoningRowAdoptsTheReasoningEntryIdWhenRecorded() {
        let projection = SessionProjection()
        projection.apply(.reasoningDelta("the user wants the weather"))
        projection.apply(.entryRecorded(id: "reasoning-1", kind: .reasoning))

        #expect(projection.transcript.map(\.id) == ["reasoning-1"])
        #expect(projection.transcript.map(\.sourceEntryId) == ["reasoning-1"])
    }

    @Test("textReset-split rows adopt two .response entry ids oldest-first")
    @MainActor
    func textResetSplitRowsAdoptResponseIdsOldestFirst() {
        let projection = SessionProjection()
        projection.apply(.textDelta("draft before the tool ran"))
        projection.apply(.textReset)
        projection.apply(.textDelta("the final answer"))
        projection.apply(.entryRecorded(id: "resp-pre-tool", kind: .response))
        projection.apply(.entryRecorded(id: "resp-final", kind: .response))

        #expect(projection.transcript.map(\.id) == ["resp-pre-tool", "resp-final"])
        #expect(
            projection.transcript.map(\.kind) == [
                .text("draft before the tool ran"), .text("the final answer"),
            ]
        )
    }

    @Test("an entryRecorded with no open row of its kind is a no-op, not a crash and not a phase change")
    @MainActor
    func entryRecordedWithNoOpenRowIsANoOp() {
        let projection = SessionProjection()
        projection.apply(.entryRecorded(id: "resp-1", kind: .response))

        #expect(projection.transcript.isEmpty)
        #expect(projection.phase == .idle)
    }

    @Test("two projections given the same event sequence produce equal row ids, adopted and provisional alike")
    @MainActor
    func twoProjectionsGivenTheSameEventsProduceEqualRowIds() {
        let compaction = CompactionResult(
            summary: "folded", summaryEntryId: "compaction-summary-1", tokensBefore: 1000, tokensAfter: 400,
            stagesApplied: ["Summarization"])
        let events: [SessionEvent] = [
            .reasoningDelta("thinking"),
            .entryRecorded(id: "reasoning-1", kind: .reasoning),
            .textDelta("hello "),
            .textDelta("world"),
            .toolCall(id: "call-1", name: "search", argumentsJSON: "{}"),
            .compaction(compaction),
            .textDelta("still streaming, never adopted"),
        ]

        let first = SessionProjection()
        let second = SessionProjection()
        for event in events {
            first.apply(event)
            second.apply(event)
        }

        #expect(first.transcript.map(\.id) == second.transcript.map(\.id))
        #expect(first.transcript.map(\.sourceEntryId) == second.transcript.map(\.sourceEntryId))
    }

    @Test("a compaction row is keyed by the result's own id and joins through summaryEntryId")
    @MainActor
    func compactionRowIsKeyedByTheResultId() {
        let projection = SessionProjection()
        let folded = CompactionResult(
            summary: "folded", summaryEntryId: "compaction-summary-1", tokensBefore: 1000, tokensAfter: 400,
            stagesApplied: ["Summarization"])
        let unfolded = CompactionResult(summary: nil, tokensBefore: 500, tokensAfter: 500, stagesApplied: [])
        projection.apply(.compaction(folded))
        projection.apply(.compaction(unfolded))

        #expect(projection.transcript.map(\.id) == [folded.id, unfolded.id])
        #expect(projection.transcript.map(\.sourceEntryId) == ["compaction-summary-1", nil])
    }

    @Test("apply(eventsFrom:) applies events yielded before a throw, then rethrows, still resetting to .idle")
    @MainActor
    func applyEventsFromAppliesPriorEventsThenRethrowsAndResetsIdle() async throws {
        enum StubError: Error, Equatable { case boom }

        let projection = SessionProjection()
        let stream = AsyncThrowingStream<SessionEvent, Error> { continuation in
            continuation.yield(.toolCall(id: "call-1", name: "search", argumentsJSON: "{}"))
            continuation.finish(throwing: StubError.boom)
        }

        var thrown: Error?
        do {
            try await projection.apply(eventsFrom: stream)
        } catch {
            thrown = error
        }

        #expect(thrown as? StubError == .boom)
        #expect(projection.phase == .idle)
        #expect(
            projection.transcript.map(\.kind) == [
                .toolCall(SessionProjection.ToolCallEntry(id: "call-1", name: "search", argumentsJSON: "{}", status: .running, summary: nil))
            ]
        )
    }
}
