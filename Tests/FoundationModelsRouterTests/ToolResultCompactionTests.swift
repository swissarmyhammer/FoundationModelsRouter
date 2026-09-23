import Foundation
import FoundationModels
import FoundationModelsRouterTestSupport
import Testing

@testable import FoundationModelsRouter

/// Task ^9ddjkjm: a tool result that takes the context over the compaction
/// trigger stops the model call at the tool-result boundary. The session
/// compacts, and the same turn goes on and answers.
///
/// Each session test drives the production backend and a real
/// `LanguageModelSession` over a ``ToolResultCompactionModel``, so the
/// entries Apple's session keeps and drops are real. No GPU is in the loop.
@Suite("A tool result that crosses the trigger compacts inside the turn")
struct ToolResultCompactionTests {
    /// The suite's temp-directory prefix.
    private static let tempDirPrefix = "ToolResultCompactionTests"

    /// The prompt of every turn of this suite.
    private static let prompt = "look up the large record and tell me when you have it"

    /// The budget of every session of this suite: a small limit, so one tool
    /// result crosses the trigger.
    private static let budget = TokenBudget(limit: 1_000, trigger: 0.8, target: 0.5)

    /// The usage of the call that asks for the tool: just under the trigger.
    private static let toolCallUsage = MeteredGenerationCall(tokensIn: 700, tokensOut: 10)

    /// The size of the large tool result, in characters (one token each).
    private static let largeResultLength = 900

    /// The size of the small tool result, in characters.
    private static let smallResultLength = 20

    /// The text a large or a small tool call returns.
    private static func toolResult(length: Int) -> String {
        "RESULT:" + String(repeating: "x", count: length)
    }

    /// A routed session over a ``ToolResultCompactionModel``, with its tool,
    /// its recorder, and the directory the router cached into.
    private struct Fixture {
        /// The session a test drives its turn on.
        let session: RoutedSession

        /// The one mounted tool.
        let tool: LargeResultTool

        /// The recorder of the session's transcript events.
        let recorder: InMemoryRecorder

        /// The temp directory the router cached into.
        let directory: URL
    }

    /// The usage of a call that reports no count, as the engine does at the
    /// first tool result of a turn.
    private static let unreportedUsage = MeteredGenerationCall(tokensIn: 0, tokensOut: 0)

    /// Builds a router and a session with ``budget`` and one tool whose
    /// result has `resultLength` characters.
    ///
    /// - Parameters:
    ///   - resultLength: The size of the tool result, in characters.
    ///   - usage: The usage the call that asks for the tool reports.
    private static func makeFixture(
        resultLength: Int, usage: MeteredGenerationCall = toolCallUsage
    ) async throws -> Fixture {
        let directory = RouterTestFixtures.makeTempDir(prefix: tempDirPrefix)
        let recorder = InMemoryRecorder()
        let tool = LargeResultTool(result: toolResult(length: resultLength))
        let container = LiveBackendContainer(model: ToolResultCompactionModel(toolCallUsage: usage))
        let router = RouterTestFixtures.makeRouter(
            cacheDir: directory, recorder: recorder,
            loader: StubModelLoader(container: container, dimension: RouterTestFixtures.stubDimension))
        let profile = try await router.resolve(profile: RouterTestFixtures.profile(), reporting: ResolutionProgress())
        let session = profile.standard.makeSession(tools: [tool], budget: budget)
        return Fixture(session: session, tool: tool, recorder: recorder, directory: directory)
    }

    /// Runs one streamed turn and collects its events.
    private static func streamedTurn(on session: RoutedSession) async throws -> [SessionEvent] {
        var events: [SessionEvent] = []
        for try await event in await session.streamEvents(to: prompt, maxTokens: nil) {
            events.append(event)
        }
        return events
    }

    /// The compaction results among `events`, in order.
    private static func compactions(in events: [SessionEvent]) -> [CompactionResult] {
        events.compactMap { event in
            guard case .compaction(let result) = event else { return nil }
            return result
        }
    }

