import Foundation
import FoundationModels
import Testing

@testable import FoundationModelsRouter

/// A turn that calls tools makes more than one generation call, and the
/// turn-level ``TokenUsage`` sums them. These tests prove that the session
/// reports each call alone, live as ``SessionEvent/generationCall(_:)`` and
/// in the run journal as a ``TranscriptEvent/Kind/generationCall`` event,
/// over a real `LanguageModelSession` whose executor reports one usage for
/// each call, and that the turn-level stamp stays the sum.
@Suite("Generation call usage: one record for each generation call of a turn")
struct GenerationCallUsageTests {
    /// The prefix of each temp directory this suite makes.
    private static let tempDirPrefix = "GenerationCallUsageTests"

    /// The working context every session resolves at, so a fill is an exact
    /// fraction of a round number.
    private static let contextTokens = 1_000

    /// The scripted usage of the three calls of one tool-loop turn: two
    /// calls that ask for the tool, then the call that answers.
    private static let threeCalls = [
        MeteredGenerationCall(tokensIn: 100, tokensOut: 30),
        MeteredGenerationCall(tokensIn: 200, tokensOut: 50),
        MeteredGenerationCall(tokensIn: 300, tokensOut: 70),
    ]

    /// A ceiling a caller names, smaller than the context of the session.
    private static let requestedCeiling = 256

    /// The prompt every turn is driven with. The metered model never reads it.
    private static let prompt = "look things up, then tell me what you found"

    /// Builds a fixture over ``threeCalls`` at ``contextTokens``.
    ///
    /// - Parameter calls: The usage of each generation call, in call order.
    /// - Returns: The fixture.
    /// - Throws: Whatever profile resolution throws.
    private static func makeFixture(
        calls: [MeteredGenerationCall] = threeCalls
    ) async throws -> MeteredToolLoopSessionFixture {
        try await MeteredToolLoopSessionFixture.make(
            calls: calls, context: contextTokens, tempDirPrefix: tempDirPrefix)
    }

    /// Drives one turn on `session` and collects every event of it.
    ///
    /// - Parameters:
    ///   - session: The session to drive the turn on.
    ///   - maxTokens: The ceiling the caller names, or `nil`.
    /// - Returns: The turn's events, in arrival order.
    /// - Throws: Whatever the stream throws.
    private static func collectEvents(on session: RoutedSession, maxTokens: Int?) async throws -> [SessionEvent] {
        var events: [SessionEvent] = []
        for try await event in await session.streamEvents(to: prompt, maxTokens: maxTokens) {
            events.append(event)
        }
        return events
    }

    /// The ``SessionEvent/generationCall(_:)`` payloads of `events`, in order.
    ///
    /// - Parameter events: The turn's events.
    /// - Returns: The usage of each reported call.
    private static func generationCalls(in events: [SessionEvent]) -> [GenerationCallUsage] {
        events.compactMap { event in
            guard case .generationCall(let usage) = event else { return nil }
            return usage
        }
    }

    /// The expected fill after a call of `contextTokens`, against ``contextTokens``.
    ///
    /// - Parameter contextTokens: The measured context after the call.
    /// - Returns: The fill fraction.
    private static func fill(afterContextOf contextTokens: Int) -> Double {
        Double(contextTokens) / Double(Self.contextTokens)
    }

    // MARK: - The records of one turn

    @Test("a turn of three generation calls reports three records with the counts of each call")
    func threeCallsGiveThreeRecords() async throws {
        let fixture = try await Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let events = try await Self.collectEvents(on: fixture.session, maxTokens: nil)

        let calls = Self.generationCalls(in: events)
        #expect(calls.map(\.tokensIn) == [100, 200, 300])
        #expect(calls.map(\.tokensOut) == [30, 50, 70])
        #expect(calls.map(\.entryKind) == [.toolCall, .toolCall, .text])
        #expect(calls.map(\.finishReason) == [.completed, .completed, .completed])
        #expect(calls.map(\.contextTokens) == [130, 250, 370])
        #expect(calls.map(\.contextFill) == [130, 250, 370].map(Self.fill(afterContextOf:)))
        let toolName = MeteredToolLoopLanguageModel.Executor.self
        #expect(fixture.tool.calledSteps == [toolName.toolStep(callIndex: 0), toolName.toolStep(callIndex: 1)])
    }

