import Foundation
import FoundationModels
import FoundationModelsRouterTestSupport
import Testing

@testable import FoundationModelsRouter

// MARK: - Model

/// The real `mlx-community` model this suite folds against, and deliberately
/// NOT ``RealModels/standard``.
///
/// ``RealModels/standard`` is `Muse-Glimmer-30B-4bit`, 18 GB of weights. Its
/// load alone costs more than this suite's whole budget, which is why this
/// suite names a model of its own instead of the target's slot roster.
///
/// `Llama-3.2-1B-Instruct-4bit` is 680 MB on disk and is a real instruct model,
/// not a toy: it follows the compaction prompt's own section structure and it
/// writes a real summary. It was chosen over the other small models already in
/// the Hugging Face cache on two properties. It is the smallest cached model
/// that is still an instruct model — `SmolLM-135M-Instruct-4bit` is smaller and
/// too small to follow an eight-section instruction. And it writes NO `<think>`
/// block, which is the whole reason ``Summarization/reasoningTokenHeadroom``
/// defaults to 4096; `Qwen3-1.7B-4bit` is comparable in size and was rejected
/// because it reasons.
private let compactionSmokeModel: ModelRef = "mlx-community/Llama-3.2-1B-Instruct-4bit"

/// The working context this suite loads ``compactionSmokeModel`` at.
///
/// Deliberately smaller than ``RealModels/context`` (8192). The largest call
/// this suite makes is one summarizer call: the compaction prompt, the folded
/// span, and the generation ceiling below. That fits well inside this window,
/// and a smaller window costs less to allocate.
private let compactionSmokeContext = 4096

/// The decoding this suite loads ``compactionSmokeModel`` with.
///
/// Pinned to argmax, for the reason ``CompactionRoundTripIntegrationTests``
/// pins it: the provider default samples from MLX's process-global PRNG, which
/// seeds itself from the clock, so the summary — and therefore the fold
/// arithmetic this suite asserts on — would differ on every run of identical
/// code. Argmax decoding consumes no randomness, which is what lets a red run
/// here be attributed to the change under test, and it is why the three runs
/// tabulated on the suite below reported identical fold numbers.
private let compactionSmokeSamplingMode: GenerationOptions.SamplingMode = .greedy

/// The wall-clock bound this suite runs under, in minutes.
///
/// Stated as a constant so the number carries its measurement. See the suite's
/// own doc comment for the measured run behind it.
private let compactionSmokeTimeLimitMinutes = 1

// MARK: - Suite

