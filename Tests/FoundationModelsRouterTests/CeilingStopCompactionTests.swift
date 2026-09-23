import Foundation
import FoundationModels
import FoundationModelsRouterTestSupport
import Testing

@testable import FoundationModelsRouter

/// Task ^46bz58k: an attempt that stops at its output token ceiling with the
/// context at or over the compaction trigger compacts, and the same turn
/// goes on with one more attempt.
///
/// Each test drives the production backend and a real `LanguageModelSession`
/// over a ``CeilingStopCompactionModel``. No GPU is in the loop.
@Suite("An attempt that stops at its output token ceiling compacts and goes on")
struct CeilingStopCompactionTests {
    /// The suite's temp-directory prefix.
    private static let tempDirPrefix = "CeilingStopCompactionTests"

    /// The prompt of every turn of this suite.
    private static let prompt = "write the long answer"

    /// The budget of every session of this suite: a small limit, so one
    /// scripted call can cross the trigger.
    private static let budget = TokenBudget(limit: 1_000, trigger: 0.8, target: 0.5)

    /// The output token ceiling the caller names for each turn.
    private static let ceiling = 50

    /// The size of the cut text of a call over the trigger, in characters
    /// (one token each): the compaction counts the transcript with the
    /// session's own counter, so the text itself must fill the context.
    private static let largeCutLength = 900

    /// The size of the cut text of a call under the trigger, in characters.
    private static let smallCutLength = 20

    /// The usage of a cut call that takes the context over the trigger.
    private static let overTriggerUsage = MeteredGenerationCall(tokensIn: 900, tokensOut: ceiling)

    /// The usage of a cut call that leaves the context under the trigger.
    private static let underTriggerUsage = MeteredGenerationCall(tokensIn: 100, tokensOut: ceiling)

    /// The cut text of `length` characters.
    private static func cutText(length: Int) -> String {
        "CUT:" + String(repeating: "x", count: length)
    }

    /// Builds a router and a session with ``budget`` over a
    /// ``CeilingStopCompactionModel`` whose cut call writes `cutLength`
    /// characters and reports `cutUsage`.
    ///
    /// - Parameters:
    ///   - cutLength: The size of the cut text, in characters.
    ///   - cutUsage: The usage the cut call reports.
    /// - Returns: The session and the temp directory the router cached into.
    private static func makeSession(
        cutLength: Int, cutUsage: MeteredGenerationCall
    ) async throws -> (session: RoutedSession, directory: URL) {
        let directory = RouterTestFixtures.makeTempDir(prefix: tempDirPrefix)
        let model = CeilingStopCompactionModel(cutText: cutText(length: cutLength), cutUsage: cutUsage)
        let container = LiveBackendContainer(model: model)
        let router = RouterTestFixtures.makeRouter(
            cacheDir: directory, recorder: InMemoryRecorder(),
            loader: StubModelLoader(container: container, dimension: RouterTestFixtures.stubDimension))
        let profile = try await router.resolve(profile: RouterTestFixtures.profile(), reporting: ResolutionProgress())
        return (profile.standard.makeSession(tools: [], budget: budget), directory)
    }

    /// Runs one streamed turn with ``ceiling`` and collects its events.
    private static func streamedTurn(on session: RoutedSession) async throws -> [SessionEvent] {
        var events: [SessionEvent] = []
        for try await event in await session.streamEvents(to: prompt, maxTokens: ceiling) {
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

    /// The finish reason of each ended attempt among `events`, in order.
    private static func finishReasons(in events: [SessionEvent]) -> [FinishReason] {
        events.compactMap { event in
            guard case .turnEnded(let usage) = event else { return nil }
            return usage.finishReason
        }
    }

    /// How many turns `events` started.
    private static func turnStarts(in events: [SessionEvent]) -> Int {
        events.filter { event in
            guard case .turnStarted = event else { return false }
            return true
        }.count
    }

    /// The text the turn streamed, joined.
    private static func streamedText(in events: [SessionEvent]) -> String {
        events.compactMap { event in
            guard case .textDelta(let text) = event else { return nil }
            return text
        }.joined()
    }

    @Test("a ceiling stop over the trigger: one compaction, one more attempt, and one turn that answers")
    func ceilingStopOverTheTriggerCompactsAndGoesOn() async throws {
        let (session, directory) = try await Self.makeSession(
            cutLength: Self.largeCutLength, cutUsage: Self.overTriggerUsage)
        defer { try? FileManager.default.removeItem(at: directory) }

        let events = try await Self.streamedTurn(on: session)

        let compactions = Self.compactions(in: events)
        #expect(compactions.count == 1)
        let compaction = try #require(compactions.first)
        #expect(compaction.summaryEntryId != nil)
        #expect(compaction.tokensAfter < compaction.tokensBefore)
        #expect(Self.finishReasons(in: events) == [.maxTokens, .completed])
        #expect(Self.turnStarts(in: events) == 1)
        #expect(Self.streamedText(in: events).contains(CeilingStopCompactionModel.Executor.answerText))
    }

    @Test("a ceiling stop under the trigger: no compaction, and the turn ends as truncated")
    func ceilingStopUnderTheTriggerEndsTruncated() async throws {
        let (session, directory) = try await Self.makeSession(
            cutLength: Self.smallCutLength, cutUsage: Self.underTriggerUsage)
        defer { try? FileManager.default.removeItem(at: directory) }

        let events = try await Self.streamedTurn(on: session)

        #expect(Self.compactions(in: events).isEmpty)
        #expect(Self.finishReasons(in: events) == [.maxTokens])
        #expect(Self.turnStarts(in: events) == 1)
        #expect(!Self.streamedText(in: events).contains(CeilingStopCompactionModel.Executor.answerText))
    }
}
