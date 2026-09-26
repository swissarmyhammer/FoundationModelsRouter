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
    /// characters and reports `cutUsage`, and runs one streamed turn with
    /// ``ceiling``.
    ///
    /// - Parameters:
    ///   - cutLength: The size of the cut text, in characters.
    ///   - cutUsage: The usage the cut call reports.
    ///   - cutEndsInsideReasoning: Whether the cut call ends inside its
    ///     thought instead of inside its response text.
    /// - Returns: The events of the turn, in order.
    private static func turnEvents(
        cutLength: Int, cutUsage: MeteredGenerationCall, cutEndsInsideReasoning: Bool = false
    ) async throws -> [SessionEvent] {
        let directory = RouterTestFixtures.makeTempDir(prefix: tempDirPrefix)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = CeilingStopCompactionModel(
            cutText: cutText(length: cutLength), cutUsage: cutUsage, cutEndsInsideReasoning: cutEndsInsideReasoning)
        let router = RouterTestFixtures.makeRouter(
            cacheDir: directory, recorder: InMemoryRecorder(),
            loader: StubModelLoader(
                container: LiveBackendContainer(model: model), dimension: RouterTestFixtures.stubDimension))
        let profile = try await router.resolve(profile: RouterTestFixtures.profile(), reporting: ResolutionProgress())
        let session = profile.standard.makeSession(tools: [], budget: budget)
        return try await collect(session.streamEvents(to: prompt, maxTokens: ceiling))
    }

    /// The finish reason of each ended submission among `events`, in order.
    /// Each end also carries the same reason in its usage.
    private static func finishReasons(in events: [SessionEvent]) -> [FinishReason] {
        let ends = events.submissionEnds
        #expect(ends.map { $0.usage?.finishReason } == ends.map(\.finishReason))
        return ends.map(\.finishReason)
    }

    /// The cause of each submission that `events` started, in order.
    private static func submissionCauses(in events: [SessionEvent]) -> [SubmissionStart.Cause] {
        events.submissionStarts.map(\.cause)
    }

    @Test(
        "a ceiling stop over the trigger: one compaction, one continuation submission, and one answer")
    func ceilingStopOverTheTriggerCompactsAndGoesOn() async throws {
        let events = try await Self.turnEvents(cutLength: Self.largeCutLength, cutUsage: Self.overTriggerUsage)

        let compactions = events.compactionResults
        #expect(compactions.count == 1)
        let compaction = try #require(compactions.first)
        #expect(compaction.summaryEntryId != nil)
        #expect(compaction.tokensAfter < compaction.tokensBefore)
        #expect(Self.finishReasons(in: events) == [.maxTokens, .completed])
        // The first submission delivers the message. The continuation after
        // the compaction delivers no new message.
        #expect(Self.submissionCauses(in: events) == [.message, .continuation])
        #expect(events.submissionStarts.map(\.messageIds.count) == [1, 0])
        // The chain has one answer, and it is the last event.
        _ = eventsInsideAnswerFrame(events)
        let answer = try #require(events.answers.first)
        #expect(answer.compactions == compactions)
        #expect(answer.reply.contains(CeilingStopCompactionModel.Executor.answerText))
        #expect(events.streamedText.contains(CeilingStopCompactionModel.Executor.answerText))
    }

    @Test("a ceiling stop under the trigger: no compaction, and the one submission ends as truncated")
    func ceilingStopUnderTheTriggerEndsTruncated() async throws {
        let events = try await Self.turnEvents(cutLength: Self.smallCutLength, cutUsage: Self.underTriggerUsage)

        #expect(events.compactionResults.isEmpty)
        #expect(Self.finishReasons(in: events) == [.maxTokens])
        #expect(Self.submissionCauses(in: events) == [.message])
        _ = eventsInsideAnswerFrame(events)
        #expect(events.answers.first?.usage?.finishReason == .maxTokens)
        #expect(!events.streamedText.contains(CeilingStopCompactionModel.Executor.answerText))
    }

    @Test("an output that ends inside the reasoning below the ceiling, over the trigger: no compaction and no continuation")
    func endedInsideReasoningOverTheTriggerDoesNotCompact() async throws {
        let usage = MeteredGenerationCall(tokensIn: Self.overTriggerUsage.tokensIn, tokensOut: Self.ceiling - 1)
        #expect(usage.tokensIn + usage.tokensOut >= Self.budget.triggerTokens)

        let events = try await Self.turnEvents(
            cutLength: Self.largeCutLength, cutUsage: usage, cutEndsInsideReasoning: true)

        #expect(events.compactionResults.isEmpty)
        #expect(Self.finishReasons(in: events) == [.endedInsideReasoning])
        #expect(Self.submissionCauses(in: events) == [.message])
        _ = eventsInsideAnswerFrame(events)
        #expect(!events.streamedText.contains(CeilingStopCompactionModel.Executor.answerText))
    }
}
