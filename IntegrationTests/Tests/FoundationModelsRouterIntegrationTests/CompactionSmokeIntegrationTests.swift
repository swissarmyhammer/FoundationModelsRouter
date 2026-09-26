import Foundation
import FoundationModels
import FoundationModelsRouterTestSupport
import Testing

@testable import FoundationModelsRouter
@testable import FoundationModelsRouterRealModelSupport

// MARK: - Model

/// The real `mlx-community` model this suite compacts against, and deliberately
/// NOT ``RealModels/standard``.
///
/// ``RealModels/standard`` is `Muse-Glimmer-30B-mxfp4`, 17 GB of weights. Its
/// load alone cost more than the whole time budget this suite had when it was
/// written, which is why this suite names a model of its own instead of the
/// target's slot roster.
///
/// `Llama-3.2-1B-Instruct-4bit` is 680 MB on disk and is a real instruct model,
/// not a toy: it follows the compaction prompt's own section structure and it
/// writes a real summary. It was chosen over the other small models already in
/// the Hugging Face cache on two properties. It is the smallest cached model
/// that is still an instruct model — `SmolLM-135M-Instruct-4bit` is smaller and
/// too small to follow an eight-section instruction. And it writes NO `<think>`
/// block, so its whole output is the summary. `Qwen3-1.7B-4bit` is comparable
/// in size and was rejected because it reasons.
private let compactionSmokeModel: ModelRef = "mlx-community/Llama-3.2-1B-Instruct-4bit"

/// The working context this suite loads ``compactionSmokeModel`` at, and the
/// window its one summarizer call runs in.
///
/// Deliberately smaller than ``RealModels/context`` (8192). The largest call
/// this suite makes is one summarizer call: the compaction prompt and the
/// whole live context as input, and the allowed summary size, capped at the
/// room the window leaves after that input, as the output ceiling. The
/// fixture fits well inside this window, and a smaller window costs less to
/// allocate.
private let compactionSmokeContext = 4096

/// The decoding this suite loads ``compactionSmokeModel`` with.
///
/// Pinned to argmax, for the reason ``CompactionRoundTripIntegrationTests``
/// pins it: the provider default samples from MLX's process-global PRNG, which
/// seeds itself from the clock, so the summary — and therefore the compaction
/// arithmetic this suite asserts on — would differ on every run of identical
/// code. Argmax decoding consumes no randomness, which is what lets a red run
/// here be attributed to the change under test, and it is why the three runs
/// tabulated on the suite below reported identical compaction numbers.
private let compactionSmokeSamplingMode: GenerationOptions.SamplingMode = .greedy

/// The calendar date this suite pins into ``compactionSmokeModel``'s prompt.
///
/// Greedy decoding above pins the SAMPLING. It does not pin the PROMPT, and the
/// Llama 3.2 chat template writes `Today Date: <today>` into the system header
/// of every summarizer call. So this suite's compaction arithmetic was a new sample on
/// every calendar day, and task ^erv2vxz measured exactly that:
/// `answerTokens=[703, 789]` on 01 Sep 2026, then `[703, 836]` on 02 Sep 2026,
/// from one binary with only `TZ` changed.
///
/// The value comes from ``RealModelContainer/chatTemplateFallbackDate``, which
/// is the template's own fallback and which states why. Task ^xfj1am4 moved it
/// there, because three gated suites pin the same date for the same reason.
private let compactionSmokeChatTemplateDate = RealModelContainer.chatTemplateFallbackDate

// MARK: - Suite

