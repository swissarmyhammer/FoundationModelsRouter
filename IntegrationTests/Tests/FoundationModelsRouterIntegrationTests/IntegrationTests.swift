import Foundation
import FoundationModelsRouterRealModelSupport
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
@Suite(
    "Gated real-model integration (milestone 7)",
    .serialized,
    .timeLimit(.minutes(integrationTestBudgetMinutes)),
    .exclusiveRealModel
)
struct IntegrationTests {
    /// Resolves the real profile and asserts every live capability against it.
    @Test("resolve real profile, then generate, embed, guide, fork, and record")
    @MainActor
    func endToEnd() async throws {
        let cacheDir = Self.makeTempDir()
        let recordingsDir = Self.makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: cacheDir)
            try? FileManager.default.removeItem(at: recordingsDir)
        }

        // A real Hub-backed loader (the fork's macros supply the concrete
        // Downloader + TokenizerLoader) and the real Hub metadata source, each
        // wrapped so the suite can observe the resolution phase progression.
        let progress = ResolutionProgress()
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
                    }
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

        let profile = try await router.resolve(profile: realProfile, reporting: progress)

        // 1. Progress advanced sizing -> downloading -> loading -> ready.
        #expect(progress.phase == .ready)
        #expect(progress.fraction == 1.0)
        for slot in [ModelSlot.standard, .flash, .embedding] {
            let sp = try #require(progress.slots[slot])
            #expect(sp.state == .ready)
            #expect(sp.chosen != nil)
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
        let session = profile.standard.makeSession(
            instructions: "You are a terse assistant."
        )
        let reply = try await session.respond(to: "Say hello in one short sentence.")
        #expect(!reply.isEmpty)

        // 3. Embedding returns dimension-length vectors AND records an embedding
        //    transcript event.
        let dimension = profile.embedding.dimension
        #expect(dimension > 0)
        let vectors = try await profile.embedding.embed(texts: ["first document", "second document"])
        #expect(vectors.count == 2)
        #expect(vectors.allSatisfy { $0.count == dimension })

        // 4. A guided session honors its grammar: the output parses against the
        //    schema (structural validity is the xgrammar guarantee).
        let schema = #"""
            {"type":"object","properties":{"city":{"type":"string"},"country":{"type":"string"}},"required":["city","country"],"additionalProperties":false}
            """#
        let guided = try await profile.standard.respond(
            to: "Name a city to visit in Japan, as JSON.",
            matching: schema
        )
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
        let childReply = try await #require(child).respond(to: "Say hi in one word.")
        #expect(!childReply.isEmpty)

        // Dropping the only reference releases the fork. No other binding
        // retains it, so this is a genuine release; the parent is unaffected
        // and keeps generating.
        child = nil
        let afterRelease = try await session.respond(to: "Still there?")
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
