import Foundation
import FoundationModels
import FoundationModelsRouterTestSupport
import Testing

@testable import FoundationModelsRouter
@testable import FoundationModelsRouterRealModelSupport

/// The real `mlx-community` model this round trip folds against, and
/// deliberately NOT ``RealModels/standard``.
///
/// ``RealModels/standard`` is `Muse-Glimmer-30B-4bit`, 18 GB of weights, and it
/// is what this suite drove until task ^k0d30s4 gave every integration test a
/// budget of two minutes. The run of 2026-08-20 measured this round trip at
/// 541.6 seconds against the 30B — 4.5 times the budget, and the only test of
/// this target that did not fit.
///
/// `Qwen2.5-3B-Instruct-4bit` is 1.6 GB on disk, and it is the subject the
/// gated fact-retention eval already measures this exact property against: see
/// `CompactionEvalRealModel` for the trial order task ^m03heaa ran and for the
/// 6 of 7 summaries of that tier, and 23 of 24 of the whole-dataset tier task
/// ^k0d30s4 has since deleted, that this model carried through a fold on
/// 2026-08-20. Step 3 below is one instance of that
/// same property, so the subject the evals measured it on is the subject to
/// measure it on here.
///
/// It is the same family as Qwen3.8-27B, the standard model task ^xx02yn6
/// designed the summarization prompt for, and it writes no `<think>` block —
/// which is what makes ``compactionRoundTripReasoningTokenHeadroom`` safe to
/// cut below the production default.
private let compactionRoundTripModel: ModelRef = "mlx-community/Qwen2.5-3B-Instruct-4bit"

/// The tokens every summarizer call of this suite is given on top of its
/// summary allowance, and deliberately not ``Summarization``'s own default of
/// 8192.
///
/// That default is sized for a model that writes a `<think>` block before its
/// answer. ``compactionRoundTripModel`` writes none, so almost all of that
/// headroom is a ceiling no generation reaches — and reaching for it is what a
/// fold pays for when the model runs on. The gated eval subset measured what
/// that freedom costs: two of seven folds generated to the ceiling, 20485 and
/// 16060 bytes of summary answer, at 28.5 seconds each, where the five bounded
/// folds cost 2.5 to 7.4 seconds.
///
/// The same value the three compaction smoke suites and every gated eval tier
/// cut this to, for the same measured reason. Not zero, so a summary has a
/// little room to finish its last sentence inside the ceiling rather than
/// always ending at it.
private let compactionRoundTripReasoningTokenHeadroom = 128

// MARK: - Suite

