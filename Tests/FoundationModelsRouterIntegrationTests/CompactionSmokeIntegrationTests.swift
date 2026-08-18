import Foundation
import FoundationModels
import FoundationModelsRouterTestSupport
import Testing

@testable import FoundationModelsRouter

// MARK: - Gate

/// The opt-in environment variable that enables the compaction smoke test, and
/// deliberately NOT `FM_ROUTER_INTEGRATION_TESTS`.
///
/// A separate variable is the whole point of this suite. Every other way to ask
/// whether compaction works against a real model is gated on
/// `FM_ROUTER_INTEGRATION_TESTS`, and setting that variable enables the
/// 15-to-30-minute suites of this target as well. This suite answers "does
/// compaction work at all" on its own, so it takes a gate of its own and drags
/// none of them in.
///
/// Read exactly as the other gates of this package are read — a file-scoped
/// constant, a `!= nil` lookup, and a suite-level `.enabled(if:)` trait — so
/// the package has one gating mechanism rather than two. Kept as its own
/// file-scoped constant rather than sharing another file's, because Swift's
/// top-level `private` is file-scoped, not target-scoped.
private let compactionSmokeEnvVar = "FM_ROUTER_COMPACTION_SMOKE"

private var compactionSmokeEnabled: Bool {
    ProcessInfo.processInfo.environment[compactionSmokeEnvVar] != nil
}

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

// MARK: - Summarizer

