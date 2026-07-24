import Foundation
import FoundationModels
import HuggingFace
import MLXHuggingFace
import MLXLMCommon
import Testing
import Tokenizers

@testable import FoundationModelsRouter

// MARK: - Gate

/// Reuses the same opt-in gating pattern as the rest of this target: unset
/// (the default, and on any CI/GPU-less box) this whole suite is skipped, so
/// `swift test` stays green without network or a GPU. Kept as its own
/// file-scoped constant rather than sharing another file's — Swift's
/// top-level `private` is file-scoped, not target-scoped.
private let compactionRoundTripIntegrationEnvVar = "FM_ROUTER_INTEGRATION_TESTS"

private var compactionRoundTripIntegrationEnabled: Bool {
    ProcessInfo.processInfo.environment[compactionRoundTripIntegrationEnvVar] != nil
}

/// The same real `mlx-community` generation model the rest of this target's
/// gated suites use for the `.standard` slot.
private let compactionRoundTripTinyModel: ModelRef = RealModels.standard

// MARK: - Suite

/// The gated end-to-end round trip for task rjvrgt9 (compaction_plan.md §4,
/// §5): the same five-step loop `Examples/CompactionDemo` prints for a human
/// to read, asserted mechanically here against a real model instead:
///
/// 1. `contextFill` climbs across scripted turns that grow the transcript.
/// 2. Compacting at the 0.80 trigger shrinks `contextFill` and never changes
///    the session's identity (id, recording directory, router id).
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
/// ``RoutedModel/restoreSessionTree(root:registry:)`` surface without paying
/// for two extra downloads. `Self.context` (2048) is deliberately smaller than
/// `RealModels.context` (8192) — the same convention `Examples/CompactionDemo`
/// uses — so a handful of scripted turns crosses the 0.80 compaction trigger
/// without needing enormous prompts.
///
/// Not executed in the authoring sandbox: like every other gated suite in
/// this target, a pre-existing MLX `default.metallib` load failure blocks
/// real-model runs here (see `compaction_plan.md`'s build-order §6.1 spike
/// notes for the same environment limitation, reproduced identically against
/// already-passing suites). This is an environment limitation of that
/// sandbox, not something this task introduced; the suite is asserted to
/// compile and be correctly gated, per this task's own instructions.
@Suite(
    "Gated real-model end-to-end coverage: RoutedSession.compact(prompt:budget:) round trip (task rjvrgt9)",
    .serialized,
    .timeLimit(.minutes(20)),
    .enabled(if: compactionRoundTripIntegrationEnabled)
)
struct CompactionRoundTripIntegrationTests {
    /// A minimal ``LoadedEmbeddingContainer`` stand-in for the unused
    /// `.embedding` slot the ``LanguageModelProfile`` this suite builds must
    /// still carry — never exercised here, only present to satisfy the type.
    private struct UnusedEmbeddingContainer: LoadedEmbeddingContainer {
        let dimension = 1
        func embed(texts: [String]) async throws -> [[Float]] { [] }
    }

    /// The working context this suite resolves the tiny model at — smaller
    /// than ``RealModels/context`` so scripted turns cross the 0.80
    /// compaction trigger without needing huge prompts. See this type's own
    /// doc comment.
    private static let context = 2048

    /// Loads the tiny model directly through a real ``LiveModelLoader`` and
    /// returns its concrete ``MLXFoundationModelsContainer``. Called once per
    /// simulated "process" — the second call models a fresh process reloading
    /// the same model from the Hub cache.
    private func makeContainer() async throws -> MLXFoundationModelsContainer {
        let loader = LiveModelLoader(
            downloader: #hubDownloader(),
            tokenizerLoader: #huggingFaceTokenizerLoader()
        )
        let loaded = try await loader.loadLLM(
            ref: compactionRoundTripTinyModel,
            slot: .standard,
            context: Self.context,
            reporting: { _ in }
        )
        return try #require(loaded as? MLXFoundationModelsContainer)
    }

