import Foundation
import FoundationModels
import FoundationModelsRouterRealModelSupport
import FoundationModelsRouterTestSupport
import Testing

@testable import FoundationModelsRouter

/// The same real `mlx-community` generation model the rest of this target's
/// gated suites use for the `.standard` slot.
private let compactionRoundTripTinyModel: ModelRef = RealModels.standard

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
/// Builds a ``LanguageModelProfile`` directly over an already-loaded tiny
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
    .timeLimit(.minutes(20)),
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
            ref: compactionRoundTripTinyModel,
            context: CompactionRoundTripFixture.context,
            samplingMode: Self.samplingMode)
        let profile = RealModelHarness.make(
            model: compactionRoundTripTinyModel,
            context: CompactionRoundTripFixture.context,
            container: container,
            cacheDir: cacheDir,
            recordingsDir: recordingsDir
        )
        // The router's own id, read off the handle it stamped. The harness
        // returns no `Router`, because this is the only fact a caller needs of
        // one and every handle already carries it.
        let routerId = profile.standard.routerId

        let session = profile.standard.makeSession(instructions: CompactionRoundTripFixture.instructions)
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
            ref: compactionRoundTripTinyModel,
            context: CompactionRoundTripFixture.context,
            samplingMode: Self.samplingMode)
        let profile2 = RealModelHarness.make(
            model: compactionRoundTripTinyModel,
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
