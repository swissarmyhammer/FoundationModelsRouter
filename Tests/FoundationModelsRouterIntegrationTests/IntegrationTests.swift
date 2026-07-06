import Foundation
import HuggingFace
import MLXHuggingFace
import MLXLMCommon
import Testing
import Tokenizers

@testable import FoundationModelsRouter

// MARK: - Gate

/// The opt-in environment variable that enables the real-model suite. Unset (the
/// default, and on any CI/GPU-less box) the whole suite is skipped, so
/// `swift test` stays green without network or a GPU.
private let integrationEnvVar = "FM_ROUTER_INTEGRATION_TESTS"

/// Whether the real-model suite is enabled for this run.
private var integrationEnabled: Bool {
    ProcessInfo.processInfo.environment[integrationEnvVar] != nil
}

// MARK: - Tiny real models

/// The deliberately small `mlx-community` models the suite co-fits into one
/// resolved profile.
///
/// - `standard` / `flash`: `SmolLM-135M-Instruct-4bit` — a ~135M-parameter 4-bit
///   Llama-family instruct model, the smallest widely-available `mlx-community`
///   causal LM. The same repo fills both generation slots so the run downloads
///   one set of weights and loads it into two resident containers.
/// - `embedding`: `Qwen3-Embedding-0.6B-4bit-DWQ` — the smallest `mlx-community`
///   embedding model wired into the fork's `EmbedderRegistry`.
private enum TinyModels {
    static let generation: ModelRef = "mlx-community/SmolLM-135M-Instruct-4bit"
    static let embedding: ModelRef = "mlx-community/Qwen3-Embedding-0.6B-4bit-DWQ"
}

/// The tiny co-fitting profile the suite resolves. A small `context` keeps the
/// per-slot KV footprint modest so all three slots comfortably co-fit.
private let tinyProfile = ProfileDefinition(
    name: "integration-tiny",
    description: "Deliberately tiny real models for the gated integration suite.",
    standard: [TinyModels.generation],
    flash: [TinyModels.generation],
    embedding: [TinyModels.embedding],
    context: 512
)

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
        _ ref: ModelRef,
        slot: ModelSlot,
        context: Int,
        reporting: @escaping @Sendable (DownloadProgress) -> Void
    ) async throws -> any LoadedLLMContainer {
        observedLoadPhases.append(await MainActor.run { progress.phase })
        return try await wrapped.loadLLM(ref, slot: slot, context: context, reporting: reporting)
    }

    func loadEmbedder(
        _ ref: ModelRef,
        slot: ModelSlot,
        reporting: @escaping @Sendable (DownloadProgress) -> Void
    ) async throws -> any LoadedEmbeddingContainer {
        observedLoadPhases.append(await MainActor.run { progress.phase })
        return try await wrapped.loadEmbedder(ref, slot: slot, reporting: reporting)
    }

    func preload(_ container: any LoadedModelContainer) async throws {
        observedPreloadPhases.append(await MainActor.run { progress.phase })
        try await wrapped.preload(container)
    }

    func evict(_ container: any LoadedModelContainer) async {
        await wrapped.evict(container)
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
        _ ref: ModelRef,
        slot: ModelSlot,
        context: Int,
        reporting: @escaping @Sendable (DownloadProgress) -> Void
    ) async throws -> any LoadedLLMContainer {
        try await wrapped.loadLLM(
            ref,
            slot: slot,
            context: context,
            reporting: observer.capturing(slot: slot, forwarding: reporting)
        )
    }

    func loadEmbedder(
        _ ref: ModelRef,
        slot: ModelSlot,
        reporting: @escaping @Sendable (DownloadProgress) -> Void
    ) async throws -> any LoadedEmbeddingContainer {
        try await wrapped.loadEmbedder(
            ref,
            slot: slot,
            reporting: observer.capturing(slot: slot, forwarding: reporting)
        )
    }

    func preload(_ container: any LoadedModelContainer) async throws {
        try await wrapped.preload(container)
    }

    func evict(_ container: any LoadedModelContainer) async {
        await wrapped.evict(container)
    }
}

// MARK: - Suite

/// The gated end-to-end integration suite (milestone 7).
///
/// It resolves the ``tinyProfile`` once — all three slots co-resident — over a
/// real ``LiveModelLoader`` (a Hub `#hubDownloader()` + `#huggingFaceTokenizerLoader()`)
/// and the real ``HuggingFaceMetadataSource``, then asserts every live capability
/// in that one resolved profile: progress advancement, generation, embedding
/// (with its transcript event), guided generation, fork lineage, and the merged
/// transcript's total order.
///
/// Gated so it never runs on a network/GPU-less box: the whole package's
/// deployment floor is macOS 27 (so the macOS-27 availability the milestone calls
/// for is guaranteed structurally — Swift Testing's `@Suite`/`@Test` macros reject
/// a redundant `@available` attribute on the type), plus an opt-in env var.
/// `.serialized` so the heavy load happens once at a time, under a generous
/// `.timeLimit`. Downloads are cached on disk by the Hub client and reused across
/// runs.
@Suite(
    "Gated real-model integration (milestone 7)",
    .serialized,
    .timeLimit(.minutes(30)),
    .enabled(if: integrationEnabled)
)
struct IntegrationTests {
    /// Resolves the tiny profile and asserts every live capability against it.
    @Test("resolve tiny profile, then generate, embed, guide, fork, and record")
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

        let profile = try await router.resolve(tinyProfile, reporting: progress)

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
        #expect(await loader.observedLoadPhases.count == 3)
        #expect(await loader.observedPreloadPhases.allSatisfy { $0 == .loading })
        #expect(await loader.observedPreloadPhases.count == 3)

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
        let vectors = try await profile.embedding.embed(["first document", "second document"])
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
        //    session. Its ``SessionKVCache`` is still just the copy/free object
        //    contract (asserted with a spy in the unit suite) — under the real
        //    `LanguageModelSession`-backed live path it is not yet wired to any
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

        // Dropping the only reference releases the fork, freeing its (inert)
        // cache object. No other binding retains it, so this is a genuine
        // release; the parent is unaffected and keeps generating.
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
