import FoundationModelsRouterRealModelSupport
import FoundationModelsRouterTestSupport
import Testing

@testable import FoundationModelsRouter

/// Ungated proof that ``CompactionRoundTripFixture``'s scripted answers are
/// still sized to reach the 0.80 compaction trigger the gated
/// `CompactionRoundTripIntegrationTests` waits on (tasks 5m97h14 and
/// ^wnj3ka3).
///
/// The gated suite is the real end-to-end proof, but it only runs with the
/// real-model target selected and a GPU present, so nothing under a plain
/// `swift test` noticed when its fixtures were less than half the size the
/// trigger needs — that suite's own doc comment claimed "a handful of
/// scripted answers crosses the 0.80 compaction trigger" and a live run measured
/// a `contextFill` of 0.41 against a 0.80 trigger. These assertions are
/// mechanical, need no model, and fail loudly if the fixtures shrink or grow
/// out of range again — which is why they live in this hermetic target, where
/// every root `swift test` run measures them (task
/// ^cvsh3m9).
///
/// They are stated in the token count a live run MEASURES, not in the
/// character count of the prompts. That difference is what this suite missed
/// the second time: the fixture cleared the trigger by 12 % in the
/// character-ratio estimate the library counted with at that time, and the
/// live run still stopped at a `contextFill` of 0.797, because that estimate
/// counted about 1.23 tokens for each token the model's own tokenizer counts.
/// That estimate is gone. This suite counts the prompts in characters with
/// ``CharacterTokenCounter`` and converts the count with a ratio it measured
/// itself. See ``realTokensPerCharacter``.
@Suite("CompactionRoundTripFixture sizing (ungated)")
struct ScriptedAnswerSizingTests {
    /// The counter this suite counts the scripted prompts with: one token per
    /// `Character`, so each count below is a character count.
    private static let counter = CharacterTokenCounter()

    /// The measured usage, in tokens, the gated suite's loop waits to see —
    /// ``CompactionRoundTripFixture/context`` at the default
    /// ``TokenBudget/trigger``, which is the same threshold that suite's
    /// `fillBeforeCompaction >= 0.80` assertion checks.
    private static var triggerTokens: Int {
        TokenBudget(limit: CompactionRoundTripFixture.context).triggerTokens
    }

    /// The tokens the gated model's own tokenizer counted for the scripted
    /// answers on the gated run of task ^wnj3ka3.
    private static let measuredRealTokens = 1496

    /// The characters the scripted answers held at the time of that
    /// measurement: the eight answers the fixture had before task ^wnj3ka3
    /// added two more. ``counter`` counts those eight answers as this many
    /// tokens.
    private static let measuredCharacters = 7338

    /// What one character of scripted prose is worth in tokens the model
    /// really counts: ``measuredRealTokens`` over ``measuredCharacters``,
    /// about 0.204. The gated model's own tokenizer reads the English prose
    /// of the scripted answers at about 4.9 characters for each token.
    private static let realTokensPerCharacter = Double(measuredRealTokens) / Double(measuredCharacters)

    /// The tokens a live run measures on top of the scripted prompt text.
    ///
    /// Measured usage covers the whole rendered conversation, not the prompts
    /// alone: the instructions entry, the chat template's own tokens for each
    /// message, and the reply of the answer that was just made. The replies add
    /// almost nothing, because ``CompactionRoundTripFixture/replyMaxTokens``
    /// is small and this model spends that budget on a `<think>` block the
    /// template does not carry forward. Measured on the gated run of the
    /// scripted answers: 1633 tokens against 1496 real prompt tokens.
    private static let liveOverheadTokens = 137

    /// How far past the trigger the fixture must carry the live run.
    ///
    /// The fixture missed the trigger by 5 tokens once (task ^wnj3ka3). A
    /// tenth of the trigger is 164 tokens, which no small change in how the
    /// model replies can give back.
    private static let triggerClearance = 1.10

    /// The tokens a live run measures for `characters` of scripted prose,
    /// converted with ``realTokensPerCharacter``.
    ///
    /// - Parameter characters: The character count of the prose.
    /// - Returns: The tokens the model's own tokenizer reads that prose as.
    private static func measuredTokens(forCharacters characters: Int) -> Int {
        Int(Double(characters) * realTokensPerCharacter)
    }

    /// The tokens a live run is expected to measure once every scripted answer
    /// has run: the prompt text converted out of its character count, plus
    /// the overhead every live answer carries.
    ///
    /// The gated loop stops at the first answer that crosses the trigger, so it
    /// normally measures less than this. This is the figure both bounds below
    /// are stated against, because both are about the fixture as a whole.
    private static var predictedLiveTokens: Int {
        measuredTokens(forCharacters: perAnswerCharacters.reduce(0, +)) + liveOverheadTokens
    }

    /// The character count of each scripted answer's prompt text, in order.
    private static var perAnswerCharacters: [Int] {
        CompactionRoundTripFixture.scriptedAnswers.map { counter.count($0) }
    }

    @Test("the scripted answers carry the live run past the 0.80 trigger, with margin")
    func scriptedAnswersReachTheTriggerWithMargin() throws {
        // The lower bound of the band the fixture must sit in. Stated in
        // measured tokens, and with a margin, because the uncalibrated
        // estimate of that time cleared the trigger on a fixture the live run
        // left below it — the whole defect of task ^wnj3ka3.
        let required = Int(Double(Self.triggerTokens) * Self.triggerClearance)
        #expect(
            Self.predictedLiveTokens > required,
            "the scripted answers predict \(Self.predictedLiveTokens) measured tokens, which does not clear the trigger's \(Self.triggerTokens) by \(Self.triggerClearance)"
        )
    }

    @Test("the whole fixture still fits the working context, so no scripted answer can die of overflow")
    func theWholeFixtureFitsTheWorkingContext() throws {
        // The upper bound of the same band. The gated loop stops at the first
        // answer that crosses the trigger, so it normally never submits the last
        // answer — but a run that needs every answer must still fit the window,
        // or that answer fails instead of compaction. Bounding the whole fixture
        // subsumes the crossing-prefix bound this replaces, because a prefix is
        // never larger than the whole.
        #expect(
            Self.predictedLiveTokens <= CompactionRoundTripFixture.context,
            "the scripted answers predict \(Self.predictedLiveTokens) measured tokens, over the \(CompactionRoundTripFixture.context)-token working context"
        )
    }

    // MARK: - The compaction makes its summarizer call by construction

    @Test("the compaction target leaves room for a summary after the instructions, so the compaction makes its one call")
    func compactionTargetLeavesRoomForASummary() throws {
        // The one call gets the room the target leaves after the
        // instructions, which the new snapshot keeps word for word. When the
        // instructions alone fill the target, the compaction makes no call
        // and writes no summary entry for the gated suite's step 4 to restore.
        let targetTokens = CompactionRoundTripFixture.compactionBudget.targetTokens
        let instructionsTokens = Self.measuredTokens(
            forCharacters: Self.counter.count(CompactionRoundTripFixture.instructions))
        #expect(
            targetTokens > instructionsTokens,
            "the instructions predict \(instructionsTokens) measured tokens, which fill the compaction target's \(targetTokens)"
        )
    }
}
