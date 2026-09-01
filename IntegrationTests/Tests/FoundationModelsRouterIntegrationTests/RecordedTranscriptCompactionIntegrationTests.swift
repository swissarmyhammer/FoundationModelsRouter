import Foundation
import FoundationModels
import FoundationModelsRouterTestSupport
import Testing

@testable import FoundationModelsRouter
@testable import FoundationModelsRouterRealModelSupport

// MARK: - Model

/// The real `mlx-community` model this suite SUMMARIZES with, and deliberately
/// not the model that WROTE the recording it folds.
///
/// Those are two different models on purpose, and the split is the point of
/// this suite. The recording is real traffic from
/// ``RealModels/standard`` — 18 GB of weights, the model this target's slow
/// gated suites drive — and it is already on disk, so folding it costs nothing
/// to produce. The summarizer is the 680 MB model the other two fast suites
/// name, for the reasons ``CompactionSmokeIntegrationTests`` records against
/// its own constant: it is a real instruct model, it follows the compaction
/// prompt's section structure, and it writes no `<think>` block.
private let recordedTranscriptCompactionModel: ModelRef = "mlx-community/Llama-3.2-1B-Instruct-4bit"

/// The working context this suite loads ``recordedTranscriptCompactionModel``
/// at.
///
/// Deliberately smaller than ``RealModels/context`` (8192). The largest call
/// this suite makes is one summarizer call over one chunk of the folded span,
/// which ``Summarization/maxChunkTokens`` already bounds at 2000 estimated
/// tokens, and a smaller window costs less to allocate.
private let recordedTranscriptCompactionContext = 4096

/// The decoding this suite loads ``recordedTranscriptCompactionModel`` with.
///
/// Pinned to argmax, for the reason both neighbouring suites pin it: the
/// provider default samples from MLX's process-global PRNG, which seeds itself
/// from the clock, so the summary — and therefore the fold arithmetic this
/// suite asserts on — would differ on every run of identical code. Argmax
/// decoding consumes no randomness, which is what lets a red run here be
/// attributed to the change under test.
private let recordedTranscriptCompactionSamplingMode: GenerationOptions.SamplingMode = .greedy

/// The calendar date this suite pins into
/// ``recordedTranscriptCompactionModel``'s prompt.
///
/// The decoding above pins the SAMPLING. It does not pin the PROMPT. The
/// Llama 3.2 chat template writes `Today Date: <today>` into the system header
/// of every summarizer call, and it reads that date off the clock. So this
/// suite's fold arithmetic was a new sample on every calendar day. Task
/// ^xfj1am4 measured that here, from one binary with only `TZ` changed:
///
/// | the date the clock stamped | summarizer calls | answerTokens |
/// |---|---|---|
/// | 01 Sep 2026 | 6 | `[864, 806, 650, 708, 863, 756]` |
/// | 02 Sep 2026 | 5 | `[830, 715, 650, 626, 722]` |
///
/// One calendar day bought a whole extra generation over the same recording.
///
/// The value comes from ``RealModelContainer/chatTemplateFallbackDate``, which
/// is the template's own fallback and which states why.
private let recordedTranscriptCompactionChatTemplateDate =
    RealModelContainer.chatTemplateFallbackDate

// MARK: - Suite

