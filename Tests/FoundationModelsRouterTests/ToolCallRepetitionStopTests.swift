import Foundation
import FoundationModels
import FoundationModelsRouterTestSupport
import Testing

@testable import FoundationModelsRouter

/// Task ^dzw15st: a tool call whose arguments repeat one line is stopped
/// before the tool runs, as a repeated response is stopped.
///
/// Each test drives the production backend and a real `LanguageModelSession`
/// over a ``RepeatingToolCallModel`` with the default ``RepetitionDetection``.
/// No GPU is in the loop. The session's counter is the
/// ``CharacterTokenCounter``: one token per character.
@Suite("A tool call whose arguments repeat is stopped before the tool runs")
struct ToolCallRepetitionStopTests {
    /// The suite's temp-directory prefix.
    private static let tempDirPrefix = "ToolCallRepetitionStopTests"

    /// The prompt of every answer of this suite.
    private static let prompt = "run the snippet"

    /// How many equal lines the repeated snippet holds, as the report of the
    /// defect states it.
    private static let repeatedLineCount = 200

    /// How many different lines the snippet that runs holds, as the report
    /// of the defect states it.
    private static let differentLineCount = 30

    /// The line of the repeated snippet: longer than
    /// ``RepetitionDetection/defaultMinimumLineLength``.
    private static let repeatedLine = #"print("the same line of the generated snippet")"#

    /// A snippet of ``differentLineCount`` different lines, each longer than
    /// the minimum line length.
    private static var differentLines: [String] {
        (0..<differentLineCount).map { index in "let value\(index) = compute(step: \(index), of: total)" }
    }

    /// Runs one streamed answer over a fresh fixture.
    ///
    /// - Parameter snippetLines: The lines of the snippet the model sends.
    /// - Returns: The fixture and the events of the answer, in order.
    private static func runAnswer(
        snippetLines: [String]
    ) async throws -> (fixture: RepeatingToolCallSessionFixture, events: [SessionEvent]) {
        let fixture = try await RepeatingToolCallSessionFixture.make(
            snippetLines: snippetLines, tempDirPrefix: tempDirPrefix)
        let events = try await collect(fixture.session.streamEvents(to: prompt))
        return (fixture, events)
    }

    /// The repetition stops among `events`, in order.
    private static func stops(in events: [SessionEvent]) -> [RepetitionStop] {
        events.compactMap { event in
            guard case .repetitionStopped(let stop) = event else { return nil }
            return stop
        }
    }

    /// Whether `transcript` holds a `.toolCalls` entry.
    private static func holdsToolCalls(_ transcript: Transcript) -> Bool {
        transcript.contains { entry in
            guard case .toolCalls = entry else { return false }
            return true
        }
    }

    @Test("a tool call whose snippet holds 200 equal lines stops with repeatedLines, and the tool does not run")
    func repeatedSnippetStopsBeforeTheToolRuns() async throws {
        let snippet = Array(repeating: Self.repeatedLine, count: Self.repeatedLineCount)
        let (fixture, events) = try await Self.runAnswer(snippetLines: snippet)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let stop = try #require(Self.stops(in: events).first)
        #expect(Self.stops(in: events).count == 1)
        #expect(stop.newLines == 1)
        #expect(stop.tokensWithoutNewLine >= RepetitionDetection.defaultWindowTokens)
        #expect(stop.recovery == 1)
        #expect(events.submissionEnds.map(\.finishReason) == [.repeatedLines, .completed])
        #expect(fixture.runs.value == 0)
        #expect(events.streamedText.contains(RepeatingToolCallModel.Executor.answerText))

        let renders = fixture.log.renders
        #expect(renders.count == 2)
        let continuation = try #require(renders.last)
        #expect(continuation.promptTexts.last == RoutedSessionActor.repetitionStopContinuationPrompt)
        #expect(!Self.holdsToolCalls(continuation))
    }

    @Test("a tool call whose snippet holds 30 different lines is not stopped, and the tool runs")
    func differentSnippetRuns() async throws {
        let (fixture, events) = try await Self.runAnswer(snippetLines: Self.differentLines)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        #expect(Self.stops(in: events).isEmpty)
        #expect(events.submissionEnds.map(\.finishReason) == [.completed])
        #expect(fixture.runs.value == 1)
        #expect(events.streamedText.contains(RepeatingToolCallModel.Executor.answerText))
    }
}
