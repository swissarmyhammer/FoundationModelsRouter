import Foundation
import FoundationModels
import Testing

@testable import FoundationModelsRouter

/// Task ^5d0qx1b: the limits of an answer are for each answer, not for each
/// submission (`generation-queue.md`, section 5.5). The chain of submissions
/// from the first delivery to the final answer is one answer.
///
/// Two limits are in the test:
///
/// - the stop of the compactions inside an answer: a compaction inside the
///   answer that applies no summary stops the next ones of that answer;
/// - the count of the repetition recoveries: ``RepetitionDetection/recoveriesPerAnswer``,
///   one for each answer in these tests.
///
/// Each test drives the production backend and a real `LanguageModelSession`
/// over an ``AnswerLimitsModel``. No GPU is in the loop. The session's counter
/// is the ``CharacterTokenCounter``: one token per character.
@Suite("The limits of an answer reset for each answer, not for each submission")
struct AnswerLimitsTests {
    /// The suite's temp-directory prefix.
    private static let tempDirPrefix = "AnswerLimitsTests"

    /// The message of the first answer of a session.
    private static let firstPrompt = "write the long answer"

    /// The message of the second answer of a session.
    private static let secondPrompt = "write one more long answer"

    /// For each compaction among `events`, in order: whether it applied a
    /// summary.
    private static func summariesApplied(in events: [SessionEvent]) -> [Bool] {
        events.compactionResults.map { $0.summaryEntryId != nil }
    }

    /// The finish reason of each ended submission among `events`, in order.
    private static func finishReasons(in events: [SessionEvent]) -> [FinishReason] {
        events.submissionEnds.map(\.finishReason)
    }

    /// The cause of each submission that `events` started, in order.
    private static func causes(in events: [SessionEvent]) -> [SubmissionStart.Cause] {
        events.submissionStarts.map(\.cause)
    }

    /// Expects that the model played every step of the script of `fixture`,
    /// and that no call found no step.
    private static func expectScriptPlayed(_ fixture: AnswerLimitsSessionFixture) {
        #expect(fixture.script.remainingSteps.isEmpty)
        #expect(fixture.script.unscriptedCalls == 0)
    }

    @Test("an answer that needs two compactions and one repetition recovery gets them, and the next answer starts with fresh limits")
    func answerGetsItsLimitsAndTheNextAnswerStartsFresh() async throws {
        let fixture = try await AnswerLimitsSessionFixture.make(tempDirPrefix: Self.tempDirPrefix)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        // The first answer: two compactions that apply a summary, then one
        // that applies none (the answer stops compacting), then its one
        // recovery. At its end, the answer used every limit it has.
        let first = try await fixture.answer(
            playing: [
                .ceilingStopThatCompacts, .ceilingStopThatCompacts, .ceilingStopWithNothingToCompact, .repeating,
                .answer,
            ],
            to: Self.firstPrompt)

        #expect(Self.summariesApplied(in: first) == [true, true, false])
        #expect(first.repetitionStops.map(\.recovery) == [1])
        #expect(Self.finishReasons(in: first) == [.maxTokens, .maxTokens, .maxTokens, .repeatedLines, .completed])
        #expect(Self.causes(in: first) == [.message, .continuation, .continuation, .continuation, .continuation])
        _ = eventsInsideAnswerFrame(first)
        #expect(first.answers.first?.reply == AnswerLimitsModel.answerText)

        // The second answer starts with fresh limits: a ceiling stop over
        // the trigger compacts again, and a repetition stop gets recovery 1
        // of 1 again.
        let second = try await fixture.answer(
            playing: [.ceilingStopThatCompacts, .repeating, .answer], to: Self.secondPrompt)

        #expect(Self.summariesApplied(in: second) == [true])
        #expect(second.repetitionStops.map(\.recovery) == [1])
        #expect(Self.finishReasons(in: second) == [.maxTokens, .repeatedLines, .completed])
        #expect(Self.causes(in: second) == [.message, .continuation, .continuation])
        _ = eventsInsideAnswerFrame(second)
        #expect(second.answers.first?.reply == AnswerLimitsModel.answerText)
        Self.expectScriptPlayed(fixture)
    }

    @Test("a continuation submission does not reset the limits of its answer")
    func continuationKeepsTheLimitsOfItsAnswer() async throws {
        // The compaction stop: a compaction that applies no summary, then a
        // recovery (one continuation), then a ceiling stop over the trigger.
        // The stop holds through the continuation, so the ceiling stop does
        // not compact, and the answer ends as truncated.
        let compaction = try await AnswerLimitsSessionFixture.make(tempDirPrefix: Self.tempDirPrefix)
        defer { try? FileManager.default.removeItem(at: compaction.directory) }
        let stopped = try await compaction.answer(
            playing: [.ceilingStopWithNothingToCompact, .repeating, .ceilingStopThatCompacts], to: Self.firstPrompt)

        #expect(Self.summariesApplied(in: stopped) == [false])
        #expect(stopped.repetitionStops.map(\.recovery) == [1])
        #expect(Self.finishReasons(in: stopped) == [.maxTokens, .repeatedLines, .maxTokens])
        #expect(Self.causes(in: stopped) == [.message, .continuation, .continuation])
        _ = eventsInsideAnswerFrame(stopped)
        Self.expectScriptPlayed(compaction)

        // The recovery count: a recovery, then a compaction that applies a
        // summary (one more continuation), then a second repetition stop.
        // The count holds through the continuation, so no recovery is left,
        // and the answer ends at the stop.
        let recovery = try await AnswerLimitsSessionFixture.make(tempDirPrefix: Self.tempDirPrefix)
        defer { try? FileManager.default.removeItem(at: recovery.directory) }
        let exhausted = try await recovery.answer(
            playing: [.repeating, .ceilingStopThatCompacts, .repeating], to: Self.firstPrompt)

        #expect(exhausted.repetitionStops.map(\.recovery) == [1, nil])
        #expect(Self.summariesApplied(in: exhausted) == [true])
        #expect(Self.finishReasons(in: exhausted) == [.repeatedLines, .maxTokens, .repeatedLines])
        #expect(Self.causes(in: exhausted) == [.message, .continuation, .continuation])
        _ = eventsInsideAnswerFrame(exhausted)
        Self.expectScriptPlayed(recovery)
    }
}