/// The fast answer to one question: does the compaction fold work against a
/// transcript that came off a RECORDING, rather than one built in Swift?
///
/// ## What this suite proves
///
/// Three facts, and no more.
///
/// 1. **A recording boots a fold.** A `transcript.jsonl` and its `session.json`
///    on disk become a real `FoundationModels.Transcript` through
///    ``TranscriptTree/load(under:)`` and
///    ``TranscriptTree/effectiveTranscript(forSession:view:)``, and
///    ``Compactor`` folds that transcript. No session is opened and no turn is
///    driven; the only generations the suite makes are the fold's own
///    summarizer calls.
/// 2. **The recording still has the shape real traffic has.** The reconstructed
///    transcript carries an instructions header, prompts, responses, reasoning
///    entries, tool calls and tool outputs. This suite asserts each of those
///    kinds is present, so a fixture that silently lost one goes red here
///    rather than quietly folding something simpler than it claims to.
/// 3. **The MAP-REDUCE path runs.** This one was not designed in; the recording
///    brought it. The folded span measures 2366 estimated tokens, past
///    ``Summarization/maxChunkTokens`` (2000), so the stage chunks the span,
///    summarizes each chunk, and re-summarizes the results — three summarizer
///    calls rather than one. ``CompactionSmokeIntegrationTests`` sizes its own
///    fixture to stay under that ceiling and asserts the one map call plus at
///    most one condense re-ask, so this is the only fast suite that reaches
///    the chunking path at all. It is also
///    the clearest illustration of the card: a recording is whatever real
///    traffic was, and it exercises code a fixture written to a budget avoids.
///
/// ## What this suite does NOT prove
///
/// **It does not measure summary quality.** Whether a fold keeps the facts a
/// resumed session needs is what `FoundationModelsRouterEvalIntegrationTests`
/// measures, over a hand-written dataset. That tier drove the 30B model in tens
/// of minutes when this sentence was written; it drives a small canary under a
/// two-minute limit now (task ^k0d30s4). That tier stays where it is.
///
/// **It does not prove the recording FORMAT is stable across schema versions.**
/// The fixture carries ``RecordingSchemaVersion`` 2. A reader that stopped
/// accepting version 2 would fail here, which is worth something; a reader that
/// gained version 3 is not exercised at all.
///
/// **It does not prove a fold works at every transcript size.** One recording,
/// one model, one fold.
///
/// **It does not prove the automatic path fires.** This suite calls
/// ``Compactor`` directly. ``AutoCompactionTriggerIntegrationTests`` is where a
/// session folds itself.
///
/// ## Why the transcript is recorded rather than built in Swift
///
/// This is the card `^pfdrppj`'s whole point, and two defects the same week
/// argued it. A transcript written in Swift is one more thing that has to be
/// kept true, and it went untrue twice: `^vjf3mdm` sized 24 seeds too small for
/// a real summary to shrink them, and `^wnj3ka3` sat a round-trip fixture below
/// its own trigger, because both were sized against an estimate rather than
/// against a measurement. A recording has neither failure mode. It has the
/// entry kinds a hand-written fixture forgets, and it is inert: no later edit
/// can shrink it by accident, because nothing in Swift describes its size.
///
/// ## Where the recording came from, and why it is checked in
///
/// `Fixtures/CompactionRecording/` holds it, and `README.md` beside it records
/// the whole recipe — the model, the date, the prompts, and the redaction
/// review. It is CHECKED IN rather than read live off the box, and that choice
/// was forced rather than preferred: this package has no ambient recordings
/// root. `Router` takes its `recordingsDir` as a parameter, no default path and
/// no environment variable names one, and every other test in the package
/// records into a fresh temporary directory it removes afterwards. A test that
/// read "whatever recording is on this box" would find nothing on any box, so
/// it would skip everywhere and prove nothing.
///
/// ## What this suite measures
///
/// Measured on 2026-08-18, on an Apple silicon box with the summarizer model
/// already in the Hugging Face cache. Three consecutive runs, each printing its
/// own numbers through the test body:
///
/// | run | wall clock | of which model load | whole `swift test` command |
/// |---|---|---|---|
/// | 1 | 10.2 s | 2.0 s | 23.4 s |
/// | 2 | 10.1 s | 1.8 s | 15.8 s |
/// | 3 | 10.3 s | 1.9 s | 15.8 s |
///
/// All three reported identical fold numbers, which is
/// ``recordedTranscriptCompactionSamplingMode`` doing its job:
///
/// | what the run measured | value |
/// |---|---|
/// | recorded events in the fixture | 31 |
/// | reconstructed transcript entries | 30 |
/// | entry kinds present | instructions, prompt, response, reasoning, toolCalls, toolOutput |
/// | the whole transcript, in estimated tokens | 4297 |
/// | the folded span | 2366 |
/// | summarizer calls | 3, at ceilings 377, 475 and 378 |
/// | what the model answered, per call | 500, 552 and 442 estimated tokens |
/// | the stored summary | 442 |
/// | stages the fold applied | elision, truncation, summarization |
/// | the fold's transcript, before and after | 4297 -> 2372 |
///
/// It is slower than its two neighbours — 10 s against their 4 s and 5 s — and
/// the three summarizer calls are the whole difference. That is the cost of
/// folding real traffic rather than a span sized to one chunk, and it is still
/// seconds.
///
/// ### The numbers this suite reports now (task ^xfj1am4)
///
/// Every number above was measured with the calendar date the run's own clock
/// stamped, so each row is one day's sample. That is what
/// ``recordedTranscriptCompactionChatTemplateDate`` closes. The rows above
/// also predate task ^xx02yn6's recovery ladder, which is why the call count
/// moved.
///
/// Measured on 2026-09-01, with the pin in place:
///
/// | what the run measured | value |
/// |---|---|
/// | the whole transcript, in estimated tokens | 4297 |
/// | the folded span | 2366 |
/// | summarizer calls | 4, each at a ceiling of 628 |
/// | what the model answered, per call | 793, 679, 708 and 661 estimated tokens |
/// | the stored summary | 661 |
/// | stages the fold applied | elision, truncation, summarization |
/// | the fold's transcript, before and after | 4297 -> 2592 |
/// | the fold's wall clock | 19.1 s, of which 1.8 s the model load |
///
/// The suite reported exactly that row under `TZ=Pacific/Midway`
/// (01 Sep 2026) and under `TZ=Pacific/Kiritimati` (02 Sep 2026), from one
/// binary with nothing else changed. The clock no longer reaches this fold.
///
/// These numbers WILL move again, because the prompt moves whenever the
/// compaction prompt or the recovery ladder changes. That is expected, and it
/// is not a regression.
///
/// The three runs of 2026-08-20 measured the fold at 12.1, then 11.7, then
/// 12.2 seconds, and the entry-kind check at 0.012, then 0.011, then 0.0
/// seconds, against ``integrationTestBudgetMinutes``, which is now the limit
/// and which states the whole run table. This suite carried
/// a three-minute limit of its own before, derived from its own dearest
/// measured run on a busy box; task ^k0d30s4 replaces that direction with one
/// budget every suite of this target shares, so a suite states no limit of its
/// own and the three minutes are gone.
///
/// One of the three compaction smoke suites, with
/// ``CompactionSmokeIntegrationTests`` and
/// ``AutoCompactionTriggerIntegrationTests``. The three answer one
/// question — does compaction work at all against a real model — in seconds.
///
@Suite(
    "Real-model smoke test: a recorded transcript boots the compaction fold (task ^pfdrppj)",
    .timeLimit(.minutes(integrationTestBudgetMinutes)),
    .exclusiveRealModel
)
struct RecordedTranscriptCompactionIntegrationTests {
    // MARK: - The recording