/// The gated end-to-end round trip for task rjvrgt9 (compaction_plan.md §4,
/// §5): the same five-step loop `Examples/CompactionDemo` prints for a human
/// to read, asserted mechanically here against a real model instead:
///
/// 1. `contextFill` climbs across scripted turns that grow the transcript.
/// 2. Compacting once the 0.80 trigger is reached — against
///    ``CompactionRoundTripFixture/foldBudget``, which forces the whole
///    pipeline through its model-assisted stage — shrinks `contextFill` and
///    never changes the session's identity (id, recording directory, router
///    id).
/// 3. A turn after compaction succeeds and recalls a fact planted only in
///    the folded span — proof the summary, not just the mechanism, worked.
/// 4. Restoring from disk (a fresh `Router`/`LanguageModelProfile`,
///    simulating a new process — the same technique
///    ``SessionTreeRestorationIntegrationTests`` uses) yields the
///    checkpointed live window: fewer entries than the full recorded
///    history.
/// 5. A further turn on the restored session succeeds.
///
/// ## What it NO LONGER proves (task ^k0d30s4)
///
/// The five steps above ran against `Muse-Glimmer-30B-4bit` and an unbounded
/// summarizer ceiling until this task, and the run of 2026-08-20 measured them
/// at 541.6 seconds — 4.5 times the two-minute budget every integration test
/// now has. Two changes bring the loop inside it:
/// ``compactionRoundTripModel`` and ``compactionRoundTripReasoningTokenHeadroom``.
/// What is no longer proven is:
///
/// - **The 30B model's summary quality.** Step 3 recalls `CRIMSON-77` out of a
///   summary a 3B model wrote. That the 3B carries the fact says nothing about
///   the 30B, and a fact this subject lost might survive under the larger one.
///   `CompactionEvalRealModel` records the same trade for the eval tiers, and
///   the measured baseline this subject is held to there.
/// - **What a fold costs when the summarizer may run on.** The headroom cut
///   makes the largest summary this loop can be handed `summaryAllowance` plus
///   ``compactionRoundTripReasoningTokenHeadroom``, whatever the model chooses
///   to write. A fold that generated to the production default's 8192 tokens is
///   no longer measured here.
///
/// Everything else is untouched. The fixture, the working context, the reply
/// ceiling, the 0.80 trigger, the fold budget, the stage list, the identity
/// checks, the restore and the further turn are all exactly what they were, so
/// each of the five steps still asserts what it always asserted.
///
/// Builds a ``LanguageModelProfile`` directly over an already-loaded
/// model's ``MLXFoundationModelsContainer`` (bypassing
/// `Router.resolve(_:reporting:)`, which would need real `.flash`/`.embedding`
/// downloads too) — the same manual-harness technique
/// ``SessionTreeRestorationIntegrationTests`` uses — so this suite reaches the
/// real public ``RoutedSession/compact(prompt:budget:)`` /
/// ``RoutedModel/restoreSessionTree(root:recordingRoot:tools:)`` surface without paying
/// for two extra downloads.
///
/// Every fixture dimension this loop drives — the working context, the reply
/// ceiling, the instructions, the fold budget, and the scripted turns — lives
/// in ``CompactionRoundTripFixture``, in the plain support target, so the
/// hermetic `ScriptedTurnSizingTests` in the unit target bounds the SAME
/// values this gated run submits (task ^cvsh3m9). `Self.samplingMode` is the
/// one knob that stays here: it shapes the live decoding, not the fixture.
///
/// This suite executes against real hardware. It was long described here as
/// blocked by an unfixable MLX `default.metallib` load failure; that was
/// wrong. The failure was a resource-colocation bug in how `swift test` lays
/// out its binaries, and ``MetalLibraryTestBootstrap`` fixes it — see that
/// type for the root cause. Nothing about the toolchain or the machine ever
/// needed to change.
@Suite(
    "Gated real-model end-to-end coverage: RoutedSession.compact(prompt:budget:) round trip (task rjvrgt9)",
    .serialized,
    // The whole target's budget. The 40 minutes this stated before were the
    // 30B model's cost with an unbounded summarizer ceiling: the run of
    // 2026-08-17 measured 425 seconds, task ^xx02yn6's condense re-ask can
    // double the fold's model work, and the run of 2026-08-20 measured 541.6.
    // The two changes at the top of this file are what removed that cost.
    .timeLimit(.minutes(integrationTestBudgetMinutes)),
    .exclusiveRealModel
)
struct CompactionRoundTripIntegrationTests {
    /// The decoding both of this suite's loads pin.
    ///
    /// Argmax. The provider default samples at temperature `0.6` from MLX's
    /// process-global PRNG, which seeds itself from the clock, so this suite's
    /// own scripted replies — and therefore its transcript sizes, its fold, and
    /// its recall answer — differed on every run of identical code (task
    /// f80n046). Argmax decoding consumes no randomness at all, which is what
    /// lets a red run here be attributed to the change under test.
    private static let samplingMode: GenerationOptions.SamplingMode = .greedy

