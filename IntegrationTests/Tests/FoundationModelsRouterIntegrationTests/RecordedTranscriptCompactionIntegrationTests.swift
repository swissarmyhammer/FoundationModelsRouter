import Foundation
import FoundationModels
import FoundationModelsRouterTestSupport
import Testing

@testable import FoundationModelsRouter
@testable import FoundationModelsRouterRealModelSupport

// MARK: - Model

/// The real `mlx-community` model this suite SUMMARIZES with, and deliberately
/// not the model that WROTE the recording it compacts.
///
/// Those are two different models on purpose, and the split is the point of
/// this suite. The recording is real traffic from
/// ``RealModels/standard`` — 18 GB of weights, the model this target's slow
/// gated suites drive — and it is already on disk, so compacting it costs nothing
/// to produce. The summarizer is the 680 MB model the other two fast suites
/// name, for the reasons ``CompactionSmokeIntegrationTests`` records against
/// its own constant: it is a real instruct model, it follows the compaction
/// prompt's section structure, and it writes no `<think>` block.
private let recordedTranscriptCompactionModel: ModelRef = "mlx-community/Llama-3.2-1B-Instruct-4bit"

/// The working context this suite loads ``recordedTranscriptCompactionModel``
/// at, and the window its one summarizer call runs in.
///
/// The compaction is one summarizer call over the whole live context, so the
/// call's input holds the whole recorded conversation. The recording ran at
/// ``RealModels/context`` (the recording tool's `workingContextTokens` states
/// the same value), so the recorded conversation fits that window by
/// construction. The same window holds the summarizer's call: the recorded
/// conversation and the compaction prompt as input, and the room left after
/// them as the output ceiling. The first compacting test prints that ceiling.
private let recordedTranscriptCompactionContext = RealModels.context

/// The decoding this suite loads ``recordedTranscriptCompactionModel`` with.
///
/// Pinned to argmax, for the reason both neighbouring suites pin it: the
/// provider default samples from MLX's process-global PRNG, which seeds itself
/// from the clock, so the summary — and therefore the compaction arithmetic this
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
/// suite's compaction arithmetic was a new sample on every calendar day. Task
/// ^xfj1am4 measured that here, from one binary with only `TZ` changed, before
/// task ^pke18c2 made the compaction one call:
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

