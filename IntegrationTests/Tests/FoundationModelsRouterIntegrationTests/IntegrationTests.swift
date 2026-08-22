import Foundation
import FoundationModels
import FoundationModelsRouterRealModelSupport
import FoundationModelsRouterTestSupport
import HuggingFace
import MLXHuggingFace
import MLXLMCommon
import Testing
import Tokenizers

@testable import FoundationModelsRouter

// MARK: - Real models

/// The profile the suite resolves, over ``RealModels``' `standard`/`flash`/
/// `embedding` repos — a real generation model in both generation slots plus a
/// real embedder, all co-resident, so the resolution/generation/embedding/
/// guided-generation/fork assertions below run against real weights rather
/// than one tiny placeholder repo.
///
/// Both generation slots name one repository today, because only one Muse
/// Glimmer repository is published — see ``RealModels/flash``. The two slots
/// therefore share one resident container, which is what
/// ``realProfileResidentContainerCount`` counts.
private let realProfile = ProfileDefinition(
    name: "integration-real",
    description: "Real mlx-community models for the gated integration suite.",
    standard: [RealModels.standard],
    flash: [RealModels.flash],
    embedding: [RealModels.embedding],
    context: RealModels.context
)

/// How many resident containers ``realProfile`` asks the loader to build, and
/// so how many times the loader below records a load and a preload.
///
/// Read off the resolve path, not off a measured run. `Router.acquireModel`
/// reads its pool before it reaches the loader and returns an already-resident
/// entry, so the loader runs one time for each distinct residency key rather
/// than one time for each slot; the preload loop guards itself the same way
/// with its own set of already-preloaded keys. A generation key is the chosen
/// reference together with the working context, and ``realProfile`` gives one
/// context to every slot, so two generation slots that name one repository
/// build one key and load one container. An embedding key carries a different
/// role, so it never merges with a generation key however the references are
/// named.
private var realProfileResidentContainerCount: Int {
    let generationRefs = Set([RealModels.standard, RealModels.flash])
    let embeddingRefs = Set([RealModels.embedding])
    return generationRefs.count + embeddingRefs.count
}

// MARK: - Phase-recording decorators

/// Wraps a real ``MetadataSource`` and records the live ``ResolutionProgress``
/// phase observed at each fetch, so the suite can prove sizing happens in the
/// `.sizing` phase — the same technique the unit `ResolveTests` use, but over the
/// real Hub source.
private actor PhaseRecordingMetadataSource: MetadataSource {
    private let wrapped: any MetadataSource
    private let progress: ResolutionProgress
    private(set) var observedPhases: [ResolutionProgress.Phase] = []

    init(wrapping: any MetadataSource, progress: ResolutionProgress) {
        self.wrapped = wrapping
        self.progress = progress
    }

    func fetchRawMetadata(repo: String, revision: String?) async throws -> RawRepoMetadata {
        observedPhases.append(await MainActor.run { progress.phase })
        return try await wrapped.fetchRawMetadata(repo: repo, revision: revision)
    }
}

/// Wraps a real ``ModelLoader`` and records the live ``ResolutionProgress`` phase
/// observed at each load and preload, so the suite can prove the pipeline
/// advances `downloading → loading → ready` over the real ``LiveModelLoader``.
private actor PhaseRecordingLoader: ModelLoader {
    private let wrapped: any ModelLoader
    private let progress: ResolutionProgress
    private(set) var observedLoadPhases: [ResolutionProgress.Phase] = []
    private(set) var observedPreloadPhases: [ResolutionProgress.Phase] = []

    init(wrapping: any ModelLoader, progress: ResolutionProgress) {
        self.wrapped = wrapping
        self.progress = progress
    }

    func loadLLM(
        ref: ModelRef,
        slot: ModelSlot,
        context: Int,
        reporting: @escaping @Sendable (DownloadProgress) -> Void
    ) async throws -> any LoadedLLMContainer {
        observedLoadPhases.append(await MainActor.run { progress.phase })
        return try await wrapped.loadLLM(ref: ref, slot: slot, context: context, reporting: reporting)
    }

    func loadEmbedder(
        ref: ModelRef,
        slot: ModelSlot,
        reporting: @escaping @Sendable (DownloadProgress) -> Void
    ) async throws -> any LoadedEmbeddingContainer {
        observedLoadPhases.append(await MainActor.run { progress.phase })
        return try await wrapped.loadEmbedder(ref: ref, slot: slot, reporting: reporting)
    }

    func preload(container: any LoadedModelContainer) async throws {
        observedPreloadPhases.append(await MainActor.run { progress.phase })
        try await wrapped.preload(container: container)
    }

    func evict(container: any LoadedModelContainer) async {
        await wrapped.evict(container: container)
    }
}

