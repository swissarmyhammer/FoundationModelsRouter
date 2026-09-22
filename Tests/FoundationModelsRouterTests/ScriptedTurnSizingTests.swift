import FoundationModelsRouterRealModelSupport
import FoundationModelsRouterTestSupport
import Testing

@testable import FoundationModelsRouter

/// Ungated proof that ``CompactionRoundTripFixture``'s scripted turns are
/// still sized to reach the 0.80 compaction trigger the gated
/// `CompactionRoundTripIntegrationTests` waits on (tasks 5m97h14 and
/// ^wnj3ka3).
///
/// The gated suite is the real end-to-end proof, but it only runs with the
/// real-model target selected and a GPU present, so nothing under a plain
/// `swift test` noticed when its fixtures were less than half the size the
/// trigger needs — that suite's own doc comment claimed "a handful of
/// scripted turns crosses the 0.80 compaction trigger" and a live run measured
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
struct ScriptedTurnSizingTests {
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
    /// turns on the gated run of task ^wnj3ka3.
    private static let measuredRealTokens = 1496

    /// The characters the scripted turns held at the time of that
    /// measurement: the eight turns the fixture had before task ^wnj3ka3
    /// added two more. ``counter`` counts those eight turns as this many
    /// tokens.
    private static let measuredCharacters = 7338

    /// What one character of scripted prose is worth in tokens the model
    /// really counts: ``measuredRealTokens`` over ``measuredCharacters``,
    /// about 0.204. The gated model's own tokenizer reads the English prose
    /// of the scripted turns at about 4.9 characters for each token.
    private static let realTokensPerCharacter = Double(measuredRealTokens) / Double(measuredCharacters)

    /// The tokens a live run measures on top of the scripted prompt text.
    ///
    /// Measured usage covers the whole rendered conversation, not the prompts
    /// alone: the instructions entry, the chat template's own tokens for each
    /// message, and the reply of the turn that was just made. The replies add
    /// almost nothing, because ``CompactionRoundTripFixture/replyMaxTokens``
    /// is small and this model spends that budget on a `<think>` block the
    /// template does not carry forward. Measured on the gated run of the
    /// scripted turns: 1633 tokens against 1496 real prompt tokens.
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

    /// The tokens a live run is expected to measure once every scripted turn
    /// has run: the prompt text converted out of its character count, plus
    /// the overhead every live turn carries.
    ///
    /// The gated loop stops at the first turn that crosses the trigger, so it
    /// normally measures less than this. This is the figure both bounds below
    /// are stated against, because both are about the fixture as a whole.
    private static var predictedLiveTokens: Int {
        measuredTokens(forCharacters: perTurnCharacters.reduce(0, +)) + liveOverheadTokens
    }

    /// How many of the newest turns the deterministic stages must leave
    /// untouched — read off ``TurnTruncation``'s own default rather than
    /// restated, so this suite tracks the stage it reasons about.
    private static var keepRecentTurns: Int {
        TurnTruncation().keepRecentTurns
    }

    /// The character count of each scripted turn's prompt text, in order.
    private static var perTurnCharacters: [Int] {
        CompactionRoundTripFixture.scriptedTurns.map { counter.count($0) }
    }