/// The summarizer this suite hands ``Compactor``: one blank-slate session per
/// call over the resident smoke model, and a record of every call made.
///
/// The blank slate matters for the same reason it does in production
/// (`RoutedSessionActorCompaction.swift`'s own summarizer): a fold's summarizer
/// call must not be added to an already-full transcript, must not write the
/// fold's own prompt into the real history, and must not leak one chunk into
/// the next.
///
/// The record is what lets this suite assert the summarizer ran at all, which
/// is one of the five facts it exists to prove. It keeps the generation ceiling
/// of each call rather than a bare count, so the count and the ceiling the fold
/// arithmetic produced are one measurement rather than two.
private actor CountingBlankSlateSummarizer: CompactionSummarizer {
    /// The resident smoke model each call opens its own session over.
    private let container: MLXFoundationModelsContainer

    /// One completed summarizer call.
    struct Call {
        /// The generation ceiling ``Summarization`` computed for this call.
        let ceiling: Int

        /// The text the model answered with, unchanged.
        let answer: String
    }

    /// Every call made, in call order — so `calls.count` is the number of
    /// generations this fold cost.
    ///
    /// The ANSWER is kept beside the ceiling, and not only the ceiling, because
    /// a fold that gets discarded returns no summary at all: the size the model
    /// really wrote is then readable nowhere else. That size is the one number
    /// that separates "the summarizer misbehaved" from "the guard is wrong",
    /// and `^azd033m` needed it.
    private(set) var calls: [Call] = []

    /// Creates a summarizer over `container`.
    ///
    /// - Parameter container: The resident smoke model to generate with.
    init(container: MLXFoundationModelsContainer) {
        self.container = container
    }

    /// Condenses `prompt` in one generation over a session that has seen
    /// nothing else.
    ///
    /// - Parameters:
    ///   - prompt: The assembled compaction instructions and content.
    ///   - maxTokens: The generation ceiling ``Summarization`` computed.
    /// - Returns: The model's answer, unchanged.
    /// - Throws: Whatever the backend throws.
    func summarize(_ prompt: String, maxTokens: Int) async throws -> String {
        let answer = try await container.makeSession(transcript: Transcript(entries: []))
            .respond(to: prompt, maxTokens: maxTokens)
        calls.append(Call(ceiling: maxTokens, answer: answer))
        return answer
    }
}

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
/// It does NOT measure fact retention, and nothing here should be read as
/// evidence about summary QUALITY. Whether a fold keeps the facts a resumed
/// session needs is what `FoundationModelsRouterEvals` measures, over a
/// hand-written dataset, against the 30B model, in tens of minutes. That tier
/// stays where it is. This suite exists because that tier answers one bit for
/// 28 minutes, and a broken summarizer, an empty answer, or a discarded fold
/// are all things a minute of real model can rule out.
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
/// ``compactionSmokeSamplingMode`` doing its job. `^azd033m` then moved them,
/// and the run above is the measurement it moved: one summarizer call at a
/// ceiling of 281 over a 600-token span, an answer of 332 estimated tokens cut
/// to a 136-token summary, and a transcript folded from 670 tokens to 206.
/// Before that card's `Summarization.cut(_:toCharacters:)` the same three runs
/// stored the answer whole, at 304 estimated tokens, and folded 670 to 374.
///
/// The gate is what those numbers rest on, and it was measured the same way.
/// `FM_ROUTER_COMPACTION_SMOKE=1 swift test`, with NO filter, ran the whole
/// package — 978 unit tests, 28 in this target, 58 evals — in 18.0 seconds,
/// this suite's real model included. Not one of the
/// `FM_ROUTER_INTEGRATION_TESTS` suites ran, which is the whole reason this
/// variable is not that one.
///
/// The limit is one minute, roughly fifteen times the measured run and the
/// smallest `.timeLimit` Swift Testing accepts.
@Suite(
    "Gated real-model smoke test: the compaction fold works end to end (task ^w1cz46m)",
    .timeLimit(.minutes(compactionSmokeTimeLimitMinutes)),
    .enabled(if: compactionSmokeEnabled),
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
    /// worst case is the case. Over three identical runs ``Summarization``
    /// computed a ceiling of 281 tokens, and the answer that came back measured
    /// 332 estimated tokens against the 600-token span it replaced.
    ///
    /// Since `^azd033m` that answer is no longer what gets STORED:
    /// ``Summarization/cut(_:toCharacters:)`` takes it down to the allowance
    /// the call earned, 136 estimated tokens, so the fold is now under a
    /// quarter of the span it stands in for. The margin here is the cut's, and
    /// the ceiling above it bounds what the run can COST rather than what it
    /// stores.
    ///
    /// Not zero, so a summary has a little room to finish its last sentence
    /// inside the ceiling rather than always ending at it.
    private static let reasoningTokenHeadroom = 128

    /// The scale ``makeBudget(forcingSummarizationOf:)`` states its fold target
    /// against.
    ///
    /// ``TokenBudget`` takes its target as a FRACTION of a limit, and this
    /// suite needs a target at a particular token COUNT read off the fixture.
    /// A large limit makes the fraction resolve back to that count exactly
    /// rather than to a rounding of it. Nothing else reads this limit:
    /// ``Compactor`` compares against ``TokenBudget/targetTokens`` alone.
    private static let budgetLimit = 1_000_000

    /// Where the fold target sits, as a share of what the deterministic stages
    /// can reach on their own.
    ///
    /// The target has one job here: be low enough that ``ToolOutputElision``
    /// and ``TurnTruncation`` cannot land the transcript under it, so the
    /// pipeline falls through to ``Summarization``. Half of the floor those two
    /// reach is unreachable by construction, whatever the fixture below grows
    /// or shrinks to — which is why the target is derived from the fixture
    /// rather than written down beside it.
    private static let foldTargetShareOfDeterministicFloor = 0.5

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
    ///   ``Summarization`` allows a call's summary a quarter of what it
    ///   condenses, and since `^azd033m` it CUTS the answer down to that
    ///   allowance rather than asking for it. Measured over this fixture: a
    ///   600-token span bought a ceiling of 281, the answer came back at 332
    ///   estimated tokens, the cut stored 136, and the whole transcript went
    ///   from 670 tokens to 206. `^fm5ddk9` measured the 30B model writing
    ///   summaries 1.30x to 2.07x the size of the spans it was given, and
    ///   `Compactor` was right to discard all seven; the cut puts that outcome
    ///   out of reach for a span this size.
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
        on the report and only one of them means the two paths agree.
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

    /// The budget that forces `transcript` all the way through the
    /// model-assisted stage.
    ///
    /// Derived from the transcript rather than written down: the target sits at
    /// ``foldTargetShareOfDeterministicFloor`` of what ``ToolOutputElision``
    /// and ``TurnTruncation`` reach between them, so neither of them can land
    /// the transcript under it and ``Compactor`` must fall through to
    /// ``Summarization``. A fixture that changes size carries its own budget
    /// with it.
    ///
    /// - Parameter transcript: The transcript the budget is measured against.
    /// - Returns: The budget to fold with.
    private static func makeBudget(forcingSummarizationOf transcript: Transcript) -> TokenBudget {
        let deterministicFloor = Compactor.estimatedTokenCount(
            of: TurnTruncation().apply(ToolOutputElision().apply(transcript)))
        let targetTokens = Int(Double(deterministicFloor) * foldTargetShareOfDeterministicFloor)
        return TokenBudget(limit: budgetLimit, target: Double(targetTokens) / Double(budgetLimit))
    }

    /// The estimated token count of the span `transcript`'s fold replaces — the
    /// turns outside the recency window, partitioned exactly as
    /// ``Summarization`` partitions them.
    ///
    /// - Parameters:
    ///   - transcript: The transcript about to be folded.
    ///   - keepRecentTurns: The recency window the fold leaves untouched.
    /// - Returns: The folded span's size, in the estimated tokens
    ///   ``Compactor``'s did-not-shrink guard measures.
    private static func foldedSpanTokens(of transcript: Transcript, keepRecentTurns: Int) -> Int {
        let (_, turns) = TranscriptTurns.split(Array(transcript))
        let (old, _) = TranscriptTurns.partition(turns, keepRecentTurns: keepRecentTurns)
        return Compactor.estimatedTokenCount(of: Transcript(entries: old.flatMap(\.entries)))
    }

    // MARK: - The test

    @Test(
        "one fold against a real model: the summarizer runs once, answers with text, and the fold is applied rather than discarded"
    )
    func theFoldWorksAgainstARealModel() async throws {
        let startedAt = Date()
        var modelLoadSeconds = 0.0
        defer {
            print(
                "[compactionSmoke] wallClockSeconds=\(String(format: "%.1f", Date().timeIntervalSince(startedAt))) "
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

        let transcript = Self.makeTranscript()
        let summarization = Summarization(reasoningTokenHeadroom: Self.reasoningTokenHeadroom)
        let summarizer = CountingBlankSlateSummarizer(container: container)

        let (_, result) = try await Compactor.compact(
            transcript,
            budget: Self.makeBudget(forcingSummarizationOf: transcript),
            summarizer: summarizer,
            summarization: summarization
        )

        await container.model.evict()

        // The evidence, on the record, before the assertions read it — so a red
        // run states the numbers it went red on rather than only the assertion
        // that failed.
        let calls = await summarizer.calls
        let ceilings = calls.map(\.ceiling)
        let answerTokens = calls.map { Compactor.estimatedTokenCount(of: $0.answer) }
        let spanTokens = Self.foldedSpanTokens(
            of: transcript, keepRecentTurns: summarization.keepRecentTurns)
        print(
            "[compactionSmoke] summarizerCalls=\(ceilings.count) ceilings=\(ceilings) "
                + "answerTokens=\(answerTokens) "
                + "spanTokens=\(spanTokens) summaryTokens=\(Compactor.estimatedTokenCount(of: result.summary ?? "")) "
                + "tokensBefore=\(result.tokensBefore) tokensAfter=\(result.tokensAfter) "
                + "stages=\(result.stagesApplied)"
        )

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
}
