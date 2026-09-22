import Foundation
import FoundationModels
import FoundationModelsRouterTestSupport
import Testing

@testable import FoundationModelsRouter

/// The counter every size in this file is measured with: one token per
/// `Character`, the same rule `SummarizationStageTests.swift` measures with.
private let counter = CharacterTokenCounter()

/// The second part of ``SummarizationStageTests``: the reasoning headroom of a
/// summarizer call, the cases where ``Summarization`` does no work or fails,
/// and ``Summarization`` wired into `Compactor.compact` as the final stage.
///
/// The suite is one type in two files. Each file stays under the size the
/// review engine can read in one prompt. The shared scripted summarizers and
/// expected-size helpers are in `SummarizationStageTests.swift`.
extension SummarizationStageTests {
    // MARK: - Reasoning headroom: a call's ceiling holds the think block as well as the answer

    @Test(
        "a summarizer call is given the reasoning headroom on top of its summary allowance, so a model that thinks before it answers still reaches the answer"
    )
    func summarizerCallCarriesReasoningHeadroomAboveItsSummaryAllowance() async throws {
        let instructions = TranscriptFixtures.makeInstructions()
        let bigText = String(repeating: "old span content ", count: 400)
        let turns = try (1...5).map {
            try TranscriptFixtures.makeTurn(index: $0, promptText: bigText, toolOutputText: bigText, responseText: bigText)
        }
        let transcript = Transcript(entries: [instructions] + turns.flatMap { $0 })

        let summarizer = ScriptedSummarizer(responses: ["summary"])
        let stage = Summarization(keepRecentTurns: 4, maxChunkTokens: 1_000_000)

        _ = try await stage.apply(
            transcript,
            prompt: .default,
            tokensBefore: try counter.count(transcript),
            priorStagesApplied: [],
            summarizer: summarizer,
            counter: counter
        )

        let ceiling = try #require(summarizer.receivedMaxTokens.first)
        let condensed = try Self.condensedContent(of: try #require(summarizer.receivedPrompts.first))
        let allowance = Self.expectedSummaryAllowance(
            condensing: condensed, ratio: stage.summaryTokenRatio, maxChunkTokens: stage.maxChunkTokens)
        // The two amounts are separate, and the ceiling is their sum: the ratio
        // sizes the summary text, and the headroom pays for the reasoning a
        // model writes before that text starts.
        #expect(ceiling == allowance + stage.reasoningTokenHeadroom)
        #expect(ceiling > allowance)
    }

    @Test("a non-default reasoningTokenHeadroom reaches the ceiling every summarizer call is given")
    func nonDefaultReasoningHeadroomReachesTheSummarizerCall() async throws {
        let instructions = TranscriptFixtures.makeInstructions()
        let turns = try TranscriptFixtures.makeTurns(5)
        let transcript = Transcript(entries: [instructions] + turns.flatMap { $0 })

        let summarizer = ScriptedSummarizer(responses: ["summary"])
        let headroom = 777
        let stage = Summarization(keepRecentTurns: 4, maxChunkTokens: 1_000_000, reasoningTokenHeadroom: headroom)

        _ = try await stage.apply(
            transcript,
            prompt: .default,
            tokensBefore: try counter.count(transcript),
            priorStagesApplied: [],
            summarizer: summarizer,
            counter: counter
        )

        // This span is small enough that the floor decides the allowance, so
        // the number the summarizer was handed states the headroom exactly.
        #expect(summarizer.receivedMaxTokens == [Summarization.minimumSummaryTokens + headroom])
    }

    @Test("the default reasoning headroom is at least the ceiling this repository measured a reasoning turn needs")
    func defaultReasoningHeadroomMeetsTheMeasuredCeiling() {
        // `GatedRealModelBudget` records the measurement: the gated model always
        // writes a `<think>` block first, a ceiling of 512 leaves its answer
        // empty, and 4096 does not. A summarizer call is one such turn, so its
        // headroom may never be smaller than the value that measurement names.
        #expect(Summarization().reasoningTokenHeadroom >= GatedRealModelBudget.responseTokenCeiling)
    }

    // MARK: - Nothing to compact: Summarization is a no-op (Compactor's fallback path)

    @Test("when every turn is inside the recency window, there is no old span to compact: Summarization returns nil")
    func nothingToCompactReturnsNil() async throws {
        let instructions = TranscriptFixtures.makeInstructions()
        let turns = try TranscriptFixtures.makeTurns(2)
        let transcript = Transcript(entries: [instructions] + turns.flatMap { $0 })

        let summarizer = ScriptedSummarizer(responses: [])
        let stage = Summarization(keepRecentTurns: 4, maxChunkTokens: 1_000_000)

        let compacted = try await stage.apply(
            transcript,
            prompt: .default,
            tokensBefore: try counter.count(transcript),
            priorStagesApplied: [],
            summarizer: summarizer,
            counter: counter
        )

        #expect(compacted == nil)
        #expect(summarizer.receivedPrompts.isEmpty)
    }

    // MARK: - Summarizer failure propagates

    @Test("a throwing summarizer's error propagates out of Summarization.apply rather than being swallowed")
    func summarizerFailurePropagates() async throws {
        let instructions = TranscriptFixtures.makeInstructions()
        let turns = try TranscriptFixtures.makeTurns(6)
        let transcript = Transcript(entries: [instructions] + turns.flatMap { $0 })

        let stage = Summarization(keepRecentTurns: 4, maxChunkTokens: 1_000_000)

        await #expect(throws: ThrowingSummarizer.Failure.self) {
            _ = try await stage.apply(
                transcript,
                prompt: .default,
                tokensBefore: try counter.count(transcript),
                priorStagesApplied: [],
                summarizer: ThrowingSummarizer(),
                counter: counter
            )
        }
    }