    @Test(
        "contextFill climbs, compact() folds at the 0.80 trigger preserving identity, a post-compact turn recalls the folded fact, restore yields the checkpointed window, and a further turn succeeds"
    )
    func compactionRoundTrip() async throws {
        let cacheDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "CompactionRoundTripIntegrationTests-cache-\(UUID().uuidString)", isDirectory: true)
        let recordingsDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "CompactionRoundTripIntegrationTests-recordings-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: cacheDir)
            try? FileManager.default.removeItem(at: recordingsDir)
        }

        let container = try await RealModelContainer.load(
            ref: compactionRoundTripModel,
            context: CompactionRoundTripFixture.context,
            samplingMode: Self.samplingMode)
        let profile = RealModelHarness.make(
            model: compactionRoundTripModel,
            context: CompactionRoundTripFixture.context,
            container: container,
            cacheDir: cacheDir,
            recordingsDir: recordingsDir
        )
        // The router's own id, read off the handle it stamped. The harness
        // returns no `Router`, because this is the only fact a caller needs of
        // one and every handle already carries it.
        let routerId = profile.standard.routerId

        // The stage is session-scoped rather than per-call, so the explicit
        // `compact(budget:)` at step 2 folds with the ceiling stated here.
        let session = profile.standard.makeSession(
            instructions: CompactionRoundTripFixture.instructions,
            summarization: Summarization(
                reasoningTokenHeadroom: compactionRoundTripReasoningTokenHeadroom)
        )
        let sessionId = session.id
        let recordingDirectoryBefore = session.recordingDirectory

        // 1. contextFill climbs across scripted turns.
        var fills: [Double] = []
        for turn in CompactionRoundTripFixture.scriptedTurns {
            _ = try await session.respond(to: turn, maxTokens: CompactionRoundTripFixture.replyMaxTokens)
            fills.append(await session.contextFill)
            if fills.last! >= 0.80 { break }
        }
        #expect(fills.count > 1, "expected more than one turn before crossing the trigger")
        #expect(
            zip(fills, fills.dropFirst()).allSatisfy { $0 <= $1 },
            "contextFill should never decrease turn over turn before compaction"
        )
        let fillBeforeCompaction = try #require(fills.last)
        #expect(fillBeforeCompaction >= 0.80)

        // 2. Compact at the trigger: shrinks fill, preserves identity.
        let result = try await session.compact(budget: CompactionRoundTripFixture.foldBudget)
        // Every stage, in order — not merely "something ran". A fold that
        // stops after the deterministic stages records a checkpoint too
        // (task ^h1008kb), but this test is about the model-assisted round
        // trip — a real summary whose quality step 3 measures by recall —
        // so `stagesApplied` non-empty cannot tell that fold from this
        // one. `CompactionRoundTripFixture.foldBudget` is what makes the
        // full pipeline a property here rather than a coincidence.
        #expect(
            result.stagesApplied == [
                ToolOutputElision.stageName, TurnTruncation.stageName, Summarization.stageName,
            ],
            "expected the full pipeline through the model-assisted stage, got \(result.stagesApplied)"
        )
        #expect(result.summary != nil)
        #expect(result.tokensAfter < result.tokensBefore)
        // The margin, on the record. This suite is the only place a fold's
        // saving is measured against a real model, and the bare inequality
        // above hides how much of one it is — a fold that saved a handful
        // of tokens passes it exactly as a fold that halved the transcript
        // does (task zche4zy, where an unbounded summary left the saving
        // near zero). Reported against the fixture's 0.25 target, not the
        // production default of 0.50 — see
        // `CompactionRoundTripFixture.foldBudget`.
        print(
            "[compactionRoundTrip] tokensBefore=\(result.tokensBefore) tokensAfter=\(result.tokensAfter) "
                + "saved=\(result.tokensBefore - result.tokensAfter)"
        )
        let fillAfterCompaction = await session.contextFill
        #expect(fillAfterCompaction < fillBeforeCompaction)
        #expect(session.id == sessionId)
        #expect(session.recordingDirectory == recordingDirectoryBefore)
        #expect(session.routerId == routerId)

        // 3. A turn after compaction succeeds and recalls the folded
        //    fact — proof the summary, not just the mechanism, worked.
        let recall = try await session.respond(
            to: "Without re-reading anything, what is the exact vault code from the project brief?",
            maxTokens: GatedRealModelBudget.responseTokenCeiling
        )
        #expect(!recall.isEmpty)
        #expect(recall.contains("CRIMSON-77"))

        await container.model.evict()

        // 4. Restore from disk — a fresh Router/profile over the same
        //    recording root, simulating a new process — yields the
        //    checkpointed live window: fewer entries than the full
        //    recorded history.
        let container2 = try await RealModelContainer.load(
            ref: compactionRoundTripModel,
            context: CompactionRoundTripFixture.context,
            samplingMode: Self.samplingMode)
        let profile2 = RealModelHarness.make(
            model: compactionRoundTripModel,
            context: CompactionRoundTripFixture.context,
            container: container2,
            cacheDir: cacheDir,
            recordingsDir: recordingsDir,
            routerId: routerId
        )
        let restoredTree = try await profile2.standard.restoreSessionTree(root: sessionId)
        let restoredSession = restoredTree.root
        #expect(restoredSession.id == sessionId)
        // The restored session continues the FIRST router's recording root,
        // which is the whole reason `RealModelHarness.make` takes a `routerId`.
        // Asserted here as well as on the pre-compaction session above, so a
        // profile built with a fresh id cannot pass by restoring nothing.
        #expect(restoredSession.routerId == routerId)

        let routerDirectory = recordingsDir.appendingPathComponent(routerId.description, isDirectory: true)
        let tree = try TranscriptTree.load(under: routerDirectory)
        let checkpointedWindow = try tree.effectiveTranscript(forSession: sessionId)
        let fullHistory = try tree.effectiveTranscript(forSession: sessionId, view: .fullHistory)
        #expect(
            checkpointedWindow.count < fullHistory.count,
            "the checkpointed restore view should be strictly smaller than the full recorded history"
        )

        // 5. A further turn on the restored session succeeds.
        let restoredReply = try await restoredSession.respond(
            to: "Reply with just the word \"restored\".", maxTokens: GatedRealModelBudget.responseTokenCeiling)
        #expect(!restoredReply.isEmpty)

        await container2.model.evict()
    }
}