    @Test("the turn-level usage stamp stays the sum of the calls, and the fill is the context of the last call")
    func turnStampStaysTheSum() async throws {
        let fixture = try await Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let events = try await Self.collectEvents(on: fixture.session, maxTokens: nil)

        guard case .turnEnded(let usage) = try #require(events.last) else {
            Issue.record("expected the last event to be turnEnded, got \(String(describing: events.last))")
            return
        }
        #expect(usage.tokensIn == 600)
        #expect(usage.tokensOut == 150)
        // The fill is the context of the render, which the last call read and
        // wrote to: 300 fed and 70 generated. It is not the sum of the calls
        // (task ^tpsc0nf).
        #expect(usage.contextFill == Self.fill(afterContextOf: 370))
        #expect(await fixture.session.contextFill == Self.fill(afterContextOf: 370))
        let journal = await fixture.recorder.events
        let stamped = try #require(journal.last { $0.kind == .response })
        #expect(stamped.tokensIn == 600)
        #expect(stamped.tokensOut == 150)
        #expect(stamped.turnUsageStamp?.input == 600)
        #expect(stamped.turnUsageStamp?.output == 150)
    }

    @Test("a tool-asking call is reported before its tool opens, and the last call before the turn ends")
    func recordsArriveLive() async throws {
        let fixture = try await Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let events = try await Self.collectEvents(on: fixture.session, maxTokens: nil)

        let recordIndices = events.indices.filter { index in
            if case .generationCall = events[index] { return true }
            return false
        }
        let openIndices = events.indices.filter { index in
            if case .toolInvocation(let record) = events[index] { return record.closedAt == nil }
            return false
        }
        let turnEndedIndex = try #require(
            events.firstIndex {
                if case .turnEnded = $0 { return true }
                return false
            })
        #expect(recordIndices.count == 3)
        #expect(openIndices.count == 2)
        #expect(recordIndices[0] < openIndices[0])
        #expect(openIndices[0] < recordIndices[1])
        #expect(recordIndices[1] < openIndices[1])
        #expect(openIndices[1] < recordIndices[2])
        #expect(recordIndices[2] < turnEndedIndex)
    }

    // MARK: - The run journal

    @Test("the run journal holds one generationCall event for each call, with its counts and no entry")
    func journalHoldsEachCall() async throws {
        let fixture = try await Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        _ = try await Self.collectEvents(on: fixture.session, maxTokens: nil)

        let journal = await fixture.recorder.events
        let records = journal.filter { $0.kind == .generationCall }
        #expect(records.map(\.tokensIn) == [100, 200, 300])
        #expect(records.map(\.tokensOut) == [30, 50, 70])
        #expect(records.allSatisfy { !$0.kind.isEntryKind && !$0.mirrorsTranscriptEntry && $0.entry == nil })
        let firstRecord = try #require(records.first)
        #expect(
            firstRecord.text
                == GenerationCallUsage(
                    tokensIn: 100, tokensOut: 30, finishReason: .completed, entryKind: .toolCall,
                    contextFill: Self.fill(afterContextOf: 130)
                ).description)
        #expect(firstRecord.text == "fed 100 tokens, generated 30 tokens, ended by the model, left a tool call, context 130 tokens")
    }

    @Test("the last call's journal event follows the response entry the call left")
    func lastCallFollowsItsResponseEntry() async throws {
        let fixture = try await Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        _ = try await Self.collectEvents(on: fixture.session, maxTokens: nil)

        let journal = await fixture.recorder.events
        let responseIndex = try #require(journal.lastIndex { $0.kind == .response })
        let lastRecordIndex = try #require(journal.lastIndex { $0.kind == .generationCall })
        let firstToolOutputIndex = try #require(journal.firstIndex { $0.kind == .toolOutput })
        let firstRecordIndex = try #require(journal.firstIndex { $0.kind == .generationCall })
        #expect(responseIndex < lastRecordIndex)
        #expect(firstRecordIndex < firstToolOutputIndex)
    }

    // MARK: - The finish reason of one call

    @Test("a call whose output count reaches the ceiling reports maxTokens, and the call after it completed")
    func ceilingCallReportsMaxTokens() async throws {
        let fixture = try await Self.makeFixture(calls: [
            MeteredGenerationCall(tokensIn: 100, tokensOut: Self.requestedCeiling),
            MeteredGenerationCall(tokensIn: 400, tokensOut: 5),
        ])
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let events = try await Self.collectEvents(on: fixture.session, maxTokens: Self.requestedCeiling)

        let calls = Self.generationCalls(in: events)
        #expect(calls.map(\.finishReason) == [.maxTokens, .completed])
        #expect(calls.map(\.entryKind) == [.toolCall, .text])
        #expect(calls.map(\.tokensOut) == [Self.requestedCeiling, 5])
    }

    @Test("the entry kind of an attempt's last call is a tool call only when the last entry is a tool call")
    func entryKindReadsTheLastEntry() {
        let toolCalls = Transcript.Entry.toolCalls(
            Transcript.ToolCalls(
                id: "calls-1",
                [
                    Transcript.ToolCall(
                        id: "call-1", toolName: "search",
                        arguments: GeneratedContent(properties: ["query": "weather"]))
                ]))
        let response = Transcript.Entry.response(
            Transcript.Response(segments: [.text(Transcript.TextSegment(content: "done"))]))

        #expect(GenerationCallEntryKind(leftBy: [toolCalls]) == .toolCall)
        #expect(GenerationCallEntryKind(leftBy: [toolCalls, response]) == .text)
        #expect(GenerationCallEntryKind(leftBy: []) == .text)
    }

    @Test("the description names the ceiling stop and the text entry")
    func descriptionNamesEveryField() {
        let usage = GenerationCallUsage(
            tokensIn: 12, tokensOut: 4, finishReason: .maxTokens, entryKind: .text, contextFill: 0.5)

        #expect(usage.contextTokens == 16)
        #expect(usage.description == "fed 12 tokens, generated 4 tokens, stopped at the token ceiling, left text, context 16 tokens")
    }

    @Test("the description of an output that ended inside the reasoning does not name the ceiling as the stop")
    func descriptionNamesTheStopInsideTheReasoning() {
        let usage = GenerationCallUsage(
            tokensIn: 12, tokensOut: 4, finishReason: .endedInsideReasoning, entryKind: .text, contextFill: 0.5)

        #expect(
            usage.description
                == "fed 12 tokens, generated 4 tokens, ended inside the reasoning before the ceiling, left text, context 16 tokens"
        )
    }
}