/// The fast answer to one question: does the compaction work against a
/// transcript that came off a RECORDING, rather than one built in Swift?
///
/// ## What this suite proves
///
/// Three facts, and no more.
///
/// 1. **A recording boots a compaction.** A `transcript.jsonl` and its `session.json`
///    on disk become a real `FoundationModels.Transcript` through
///    ``TranscriptTree/load(under:)`` and
///    ``TranscriptTree/effectiveTranscript(forSession:view:)``, and
///    ``Compactor`` compacts that transcript. No session is opened and no turn is
///    driven; the only generation the suite makes is the compaction's own
///    summarizer call.
/// 2. **The recording still has the shape real traffic has.** The reconstructed
///    transcript carries an instructions header, prompts, responses, reasoning
///    entries, tool calls and tool outputs. This suite asserts each of those
///    kinds is present, so a fixture that silently lost one goes red here
///    rather than quietly compacting something simpler than it claims to.
/// 3. **One call holds a whole real conversation.** The compaction sends the
///    whole recorded conversation — every entry kind above — to the summarizer
///    in one call, and stores one summary. The recording is larger than the
///    fixture ``CompactionSmokeIntegrationTests`` builds, and it carries
///    reasoning and tool traffic that fixture does not. A recording is
///    whatever real traffic was, and it exercises what a fixture written to a
///    budget avoids.
///
/// ## What this suite does NOT prove
///
/// **It does not measure summary quality.** Whether a compaction keeps the facts a
/// resumed session needs is what `FoundationModelsRouterEvalIntegrationTests`
/// measures, over a hand-written dataset.
///
/// **It does not prove the recording FORMAT is stable across schema versions.**
/// The fixture carries ``RecordingSchemaVersion`` 2. A reader that stopped
/// accepting version 2 would fail here, which is worth something; a reader that
/// gained version 3 is not exercised at all.
///
/// **It does not prove a compaction works at every transcript size.** One recording,
/// one model, one compaction.
///
/// **It does not prove the automatic path fires.** This suite calls
/// ``Compactor`` directly. ``AutoCompactionTriggerIntegrationTests`` is where a
/// session compacts itself.
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
/// ## What this suite measured before task ^pke18c2
///
/// Every number in this section predates task ^pke18c2, which made the
/// compaction one summarizer call over the whole live context. The earlier
/// compaction summarized part of the conversation, in more than one call, at
/// a window of 4096. Nobody has measured this suite again since that change.
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
/// All three reported identical compaction numbers, which is
/// ``recordedTranscriptCompactionSamplingMode`` doing its job:
///
/// | what the run measured | value |
/// |---|---|
/// | recorded events in the fixture | 31 |
/// | reconstructed transcript entries | 30 |
/// | entry kinds present | instructions, prompt, response, reasoning, toolCalls, toolOutput |
/// | the whole transcript, in estimated tokens | 4297 |
/// | summarizer calls | 3 |
/// | the compaction's transcript, before and after | 4297 -> 2372 |
///
/// Measured on 2026-09-01, with ``recordedTranscriptCompactionChatTemplateDate``
/// in place: 4 summarizer calls, and the transcript went from 4297 to 2592
/// estimated tokens in 19.1 s, of which 1.8 s was the model load. The suite
/// reported exactly that under `TZ=Pacific/Midway` (01 Sep 2026) and under
/// `TZ=Pacific/Kiritimati` (02 Sep 2026), from one binary with nothing else
/// changed. The clock no longer reaches this compaction.
///
/// These numbers WILL move again, because the prompt moves whenever the
/// compaction prompt changes. That is expected, and it is not a regression.
///
/// The limit is ``integrationTestBudgetMinutes``, which states the whole run
/// table. Task ^k0d30s4 gave every suite of this target that one budget, so a
/// suite states no limit of its own.
///
/// One of the three compaction smoke suites, with
/// ``CompactionSmokeIntegrationTests`` and
/// ``AutoCompactionTriggerIntegrationTests``. The three answer one
/// question — does compaction work at all against a real model — in seconds.
@Suite(
    "Real-model smoke test: a recorded transcript boots the compaction (task ^pfdrppj)",
    .timeLimit(.minutes(integrationTestBudgetMinutes)),
    .exclusiveRealModel
)
struct RecordedTranscriptCompactionIntegrationTests {
    /// The tag every printed line of this suite's compaction carries.
    private static let compactionLabel = "recordedTranscriptCompaction"

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
        // This test loads no model, so it has no live counter. The character
        // counter states the recording's size in characters. The compacting
        // test below prints the size in the model's own tokens, as
        // `tokensBefore`.
        let transcriptCharacters = try CharacterTokenCounter().count(transcript)
        print(
            "[\(Self.compactionLabel)] session=\(sessionId) entries=\(Array(transcript).count) "
                + "kinds=\(kinds) "
                + "transcriptCharacters=\(transcriptCharacters)"
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
        "one compaction of the recorded transcript against a real model: the summarizer runs once, answers with text, and the compaction is applied rather than discarded"
    )
    func theRecordedTranscriptCompacts() async throws {
        let startedAt = Date()
        var modelLoadSeconds = 0.0
        defer {
            print(
                "[\(Self.compactionLabel)] wallClockSeconds=\(String(format: "%.1f", Date().timeIntervalSince(startedAt))) "
                    + "modelLoadSeconds=\(String(format: "%.1f", modelLoadSeconds))"
            )
        }

        let (transcript, _) = try Self.recordedTranscript()

        let loadStartedAt = Date()
        let loaded = try await RealModelContainer.load(
            ref: recordedTranscriptCompactionModel,
            context: recordedTranscriptCompactionContext,
            samplingMode: recordedTranscriptCompactionSamplingMode,
            chatTemplateDate: recordedTranscriptCompactionChatTemplateDate
        )
        modelLoadSeconds = Date().timeIntervalSince(loadStartedAt)

        let outcome = try await TranscriptCompaction.run(
            transcript,
            container: loaded,
            windowTokens: recordedTranscriptCompactionContext,
            label: Self.compactionLabel
        )
        await loaded.container.model.evict()

        // The loaded model's own counter, the counter the compaction counted
        // with, so every size this test reads is in one unit.
        let counter = loaded.container.tokenCounter
        let result = outcome.result

        // 1. The summarizer ran exactly once. A compaction is one call over
        //    the whole live context, whatever size the recording is. No call
        //    means the compaction stopped on a shortfall, which the message
        //    names.
        #expect(
            outcome.ceilings.count == 1,
            "expected one summarizer call, got \(outcome.ceilings.count) at ceilings \(outcome.ceilings), shortfall \(String(describing: result.shortfall))"
        )

        // 2. It answered with text. `^bgxtdk3` was an empty summary on 19 of 19
        //    gated seeds, and an empty summary erases the conversation it replaced.
        let summary = try #require(
            result.summary,
            "the compaction was discarded, so there is no summary to read — see stages above")
        #expect(
            !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            "the summarizer answered with no text"
        )

        // 3. The summary is smaller than the span it replaced, in the unit
        //    `Compactor`'s did-not-shrink check measures. `^fm5ddk9` measured
        //    the 30B model at 1.30x to 2.07x here.
        let summaryTokens = counter.count(summary)
        let spanTokens = try outcome.spanTokens(counter: counter)
        #expect(
            summaryTokens < spanTokens,
            "the summary counts \(summaryTokens) tokens against the \(spanTokens)-token span it replaced"
        )

        // 4. The compaction was APPLIED. An empty `stagesApplied` is `Compactor`'s
        //    shortfall exit, which returns the ORIGINAL transcript — the exit 7
        //    of 7 gated seeds took in `^fm5ddk9` while still reporting a
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
}