/// The fast answer to one question: does the compaction path work end to end
/// against a real model?
///
/// ## What this suite proves, and what it does not
///
/// It proves the PATH WORKS. Five facts, and no more:
///
/// 1. The summarizer was called exactly once. A compaction is one summarizer
///    call over the whole live context, and that call is also this suite's
///    generation budget.
/// 2. It answered with text that is not empty (`^bgxtdk3` stored an empty
///    summary on 19 of 19 gated seeds).
/// 3. The summary is smaller than the span it replaced, in the tokens of the
///    counter ``Compactor``'s did-not-shrink check itself measures with.
/// 4. The compaction was APPLIED — ``CompactionResult/stagesApplied`` is
///    ``Summarization/stageName`` alone, and not the shortfall exit that
///    discarded 7 of 7 gated compactions in `^fm5ddk9`.
/// 5. ``CompactionResult/tokensAfter`` is under
///    ``CompactionResult/tokensBefore``.
///
/// It proves one more, added by `^azd033m`: a fact stated at the very END of
/// the compacted conversation is still in the summary the compaction stores.
/// That is one fact, on one fixture, against one small model, and it is
/// deliberately narrow. It is a REGRESSION check, not a recall score. A model
/// writes about a conversation in the order the conversation states it, so a
/// summary that runs out of room loses the last fact first, and only a planted
/// late fact catches that loss. Whether a compaction keeps the facts a resumed
/// session needs IN GENERAL is what `FoundationModelsRouterEvalIntegrationTests`
/// measures, over a hand-written dataset. This suite still earns its place,
/// because a broken summarizer, an empty answer, a discarded compaction, and a
/// compaction that dropped the fact it existed to carry are all things a few
/// seconds of real model can rule out.
///
/// ## How it stays fast
///
/// Three budget decisions, and each one is a property this suite asserts or a
/// constant that states its own reason:
///
/// - ``compactionSmokeModel`` rather than the 18 GB ``RealModels/standard``.
/// - One fixture, not a dataset.
/// - ONE generation: the one summarizer call of
///   ``Compactor/compact(_:prompt:budget:counter:summarizers:summarization:pendingRuns:protection:abandoning:)``,
///   and nothing after it. No resumed session and no answer after the
///   compaction — that is another generation, and "works at all" does not
///   need one.
///
/// ## What this suite measured before task ^pke18c2
///
/// Every number in this section predates task ^pke18c2, which made the
/// compaction one summarizer call over the whole live context. The earlier
/// compaction summarized part of the conversation, and it could make more than
/// one call. Nobody has measured this suite again since that change.
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
/// All three reported identical compaction numbers, which is
/// ``compactionSmokeSamplingMode`` doing its job.
///
/// Task ^49dy082 measured the planted-fact test red on 6 of 6 runs. Under
/// greedy decoding the model wrote one line again and again, and that line was
/// a quoted example out of the compaction prompt — 60 copies of one line and no
/// fact of the conversation. `CompactionPrompt.default` quotes no example fact
/// since then.
///
/// Every number above was measured with the calendar date the run's own clock
/// stamped, so each row is one day's sample. Task ^f0k3aah closed that hole
/// with ``compactionSmokeChatTemplateDate``, and the measurement that shows
/// why is this suite's compaction under three stamped dates, one binary, nothing
/// else changed:
///
/// | the date the template stamped | answerTokens | stored summary |
/// |---|---|---|
/// | 01 Sep 2026 | `[703, 789]` | 624 |
/// | 02 Sep 2026 | `[703, 836]` | 615 |
/// | 03 Sep 2026 | `[703, 792]` | 598 |
/// | 26 Jul 2024, the pinned value | `[689, 701]` | 443 |
///
/// The first two rows are the rows task ^erv2vxz measured by moving `TZ`, and
/// that run reproduced both from the stamped date alone. The last row compacted
/// the same under `TZ=Pacific/Kiritimati` (02 Sep 2026), under
/// `TZ=Pacific/Midway` and under `TZ=UTC`. The clock no longer reaches this
/// compaction.
///
/// The smoke tier is this suite, ``AutoCompactionTriggerIntegrationTests`` and
/// ``RecordedTranscriptCompactionIntegrationTests``. All three answer one
/// question — does compaction work at all against a real model — and all
/// three answer it in seconds. Measured under the variable this tier used to
/// read: the whole package, this suite's real model included, in 18.0
/// seconds.
///
/// The suite has no time limit. A run ends when it ends, or when the caller
/// stops it.
@Suite(
    "Real-model smoke test: the compaction works end to end (task ^w1cz46m)",
    .exclusiveRealModel
)
struct CompactionSmokeIntegrationTests {
    /// The tag every printed line of this suite's compaction carries.
    private static let compactionLabel = "compactionSmoke"

    // MARK: - The fixture

    /// The system instructions the fixture transcript's header carries. The
    /// compaction keeps the header in the new snapshot.
    private static let instructions = "You are a terse, literal assistant."

    /// The reply text to every message after the second.
    ///
    /// Short on purpose. The fixture's size has to sit in the PROMPTS, because
    /// this suite builds the transcript itself rather than generating it: a
    /// long scripted reply would inflate the conversation without making the
    /// fixture any more like a real conversation. The replies to the two long
    /// messages do not carry it. ``longMessageReplies`` states why.
    private static let scriptedReply = "Acknowledged."

    /// The reply text to each of the two LONG messages, in message order: one
    /// distinct restatement of the prompt it answers, in the voice of the
    /// terse assistant ``instructions`` names.
    ///
    /// Distinct, and not ``scriptedReply``, because of a measurement that
    /// predates task ^pke18c2. Task ^3dy1ry9 measured what one identical reply
    /// to both long messages cost. The rendered conversation then read
    /// `Assistant: Acknowledged.` twice, and ``compactionSmokeModel`` wrote
    /// that line back after almost every bullet of its summary: 25 of its 47
    /// content lines repeated an earlier line. With these replies the model
    /// wrote a summary that stated ``plantedFactValue`` in sections 2 and 3.
    private static let longMessageReplies: [String] = [
        "Noted: the replacement streams each file, commits in bounded batches, keeps a rejects file beside the index, "
            + "and reads batch size from a setting.",
        "Clear: both paths run for one release, stations cut over oldest first after seven clean reports, "
            + "and the old index stays until the release after.",
    ]