    // MARK: - An empty summarizer answer is a compaction failure

    @Test("a summarizer answer with no text is reported as a compaction failure, never stored as the compaction's summary")
    func emptySummarizerAnswerIsReported() async throws {
        let instructions = TranscriptFixtures.makeInstructions()
        let turns = try TranscriptFixtures.makeTurns(6)
        let transcript = Transcript(entries: [instructions] + turns.flatMap { $0 })

        let summarizer = ScriptedSummarizer(responses: [""])
        let stage = Summarization(keepRecentTurns: 4, maxChunkTokens: 1_000_000)

        await #expect(throws: SummarizationError.emptySummary) {
            _ = try await stage.apply(
                transcript,
                prompt: .default,
                tokensBefore: try counter.count(transcript),
                priorStagesApplied: [],
                summarizer: summarizer,
                counter: counter
            )
        }
    }

    @Test("a summarizer answer of whitespace alone is reported the same way: it carries no summary either")
    func whitespaceOnlySummarizerAnswerIsReported() async throws {
        let instructions = TranscriptFixtures.makeInstructions()
        let turns = try TranscriptFixtures.makeTurns(6)
        let transcript = Transcript(entries: [instructions] + turns.flatMap { $0 })

        let summarizer = ScriptedSummarizer(responses: ["  \n\t  "])
        let stage = Summarization(keepRecentTurns: 4, maxChunkTokens: 1_000_000)

        await #expect(throws: SummarizationError.emptySummary) {
            _ = try await stage.apply(
                transcript,
                prompt: .default,
                tokensBefore: try counter.count(transcript),
                priorStagesApplied: [],
                summarizer: summarizer,
                counter: counter
            )
        }
    }

    @Test("an empty answer from the reduce round is reported too, so every call of a chunked compaction is checked")
    func emptyReduceRoundAnswerIsReported() async throws {
        let instructions = TranscriptFixtures.makeInstructions()
        let turns = try (1...6).map { try TranscriptFixtures.makeTurn(index: $0, toolOutputText: "result-\($0)") }
        let transcript = Transcript(entries: [instructions] + turns.flatMap { $0 })

        // One old turn per chunk (as `longSpanMapReducesAcrossChunks` sets up):
        // 2 map calls that answer, then 1 reduce call that answers nothing.
        let oneTurnTokens = try counter.count(Transcript(entries: turns[0]))
        let summarizer = ScriptedSummarizer(responses: ["chunk-summary-A", "chunk-summary-B", ""])
        let stage = Summarization(keepRecentTurns: 4, maxChunkTokens: oneTurnTokens)

        await #expect(throws: SummarizationError.emptySummary) {
            _ = try await stage.apply(
                transcript,
                prompt: .default,
                tokensBefore: try counter.count(transcript),
                priorStagesApplied: [],
                summarizer: summarizer,
                counter: counter
            )
        }
        #expect(summarizer.receivedPrompts.count == 3)
    }

    // MARK: - Compactor-level integration: Summarization wired in as the final stage

    /// How many turns ``makeModelAssistedCompactionFixture()`` builds.
    private static let compactionFixtureTurnCount = 6

    /// How many times each of a fixture turn's three text fields repeats its
    /// content phrase — large enough that one turn on its own exceeds
    /// ``Summarization/maxChunkTokens``'s default, so the default chunking
    /// gives each old turn a summarizer call of its own.
    private static let compactionFixtureRepeatsPerTurn = 400

    /// The context-window size ``makeModelAssistedCompactionFixture()``'s budget is
    /// stated against — far larger than the fixture, so the target fraction
    /// alone decides what the pipeline has to do.
    private static let compactionFixtureBudgetLimit = 1_000_000

    /// The fraction of ``compactionFixtureBudgetLimit`` a compaction is triggered at —
    /// irrelevant to these tests, which call `compact` directly rather than
    /// wait for a trigger, but a ``TokenBudget`` requires one.
    private static let compactionFixtureTrigger = 0.80

    /// The fixture the `Compactor.compact` tests below share: a header, six
    /// turns whose content is far too large for the deterministic stages to
    /// land, and a budget whose target sits below even their best effort — so
    /// the pipeline always falls through to ``Summarization``.
    ///
    /// Each turn's text names its own index, so a test can tell from a
    /// summarizer's assembled prompt which turns the compaction condensed.
    ///
    /// - Returns: The turns in order, the transcript over them, and the budget
    ///   to compact it against.
    private static func makeModelAssistedCompactionFixture() throws -> (
        turns: [[Transcript.Entry]], transcript: Transcript, budget: TokenBudget
    ) {
        try makeSizedCompactionFixture(phrase: "large content", repeatsPerText: compactionFixtureRepeatsPerTurn)
    }

    /// The one construction every sized compaction fixture here shares: a header,
    /// ``compactionFixtureTurnCount`` turns whose three text fields each repeat
    /// `"<phrase> turn-<index> "` `repeatsPerText` times, and the usual
    /// compaction-forcing budget. The phrase names the fixture in a summarizer's
    /// assembled prompt, and the repeat count sets the span's size.
    ///
    /// - Parameters:
    ///   - phrase: The text each turn's fields open with.
    ///   - repeatsPerText: How many times each field repeats its phrase.
    /// - Returns: The turns in order, the transcript over them, and the budget
    ///   to compact it against.
    /// - Throws: Whatever the fixture construction throws.
    private static func makeSizedCompactionFixture(phrase: String, repeatsPerText: Int) throws -> (
        turns: [[Transcript.Entry]], transcript: Transcript, budget: TokenBudget
    ) {
        let instructions = TranscriptFixtures.makeInstructions()
        let turns = try (1...compactionFixtureTurnCount).map { index -> [Transcript.Entry] in
            let text = String(repeating: "\(phrase) turn-\(index) ", count: repeatsPerText)
            return try TranscriptFixtures.makeTurn(
                index: index, promptText: text, toolOutputText: text, responseText: text)
        }
        let transcript = Transcript(entries: [instructions] + turns.flatMap { $0 })
        let budget = try makeCompactionForcingBudget(for: transcript)
        return (turns, transcript, budget)
    }

    /// The small-span fixture the last-resort cut is exercised over through
    /// `Compactor.compact`: a header, six SMALL turns, and the same budget
    /// every fixture here uses.
    ///
    /// Small on purpose: the span's token budget sits far under every scripted
    /// answer, and under the ``Summarization/minimumSummaryTokens`` floor's
    /// own size, so a compaction of this span can only shrink through the recovery
    /// ladder — and the ladder's last step, the cut, is what the tests over
    /// this fixture observe.
    ///
    /// - Returns: The turns in order, the transcript over them, and the budget
    ///   to compact it against.
    /// - Throws: Whatever the fixture construction throws.
    private static func makeSmallSpanCompactionFixture() throws -> (
        turns: [[Transcript.Entry]], transcript: Transcript, budget: TokenBudget
    ) {
        let turns = try TranscriptFixtures.makeTurns(compactionFixtureTurnCount)
        let transcript = Transcript(entries: [TranscriptFixtures.makeInstructions()] + turns.flatMap { $0 })
        let budget = try makeCompactionForcingBudget(for: transcript)
        return (turns, transcript, budget)
    }

    /// The budget that forces `transcript` all the way through to
    /// ``Summarization``: a target at half of what ``ToolOutputElision`` and
    /// ``TurnTruncation`` reach between them, which neither of them can land
    /// under.
    ///
    /// - Parameter transcript: The transcript the target is measured against.
    /// - Returns: The budget to compact it with.
    /// - Throws: What the counter throws.
    private static func makeCompactionForcingBudget(for transcript: Transcript) throws -> TokenBudget {
        let afterBoth = try counter.count(TurnTruncation().apply(ToolOutputElision().apply(transcript)))
        let targetShareOfDeterministicFloor = 2
        return TokenBudget(
            limit: compactionFixtureBudgetLimit,
            trigger: compactionFixtureTrigger,
            target: Double(afterBoth / targetShareOfDeterministicFloor) / Double(compactionFixtureBudgetLimit)
        )
    }

    // MARK: - Background-runs compaction fixtures (task ^64f3hnv)

    /// How many runs ``makeBackgroundRuns()`` tracks — the shape task ^64f3hnv
    /// measured: ten runs with an eight-byte op and no progress render 973
    /// bytes, a cost the compaction pays per run rather than per span token.
    private static let backgroundRunCount = 10

    /// How many times each text field of a ``makeBackgroundRunsCompactionFixture()``
    /// turn repeats its phrase — sized so the compacted span comes to about
    /// 1,180 tokens: under the stage's default ``Summarization/maxChunkTokens``,
    /// so one call condenses it; larger than the ten background runs'
    /// rendering; and close enough to it that the rendering eats most of the
    /// margin between the two.
    private static let backgroundRunsFixtureRepeatsPerText = 10

    /// How many times each text field of an
    /// ``makeOverwhelmedSpanCompactionFixture()`` turn repeats its phrase — sized so
    /// the span's tokens stay UNDER the background runs' rendering plus the
    /// shrink margin, which drives the span token budget to zero or below: the
    /// geometry where no summary of any length can make the compaction shrink, and
    /// only the did-not-shrink guard can answer.
    private static let overwhelmedSpanRepeatsPerText = 8

    /// How many times the background-runs tests' scripted answer repeats its
    /// phrase — far past every retention bound in these fixtures, so the cut
    /// always runs.
    private static let backgroundRunsAnswerRepeats = 200

    /// Background-run summaries in the shape task ^64f3hnv measured:
    /// ``backgroundRunCount`` runs, each with a 26-character completion token, an
    /// eight-byte op, and no progress reported yet.
    ///
    /// - Returns: The background runs, in tracking order.
    private static func makeBackgroundRuns() -> [CompactionSegment.PendingRunSummary] {
        (1...backgroundRunCount).map { index in
            CompactionSegment.PendingRunSummary(
                completionToken: String(format: "01ARZ3NDEKTSV4RRFFQ69G5F%02d", index),
                op: "run tool",
                latestProgressDetail: nil
            )
        }
    }

    /// The fixture `aCompactionWithBackgroundRunsOverAModestSpanIsStillApplied` compactions: a
    /// header, six MODEST turns, and the usual compaction-forcing budget. Modest is
    /// the point — the span is small enough that the background runs' rendering
    /// spends most of the retention margin, and large enough that a summary cut
    /// down for that rendering still shrinks the transcript.
    ///
    /// - Returns: The turns in order, the transcript over them, and the budget
    ///   to compact it against.
    /// - Throws: Whatever the fixture construction throws.
    private static func makeBackgroundRunsCompactionFixture() throws -> (
        turns: [[Transcript.Entry]], transcript: Transcript, budget: TokenBudget
    ) {
        try makeSizedCompactionFixture(phrase: "modest span", repeatsPerText: backgroundRunsFixtureRepeatsPerText)
    }

    /// The fixture whose span the background runs' rendering overwhelms: the
    /// rendering alone reaches the retention bound, so the span token budget
    /// is zero or below. A cut that (wrongly) emptied the summary to fit that
    /// budget would store a boundary entry that carries no text at all.
    ///
    /// - Returns: The turns in order, the transcript over them, and the budget
    ///   to compact it against.
    /// - Throws: Whatever the fixture construction throws.
    private static func makeOverwhelmedSpanCompactionFixture() throws -> (
        turns: [[Transcript.Entry]], transcript: Transcript, budget: TokenBudget
    ) {
        try makeSizedCompactionFixture(phrase: "tiny span", repeatsPerText: overwhelmedSpanRepeatsPerText)
    }

    @Test("Compactor.compact wires Summarization in as the final stage when the deterministic stages alone aren't enough")
    func compactorWiresInSummarizationAsFinalStage() async throws {
        let (turns, transcript, budget) = try Self.makeModelAssistedCompactionFixture()
        let tokensBefore = try counter.count(transcript)

        // The two old turns' content comfortably exceeds Summarization's
        // default maxChunkTokens (2000), so each becomes its own chunk: 2 map
        // calls, then 1 reduce call over their summaries — the reduce call's
        // result is what CompactionResult.summary carries.
        let summarizer = ScriptedSummarizer(responses: ["chunk-summary-1", "chunk-summary-2", "end-to-end summary"])
        let (resultTranscript, result) = try await Compactor.compact(
            transcript, budget: budget, counter: counter, summarizer: summarizer)

        #expect(result.stagesApplied == ["ToolOutputElision", "TurnTruncation", "Summarization"])
        #expect(result.summary == "end-to-end summary")
        #expect(result.tokensBefore == tokensBefore)

        let entries = Array(resultTranscript)
        #expect(entries.first == TranscriptFixtures.makeInstructions())
        guard case .response(let response) = entries[1], case .structure(let segment) = response.segments.last,
            let compaction = try CompactionSegment(structuredSegment: segment)
        else {
            Issue.record("expected the compacted transcript's second entry to carry a CompactionSegment")
            return
        }
        #expect(compaction.content.promptName == CompactionPrompt.default.name)
        let expectedRecentTail = turns.suffix(4).flatMap { $0 }
        #expect(Array(entries.suffix(expectedRecentTail.count)) == expectedRecentTail)
    }

    @Test("Compactor.compact with no summarizer degrades to the deterministic stages: no Summarization, no summary")
    func compactorWithNoSummarizerDegradesToModelFreePipeline() async throws {
        let instructions = TranscriptFixtures.makeInstructions()
        let bigText = String(repeating: "big ", count: 2000)
        let turns = try (1...2).map {
            try TranscriptFixtures.makeTurn(index: $0, promptText: bigText, toolOutputText: bigText, responseText: bigText)
        }
        let transcript = Transcript(entries: [instructions] + turns.flatMap { $0 })

        let tokensBefore = try counter.count(transcript)
        let limit = 1_000_000
        let budget = TokenBudget(limit: limit, trigger: 0.80, target: Double(tokensBefore / 2) / Double(limit))

        let (resultTranscript, result) = try await Compactor.compact(transcript, budget: budget, counter: counter)

        #expect(resultTranscript == transcript)
        #expect(result.stagesApplied.isEmpty)
        #expect(result.summary == nil)
    }

    @Test(
        "a compaction of a span smaller than every answer is still applied: the last-resort cut bounds the summary under the span, and the result records the cut"
    )
    func compactReportsTheLastResortCut() async throws {
        // The trim fires only when the compaction would otherwise fail to shrink,
        // and the report records when it fires (task ^xx02yn6). A span this
        // small earns a token budget far under every candidate answer, so the
        // recovery ladder runs to its last step and `CompactionResult` says
        // so.
        let (turns, transcript, budget) = try Self.makeSmallSpanCompactionFixture()
        let tokensBefore = try counter.count(transcript)
        let oldTurns = Array(turns.prefix(Self.compactionFixtureTurnCount - Summarization().keepRecentTurns))
        let summarizer = OversizedSummarizer(summary: String(repeating: "verbose summary ", count: tokensBefore))
        let spanBudget = try Self.expectedSummaryTokenBudget(compactingOld: oldTurns)
        #expect(counter.count(summarizer.summary) > spanBudget)  // sanity: every answer overruns

        let (_, result) = try await Compactor.compact(transcript, budget: budget, counter: counter, summarizer: summarizer)

        #expect(result.stagesApplied.last == Summarization.stageName)
        #expect(result.tokensAfter < tokensBefore)
        #expect(result.summaryCut)
        let summary = try #require(result.summary)
        #expect(summarizer.summary.hasPrefix(summary))
        #expect(counter.count(summary) <= spanBudget)
    }

    @Test("a result that recorded the last-resort cut keeps it through the summarizer-model naming copy")
    func withSummarizerModelKeepsTheRecordedCut() {
        let result = CompactionResult(
            summary: "cut summary", summaryCut: true, tokensBefore: 100, tokensAfter: 50,
            stagesApplied: [Summarization.stageName])
        #expect(result.withSummarizerModel("mlx-community/example").summaryCut)
    }

    @Test(
        "a compaction whose summarizer ignored every ceiling is applied rather than discarded, because the recovery ladder brought the summary under the span"
    )
    func aCompactionWhoseSummaryOverranItsAllowanceIsStillApplied() async throws {
        // This is what enforcing the bound in code buys. `^fm5ddk9` measured 7
        // of 7 gated seeds answering 1.30x to 2.07x the size of the span they
        // were condensing, so `Compactor` discarded 7 of 7 compactions and the eval
        // measured nothing about compaction at all. An answer of that shape now
        // compacts, and the guard below it is untouched — it stays the backstop
        // for the compaction no cut can save.
        let (_, transcript, budget) = try Self.makeModelAssistedCompactionFixture()
        let tokensBefore = try counter.count(transcript)
        let summarizer = OversizedSummarizer(summary: String(repeating: "verbose summary ", count: tokensBefore))
        // sanity: the raw answer really would have grown the transcript
        #expect(counter.count(summarizer.summary) > tokensBefore)

        let (_, result) = try await Compactor.compact(transcript, budget: budget, counter: counter, summarizer: summarizer)

        #expect(result.stagesApplied == ["ToolOutputElision", "TurnTruncation", "Summarization"])
        #expect(result.tokensAfter < tokensBefore)
        #expect(result.summaryCut)
        let summary = try #require(result.summary)
        #expect(summarizer.summary.hasPrefix(summary))
    }

    @Test(
        "a compaction over a modest span with background runs is applied: the cut leaves room for the pending-runs rendering the boundary entry carries"
    )
    func aCompactionWithBackgroundRunsOverAModestSpanIsStillApplied() async throws {
        // The shape task ^64f3hnv measured. The per-call cut bounds the summary
        // TEXT, the did-not-shrink guard measures the whole replacement ENTRY,
        // and the boundary entry carries the pending-runs rendering as a second
        // .text segment. On a modest span the rendering alone used to spend the
        // retention margin, so the compaction was discarded whatever the summary said
        // — and a session that tracks background runs is the case the rendering
        // exists for. The cut now charges the rendering against the bound.
        let (turns, transcript, budget) = try Self.makeBackgroundRunsCompactionFixture()
        let tokensBefore = try counter.count(transcript)
        let pendingRuns = Self.makeBackgroundRuns()
        let rendering = CompactionSegment.renderedPendingRuns(pendingRuns)
        let renderingTokens = counter.count(rendering)
        let spanEntries = turns.prefix(Self.compactionFixtureTurnCount - Summarization().keepRecentTurns).flatMap { $0 }
        let spanTokens = try counter.count(Transcript(entries: spanEntries))

        let answer = String(repeating: "verbose summary ", count: Self.backgroundRunsAnswerRepeats)
        let summarizer = ScriptedSummarizer(responses: [answer, answer])
        let (_, result) = try await Compactor.compact(
            transcript, budget: budget, counter: counter, summarizer: summarizer, pendingRuns: pendingRuns)

        // The scenario really is the defect's shape, in the guard's own
        // units: the rendering leaves room under the span token budget, and
        // every candidate answer overruns what is left, so only the recovery
        // ladder's cut can save the compaction.
        let spanBudget = try Self.expectedSummaryTokenBudget(
            compactingOld: [spanEntries], renderingTokens: renderingTokens)
        #expect(spanBudget > 0)
        #expect(counter.count(answer) > spanBudget)
        #expect(renderingTokens < spanTokens)

        // Applied, not discarded: the whole entry stays under the span.
        #expect(result.stagesApplied.last == Summarization.stageName)
        #expect(result.tokensBefore == tokensBefore)
        #expect(result.tokensAfter < tokensBefore)
        #expect(result.summaryCut)

        // What the compaction stored is a prefix of the answer, and the stored
        // summary plus the rendering stay under the span.
        let summary = try #require(result.summary)
        #expect(answer.hasPrefix(summary))
        #expect(counter.count(summary) + renderingTokens < spanTokens)

        // Control: the same compaction with no background runs is applied too, so the
        // pending-runs rendering is the one variable in this scenario.
        let controlSummarizer = ScriptedSummarizer(responses: [answer, answer])
        let (_, control) = try await Compactor.compact(
            transcript, budget: budget, counter: counter, summarizer: controlSummarizer)
        #expect(control.stagesApplied.last == Summarization.stageName)
        #expect(control.tokensAfter < tokensBefore)
    }

    @Test(
        "a compaction whose background runs' rendering alone spends the span token budget is discarded whole — never applied with an emptied summary"
    )
    func aCompactionWhosePendingRunsRenderingAloneReachesTheBoundIsDiscarded() async throws {
        // Below this bound no summary of any length can pay for the rendering,
        // so the safe answer is the guard's: discard the compaction and return the
        // original transcript. The dangerous wrong answer is a cut that empties
        // the summary to make the arithmetic work, so that the compaction would
        // be applied carrying no summary text at all.
        let (turns, transcript, budget) = try Self.makeOverwhelmedSpanCompactionFixture()
        let tokensBefore = try counter.count(transcript)
        let pendingRuns = Self.makeBackgroundRuns()
        let rendering = CompactionSegment.renderedPendingRuns(pendingRuns)
        let renderingTokens = counter.count(rendering)
        let spanEntries = turns.prefix(Self.compactionFixtureTurnCount - Summarization().keepRecentTurns).flatMap { $0 }
        let spanTokens = try counter.count(Transcript(entries: spanEntries))

        let answer = String(repeating: "verbose summary ", count: Self.backgroundRunsAnswerRepeats)
        let summarizer = ScriptedSummarizer(responses: [answer])
        let (resultTranscript, result) = try await Compactor.compact(
            transcript, budget: budget, counter: counter, summarizer: summarizer, pendingRuns: pendingRuns)

        // The geometry: the rendering alone drives the span token budget to
        // zero or below, so no summary of any length can make the compaction
        // shrink, and no condense pass is worth a generation.
        let spanBudget = try Self.expectedSummaryTokenBudget(
            compactingOld: [spanEntries], renderingTokens: renderingTokens)
        #expect(spanBudget <= 0)
        #expect(renderingTokens > 0)
        #expect(spanTokens > 0)

        // One summarizer call only: a budget at or under zero earns no
        // condense pass, because no rewrite of any length could fit it.
        #expect(summarizer.receivedPrompts.count == 1)

        // Discarded whole, exactly like every other compaction that cannot shrink.
        #expect(resultTranscript == transcript)
        #expect(result.stagesApplied.isEmpty)
        #expect(result.summary == nil)
        #expect(result.tokensBefore == tokensBefore)
        #expect(result.tokensAfter == tokensBefore)
    }

    @Test("Compactor.compact reports an empty summary rather than apply a compaction whose boundary would carry no text")
    func compactorReportsAnEmptySummaryRatherThanApplyIt() async throws {
        // The same fixture `compactorWiresInSummarizationAsFinalStage` compacts,
        // differing only in what the summarizer answers: nothing at all.
        let (_, transcript, budget) = try Self.makeModelAssistedCompactionFixture()
        let summarizer = ScriptedSummarizer(responses: [""])

        await #expect(throws: SummarizationError.emptySummary) {
            _ = try await Compactor.compact(transcript, budget: budget, counter: counter, summarizer: summarizer)
        }
    }

    @Test("a supplied summarizer is never invoked when the deterministic stages alone already land under target")
    func summarizerNotInvokedWhenDeterministicStagesSuffice() async throws {
        let instructions = TranscriptFixtures.makeInstructions()
        let turns = try (1...6).map { try TranscriptFixtures.makeTurn(index: $0, toolOutputText: "small result") }
        let transcript = Transcript(entries: [instructions] + turns.flatMap { $0 })

        let tokensBefore = try counter.count(transcript)
        let limit = 1_000_000
        let budget = TokenBudget(limit: limit, trigger: 0.80, target: Double(tokensBefore * 2) / Double(limit))

        let summarizer = ScriptedSummarizer(responses: [])
        let (resultTranscript, result) = try await Compactor.compact(
            transcript, budget: budget, counter: counter, summarizer: summarizer)

        #expect(resultTranscript == transcript)
        #expect(result.stagesApplied.isEmpty)
        #expect(result.summary == nil)
        #expect(summarizer.receivedPrompts.isEmpty)
    }

    // MARK: - The stage's own tuning, set through Compactor.compact

    @Test("a non-default summaryTokenRatio set through Compactor.compact reaches the ceiling the summarizer call is given")
    func compactCarriesSummaryTokenRatioIntoTheSummarizerCall() async throws {
        let (_, transcript, budget) = try Self.makeModelAssistedCompactionFixture()
        let summarizer = ScriptedSummarizer(responses: [])
        let defaults = Summarization()
        let ratio = 0.5

        let (_, result) = try await Compactor.compact(
            transcript,
            budget: budget,
            counter: counter,
            summarizer: summarizer,
            summarization: Summarization(summaryTokenRatio: ratio)
        )

        #expect(result.stagesApplied.last == Summarization.stageName)

        // The first call is a map call over one whole old turn, whose content
        // is large enough that the ratio — not the minimumSummaryTokens floor —
        // decides the ceiling, so the knob is visible in the number the
        // summarizer was handed.
        let firstPrompt = try #require(summarizer.receivedPrompts.first)
        let firstContent = try Self.condensedContent(of: firstPrompt)
        let firstCeiling = try #require(summarizer.receivedMaxTokens.first)
        #expect(
            firstCeiling
                == Self.expectedCeiling(
                    condensing: firstContent,
                    ratio: ratio,
                    maxChunkTokens: defaults.maxChunkTokens,
                    headroom: defaults.reasoningTokenHeadroom))
        // And it is that knob, not the default, that produced it.
        #expect(
            firstCeiling
                != Self.expectedCeiling(
                    condensing: firstContent,
                    ratio: defaults.summaryTokenRatio,
                    maxChunkTokens: defaults.maxChunkTokens,
                    headroom: defaults.reasoningTokenHeadroom))
    }

    @Test("a non-default maxChunkTokens set through Compactor.compact reaches the compaction's map-reduce chunking")
    func compactCarriesMaxChunkTokensIntoTheChunking() async throws {
        let (_, transcript, budget) = try Self.makeModelAssistedCompactionFixture()
        let summarizer = ScriptedSummarizer(responses: ["one-shot summary"])

        let (_, result) = try await Compactor.compact(
            transcript,
            budget: budget,
            counter: counter,
            summarizer: summarizer,
            summarization: Summarization(maxChunkTokens: Self.wholeSpanChunkTokens)
        )

        // The default 2000 gives each of the two old turns a chunk of its own —
        // 2 map calls, then a reduce call over their summaries, as
        // `compactorWiresInSummarizationAsFinalStage` asserts. A ceiling wide
        // enough for the whole span condenses both turns in one call instead.
        #expect(summarizer.receivedPrompts.count == 1)
        let content = try Self.condensedContent(of: try #require(summarizer.receivedPrompts.first))
        #expect(content.contains("turn-1"))
        #expect(content.contains("turn-2"))
        #expect(result.summary == "one-shot summary")
    }

    @Test("a non-default keepRecentTurns set through Compactor.compact reaches the compaction's recency window")
    func compactCarriesKeepRecentTurnsIntoTheCompaction() async throws {
        let (turns, transcript, budget) = try Self.makeModelAssistedCompactionFixture()
        let summarizer = ScriptedSummarizer(responses: [])
        let keepRecentTurns = 2

        let (resultTranscript, _) = try await Compactor.compact(
            transcript,
            budget: budget,
            counter: counter,
            summarizer: summarizer,
            summarization: Summarization(keepRecentTurns: keepRecentTurns)
        )

        // The default 4 keeps turns 3...6 and compacts turns 1 and 2. A window of
        // 2 keeps only turns 5 and 6, so the tail the compaction left untouched is
        // shorter and turns 3 and 4 are inside the span the summarizer read.
        let expectedRecentTail = turns.suffix(keepRecentTurns).flatMap { $0 }
        let entries = Array(resultTranscript)
        #expect(Array(entries.suffix(expectedRecentTail.count)) == expectedRecentTail)
        // The header, the one synthesized summary entry, and that tail — and
        // nothing else. Counting the whole transcript is what makes the window
        // narrower rather than merely ending in the same turns: the default's
        // wider window would leave turns 3 and 4 in front of the tail here.
        #expect(entries.count == 1 + 1 + expectedRecentTail.count)
        #expect(summarizer.receivedPrompts.contains { $0.contains("turn-4") })
        #expect(!summarizer.receivedPrompts.contains { $0.contains("turn-5") })
    }
}