    /// Builds a real ``LanguageModelProfile`` directly over `container`,
    /// stamped with `id` (pass the first router's `id` to continue the same
    /// recording root) and `recordingsDir` — the same manual-harness
    /// technique ``SessionTreeRestorationIntegrationTests`` uses, so this
    /// suite reaches `Router.resolve(_:reporting:)`-adjacent behavior without
    /// downloading the `.flash`/`.embedding` slots too.
    private func buildProfile(
        id: ULID = .generate(),
        container: MLXFoundationModelsContainer,
        cacheDir: URL,
        recordingsDir: URL
    ) -> (router: Router, profile: LanguageModelProfile) {
        let recorder = JSONLRecorder(directory: recordingsDir)
        let router = Router(id: id, cacheDir: cacheDir, recordingsDir: recordingsDir, recorder: recorder)

        func noopResolution(_ slot: ModelSlot) -> SlotResolution {
            SlotResolution(
                slot: slot,
                remainingBudgetBytes: 0,
                chosen: compactionRoundTripTinyModel,
                considered: [],
                contextTokens: Self.context
            )
        }
        // The same root-plus-writer pair `Router.makeDurableRecording` builds:
        // every session vended below writes its `session.json` through this, so
        // the tree this suite restores from carries the facts to interpret it
        // by.
        func durableRecording(_ slot: ModelSlot) -> DurableRecording {
            DurableRecording(
                root: recordingsDir,
                sidecarWriter: SessionSidecarWriter(
                    slot: slot,
                    model: compactionRoundTripTinyModel,
                    context: noopResolution(slot).contextTokens,
                    recordingLevel: .full,
                    profile: nil
                )
            )
        }
        let standard = RoutedLLM(
            slot: .standard,
            chosen: compactionRoundTripTinyModel,
            footprintBytes: 0,
            resolution: noopResolution(.standard),
            container: container,
            routerId: router.id,
            recorder: recorder,
            durableRecording: durableRecording(.standard)
        )
        let flash = RoutedLLM(
            slot: .flash,
            chosen: compactionRoundTripTinyModel,
            footprintBytes: 0,
            resolution: noopResolution(.flash),
            container: container,
            routerId: router.id,
            recorder: recorder,
            durableRecording: durableRecording(.flash)
        )
        let embedding = RoutedEmbedder(
            slot: .embedding,
            chosen: compactionRoundTripTinyModel,
            footprintBytes: 0,
            resolution: noopResolution(.embedding),
            container: UnusedEmbeddingContainer(),
            routerId: router.id,
            recorder: recorder,
            durableRecording: durableRecording(.embedding)
        )
        let profile = LanguageModelProfile(
            definitionName: "test",
            standard: standard,
            flash: flash,
            embedding: embedding,
            router: router,
            residencyToken: .generate()
        )
        return (router, profile)
    }

    /// Long, distinct scripted documents fed into the session one per turn —
    /// enough cumulative text, against ``context``'s small 2048-token budget,
    /// to cross the 0.80 compaction trigger within a handful of turns. The
    /// first plants a fact only recoverable, after compaction, from the
    /// fold's summary — mirroring `Examples/CompactionDemo`'s own fixtures.
    private static let scriptedTurns: [String] = [
        """
        Project brief: this session's internal vault code is CRIMSON-77.
        Remember it precisely; you will be asked about it later. The project
        catalogs a fictional archive of nineteenth-century weather station
        logs from six remote outposts, each reporting barometric pressure,
        wind direction, and temperature three times daily for eleven
        consecutive years. Reply with one short sentence acknowledging this.
        """,
        """
        Architecture notes: the archive is split into per-outpost shards,
        each stored as a delimited text file with a fixed-width header
        naming the outpost, its coordinates, and the observer's name for
        that decade. Shards are concatenated chronologically before
        indexing, so ingestion must sort by the header's decade field
        before doing anything else. Reply with one short sentence
        acknowledging this.
        """,
        """
        Data-quality notes: roughly four percent of entries are missing a
        wind-direction reading, always recorded as a bare dash rather than
        omitted entirely, so parsers must treat a lone dash as an explicit
        missing value rather than a parse failure. A smaller share carry an
        obviously transposed temperature decimal, flagged for manual review
        rather than auto-corrected. Reply with one short sentence
        acknowledging this.
        """,
        """
        Indexing notes: the search index keys on outpost name and decade,
        with a secondary index on temperature range so a query for cold
        readings at any outpost in a given decade resolves without a full
        scan. The secondary index is rebuilt lazily, the first time a
        range-style query touches an un-indexed decade. Reply with one
        short sentence acknowledging this.
        """,
        """
        Open questions: whether to normalize pre-1875 pressure readings,
        which used a different reference unit than later entries, and
        whether the six outposts should be weighted equally or by their
        number of surviving entries when computing archive-wide averages,
        since two outposts lost several years of records to a fire. Reply
        with one short sentence acknowledging this.
        """,
        """
        Status notes: three of the six outposts have been fully indexed and
        validated against their source shards. The remaining three await a
        second ingestion pass to resolve the missing wind-direction dashes
        described earlier, since the first pass's parser predates that fix.
        Reply with one short sentence acknowledging this.
        """,
        """
        Further status: no archive-wide statistics should be treated as
        final until all six outposts have passed the second ingestion pass.
        The three already-indexed outposts are believed correct on their
        own, but any statistic mixing outposts across the two ingestion
        passes is provisional. Reply with one short sentence acknowledging
        this.
        """,
        """
        Final notes for this session: the second ingestion pass is expected
        to complete within the week, at which point the archive-wide
        averages described earlier can be finalized and the open questions
        about normalization and outpost weighting revisited. Reply with one
        short sentence acknowledging this.
        """,
    ]