/// The fast answer to one question: does the compaction path work end to end
/// against a real model?
///
/// ## What this suite proves, and what it does not
///
/// It proves the PATH WORKS. Five facts, and no more:
///
/// 1. The summarizer was called — exactly once, which is also this suite's
///    generation budget.
/// 2. It answered with text that is not empty (`^bgxtdk3` stored an empty
///    summary on 19 of 19 gated seeds).
/// 3. The summary is smaller than the span it replaced, in the estimated
///    tokens ``Compactor``'s did-not-shrink guard itself measures.
/// 4. The fold was APPLIED — ``CompactionResult/stagesApplied`` ends with
///    ``Summarization/stageName``, rather than the shortfall exit that
///    discarded 7 of 7 gated folds in `^fm5ddk9`.
/// 5. ``CompactionResult/tokensAfter`` is under
///    ``CompactionResult/tokensBefore``.
///
/// It proves one more, added by `^azd033m`: a fact stated at the very END of
/// the folded span is still in the summary the fold stores. That is one fact,
/// on one fixture, against one small model, and it is deliberately narrow — it
/// is a REGRESSION check on the way this fold was measured losing facts, not a
/// recall score. The bound the stage applies to a summarizer's answer keeps a
/// PREFIX of it, so it drops what the model wrote last, and nothing but a
/// planted late fact catches that. Whether a fold keeps the facts a resumed
/// session needs IN GENERAL is still what `FoundationModelsRouterEvals`
/// measures, over a hand-written dataset, against the 30B model, in tens of
/// minutes. That tier stays where it is. This suite exists because that tier
/// answers one bit for 28 minutes, and a broken summarizer, an empty answer, a
/// discarded fold, and now a fold that dropped the fact it existed to carry are
/// all things a few seconds of real model can rule out.
///
/// ## How it stays fast
///
/// Four budget decisions, and each one is a property this suite asserts or a
/// constant that states its own reason:
///
/// - ``compactionSmokeModel`` rather than the 18 GB ``RealModels/standard``.
/// - One fixture, not a dataset.
/// - ONE generation: ``Compactor/compact(_:prompt:budget:summarizer:summarization:pendingRuns:)``
///   and nothing after it. No resumed session and no answering turn — that is a
///   second generation, and "works at all" does not need one.
/// - ``reasoningTokenHeadroom``, sized for a model that writes no reasoning,
///   rather than the 4096 the 30B path needs.
///
/// ## The measurement behind ``compactionSmokeTimeLimitMinutes``
///
/// Measured on 2026-08-18, on an Apple silicon box with the model already in
/// the Hugging Face cache. Three consecutive runs, each printing its own
/// numbers through the test body:
///
/// | run | wall clock | of which model load | whole `swift test` command |
/// |---|---|---|---|
/// | 1 | 4.1 s | 2.0 s | 16.3 s |
/// | 2 | 4.0 s | 1.9 s | 10.4 s |
/// | 3 | 4.1 s | 2.0 s | 10.2 s |
///
/// All three reported identical fold numbers, which is
/// ``compactionSmokeSamplingMode`` doing its job. Those three runs predate the
/// planted fact, so the fixture is a little larger now and the suite folds it
/// twice, once per test; the same box then reported 4.1 s per fold and 6.3 s
/// for the pair, of which 2.0 s is each fold's model load.
///
/// The fold numbers moved twice, both times on `^azd033m`, and both are worth
/// keeping because they are what the two bounds cost:
///
/// | the fold | answer | stored summary | transcript |
/// |---|---|---|---|
/// | cut at `summaryTokenRatio` of the content | 330 | 160 | 713 -> 230 |
/// | cut at `summaryRetentionRatio` of it | 330 | 330 | 713 -> 400 |
///
/// Both rows are one summarizer call at a ceiling of 291 over a 643-token span,
/// and both shrank the transcript, so `Compactor` applied either. The first row
/// discarded half of what the model wrote — including the fact planted at the
/// end of the span, which is why the second test below exists.
///
/// The smoke tier is what those numbers rest on: this suite,
/// ``AutoCompactionTriggerIntegrationTests`` and
/// ``RecordedTranscriptCompactionIntegrationTests``. All three answer one
/// question — does compaction work at all against a real model — and all
/// three answer it in seconds. Measured under the variable this tier used to
/// read: the whole package, this suite's real model included, in 18.0
/// seconds.
///
/// The limit is one minute, roughly nine times the measured run of the pair and
/// the smallest `.timeLimit` Swift Testing accepts.
@Suite(
    "Real-model smoke test: the compaction fold works end to end (task ^w1cz46m)",
    .timeLimit(.minutes(compactionSmokeTimeLimitMinutes)),
    .exclusiveRealModel
)
struct CompactionSmokeIntegrationTests {
    // MARK: - Fold tuning

    /// The tokens every summarizer call of this suite is given on top of its
    /// summary allowance, and deliberately not ``Summarization``'s own default
    /// of 4096.
    ///
    /// That default is sized for a model that always writes a `<think>` block
    /// before its answer — `Tests/FoundationModelsRouterTestSupport/GatedRealModelBudget.swift`
    /// records that measurement. ``compactionSmokeModel`` writes no such block,
    /// so almost all of that headroom would be a ceiling no generation ever
    /// reaches.
    ///
    /// Cutting it does two things this suite wants. It bounds the worst-case
    /// generation, which is the one unbounded cost in the run. And it makes the
    /// fold arithmetic hold BY CONSTRUCTION rather than by the model's good
    /// behaviour: the ceiling is a hard stop on the whole generation, so the
    /// largest summary this suite can be handed is `summaryAllowance + this`,
    /// whatever the model chooses to write.
    ///
    /// The measurement says the model really does write to that stop, so the
    /// worst case is the case. ``Summarization`` computes a ceiling of 291
    /// tokens over this fixture, and the answer that comes back measures 330
    /// estimated tokens against the 643-token span it replaces.
    ///
    /// That answer is what gets STORED, whole.
    /// ``Summarization/cut(_:toCharacters:)`` bounds it at
    /// ``Summarization/summaryRetentionRatio`` of the call's content, which
    /// this answer is well inside, so the fold keeps every word of it and still
    /// halves the transcript. So this headroom bounds what the run can COST,
    /// and the shrinking is the model's own compression rather than a cut's.
    ///
    /// Not zero, so a summary has a little room to finish its last sentence
    /// inside the ceiling rather than always ending at it.
    private static let reasoningTokenHeadroom = 128

