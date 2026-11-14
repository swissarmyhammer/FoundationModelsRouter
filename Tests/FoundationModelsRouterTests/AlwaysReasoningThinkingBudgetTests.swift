import Foundation
import FoundationModels
import FoundationModelsRouterTestSupport
import MLXLMCommon
import Testing

@testable import FoundationModelsRouter

/// Task ^qmewzw0: the reasoning control of a model, and the thinking budget an
/// always-reasoning model gets where the router asks for reasoning off.
///
/// No GPU is in the loop. The session tests drive the production backend and a
/// real `LanguageModelSession` over a scripted model, and the session's counter
/// is the ``CharacterTokenCounter``: one token per character.
@Suite("A model reports its reasoning control: switchable, always on, or none")
struct ReasoningControlTests {
    @Test("an MLX template-flag strategy is switchable")
    func templateFlagIsSwitchable() {
        let strategy = ReasoningPromptStrategy.templateFlag(key: "enable_thinking", defaultOn: true)

        #expect(ReasoningControl(promptStrategy: strategy) == .switchable)
    }

    @Test("an MLX always-on strategy is always on")
    func alwaysOnStrategyIsAlwaysOn() {
        #expect(ReasoningControl(promptStrategy: .alwaysOn) == .alwaysOn)
    }

    @Test("an MLX strategy with no thinking control is none")
    func noneStrategyIsNone() {
        #expect(ReasoningControl(promptStrategy: ReasoningPromptStrategy.none) == .none)
    }

    @Test("an MLX model with no reasoning configuration is none")
    func missingReasoningConfigurationIsNone() {
        #expect(ReasoningControl(promptStrategy: nil) == .none)
    }

    @Test("a llama.cpp chat template that supports thinking is switchable")
    func thinkingTemplateIsSwitchable() {
        #expect(ReasoningControl(templateSupportsThinking: true) == .switchable)
    }

    @Test("a llama.cpp chat template with no thinking is none")
    func plainTemplateIsNone() {
        #expect(ReasoningControl(templateSupportsThinking: false) == .none)
    }

    @Test("the thinking allowance is 8,192 tokens, the measured reasoning of Flint on a summary and some room")
    func thinkingAllowanceIsTheDecidedValue() {
        #expect(ReasoningControl.thinkingAllowance == 8_192)
    }
}

/// The output ceiling of a summarizer call for each reasoning control.
@Suite("An always-reasoning summarizer gets a thinking allowance on top of the summary size")
struct SummarizerThinkingAllowanceTests {
    /// The two summarizer tiers, each of which keeps the ceiling rule.
    static let tiers: [CompactionSummarizerTier] = [.flash, .ownModel]

    /// The size the summary may take in each call of this suite, in tokens.
    private static let allowedSummaryTokens = 150

    /// The input of each call of this suite, in tokens.
    private static let inputTokens = 1_000

    /// A window whose room after the input holds the summary and the
    /// thinking allowance with room to spare.
    private static let roomyWindow = inputTokens + allowedSummaryTokens + ReasoningControl.thinkingAllowance + 500

    /// A window whose room after the input holds the summary, and less than
    /// the summary and the thinking allowance.
    private static let tightWindow = inputTokens + allowedSummaryTokens + 100

    /// A window whose room after the input is smaller than the summary.
    private static let crampedWindow = inputTokens + allowedSummaryTokens - 50

    /// A call with ``inputTokens`` of input and ``allowedSummaryTokens`` of summary.
    private static let call = CompactionCall(
        id: "thinking-allowance", transcript: Transcript(entries: []), promptName: CompactionPrompt.default.name,
        prompt: "", inputTokens: inputTokens, allowedSummaryTokens: allowedSummaryTokens, tokensBefore: 0,
        instructions: [], keptEntries: [], protectedTokens: 0, pendingRuns: [])

    /// A slot of `tier` over a summarizer that records its calls.
    private static func slot(
        _ tier: CompactionSummarizerTier, window: Int, control: ReasoningControl
    ) -> CompactionSummarizerSlot {
        CompactionSummarizerSlot(
            tier: tier, summarizer: RecordingSummarizer(summary: "summary"), windowTokens: window, model: nil,
            reasoningControl: control)
    }