    /// The text the turn streamed, joined.
    private static func streamedText(in events: [SessionEvent]) -> String {
        events.compactMap { event in
            guard case .textDelta(let text) = event else { return nil }
            return text
        }.joined()
    }

    @Test("the tool result crosses the trigger: one compaction, then the same turn answers")
    func crossingResultCompactsAndTheTurnAnswers() async throws {
        let fixture = try await Self.makeFixture(resultLength: Self.largeResultLength)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let events = try await Self.streamedTurn(on: fixture.session)

        let compactions = Self.compactions(in: events)
        #expect(compactions.count == 1)
        let compaction = try #require(compactions.first)
        #expect(compaction.summaryEntryId != nil)
        #expect(compaction.tokensAfter < compaction.tokensBefore)
        #expect(fixture.tool.calls == 1)
        let turnStarts = events.filter { event in
            guard case .turnStarted = event else { return false }
            return true
        }
        #expect(turnStarts.count == 1)
        #expect(Self.streamedText(in: events).contains(ToolResultCompactionModel.Executor.answerText))
    }

    @Test("the record holds the stopped rounds, then the compaction boundary, then the continuation")
    func recordHoldsTheStoppedRoundsBeforeTheBoundary() async throws {
        let fixture = try await Self.makeFixture(resultLength: Self.largeResultLength)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        _ = try await Self.streamedTurn(on: fixture.session)

        let events = await fixture.recorder.events
        let checkpoint = try #require(TranscriptTree.newestCompactionCheckpoint(in: events))
        let outputIndex = try #require(
            events.firstIndex { $0.kind == .toolOutput && ($0.text ?? "").contains(Self.toolResult(length: Self.largeResultLength)) })
        let callsIndex = try #require(events.firstIndex { $0.kind == .toolCalls })
        let reasoningIndex = try #require(events.firstIndex { $0.kind == .reasoning })
        let promptIndex = try #require(events.firstIndex { $0.kind == .prompt && ($0.text ?? "").contains(Self.prompt) })
        let continuationIndex = try #require(
            events.firstIndex { $0.kind == .prompt && ($0.text ?? "").contains(RoutedSessionActor.compactionContinuationPrompt) })
        #expect(promptIndex < reasoningIndex)
        #expect(reasoningIndex < callsIndex)
        #expect(callsIndex < outputIndex)
        #expect(outputIndex < checkpoint.index)
        #expect(checkpoint.index < continuationIndex)
    }

    @Test("with no usage reported yet, the counted context still lets the first tool result cross the trigger")
    func unreportedUsageStillCrosses() async throws {
        let fixture = try await Self.makeFixture(resultLength: Self.largeResultLength, usage: Self.unreportedUsage)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let events = try await Self.streamedTurn(on: fixture.session)

        #expect(Self.compactions(in: events).count == 1)
        #expect(fixture.tool.calls == 1)
        #expect(Self.streamedText(in: events).contains(ToolResultCompactionModel.Executor.answerText))
    }

    @Test("a tool result under the trigger does not compact, and the turn answers")
    func resultUnderTheTriggerDoesNotCompact() async throws {
        let fixture = try await Self.makeFixture(resultLength: Self.smallResultLength)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let events = try await Self.streamedTurn(on: fixture.session)

        #expect(Self.compactions(in: events).isEmpty)
        #expect(Self.streamedText(in: events).contains(ToolResultCompactionModel.Executor.answerText))
    }

    @Test("a user stop during the tool call stays a user stop, not a compaction")
    func userStopStaysAStop() async throws {
        let fixture = try await Self.makeFixture(resultLength: Self.largeResultLength)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        fixture.tool.stopsTurn(of: fixture.session)

        let stream = await fixture.session.streamEvents(to: Self.prompt, maxTokens: nil)
        let collected = EventLog()
        await #expect(throws: CancellationError.self) {
            for try await event in stream {
                await collected.append(event)
            }
        }

        #expect(Self.compactions(in: await collected.events).isEmpty)
    }
}

/// The events one stream gave, kept across the `#expect(throws:)` closure.
private actor EventLog {
    /// The events, in the order the stream gave them.
    private(set) var events: [SessionEvent] = []

    /// Keeps `event` after every earlier event.
    func append(_ event: SessionEvent) {
        events.append(event)
    }
}