    @Test("the scripted turns carry the live run past the 0.80 trigger, with margin")
    func scriptedTurnsReachTheTriggerWithMargin() throws {
        // The lower bound of the band the fixture must sit in. Stated in
        // measured tokens, and with a margin, because the uncalibrated
        // estimate of that time cleared the trigger on a fixture the live run
        // left below it — the whole defect of task ^wnj3ka3.
        let required = Int(Double(Self.triggerTokens) * Self.triggerClearance)
        #expect(
            Self.predictedLiveTokens > required,
            "the scripted turns predict \(Self.predictedLiveTokens) measured tokens, which does not clear the trigger's \(Self.triggerTokens) by \(Self.triggerClearance)"
        )
    }

    @Test("the whole fixture still fits the working context, so no scripted turn can die of overflow")
    func theWholeFixtureFitsTheWorkingContext() throws {
        // The upper bound of the same band. The gated loop stops at the first
        // turn that crosses the trigger, so it normally never submits the last
        // turn — but a run that needs every turn must still fit the window, or
        // that turn fails instead of compaction. Bounding the whole fixture
        // subsumes the crossing-prefix bound this replaces, because a prefix is
        // never larger than the whole.
        #expect(
            Self.predictedLiveTokens <= CompactionRoundTripFixture.context,
            "the scripted turns predict \(Self.predictedLiveTokens) measured tokens, over the \(CompactionRoundTripFixture.context)-token working context"
        )
    }

    // MARK: - The compaction reaches the model-assisted stage by construction (task f80n046)

    @Test("no window of consecutive scripted turns fits under the compaction target, so the deterministic stages alone can never land it")
    func recencyWindowCannotFitUnderTheCompactionTarget() throws {
        // `TurnTruncation` keeps the newest `keepRecentTurns` turns verbatim
        // and `ToolOutputElision` touches nothing here (these turns call no
        // tools), so the deterministic pipeline's floor is that window. When
        // the window cannot fit under target, the pipeline must fall through
        // to `Summarization` — which is the only stage that synthesizes the
        // summary entry the gated suite's step 4 restores.
        //
        // Which four turns the window holds depends on how many turns the live
        // run needed to cross the trigger, so every consecutive window is
        // checked rather than only the last. Prompt text alone, converted to
        // the tokens the live run measures: the window also carries the
        // replies and the header, which only add.
        let targetTokens = CompactionRoundTripFixture.compactionBudget.targetTokens
        let keepRecentTurns = Self.keepRecentTurns
        let turns = CompactionRoundTripFixture.scriptedTurns
        #expect(turns.count > keepRecentTurns)
        for start in 0...(turns.count - keepRecentTurns) {
            let window = turns[start..<(start + keepRecentTurns)]
            let windowTokens = Self.measuredTokens(forCharacters: Self.counter.count(window.joined()))
            #expect(
                windowTokens > targetTokens,
                "turns \(start)..<\(start + keepRecentTurns) predict \(windowTokens) measured prompt tokens, which does not exceed the compaction target's \(targetTokens)"
            )
        }
    }

    @Test("the first turns cannot cross the trigger before some turn falls outside the recency window, so a compaction always has an old span to summarize")
    func triggerIsNotReachedBeforeAnOldSpanExists() throws {
        // The other half of the same property: `Summarization` returns `nil`
        // — and the pipeline reports the oversized-tail shortfall with an
        // empty `stagesApplied` — when every turn is still inside the recency
        // window. So the trigger must not be reachable within the first
        // `keepRecentTurns` turns.
        //
        // Worst case, and mechanical: every one of those turns' replies runs
        // to the full `replyMaxTokens` ceiling, and the header's instructions
        // count too. The prompt text and the header are converted to the
        // tokens the live run measures; the reply ceiling is already in them.
        let keepRecentTurns = Self.keepRecentTurns
        let firstTurns = CompactionRoundTripFixture.scriptedTurns.prefix(keepRecentTurns)
        let promptTokens = Self.measuredTokens(forCharacters: Self.counter.count(firstTurns.joined()))
        let replyTokens = keepRecentTurns * CompactionRoundTripFixture.replyMaxTokens
        let headerTokens = Self.measuredTokens(
            forCharacters: Self.counter.count(CompactionRoundTripFixture.instructions))
        let worstCase = promptTokens + replyTokens + headerTokens
        #expect(
            worstCase < Self.triggerTokens,
            "the first \(keepRecentTurns) turns reach \(worstCase) tokens at their largest, at or over the trigger's \(Self.triggerTokens) — the compaction could find no turn outside the recency window to summarize"
        )
    }
}