    @Test("a switchable summarizer's ceiling is the allowed summary size", arguments: Self.tiers)
    func switchableCeilingIsTheSummarySize(tier: CompactionSummarizerTier) {
        let slot = Self.slot(tier, window: Self.roomyWindow, control: .switchable)

        #expect(Self.call.outputCeiling(for: slot) == Self.allowedSummaryTokens)
    }

    @Test("a summarizer with no reasoning control gets the allowed summary size", arguments: Self.tiers)
    func noControlCeilingIsTheSummarySize(tier: CompactionSummarizerTier) {
        let slot = Self.slot(tier, window: Self.roomyWindow, control: .none)

        #expect(Self.call.outputCeiling(for: slot) == Self.allowedSummaryTokens)
    }

    @Test("an always-reasoning summarizer's ceiling adds the thinking allowance", arguments: Self.tiers)
    func alwaysOnCeilingAddsTheThinkingAllowance(tier: CompactionSummarizerTier) {
        let slot = Self.slot(tier, window: Self.roomyWindow, control: .alwaysOn)

        #expect(Self.call.outputCeiling(for: slot) == Self.allowedSummaryTokens + ReasoningControl.thinkingAllowance)
    }

    @Test("the room the window leaves caps an always-reasoning ceiling", arguments: Self.tiers)
    func roomCapsTheAlwaysOnCeiling(tier: CompactionSummarizerTier) {
        let slot = Self.slot(tier, window: Self.tightWindow, control: .alwaysOn)

        #expect(Self.call.outputCeiling(for: slot) == Self.tightWindow - Self.inputTokens)
    }

    @Test("an always-reasoning flash tier does not run when the room is under the summary size")
    func alwaysOnFlashNeedsRoomForTheSummary() {
        let slot = Self.slot(.flash, window: Self.crampedWindow, control: .alwaysOn)

        #expect(Self.call.outputCeiling(for: slot) == nil)
    }

    @Test("an always-reasoning own model runs in the room that is left under the summary size")
    func alwaysOnOwnModelRunsInTheRoomLeft() {
        let slot = Self.slot(.ownModel, window: Self.crampedWindow, control: .alwaysOn)

        #expect(Self.call.outputCeiling(for: slot) == Self.crampedWindow - Self.inputTokens)
    }
}

/// The reasoning token limit of the first pass of a recovery.
@Suite("A recovery asks a switchable model for reasoning off, and gives an always-reasoning model a thinking budget")
struct RecoveryFirstPassTests {
    @Test("a switchable model's recovery runs its first pass with the reasoning off")
    func switchableTurnsReasoningOff() {
        #expect(RecoveryFirstPass(control: .switchable) == .reasoningOff)
    }

    @Test("a model with no reasoning control keeps the request for reasoning off")
    func noControlKeepsTheRequest() {
        #expect(RecoveryFirstPass(control: .none) == .reasoningOff)
    }

    @Test("an always-reasoning model's recovery reasons under the thinking allowance")
    func alwaysOnGetsTheThinkingBudget() {
        #expect(
            RecoveryFirstPass(control: .alwaysOn)
                == .thinkingBudget(reasoningTokenLimit: ReasoningControl.thinkingAllowance))
    }
}

/// The detector applies a reasoning limit of the first pass to the reasoning
/// before the first tool call of the attempt, and the limit of the session
/// after it.
@Suite("The detector applies the first-pass reasoning limit until the first tool call")
struct FirstPassReasoningLimitTests {
    /// The limit of the session in this suite, in tokens.
    private static let sessionLimit = 1_000

    /// The first-pass limit of this suite, in tokens.
    private static let firstPassLimit = 100

    /// A line of 49 characters, with its line feed 50 tokens.
    private static let line = "The model reads one more part of the parser code."

    /// A text of complete lines whose tokens reach ``firstPassLimit``.
    private static var textAtFirstPassLimit: String {
        String(repeating: line + "\n", count: firstPassLimit / (line.count + 1))
    }