    /// The distinctive value planted at the END of the second long message,
    /// and the one thing ``aPlantedFactLateInTheConversationSurvivesTheCompaction``
    /// reads the summary for.
    ///
    /// A coined proper noun rather than a phrase, because the assertion has to
    /// be exact: a paraphrase of a phrase still passes a substring check by
    /// accident, and a name the model did not carry cannot.
    ///
    /// A proper noun rather than an alphanumeric identifier, and that choice is
    /// measured. The first version of this fixture planted the release ticket
    /// `REL-8842`. ``compactionSmokeModel`` reproduced the SENTENCE — "the
    /// cut-over is authorised by exactly one release ticket" — and dropped the
    /// identifier, exactly as it dropped every other value in the conversation.
    /// A 1B model paraphrases values and copies names, so an identifier would
    /// have made this test measure the model's weakness rather than the
    /// compaction's.
    private static let plantedFactValue = "Kestrel"

    /// The sentence carrying ``plantedFactValue``, appended as the last thing
    /// the second long message says.
    ///
    /// Its position is the whole point. A model writes about a conversation in
    /// the order the conversation states it, so a summary that runs out of
    /// room loses the last long fact first.
    private static let plantedFact = """
        Cut-over for every station is authorised by the \(plantedFactValue) board and by nobody else, and the \
        comparison job refuses to run for a station the \(plantedFactValue) board has not approved.
        """

    /// The scripted prompts, oldest first — the fixture's whole size budget.
    ///
    /// The compaction summarizes the whole live context in one call: the
    /// header, both long messages and the four short messages, each with its
    /// reply. The fixture is sized to two properties at once.
    ///
    /// - Small enough that the call's input fits ``compactionSmokeContext``
    ///   with room left for the summary. The call's output ceiling is the
    ///   stated summary size, capped at that room, and the first test prints
    ///   it.
    /// - Large enough that a summary of the stated size shrinks the context.
    ///   ``TranscriptCompaction/budget(of:counter:)`` sets the target at the
    ///   default share of the transcript's own size, and the compaction states
    ///   the target less the header as the summary's size. `^fm5ddk9` measured
    ///   the 30B model writing summaries 1.30x to 2.07x the size of the text it
    ///   was given, and `Compactor` was right to discard all seven. The
    ///   did-not-shrink check still discards such a summary, and the first test
    ///   fails on it.
    ///
    /// The second message ends with ``plantedFact``, which is the whole fixture
    /// for ``aPlantedFactLateInTheConversationSurvivesTheCompaction``.
    ///
    /// The last four messages are short questions about the long messages.
    /// They make the fixture a real exchange of six messages and six replies,
    /// and the call summarizes them with the rest.
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

