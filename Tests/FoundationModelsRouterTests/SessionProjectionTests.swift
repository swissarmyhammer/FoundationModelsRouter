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
        projection.apply(.toolStatus(id: "call-1", status: .running, summary: nil))

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
        projection.apply(.toolStatus(id: "call-1", status: .running, summary: nil))
        projection.apply(.toolStatus(id: "call-1", status: .completed, summary: "72F and sunny"))

        #expect(
            projection.transcript.map(\.kind) == [
                .toolCall(
                    SessionProjection.ToolCallEntry(
                        id: "call-1", name: "search", argumentsJSON: "{}", status: .completed, summary: "72F and sunny"))
            ]
        )
    }

    @Test("two concurrent same-name tool calls are tracked as distinct entries, correlated by id")
    @MainActor
    func twoConcurrentSameNameToolCallsAreDistinctEntries() {
        let projection = SessionProjection()
        projection.apply(.toolCall(id: "call-a", name: "search", argumentsJSON: #"{"city":"NYC"}"#))
        projection.apply(.toolStatus(id: "call-a", status: .running, summary: nil))
        projection.apply(.toolCall(id: "call-b", name: "search", argumentsJSON: #"{"city":"SF"}"#))
        projection.apply(.toolStatus(id: "call-b", status: .running, summary: nil))
        projection.apply(.toolStatus(id: "call-a", status: .completed, summary: "NYC: sunny"))
        projection.apply(.toolStatus(id: "call-b", status: .completed, summary: "SF: foggy"))

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
        projection.apply(.toolStatus(id: "unknown", status: .completed, summary: "ignored"))

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