    /// The model-assisted stage this suite folds with.
    ///
    /// ``Summarization/keepRecentTurns`` stays at its own default of 4, because
    /// the recorded conversation is long enough that four recent turns still
    /// leave a span to fold. Nothing here is sized against the recording; this
    /// is the production default, unchanged.
    ///
    /// ``Summarization/reasoningTokenHeadroom`` is cut to
    /// ``reasoningTokenHeadroom`` for the reason both neighbouring suites cut
    /// it.
    private static var foldSummarization: Summarization {
        Summarization(reasoningTokenHeadroom: reasoningTokenHeadroom)
    }

    /// The tokens every summarizer call of this suite is given on top of its
    /// summary allowance, and deliberately not ``Summarization``'s own default
    /// of 4096.
    ///
    /// The same value both neighbouring suites use, for the same measured
    /// reason: that default is sized for a model that always writes a `<think>`
    /// block before its answer, and ``recordedTranscriptCompactionModel`` writes
    /// no such block. Cutting it bounds the one unbounded cost in the run, which
    /// is the summarizer generation.
    private static let reasoningTokenHeadroom = 128

    /// The tag every printed line of this suite's fold carries.
    private static let foldLabel = "recordedTranscriptCompaction"

    // MARK: - Reading the recording

    /// Reconstructs the recorded conversation, reading nothing but the files in
    /// the bundled fixture.
    ///
    /// This is the whole boot path the card asks for, and it is two public
    /// calls. Neither needs a `Router`, a model, or a session.
    ///
    /// The fixture directory arrives through ``CompactionRecordingFixture``:
    /// it plays the recording root, and the session sits directly under it as
    /// `<sessionId>/{session.json,transcript.jsonl}` — the shape the router
    /// writes for a session vended with a per-session `recordingRoot:`, and
    /// the shape ``TranscriptTree/load(under:)`` requires. Nothing here names
    /// the session id: this function reads it off the loaded tree, so no ULID
    /// is written down in Swift and a re-recorded fixture needs no edit in
    /// this file.
    ///
    /// - Returns: The recorded session's whole conversation, and its id.
    /// - Throws: An expectation failure when the fixture is missing or holds no
    ///   session, and whatever ``TranscriptTree`` throws for a recording it
    ///   cannot read.
    private static func recordedTranscript() throws -> (transcript: Transcript, sessionId: ULID) {
        let recordingRoot = try #require(
            CompactionRecordingFixture.directory,
            "the support target's bundle vends no resource directory, so the recording fixture is unreachable"
        )
        let tree = try TranscriptTree.load(under: recordingRoot)
        let root = try #require(
            tree.roots.first,
            "the recording at \(recordingRoot.path) holds no session — is the fixture checked in?"
        )
        return (try tree.effectiveTranscript(forSession: root.id, view: .fullHistory), root.id)
    }

    // MARK: - The tests

    @Test(
        "the recorded transcript still carries the entry kinds real traffic has: an instructions header, prompts, responses, reasoning, tool calls and tool outputs"
    )
    func theRecordingCarriesTheShapeRealTrafficHas() throws {
        let (transcript, sessionId) = try Self.recordedTranscript()
        let kinds = TranscriptEntryKinds.names(of: transcript)
        print(
            "[\(Self.foldLabel)] session=\(sessionId) entries=\(Array(transcript).count) "
                + "kinds=\(kinds) "
                + "transcriptTokens=\(Compactor.estimatedTokenCount(of: transcript))"
        )

        // The entry kinds a transcript written in Swift forgets. `^vjf3mdm` and
        // `^wnj3ka3` were both about a fixture that had quietly stopped being
        // what its own doc comment claimed, and this assertion is what makes
        // the same drift loud for a recording.
        for kind in TranscriptEntryKinds.realTrafficKinds {
            #expect(
                kinds.contains(kind),
                "the recorded transcript carries no \(kind) entry — it holds \(kinds)"
            )
        }
    }

    @Test(
        "one fold of the recorded transcript against a real model: the summarizer runs, answers with text, and the fold is applied rather than discarded"
    )
    func theRecordedTranscriptFolds() async throws {
        let startedAt = Date()
        var modelLoadSeconds = 0.0
        defer {
            print(
                "[\(Self.foldLabel)] wallClockSeconds=\(String(format: "%.1f", Date().timeIntervalSince(startedAt))) "
                    + "modelLoadSeconds=\(String(format: "%.1f", modelLoadSeconds))"
            )
        }

        let (transcript, _) = try Self.recordedTranscript()

        let loadStartedAt = Date()
        let container = try await RealModelContainer.load(
            ref: recordedTranscriptCompactionModel,
            context: recordedTranscriptCompactionContext,
            samplingMode: recordedTranscriptCompactionSamplingMode,
            chatTemplateDate: recordedTranscriptCompactionChatTemplateDate
        )
        modelLoadSeconds = Date().timeIntervalSince(loadStartedAt)

        let outcome = try await CompactionFold.run(
            transcript,
            summarization: Self.foldSummarization,
            container: container,
            label: Self.foldLabel
        )
        await container.model.evict()

        let result = outcome.result

        // 1. The summarizer ran. Its call count is the whole generation budget
        //    of this suite, and it is read rather than asserted at a number:
        //    the recorded span decides how many chunks
        //    `Summarization.maxChunkTokens` splits it into, and nothing in
        //    Swift should restate a size the recording already fixes.
        #expect(
            !outcome.ceilings.isEmpty,
            "the summarizer was never called, so no fold was attempted"
        )

        // 2. It answered with text. `^bgxtdk3` was an empty summary on 19 of 19
        //    gated seeds, and an empty summary erases the span it replaced.
        let summary = try #require(
            result.summary,
            "the fold was discarded, so there is no summary to read — see stages above")
        #expect(
            !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            "the summarizer answered with no text"
        )

        // 3. The summary is smaller than the span it replaced, in the unit
        //    `Compactor`'s did-not-shrink guard measures. `^fm5ddk9` measured
        //    the 30B model at 1.30x to 2.07x here.
        let summaryTokens = Compactor.estimatedTokenCount(of: summary)
        #expect(
            summaryTokens < outcome.spanTokens,
            "the summary estimates \(summaryTokens) tokens against the \(outcome.spanTokens)-token span it replaced"
        )

        // 4. The fold was APPLIED. An empty `stagesApplied` is `Compactor`'s
        //    shortfall exit, which returns the ORIGINAL transcript — the exit 7
        //    of 7 gated seeds took in `^fm5ddk9` while still reporting a
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