// MARK: - Download-byte observation

/// A thread-safe recorder of the raw ``DownloadProgress`` ticks a slot's download
/// forwards, so the gated suite can prove the live byte percentage is real —
/// `bytesTotal > 0` and `bytesDownloaded` reaching `bytesTotal` across the ticks,
/// not a single `0 → 100` jump.
///
/// `@unchecked Sendable` with a lock because the loader's `@Sendable` reporting
/// closure records into it from the download's own execution context.
private final class DownloadByteObserver: @unchecked Sendable {
    private let lock = NSLock()
    private var ticksBySlot: [ModelSlot: [DownloadProgress]] = [:]

    /// Wraps a slot's reporting closure so every tick is recorded before being
    /// forwarded to the router's own reporter.
    func capturing(
        slot: ModelSlot,
        forwarding reporting: @escaping @Sendable (DownloadProgress) -> Void
    ) -> @Sendable (DownloadProgress) -> Void {
        { dp in
            self.lock.lock()
            self.ticksBySlot[slot, default: []].append(dp)
            self.lock.unlock()
            reporting(dp)
        }
    }

    /// The slots that observed at least one download tick.
    var observedSlots: [ModelSlot] {
        lock.lock()
        defer { lock.unlock() }
        return Array(ticksBySlot.keys)
    }

    /// The ticks recorded for a slot, in arrival order.
    func ticks(for slot: ModelSlot) -> [DownloadProgress] {
        lock.lock()
        defer { lock.unlock() }
        return ticksBySlot[slot] ?? []
    }
}

/// Wraps a real ``ModelLoader`` and captures the ``DownloadProgress`` ticks each
/// slot's download forwards into a ``DownloadByteObserver``, without disturbing
/// the router's own reporting.
private struct DownloadObservingLoader: ModelLoader {
    let wrapped: any ModelLoader
    let observer: DownloadByteObserver

    func loadLLM(
        ref: ModelRef,
        slot: ModelSlot,
        context: Int,
        reporting: @escaping @Sendable (DownloadProgress) -> Void
    ) async throws -> any LoadedLLMContainer {
        try await wrapped.loadLLM(
            ref: ref,
            slot: slot,
            context: context,
            reporting: observer.capturing(slot: slot, forwarding: reporting)
        )
    }

    func loadEmbedder(
        ref: ModelRef,
        slot: ModelSlot,
        reporting: @escaping @Sendable (DownloadProgress) -> Void
    ) async throws -> any LoadedEmbeddingContainer {
        try await wrapped.loadEmbedder(
            ref: ref,
            slot: slot,
            reporting: observer.capturing(slot: slot, forwarding: reporting)
        )
    }

    func preload(container: any LoadedModelContainer) async throws {
        try await wrapped.preload(container: container)
    }

    func evict(container: any LoadedModelContainer) async {
        await wrapped.evict(container: container)
    }
}

// MARK: - Suite

