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
/// 2. Compacting once the 0.80 trigger is reached — against ``foldBudget``,
///    which forces the whole pipeline through its model-assisted stage —
///    shrinks `contextFill` and never changes the session's identity (id,
///    recording directory, router id).
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
/// ``RoutedModel/restoreSessionTree(root:recordingRoot:registry:tools:)`` surface without paying
/// for two extra downloads. `Self.context` (2048) is deliberately smaller than
/// `RealModels.context` (8192) — the same convention `Examples/CompactionDemo`
/// uses — so a handful of scripted turns crosses the 0.80 compaction trigger
/// without needing enormous prompts.
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
    .enabled(if: compactionRoundTripIntegrationEnabled),
    .exclusiveRealModel
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
    fileprivate static let context = 2048

    /// The reply ceiling every scripted turn below is submitted with, and the
    /// worst case ``ScriptedTurnSizingTests`` bounds a turn's total size by.
    fileprivate static let replyMaxTokens = 64

    /// The system instructions the round trip's session is created with —
    /// part of the transcript's header, which no compaction stage may touch,
    /// so ``ScriptedTurnSizingTests`` counts it too.
    fileprivate static let instructions =
        "You are a terse assistant. Follow each instruction exactly and keep replies to one sentence."

    /// The budget the round trip folds against.
    ///
    /// Deliberately not the default (`target` 0.50). A 0.50 target of this
    /// suite's 2048-token working context is 1024 estimated tokens, and the
    /// four newest scripted turns — the recency window
    /// ``ToolOutputElision``/``TurnTruncation`` may not touch — estimate
    /// within a couple of hundred tokens of that either side depending on how
    /// long the model's own four most recent replies happened to run. Whether
    /// the deterministic stages landed under target on their own, and so
    /// whether ``Summarization`` ran at all, was therefore decided by sampled
    /// reply lengths rather than by anything this suite asserts — the same run
    /// could reach stage 3 or stop at stage 2 (task f80n046). Both shapes now
    /// record a compaction checkpoint (task ^h1008kb), but only the stage-3
    /// run synthesizes the real summary whose recall step 3 measures.
    ///
    /// A 0.25 target is 512 tokens, which the recency window's own prompt text
    /// exceeds on its own by a wide margin whichever four turns it happens to
    /// be — ``ScriptedTurnSizingTests/recencyWindowCannotFitUnderTheFoldTarget()``
    /// pins that mechanically — so the deterministic stages cannot land under
    /// it and the model-assisted stage always runs. It changes nothing about
    /// *what* is folded: the old/recent split is `keepRecentTurns`' business,
    /// not the target's, so the folded span, the summary, and the restored
    /// window are exactly what a default-budget fold would produce on the run
    /// where it happened to reach stage 3.
    fileprivate static let foldBudget = TokenBudget(limit: context, target: 0.25)

    /// Loads the tiny model directly through a real ``LiveModelLoader`` and
    /// returns its concrete ``MLXFoundationModelsContainer``. Called once per
    /// simulated "process" — the second call models a fresh process reloading
    /// the same model from the Hub cache.
    ///
    /// Decoding is pinned to
    /// ``FoundationModels/GenerationOptions/SamplingMode/greedy``. The provider
    /// default samples at temperature `0.6` from MLX's process-global PRNG,
    /// which seeds itself from the clock, so this suite's own scripted replies
    /// — and therefore its transcript sizes, its fold, and its recall answer —
    /// differed on every run of identical code (task f80n046). Argmax decoding
    /// consumes no randomness at all, which is what lets a red run here be
    /// attributed to the change under test.
    private func makeContainer() async throws -> MLXFoundationModelsContainer {
        let loader = LiveModelLoader(
            downloader: #hubDownloader(),
            tokenizerLoader: #huggingFaceTokenizerLoader(),
            samplingMode: .greedy
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
                    profile: nil,
                    routerId: router.id
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
    ///
    /// Each turn is a long paragraph, and the length is load-bearing rather
    /// than decorative: crossing the trigger takes 1638 measured tokens
    /// (`0.80 * 2048`), so the turns have to carry that much text between them
    /// before the loop below runs out of them. The shorter versions these
    /// replaced totalled roughly 718 estimated tokens across all eight — the
    /// live run measured 846 and stalled at a `contextFill` of 0.41, less than
    /// half the trigger, because the suite had never actually executed against
    /// real hardware to find out (task 5m97h14).
    /// `ScriptedTurnSizingTests` pins the size so it cannot silently shrink
    /// again.
    fileprivate static let scriptedTurns: [String] = [
        """
        Project brief: this session's internal vault code is CRIMSON-77.
        Remember it precisely; you will be asked about it later. The project
        catalogs a fictional archive of nineteenth-century weather station
        logs from six remote outposts, each reporting barometric pressure,
        wind direction, and temperature three times daily for eleven
        consecutive years. The outposts were staffed on rotating two-year
        postings, so the handwriting changes partway through most volumes and
        the abbreviations used for wind direction change along with it. Two of
        the six kept their readings in a local unit that a later archivist
        converted in pencil directly onto the original page, which means the
        converted figures and the originals now sit side by side with nothing
        marking which is which. The archive also holds the outposts' incoming
        correspondence, which is out of scope for this project but shares the
        same shelf numbering and is easy to pull by mistake. Reply with one
        short sentence acknowledging this.
        """,
        """
        Architecture notes: the archive is split into per-outpost shards,
        each stored as a delimited text file with a fixed-width header
        naming the outpost, its coordinates, and the observer's name for
        that decade. Shards are concatenated chronologically before
        indexing, so ingestion must sort by the header's decade field
        before doing anything else; sorting by filename looks equivalent and
        is not, because three of the outposts were renamed mid-century and
        their files were retitled to match. The delimiter is a tab in the
        earlier shards and a run of spaces in the later ones, a change that
        was never recorded anywhere except in the ingestion code, so the
        reader sniffs the first data line of each shard rather than trusting
        a configured value. Headers are repeated at the top of every page in
        the original volumes and were transcribed each time, so the reader
        also has to drop repeated headers rather than treat them as rows.
        Reply with one short sentence acknowledging this.
        """,
        """
        Data-quality notes: roughly four percent of entries are missing a
        wind-direction reading, always recorded as a bare dash rather than
        omitted entirely, so parsers must treat a lone dash as an explicit
        missing value rather than a parse failure. A smaller share carry an
        obviously transposed temperature decimal, flagged for manual review
        rather than auto-corrected, because the transposition is not always
        recoverable: a reading of 3.71 could plausibly have been 37.1 or
        73.1 depending on the season and the outpost's altitude. Pressure
        readings taken during the two documented instrument replacements
        show a step change of about half a unit that is an artefact of the
        new instrument rather than weather, and the archive's own notes
        disagree with the correspondence about exactly which week each
        replacement happened. None of these are corrected in place; every
        one is annotated. Reply with one short sentence acknowledging this.
        """,
        """
        Indexing notes: the search index keys on outpost name and decade,
        with a secondary index on temperature range so a query for cold
        readings at any outpost in a given decade resolves without a full
        scan. The secondary index is rebuilt lazily, the first time a
        range-style query touches an un-indexed decade, which keeps the
        initial ingest fast at the cost of one slow query per decade per
        process. Outpost names are stored twice, once as transcribed and
        once normalised, because the renames mean a single outpost appears
        under two names across the archive and a reader searching for either
        should find both. The decade field is stored as an integer rather
        than a string so range queries work without lexicographic
        surprises, and the pre-1800 volumes, of which there are only a
        handful, are excluded from the secondary index entirely rather than
        special-cased. Reply with one short sentence acknowledging this.
        """,
        """
        Open questions: whether to normalize pre-1875 pressure readings,
        which used a different reference unit than later entries, and
        whether the six outposts should be weighted equally or by their
        number of surviving entries when computing archive-wide averages,
        since two outposts lost several years of records to a fire. Related
        and unresolved: whether a reading annotated as a suspected
        transposition should be excluded from averages, included as
        transcribed, or included with the correction the annotator
        suggested but did not apply. Excluding them biases the averages
        toward the outposts with tidier record-keeping, and including them
        as transcribed leaves a handful of physically impossible values in
        the summary statistics. There is also no agreement on whether the
        pencil unit conversions should be treated as data or as commentary.
        Reply with one short sentence acknowledging this.
        """,
        """
        Status notes: three of the six outposts have been fully indexed and
        validated against their source shards. The remaining three await a
        second ingestion pass to resolve the missing wind-direction dashes
        described earlier, since the first pass's parser predates that fix
        and silently dropped those rows instead of keeping them as explicit
        missing values. The validation for the finished three compared row
        counts, date continuity, and a sampled hundred readings per decade
        against photographs of the original pages; two transcription errors
        were found and corrected that way, both in the same volume, both in
        the observer name rather than in a reading. The photographs
        themselves are not part of the archive and live on separate
        storage, so the validation is not reproducible from the archive
        alone, which several people have objected to. Reply with one short
        sentence acknowledging this.
        """,
        """
        Further status: no archive-wide statistics should be treated as
        final until all six outposts have passed the second ingestion pass.
        The three already-indexed outposts are believed correct on their
        own, but any statistic mixing outposts across the two ingestion
        passes is provisional, and that includes every headline number
        published so far. The provisional figures have already been quoted
        in two internal write-ups without that caveat attached, which is
        how the current confusion started, and both write-ups now carry a
        correction notice that is easy to miss. Going forward every derived
        figure is stamped with the ingestion-pass state of each outpost it
        draws on, so a reader can tell at a glance whether a number mixes
        passes, and any figure that does is rendered in a way that makes
        the mixture obvious rather than relying on a footnote. Reply with
        one short sentence acknowledging this.
        """,
        """
        Final notes for this session: the second ingestion pass is expected
        to complete within the week, at which point the archive-wide
        averages described earlier can be finalized and the open questions
        about normalization and outpost weighting revisited. The plan is to
        resolve the weighting question first, since the normalization
        decision only changes pre-1875 readings while the weighting
        decision changes every archive-wide figure, and to write both
        decisions down as part of the archive rather than as a separate
        document that can drift away from it. After that the remaining work
        is the transposition annotations, which need a human pass rather
        than a rule, and the question of what to do with the pencil unit
        conversions. Nothing in this list depends on the indexing work,
        which is finished apart from the lazy secondary-index rebuilds.
        Reply with one short sentence acknowledging this.
        """,
    ]

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

        let container = try await makeContainer()
        let (router, profile) = buildProfile(
            container: container, cacheDir: cacheDir, recordingsDir: recordingsDir)

        let session = profile.standard.makeSession(instructions: Self.instructions)
        let sessionId = session.id
        let recordingDirectoryBefore = session.recordingDirectory

        // 1. contextFill climbs across scripted turns.
        var fills: [Double] = []
        for turn in Self.scriptedTurns {
            _ = try await session.respond(to: turn, maxTokens: Self.replyMaxTokens)
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
        let result = try await session.compact(budget: Self.foldBudget)
        // Every stage, in order — not merely "something ran". A fold that
        // stops after the deterministic stages records a checkpoint too
        // (task ^h1008kb), but this test is about the model-assisted round
        // trip — a real summary whose quality step 3 measures by recall —
        // so `stagesApplied` non-empty cannot tell that fold from this
        // one. `Self.foldBudget` is what makes the full pipeline a
        // property here rather than a coincidence.
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
        // near zero). Reported against `Self.foldBudget`'s 0.25 target,
        // not the production default of 0.50 — see `foldBudget`.
        print(
            "[compactionRoundTrip] tokensBefore=\(result.tokensBefore) tokensAfter=\(result.tokensAfter) "
                + "saved=\(result.tokensBefore - result.tokensAfter)"
        )
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

// MARK: - Ungated fixture sizing

/// Ungated proof that ``CompactionRoundTripIntegrationTests``' own scripted
/// turns are still sized to reach the 0.80 compaction trigger (task 5m97h14).
///
/// The gated suite above is the real end-to-end proof, but it only runs with
/// `FM_ROUTER_INTEGRATION_TESTS` set and a GPU present, so nothing under a
/// plain `swift test` noticed when its fixtures were less than half the size
/// the trigger needs — the suite's own doc comment claimed "a handful of
/// scripted turns crosses the 0.80 compaction trigger" and a live run measured
/// a `contextFill` of 0.41 against a 0.80 trigger. These two assertions are
/// mechanical, need no model, and fail loudly if the fixtures shrink or grow
/// out of range again.
@Suite("CompactionRoundTripIntegrationTests fixture sizing (ungated)")
struct ScriptedTurnSizingTests {
    /// The measured usage, in tokens, the gated suite's loop waits to see —
    /// ``CompactionRoundTripIntegrationTests/context`` at the default
    /// ``TokenBudget/trigger``, which is the same threshold that suite's
    /// `fillBeforeCompaction >= 0.80` assertion checks.
    private static var triggerTokens: Int {
        TokenBudget(limit: CompactionRoundTripIntegrationTests.context).triggerTokens
    }

    /// How many of the newest turns the deterministic stages must leave
    /// untouched — read off ``TurnTruncation``'s own default rather than
    /// restated, so this suite tracks the stage it reasons about.
    private static var keepRecentTurns: Int {
        TurnTruncation().keepRecentTurns
    }

    /// The estimated token count of each scripted turn's prompt text, in order.
    private static var perTurnTokens: [Int] {
        CompactionRoundTripIntegrationTests.scriptedTurns.map(Compactor.estimatedTokenCount(of:))
    }

    @Test("the scripted turns carry more prompt tokens between them than the 0.80 trigger needs")
    func scriptedTurnsExceedTheTrigger() throws {
        // Prompt text only: a live transcript also carries the instructions and
        // every reply, so this is the conservative bound — the real run crosses
        // the trigger strictly sooner than these numbers alone would.
        let total = Self.perTurnTokens.reduce(0, +)
        #expect(
            total > Self.triggerTokens,
            "the scripted turns estimate \(total) prompt tokens, which does not exceed the trigger's \(Self.triggerTokens)"
        )
    }

    @Test("the prefix that first crosses the trigger still fits inside the working context")
    func crossingPrefixFitsTheContext() throws {
        // The turn that crosses the trigger is submitted with everything before
        // it as its prompt, so that prefix has to fit the window or the turn
        // dies instead of folding. Replies push the real crossing earlier,
        // making this the worst case for prompt size.
        var cumulative = 0
        var crossingPrefix: Int?
        for tokens in Self.perTurnTokens {
            cumulative += tokens
            if cumulative > Self.triggerTokens {
                crossingPrefix = cumulative
                break
            }
        }
        let prefix = try #require(
            crossingPrefix, "no prefix of the scripted turns crosses the trigger at all")
        #expect(
            prefix <= CompactionRoundTripIntegrationTests.context,
            "the prefix that crosses the trigger estimates \(prefix) tokens, over the \(CompactionRoundTripIntegrationTests.context)-token working context"
        )
    }

    // MARK: - The fold reaches the model-assisted stage by construction (task f80n046)

    @Test("no window of consecutive scripted turns fits under the fold target, so the deterministic stages alone can never land it")
    func recencyWindowCannotFitUnderTheFoldTarget() throws {
        // `TurnTruncation` keeps the newest `keepRecentTurns` turns verbatim
        // and `ToolOutputElision` touches nothing here (these turns call no
        // tools), so the deterministic pipeline's floor is that window. When
        // the window cannot fit under target, the pipeline must fall through
        // to `Summarization` — which is the only stage that synthesizes the
        // summary entry the gated suite's step 4 restores.
        //
        // Which four turns the window holds depends on how many turns the live
        // run needed to cross the trigger, so every consecutive window is
        // checked rather than only the last. Prompt text alone: the window also
        // carries the replies and the header, which only add.
        let targetTokens = CompactionRoundTripIntegrationTests.foldBudget.targetTokens
        let keepRecentTurns = Self.keepRecentTurns
        let turns = CompactionRoundTripIntegrationTests.scriptedTurns
        #expect(turns.count > keepRecentTurns)
        for start in 0...(turns.count - keepRecentTurns) {
            let window = turns[start..<(start + keepRecentTurns)]
            let windowTokens = Compactor.estimatedTokenCount(of: window.joined())
            #expect(
                windowTokens > targetTokens,
                "turns \(start)..<\(start + keepRecentTurns) estimate \(windowTokens) prompt tokens, which does not exceed the fold target's \(targetTokens)"
            )
        }
    }

    @Test("the first turns cannot cross the trigger before some turn falls outside the recency window, so a fold always has an old span to summarize")
    func triggerIsNotReachedBeforeAnOldSpanExists() throws {
        // The other half of the same property: `Summarization` returns `nil`
        // — and the pipeline reports the oversized-tail shortfall with an
        // empty `stagesApplied` — when every turn is still inside the recency
        // window. So the trigger must not be reachable within the first
        // `keepRecentTurns` turns.
        //
        // Worst case, and mechanical: every one of those turns' replies runs
        // to the full `replyMaxTokens` ceiling, and the header's instructions
        // count too.
        let keepRecentTurns = Self.keepRecentTurns
        let firstTurns = CompactionRoundTripIntegrationTests.scriptedTurns.prefix(keepRecentTurns)
        let promptTokens = Compactor.estimatedTokenCount(of: firstTurns.joined())
        let replyTokens = keepRecentTurns * CompactionRoundTripIntegrationTests.replyMaxTokens
        let headerTokens = Compactor.estimatedTokenCount(of: CompactionRoundTripIntegrationTests.instructions)
        let worstCase = promptTokens + replyTokens + headerTokens
        #expect(
            worstCase < Self.triggerTokens,
            "the first \(keepRecentTurns) turns reach \(worstCase) tokens at their largest, at or over the trigger's \(Self.triggerTokens) — the fold could find no turn outside the recency window to summarize"
        )
    }
}