/// The rebuild of a stopped attempt's transcript, with no session.
@Suite("The transcript of an attempt that a compaction yield stopped")
struct InFlightTranscriptTests {
    /// The composed prompt of the stopped attempt.
    private static let composedPrompt = "the prompt of the attempt"

    /// The name of the tool of each case.
    private static let toolName = "lookup"

    /// The text of the tool result of each case.
    private static let resultText = "the tool result"

    /// An entry from before the attempt.
    private static let earlierEntry = Transcript.Entry.response(
        Transcript.Response(
            id: "earlier", assetIDs: [], segments: [.text(Transcript.TextSegment(content: "earlier"))]))

    /// The one tool result of each case.
    private static let result = ToolResultAppend(
        toolName: toolName, arguments: AmbientToolArguments(value: "x"), text: resultText)

    /// A yield marker with `liveEntries` and one tool result.
    private static func yield(liveEntries: [Transcript.Entry]) -> CompactionYield {
        CompactionYield(measuredTokens: 1, results: [result], liveEntries: liveEntries, snapshotEntries: [])
    }

    @Test("with no source of the attempt, the rebuild adds the prompt, the call, and the output, in order")
    func rebuildAddsWhatNoSourceHolds() throws {
        let rebuilt = InFlightTranscript.rebuilt(
            settledEntries: [Self.earlierEntry], yield: Self.yield(liveEntries: []),
            entryIdsBeforeAttempt: [Self.earlierEntry.id], composedPrompt: Self.composedPrompt)

        #expect(rebuilt.count == 4)
        #expect(rebuilt[0].id == Self.earlierEntry.id)
        #expect(Self.isPrompt(entry: rebuilt[1]))
        let calls = try #require(Self.toolCalls(of: rebuilt[2]))
        let output = try #require(Self.toolOutput(of: rebuilt[3]))
        #expect(calls.first?.id == output.id)
        #expect(output.toolName == Self.toolName)
    }

    /// Whether `entry` is a `.prompt` entry.
    private static func isPrompt(entry: Transcript.Entry) -> Bool {
        if case .prompt = entry { return true }
        return false
    }

    /// The calls of `entry` when it is a `.toolCalls` entry, else `nil`.
    private static func toolCalls(of entry: Transcript.Entry) -> Transcript.ToolCalls? {
        if case .toolCalls(let calls) = entry { return calls }
        return nil
    }

    /// The output of `entry` when it is a `.toolOutput` entry, else `nil`.
    private static func toolOutput(of entry: Transcript.Entry) -> Transcript.ToolOutput? {
        if case .toolOutput(let output) = entry { return output }
        return nil
    }

    @Test("a call in the live entries is paired, and an unanswered call of that round is removed")
    func rebuildPairsTheLiveCallAndRemovesTheUnanswered() throws {
        let arguments = GeneratedContent(properties: ["value": "x"])
        let calls = Transcript.Entry.toolCalls(
            Transcript.ToolCalls(
                id: "round",
                [
                    Transcript.ToolCall(id: "answered", toolName: Self.toolName, arguments: arguments),
                    Transcript.ToolCall(id: "cancelled", toolName: "other", arguments: arguments),
                ]))
        let prompt = Transcript.Entry.prompt(
            Transcript.Prompt(id: "prompt", segments: [.text(Transcript.TextSegment(content: Self.composedPrompt))]))

        let rebuilt = InFlightTranscript.rebuilt(
            settledEntries: [Self.earlierEntry], yield: Self.yield(liveEntries: [Self.earlierEntry, prompt, calls]),
            entryIdsBeforeAttempt: [Self.earlierEntry.id], composedPrompt: Self.composedPrompt)

        #expect(rebuilt.map(\.id) == [Self.earlierEntry.id, "prompt", "round", "answered"])
        let kept = try #require(Self.toolCalls(of: rebuilt[2]))
        #expect(kept.map(\.id) == ["answered"])
    }
}