/// The gated end-to-end integration suite (milestone 7).
///
/// It resolves the ``realProfile`` once — all three slots co-resident — over a
/// real ``LiveModelLoader`` (a Hub `#hubDownloader()` + `#huggingFaceTokenizerLoader()`)
/// and the real ``HuggingFaceMetadataSource``, then asserts every live capability
/// in that one resolved profile: progress advancement, generation, embedding
/// (with its transcript event), guided generation, fork lineage, and the merged
/// transcript's total order.
///
/// In a target of its own so it never runs on a network/GPU-less box: the whole
/// package's deployment floor is macOS 27 (so the macOS-27 availability the
/// milestone calls for is guaranteed structurally — Swift Testing's
/// `@Suite`/`@Test` macros reject a redundant `@available` attribute on the
/// type), and the target lives in the nested `IntegrationTests/` package,
/// which a root `swift test` cannot see. `.serialized` so the heavy load
/// happens once at a time, under ``integrationTestBudgetMinutes``. Downloads
/// are cached on disk by the Hub client and reused across runs — a box that has
/// never fetched these models pays that download inside the budget.
///
/// The three runs of 2026-08-20 measured this test at 46.6, then 48.7, then
/// 44.9 seconds, against the 30 minutes the limit stated before task ^k0d30s4's
/// budget replaced it. See ``integrationTestBudgetMinutes`` for the whole
/// run table.
///
/// ## What it NO LONGER proves (task ^pa5q5dt)
///
/// Runs 6 and 7 of 2026-08-21 measured this test at 89.8 and 55.0 seconds, and
/// the 89.8 was 75 percent of ``integrationTestBudgetMinutes`` and the dearest
/// test of the target. The per-phase clock this test now prints says where the
/// cost stands. Measured in isolation on 2026-08-22, on a box that ran a
/// GPU-heavy game for the whole measurement (load average above 10): resolve
/// 5.4 seconds, the plain turn 22.4, the embedding 0.03, the guided turn 5.2,
/// the fork turn 20.6 and the parent turn 2.0 — 55.8 seconds, of which the two
/// first turns of a session are 43. Each of those turns is one short prompt
/// answered by the 30B, so the cost is the `<think>` block it writes ahead of
/// the answer.
///
/// Three changes stand against that, and each is stated where it is made:
/// ``samplingMode`` pins argmax decoding; every turn passes
/// ``GatedRealModelBudget/responseTokenCeiling`` as its reply ceiling; and the
/// test body is no longer `@MainActor`, so only the `@MainActor`
/// ``ResolutionProgress`` reads hop to the main actor. The measurement after
/// them, on the same box under the same load: 57.1 seconds, with the plain
/// turn at 22.5 and the fork turn at 22.2.
///
/// ``RealModels/standard`` stays. This is the one test of the target that
/// drives `Router.resolve(profile:reporting:)` end to end over the real Hub —
/// real sizing, real joint fit and two real containers co-resident — and the
/// profile it resolves is the one the rest of the target names. Every other
/// gated suite loads a container directly and never reaches the resolver, so
/// a smaller generation model here would stop proving that the standard
/// profile resolves at all. `RealToolTurnComparisonTests` states the same
/// trade in the other direction, for a suite whose point is the tool turn
/// rather than the resolution.
///
/// What is no longer proven is:
///
/// - **The sampled path.** Every turn decodes with argmax now, so a red run is
///   attributable to the change under test, and the behavior under the
///   provider's default sampling is not measured here. This never disables
///   thinking: the 30B still writes its `<think>` block before each answer.
/// - **A turn past the ceiling.** Each of the four turns stops at
///   ``GatedRealModelBudget/responseTokenCeiling`` tokens rather than at
///   `LiveModelLoader`'s own default of 8192. A turn that generated past it is
///   no longer measured here.
/// - **The whole test body on the main actor.** The four turns run off the
///   main actor now. That change was measured and it moved no phase: on the
///   same box the plain turn went 22.4 to 22.7 seconds, resolve 5.37 to 5.38
///   and the embedding 0.026 to 0.026. It is kept because the target's rule
///   asks for it, not because it bought time.
///
/// Everything else is untouched: the profile, the resolver, the phase and
/// byte-progress assertions, the generation, the embedding, the guided
/// grammar, the fork lineage and the merged transcript's total order are
/// exactly what they were.
@Suite(
    "Gated real-model integration (milestone 7)",
    .serialized,
    .timeLimit(.minutes(integrationTestBudgetMinutes)),
    .exclusiveRealModel
)
struct IntegrationTests {
    /// The tag the per-phase wall-clock line of ``endToEnd()`` opens with.
    ///
    /// Its own tag, and not the target's `gatedTest` one, so a grep that
    /// collects the run table's per-test measurements never picks up a phase
    /// line. See ``integrationTestBudgetMinutes`` for that table.
    private static let phaseLabel = "endToEndPhase"

    /// The decoding strategy every container this test loads generates with.
    ///
    /// Until task ^pa5q5dt the test built its ``LiveModelLoader`` with no
    /// sampling mode, so every turn took the provider's own default —
    /// temperature 0.6 out of MLX's clock-seeded, process-global PRNG. The 30B
    /// always writes a `<think>` block before its answer, that block is a
    /// different length on every run of identical code, and this test's whole
    /// cost is that block, so the wall clock was a property of the run rather
    /// than of the code. Two isolation runs on 2026-08-22 measured the fork
    /// turn at 20.6 and then 1.0 seconds with nothing between them that could
    /// reach the model. Argmax decoding makes each turn repeat exactly.
    ///
    /// This never disables thinking: the model still writes its `<think>`
    /// block, and this only fixes which tokens it picks.
    private static let samplingMode: GenerationOptions.SamplingMode = .greedy