    /// Builds the fixture transcript: the header, then one message and its
    /// reply per entry of ``scriptedPrompts``, each a `.prompt` and a
    /// `.response`.
    ///
    /// - Returns: The transcript to compact.
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
                            .text(
                                Transcript.TextSegment(
                                    id: "response-\(index)-text", content: reply(forMessage: index)))
                        ]
                    )
                )
            )
        }
        return Transcript(entries: entries)
    }

    /// The reply to the message at `index` of ``scriptedPrompts``: its own
    /// entry of ``longMessageReplies`` for a long message, and
    /// ``scriptedReply`` for a short message.
    ///
    /// - Parameter index: The message's position in ``scriptedPrompts``.
    /// - Returns: The reply text.
    private static func reply(forMessage index: Int) -> String {
        index < longMessageReplies.count ? longMessageReplies[index] : scriptedReply
    }

    // MARK: - One compacted run

    /// Loads the smoke model, compacts the fixture once through ``TranscriptCompaction``,
    /// evicts the model, and puts this suite's own wall clock on the record — so
    /// a red run states what it went red on rather than only which assertion
    /// failed.
    ///
    /// Everything after the load is ``TranscriptCompaction``'s, which prints the compaction
    /// numbers themselves. This function owns the model's lifetime because it is
    /// the only thing that knows this suite loads once per test.
    ///
    /// - Returns: Everything the run measured, and the loaded model's own
    ///   counter, the counter the compaction counted with, so a test reads
    ///   every size in the unit the did-not-shrink check measured.
    /// - Throws: Whatever the load or the compaction throws.
    private static func compactTheFixture() async throws -> (
        outcome: TranscriptCompactionOutcome, counter: any TokenCounter
    ) {
        let startedAt = Date()
        var modelLoadSeconds = 0.0
        defer {
            print(
                "[\(compactionLabel)] wallClockSeconds=\(String(format: "%.1f", Date().timeIntervalSince(startedAt))) "
                    + "modelLoadSeconds=\(String(format: "%.1f", modelLoadSeconds))"
            )
        }

        let loadStartedAt = Date()
        let loaded = try await RealModelContainer.load(
            ref: compactionSmokeModel,
            context: compactionSmokeContext,
            samplingMode: compactionSmokeSamplingMode,
            chatTemplateDate: compactionSmokeChatTemplateDate
        )
        modelLoadSeconds = Date().timeIntervalSince(loadStartedAt)

        let outcome = try await TranscriptCompaction.run(
            makeTranscript(),
            container: loaded,
            windowTokens: compactionSmokeContext,
            label: compactionLabel
        )
        await loaded.container.model.evict()
        return (outcome, loaded.container.tokenCounter)
    }

    // MARK: - The tests

    @Test(
        "one compaction against a real model: the summarizer answers in one call, and the compaction is applied rather than discarded"
    )
    func theCompactionWorksAgainstARealModel() async throws {
        let (outcome, counter) = try await Self.compactTheFixture()
        let result = outcome.result
        let ceilings = outcome.ceilings
        let spanTokens = try outcome.spanTokens(counter: counter)

        // 1. The summarizer ran exactly once. A compaction is one call over
        //    the whole live context. No call means the compaction stopped on a
        //    shortfall before it called the model, and a second call means the
        //    compaction is no longer one call.
        #expect(
            ceilings.count == 1,
            "expected one summarizer call, got \(ceilings.count) at ceilings \(ceilings), shortfall \(String(describing: result.shortfall))"
        )

        // 2. It answered with text. `^bgxtdk3` was an empty summary on 19 of 19
        //    gated seeds, and an empty summary erases the conversation it replaced.
        let summary = try #require(
            result.summary, "the compaction was discarded, so there is no summary to read — see stages above")
        #expect(
            !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            "the summarizer answered with no text"
        )

        // 3. The summary is smaller than the span it replaced, in the unit
        //    `Compactor`'s did-not-shrink check measures. `^fm5ddk9` measured
        //    the 30B model at 1.30x to 2.07x here.
        let summaryTokens = counter.count(summary)
        #expect(
            summaryTokens < spanTokens,
            "the summary counts \(summaryTokens) tokens against the \(spanTokens)-token span it replaced"
        )

        // 4. The compaction was APPLIED. An empty `stagesApplied` is `Compactor`'s
        //    shortfall exit, which returns the ORIGINAL transcript — the exit
        //    7 of 7 gated seeds took in `^fm5ddk9` while still reporting a
        //    summarizer call.
        #expect(
            result.stagesApplied == [Summarization.stageName],
            "expected the compaction to be applied, got stages \(result.stagesApplied), shortfall \(String(describing: result.shortfall))"
        )

        // 5. The returned result shrank.
        #expect(
            result.tokensAfter < result.tokensBefore,
            "tokensAfter \(result.tokensAfter) did not fall under tokensBefore \(result.tokensBefore)"
        )
    }

    @Test("a fact planted at the end of the long messages is still in the summary the compaction stores")
    func aPlantedFactLateInTheConversationSurvivesTheCompaction() async throws {
        // The property a compaction exists for. Shrinking a transcript is the cost a
        // compaction pays; carrying the facts forward is what it is paid FOR, and a
        // compaction that shrank the transcript and dropped the fact has not worked.
        //
        // Before task ^pke18c2, three measured causes took this fact, and each
        // took it from the END of the long messages, where `plantedFact` stands:
        // a bound that kept the first part of the answer (`^azd033m`), a model
        // that wrote one line again and again until its output ran out
        // (`^49dy082`), and a fixture reply the model copied into its summary
        // (`^3dy1ry9`). `longMessageReplies` records the last one.
        let (outcome, counter) = try await Self.compactTheFixture()
        let summary = try #require(
            outcome.result.summary, "the compaction was discarded, so there is no summary to read")
        let spanTokens = try outcome.spanTokens(counter: counter)

        #expect(
            summary.contains(Self.plantedFactValue),
            """
            the compaction dropped \(Self.plantedFactValue), stated last in the long messages it replaced.
            answer \(outcome.answerTokens(counter: counter)) tokens, stored summary \
            \(counter.count(summary)), span \(spanTokens).
            the answer the model gave was:
            \(outcome.calls.map(\.answer).joined(separator: "\n---\n"))
            the summary the compaction stored was:
            \(summary)
            """
        )
    }
}