    /// The tag every printed line of this suite's fold carries.
    private static let foldLabel = "compactionSmoke"

    // MARK: - The fixture

    /// The system instructions the fixture transcript's header carries. No
    /// compaction stage may touch the header.
    private static let instructions = "You are a terse, literal assistant."

    /// The reply text every scripted turn carries.
    ///
    /// Short on purpose. The fixture's size has to sit in the PROMPTS, because
    /// this suite builds the transcript itself rather than generating it: a
    /// long scripted reply would inflate the folded span without making the
    /// fixture any more like a real conversation.
    private static let scriptedReply = "Acknowledged."

    /// The distinctive value planted at the very END of the folded span, and
    /// the one thing ``aPlantedFactLateInTheSpanSurvivesTheFold`` reads the
    /// summary for.
    ///
    /// A coined proper noun rather than a phrase, because the assertion has to
    /// be exact: a paraphrase of a phrase still passes a substring check by
    /// accident, and a name the model did not carry cannot.
    ///
    /// A proper noun rather than an alphanumeric identifier, and that choice is
    /// measured. The first version of this fixture planted the release ticket
    /// `REL-8842`. ``compactionSmokeModel`` reproduced the SENTENCE — "the
    /// cut-over is authorised by exactly one release ticket" — and dropped the
    /// identifier, exactly as it dropped every other value in the span. A 1B
    /// model paraphrases values and copies names, so an identifier would have
    /// made this test measure the model's weakness rather than the fold's.
    private static let plantedFactValue = "Kestrel"

    /// The sentence carrying ``plantedFactValue``, appended as the last thing
    /// the folded span says.
    ///
    /// Its position is the whole point. A cut that keeps a PREFIX of the
    /// model's answer drops what the model wrote LAST, and a model writes
    /// about a span in the order the span states it, so the last fact stated
    /// is the first one such a cut loses.
    private static let plantedFact = """
        Cut-over for every station is authorised by the \(plantedFactValue) board and by nobody else, and the \
        comparison job refuses to run for a station the \(plantedFactValue) board has not approved.
        """