    @Test(
        "contextFill climbs, compact() folds at the 0.80 trigger preserving identity, a post-compact turn recalls the folded fact, restore yields the checkpointed window, and a further turn succeeds"
    )
    func compactionRoundTrip() async throws {
        try await GatedSuiteSerialGate.shared.withPermit {
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

            let container = try await makeContainer()
            let (router, profile) = buildProfile(
                container: container, cacheDir: cacheDir, recordingsDir: recordingsDir)

            let session = profile.standard.makeSession(
                instructions: "You are a terse assistant. Follow each instruction exactly and keep replies to one sentence."
            )
            let sessionId = session.id
            let recordingDirectoryBefore = session.recordingDirectory

            // 1. contextFill climbs across scripted turns.
            var fills: [Double] = []
            for turn in Self.scriptedTurns {
                _ = try await session.respond(to: turn, maxTokens: 64)
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
            let result = try await session.compact()
            #expect(!result.stagesApplied.isEmpty, "expected at least one stage to fold the over-budget transcript")
            #expect(result.tokensAfter < result.tokensBefore)
            let fillAfterCompaction = await session.contextFill
            #expect(fillAfterCompaction < fillBeforeCompaction)
            #expect(session.id == sessionId)
            #expect(session.recordingDirectory == recordingDirectoryBefore)
            #expect(session.routerId == router.id)

            // 3. A turn after compaction succeeds and recalls the folded
            //    fact — proof the summary, not just the mechanism, worked.
            let recall = try await session.respond(
                to: "Without re-reading anything, what is the exact vault code from the project brief?",
                maxTokens: 32
            )
            #expect(!recall.isEmpty)
            #expect(recall.contains("CRIMSON-77"))

            await container.model.evict()

            // 4. Restore from disk — a fresh Router/profile over the same
            //    recording root, simulating a new process — yields the
            //    checkpointed live window: fewer entries than the full
            //    recorded history.
            let container2 = try await makeContainer()
            let (_, profile2) = buildProfile(
                id: router.id, container: container2, cacheDir: cacheDir, recordingsDir: recordingsDir
            )
            let restoredTree = try await profile2.standard.restoreSessionTree(root: sessionId)
            let restoredSession = restoredTree.root
            #expect(restoredSession.id == sessionId)

            let routerDirectory = recordingsDir.appendingPathComponent(router.id.description, isDirectory: true)
            let tree = try TranscriptTree.load(under: routerDirectory)
            let checkpointedWindow = try tree.effectiveTranscript(forSession: sessionId)
            let fullHistory = try tree.effectiveTranscript(forSession: sessionId, view: .fullHistory)
            #expect(
                checkpointedWindow.count < fullHistory.count,
                "the checkpointed restore view should be strictly smaller than the full recorded history"
            )

            // 5. A further turn on the restored session succeeds.
            let restoredReply = try await restoredSession.respond(
                to: "Reply with just the word \"restored\".", maxTokens: 16)
            #expect(!restoredReply.isEmpty)

            await container2.model.evict()
        }
    }
}