    /// Resolves the real profile and asserts every live capability against it.
    @Test("resolve real profile, then generate, embed, guide, fork, and record")
    func endToEnd() async throws {
        let cacheDir = Self.makeTempDir()
        let recordingsDir = Self.makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: cacheDir)
            try? FileManager.default.removeItem(at: recordingsDir)
        }

        // Each phase's own wall clock, printed however the test ends, so the
        // cost can be read against the phase that carries it rather than
        // against the total alone. `RealToolTurnComparisonTests` prints the
        // same split for the same reason.
        var resolveDuration: Duration = .zero
        var plainTurnDuration: Duration = .zero
        var embedDuration: Duration = .zero
        var guidedTurnDuration: Duration = .zero
        var forkTurnDuration: Duration = .zero
        var parentTurnDuration: Duration = .zero
        defer {
            print(
                "[\(Self.phaseLabel)] resolve=\(resolveDuration) plainTurn=\(plainTurnDuration) "
                    + "embed=\(embedDuration) guidedTurn=\(guidedTurnDuration) "
                    + "forkTurn=\(forkTurnDuration) parentTurn=\(parentTurnDuration)"
            )
        }

        // A real Hub-backed loader (the fork's macros supply the concrete
        // Downloader + TokenizerLoader) and the real Hub metadata source, each
        // wrapped so the suite can observe the resolution phase progression.
        let progress = await MainActor.run { ResolutionProgress() }
        let source = PhaseRecordingMetadataSource(
            wrapping: HuggingFaceMetadataSource(),
            progress: progress
        )
        let byteObserver = DownloadByteObserver()
        let loader = PhaseRecordingLoader(
            wrapping: DownloadObservingLoader(
                wrapped: LiveModelLoader(
                    downloader: #hubDownloader(),
                    tokenizerLoader: #huggingFaceTokenizerLoader(),
                    weightsLocation: { id in
                        HubClient.default.cache?.repoDirectory(
                            repo: Repo.ID(rawValue: id) ?? Repo.ID(namespace: id, name: ""),
                            kind: .model
                        ) ?? FileManager.default.temporaryDirectory
                    },
                    samplingMode: Self.samplingMode
                ),
                observer: byteObserver
            ),
            progress: progress
        )
        let router = Router(
            cacheDir: cacheDir,
            recordingsDir: recordingsDir,
            recorder: JSONLRecorder(directory: recordingsDir),
            metadataSource: source,
            loader: loader
        )

        let resolveStarted = ContinuousClock.now
        let profile = try await router.resolve(profile: realProfile, reporting: progress)
        resolveDuration = ContinuousClock.now - resolveStarted

        // 1. Progress advanced sizing -> downloading -> loading -> ready.
        //
        //    `ResolutionProgress` is `@MainActor`, so its reads hop to the main
        //    actor here rather than isolating the whole test body to it. The
        //    four generation turns below then run off the main actor, which is
        //    what the target's own rule asks for.
        try await MainActor.run {
            #expect(progress.phase == .ready)
            #expect(progress.fraction == 1.0)
            for slot in [ModelSlot.standard, .flash, .embedding] {
                let sp = try #require(progress.slots[slot])
                #expect(sp.state == .ready)
                #expect(sp.chosen != nil)
            }
        }
        #expect(await source.observedPhases.contains(.sizing))
        #expect(await loader.observedLoadPhases.allSatisfy { $0 == .downloading })
        // One load and one preload for each resident container the profile
        // asks for — see `realProfileResidentContainerCount`, which reads that
        // number off the profile rather than restating it.
        #expect(await loader.observedLoadPhases.count == realProfileResidentContainerCount)
        #expect(await loader.observedPreloadPhases.allSatisfy { $0 == .loading })
        #expect(await loader.observedPreloadPhases.count == realProfileResidentContainerCount)

        // 1b. The live byte percentage is real: every slot that downloaded
        //     observed a known byte total (> 0) and its byte count reached that
        //     total across the ticks — a true percentage, not a single 0 -> 100
        //     jump. (Cached weights still emit a full 0 -> total progression.)
        let downloadedSlots = byteObserver.observedSlots.filter { !byteObserver.ticks(for: $0).isEmpty }
        #expect(!downloadedSlots.isEmpty)
        for slot in downloadedSlots {
            let ticks = byteObserver.ticks(for: slot)
            let maxTotal = ticks.map(\.bytesTotal).max() ?? 0
            let maxDownloaded = ticks.map(\.bytesDownloaded).max() ?? 0
            #expect(maxTotal > 0)
            #expect(maxDownloaded == maxTotal)
        }

        // 2. A standard session returns non-empty text.
        //
        //    Every turn below states `GatedRealModelBudget.responseTokenCeiling`
        //    as its reply ceiling. Without one each turn takes
        //    `LiveModelLoader`'s own default of 8192 tokens, so a run whose
        //    `<think>` block does not stop cannot be held inside the budget.
        //    The ceiling gives space to the `<think>` block and to the answer —
        //    see that constant — and a turn that stops earlier still costs only
        //    the tokens it generated.
        let session = profile.standard.makeSession(
            instructions: "You are a terse assistant."
        )
        let plainTurnStarted = ContinuousClock.now
        let reply = try await session.respond(
            to: "Say hello in one short sentence.",
            maxTokens: GatedRealModelBudget.responseTokenCeiling)
        plainTurnDuration = ContinuousClock.now - plainTurnStarted
        #expect(!reply.isEmpty)

        // 3. Embedding returns dimension-length vectors AND records an embedding
        //    transcript event.
        let dimension = profile.embedding.dimension
        #expect(dimension > 0)
        let embedStarted = ContinuousClock.now
        let vectors = try await profile.embedding.embed(texts: ["first document", "second document"])
        embedDuration = ContinuousClock.now - embedStarted
        #expect(vectors.count == 2)
        #expect(vectors.allSatisfy { $0.count == dimension })

        // 4. A guided session honors its grammar: the output parses against the
        //    schema (structural validity is the xgrammar guarantee).
        let schema = #"""
            {"type":"object","properties":{"city":{"type":"string"},"country":{"type":"string"}},"required":["city","country"],"additionalProperties":false}
            """#
        let guidedTurnStarted = ContinuousClock.now
        let guided = try await profile.standard.respond(
            to: "Name a city to visit in Japan, as JSON.",
            matching: schema,
            maxTokens: GatedRealModelBudget.responseTokenCeiling
        )
        guidedTurnDuration = ContinuousClock.now - guidedTurnStarted
        guard case .object(let object) = guided else {
            Issue.record("guided output was not a JSON object: \(guided)")
            return
        }
        #expect(object.keys.sorted() == ["city", "country"])
        if case .string = object["city"] {} else { Issue.record("'city' should be a string") }
        if case .string = object["country"] {} else { Issue.record("'country' should be a string") }

        // 5. A fork continues the parent's conversation as an independent child
        //    session, seeded from the parent's accumulated transcript via
        //    `LanguageModelSessionBackend.makeFork()` — under the real
        //    `LanguageModelSession`-backed live path this is not yet wired to any
        //    real prefix-compute reuse (see plan.md's "Sessions & KV cache" open
        //    question); fork lineage and independent generation are what this
        //    asserts here.
        var child: RoutedSession? = try await session.fork(workingDirectory: nil)
        #expect(child?.parentId == session.id)
        #expect(child?.id != session.id)
        let childRecordingDirectory = try #require(child).recordingDirectory
        // The child's transcript nests directly under the parent's directory.
        #expect(
            childRecordingDirectory.deletingLastPathComponent().standardizedFileURL
                == session.recordingDirectory.standardizedFileURL
        )
        let forkTurnStarted = ContinuousClock.now
        let childReply = try await #require(child).respond(
            to: "Say hi in one word.",
            maxTokens: GatedRealModelBudget.responseTokenCeiling)
        forkTurnDuration = ContinuousClock.now - forkTurnStarted
        #expect(!childReply.isEmpty)

        // Dropping the only reference releases the fork. No other binding
        // retains it, so this is a genuine release; the parent is unaffected
        // and keeps generating.
        child = nil
        let parentTurnStarted = ContinuousClock.now
        let afterRelease = try await session.respond(
            to: "Still there?",
            maxTokens: GatedRealModelBudget.responseTokenCeiling)
        parentTurnDuration = ContinuousClock.now - parentTurnStarted
        #expect(!afterRelease.isEmpty)

        // 6. Recording: the fork's transcript.jsonl is physically nested under
        //    the parent's directory, and the merged log across the whole run is
        //    totally ordered by (ts, seq).
        let childFile = childRecordingDirectory
            .appendingPathComponent("transcript.jsonl", isDirectory: false)
        #expect(FileManager.default.fileExists(atPath: childFile.path))

        let merged = try MergedTranscript.merged(under: recordingsDir)
        #expect(!merged.isEmpty)
        // The embedding event landed in the recordings tree.
        #expect(merged.contains { $0.kind == .embedding })
        // Totally ordered by (ts, seq): the recorder's monotonic seq is the tie
        // breaker, so the merged stream is already sorted and its seqs unique.
        let ordered = merged.sorted { ($0.ts, $0.seq) < ($1.ts, $1.seq) }
        #expect(merged.map(\.seq) == ordered.map(\.seq))
        #expect(Set(merged.map(\.seq)).count == merged.count)

        await profile.release()
    }

    /// Creates a unique temporary directory.
    private static func makeTempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FMRouterIntegration-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