    /// The scripted prompts, oldest first — the fixture's whole size budget.
    ///
    /// The shape is deliberate and the arithmetic is what makes this suite
    /// fast and its fold certain.
    ///
    /// The first two turns are long, and they are the FOLDED SPAN:
    /// ``Summarization/keepRecentTurns`` defaults to 4, so with six turns the
    /// oldest two are what the fold replaces. They are sized to two properties
    /// at once.
    ///
    /// - Under ``Summarization/maxChunkTokens`` (2000 estimated tokens), so the
    ///   span is ONE chunk and the fold costs ONE generation. The test asserts
    ///   that count, so the fixture cannot grow past it in silence.
    /// - Large enough that the fold cannot fail to shrink the transcript.
    ///   Since `^azd033m` ``Summarization`` CUTS an answer that overruns the
    ///   share of its content it may retain, rather than asking the model for a
    ///   length, so a span this size cannot buy a summary that fails
    ///   ``Compactor``'s did-not-shrink guard. Measured over this fixture: a
    ///   643-token span bought a ceiling of 291, the answer came back at 330
    ///   estimated tokens — inside the bound, so stored whole — and the whole
    ///   transcript went from 713 tokens to 400. `^fm5ddk9` measured the 30B
    ///   model writing summaries 1.30x to 2.07x the size of the spans it was
    ///   given, and `Compactor` was right to discard all seven; the cut puts
    ///   that outcome out of reach for a span this size.
    ///
    /// The second turn ends with ``plantedFact``, which is the whole fixture
    /// for ``aPlantedFactLateInTheSpanSurvivesTheFold``.
    ///
    /// The last four turns are short. They are the recency window, which no
    /// stage may touch, and their only job is to exist — the deterministic
    /// floor the fold target is derived from is the header plus this window.
    private static let scriptedPrompts: [String] = [
        """
        Project brief. We are replacing the ingest path for the station archive. The present path reads each
        station file end to end, parses every row into a record, and writes the whole batch to the index in one
        transaction, which means a single malformed row fails a file that is otherwise sound and leaves the
        index holding nothing from it. The replacement streams each file, parses row by row, and commits in
        bounded batches, so a malformed row costs its own batch and no more. Rows the parser rejects are
        written to a rejects file beside the index, with the source path, the row number, and the reason,
        rather than dropped. The rejects file is read by hand, not by a tool, because every rejection so far
        has needed a person to decide whether the row was mistyped at the source or mistranscribed later, and
        no rule we have written separates those two. Batch size is a setting rather than a constant, because
        the right size differs by an order of magnitude between the small station files and the two large ones,
        and a single value that suits both does not exist. The index format itself does not change, so a reader
        built against the present path keeps working against the replacement without an edit.
        """,
        """
        Migration plan. The two paths run side by side for one release. The new path writes to an index under a
        separate directory, the old path keeps writing where it always has, and a comparison job reads both and
        reports every station whose record counts, date ranges, or checksums differ. The comparison runs
        nightly and its report is kept, so a difference that appears once and goes away is still visible
        afterwards rather than lost. We cut over a station at a time rather than all at once, oldest station
        first, because the oldest files exercise the widest range of formats and a failure there is the one we
        most want to see early. A station is cut over only after seven consecutive clean comparison reports,
        and cutting over means the old path stops writing that station rather than that its old index is
        removed; the old index stays until the release after, so a rollback is a configuration change and not a
        restore. The comparison job is the piece with no fallback: if it cannot read either index it reports a
        failure rather than an empty difference, because an empty difference and an unread index look identical
        on the report and only one of them means the two paths agree. \(plantedFact)
        """,
        "Summarize the batch-size decision in one line.",
        "Name the file rejected rows are written to.",
        "State how many clean reports a station needs before cut-over.",
        "State what a rollback costs after cut-over.",
    ]

    // MARK: - Fixture construction

    /// Builds the fixture transcript: the header, then one turn per entry of
    /// ``scriptedPrompts``, each a `.prompt` and a `.response`.
    ///
    /// - Returns: The transcript to fold.
    private static func makeTranscript() -> Transcript {
        var entries: [Transcript.Entry] = [
            .instructions(
                Transcript.Instructions(
                    id: "instr-1",
                    segments: [.text(Transcript.TextSegment(id: "instr-1-text", content: instructions))],
                    toolDefinitions: []
                )
            )
        ]
        for (index, prompt) in scriptedPrompts.enumerated() {
            entries.append(
                .prompt(
                    Transcript.Prompt(
                        id: "prompt-\(index)",
                        segments: [.text(Transcript.TextSegment(id: "prompt-\(index)-text", content: prompt))]
                    )
                )
            )
            entries.append(
                .response(
                    Transcript.Response(
                        id: "response-\(index)",
                        segments: [
                            .text(Transcript.TextSegment(id: "response-\(index)-text", content: scriptedReply))
                        ]
                    )
                )
            )
        }
        return Transcript(entries: entries)
    }

    // MARK: - One folded run

    /// Loads the smoke model, folds the fixture once through ``CompactionFold``,
    /// evicts the model, and puts this suite's own wall clock on the record — so
    /// a red run states what it went red on rather than only which assertion
    /// failed.
    ///
    /// Everything after the load is ``CompactionFold``'s, which prints the fold
    /// numbers themselves. This function owns the model's lifetime because it is
    /// the only thing that knows this suite loads once per test.
    ///
    /// - Returns: Everything the run measured.
    /// - Throws: Whatever the load or the fold throws.
    private static func foldTheFixture() async throws -> CompactionFoldOutcome {
        let startedAt = Date()
        var modelLoadSeconds = 0.0
        defer {
            print(
                "[\(foldLabel)] wallClockSeconds=\(String(format: "%.1f", Date().timeIntervalSince(startedAt))) "
                    + "modelLoadSeconds=\(String(format: "%.1f", modelLoadSeconds))"
            )
        }

        let loadStartedAt = Date()
        let container = try await RealModelContainer.load(
            ref: compactionSmokeModel,
            context: compactionSmokeContext,
            samplingMode: compactionSmokeSamplingMode
        )
        modelLoadSeconds = Date().timeIntervalSince(loadStartedAt)

        let outcome = try await CompactionFold.run(
            makeTranscript(),
            summarization: Summarization(reasoningTokenHeadroom: reasoningTokenHeadroom),
            container: container,
            label: foldLabel
        )
        await container.model.evict()
        return outcome
    }