    /// A detector with ``sessionLimit`` and ``firstPassLimit``, and a window
    /// that no test fills.
    private static func makeDetector() -> RepetitionDetector {
        RepetitionDetector(
            detection: RepetitionDetection(windowTokens: .max, reasoningTokenLimit: sessionLimit),
            tokenCounter: CharacterTokenCounter(), firstPassReasoningTokenLimit: firstPassLimit)
    }

    @Test("the reasoning of the first pass stops at the first-pass limit")
    func firstPassReasoningStopsAtTheFirstPassLimit() {
        var detector = Self.makeDetector()

        _ = detector.observe([WatchedText(entryId: "r", text: Self.textAtFirstPassLimit, isReasoning: true)])

        let expected = ReasoningLimitFinding(reasoningTokens: Self.firstPassLimit, limit: Self.firstPassLimit)
        #expect(detector.reasoningLimitFinding() == expected)
    }

    @Test("the reasoning after a tool call is under the session limit")
    func reasoningAfterAToolCallIsUnderTheSessionLimit() {
        var detector = Self.makeDetector()

        _ = detector.observe([
            WatchedText(entryId: "r1", text: Self.line + "\n", isReasoning: true),
            WatchedText(entryId: "c", text: "", isToolCalls: true),
            WatchedText(entryId: "r2", text: Self.textAtFirstPassLimit, isReasoning: true),
        ])

        #expect(detector.reasoningLimitFinding() == nil)
    }
}

/// The recovery of an always-reasoning model, end to end over a scripted model.
@Suite("The recovery of an always-reasoning model reasons under the thinking allowance")
struct AlwaysReasoningRecoveryTests {
    /// The suite's temp-directory prefix.
    private static let tempDirPrefix = "AlwaysReasoningRecoveryTests"

    /// The prompt of every answer of this suite.
    private static let prompt = "fix the failing test"

    /// Runs one streamed answer over an always-reasoning ``StagedReasoningModel``.
    /// The caller ends the fixture.
    ///
    /// - Parameters:
    ///   - scripts: The script of each call, in call order.
    ///   - detection: The repetition detection of the session.
    /// - Returns: The fixture and the events of the answer, in order.
    private static func runAlwaysOnAnswer(
        scripts: [RepeatingReasoningScript], detection: RepetitionDetection = RepetitionDetection()
    ) async throws -> (fixture: StagedReasoningSessionFixture, events: [SessionEvent]) {
        try await StagedReasoningSessionFixture.answer(
            to: prompt, scripts: scripts, detection: detection, reasoningControl: .alwaysOn,
            tempDirPrefix: tempDirPrefix)
    }

    @Test("a recovery stops the reasoning of an always-reasoning model at the thinking allowance")
    func recoveryReasonsUnderTheThinkingAllowance() async throws {
        let (fixture, events) = try await Self.runAlwaysOnAnswer(scripts: [
            .reasoningHeldAtLimit(), .reasoningHeldAtLimit(ReasoningControl.thinkingAllowance),
        ])
        defer { await fixture.end() }

        #expect(
            events.reasoningStops.map(\.limit)
                == [RepetitionDetection.defaultReasoningTokenLimit, ReasoningControl.thinkingAllowance])
    }

    @Test("a recovery of an always-reasoning model does not ask for reasoning off")
    func recoveryDoesNotAskForReasoningOff() async throws {
        let (fixture, _) = try await Self.runAlwaysOnAnswer(scripts: [
            .reasoningHeldAtLimit(), .reasoningHeldAtLimit(ReasoningControl.thinkingAllowance),
        ])
        defer { await fixture.end() }

        #expect(fixture.log.reasoningLevels == [nil, nil, nil])
    }

    @Test("the final pass of an always-reasoning model reasons under the thinking allowance")
    func finalPassReasonsUnderTheThinkingAllowance() async throws {
        let (fixture, events) = try await Self.runAlwaysOnAnswer(
            scripts: [.reasoningHeldAtLimit(), .reasoningHeldAtLimit(ReasoningControl.thinkingAllowance)],
            detection: RepetitionDetection(recoveriesPerAnswer: 0))
        defer { await fixture.end() }

        #expect(
            events.reasoningStops.map(\.limit)
                == [RepetitionDetection.defaultReasoningTokenLimit, ReasoningControl.thinkingAllowance])
    }
}