    // MARK: - The tests

    @Test(
        "one fold against a real model: the summarizer runs once, answers with text, and the fold is applied rather than discarded"
    )
    func theFoldWorksAgainstARealModel() async throws {
        let outcome = try await Self.foldTheFixture()
        let result = outcome.result
        let ceilings = outcome.ceilings
        let spanTokens = outcome.spanTokens

        // 1. The summarizer ran — and exactly once, which is this suite's whole
        //    generation budget. A fixture that grew past
        //    `Summarization.maxChunkTokens` would buy a second call and a
        //    reduce round, and would fail here rather than merely get slower.
        #expect(
            ceilings.count == 1,
            "expected exactly one summarizer call, got \(ceilings.count) at ceilings \(ceilings)"
        )

        // 2. It answered with text. `^bgxtdk3` was an empty summary on 19 of 19
        //    gated seeds, and an empty summary erases the span it replaced.
        let summary = try #require(
            result.summary, "the fold was discarded, so there is no summary to read — see stages above")
        #expect(
            !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            "the summarizer answered with no text"
        )

        // 3. The summary is smaller than the span it replaced, in the unit
        //    `Compactor`'s did-not-shrink guard measures. `^fm5ddk9` measured
        //    the 30B model at 1.30x to 2.07x here.
        let summaryTokens = Compactor.estimatedTokenCount(of: summary)
        #expect(
            summaryTokens < spanTokens,
            "the summary estimates \(summaryTokens) tokens against the \(spanTokens)-token span it replaced"
        )

        // 4. The fold was APPLIED. An empty `stagesApplied` is `Compactor`'s
        //    shortfall exit, which returns the ORIGINAL transcript — the exit
        //    7 of 7 gated seeds took in `^fm5ddk9` while still reporting a
        //    summarizer call.
        #expect(
            result.stagesApplied.last == Summarization.stageName,
            "expected the fold to be applied, got stages \(result.stagesApplied)"
        )

        // 5. The returned result shrank.
        #expect(
            result.tokensAfter < result.tokensBefore,
            "tokensAfter \(result.tokensAfter) did not fall under tokensBefore \(result.tokensBefore)"
        )
    }

    @Test("a fact planted at the very end of the folded span is still in the summary the fold stores")
    func aPlantedFactLateInTheSpanSurvivesTheFold() async throws {
        // The property a fold exists for. Shrinking a transcript is the cost a
        // fold pays; carrying the facts forward is what it is paid FOR, and a
        // fold that shrank the transcript and dropped the fact has not worked.
        //
        // `^azd033m` measured the way that failure arrives. The bound the stage
        // applies to a summarizer's answer keeps a PREFIX of it, so it is
        // content-blind: it keeps what the model said first and drops what it
        // said last. On this fixture it cut a 330-token answer to 160 tokens —
        // half of the answer discarded — and `plantedFact` stands at the very
        // end of the span, which is where a prefix cut takes its loss. The
        // model DID name the fact, twice; the fold stored neither mention.
        let outcome = try await Self.foldTheFixture()
        let summary = try #require(
            outcome.result.summary, "the fold was discarded, so there is no summary to read")

        #expect(
            summary.contains(Self.plantedFactValue),
            """
            the fold dropped \(Self.plantedFactValue), stated last in the span it replaced.
            answer \(outcome.answerTokens) estimated tokens, stored summary \
            \(Compactor.estimatedTokenCount(of: summary)), span \(outcome.spanTokens).
            the answer the model gave was:
            \(outcome.calls.map(\.answer).joined(separator: "\n---\n"))
            the summary the fold stored was:
            \(summary)
            """
        )
    }
}
