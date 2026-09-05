import Foundation
import FoundationModels

@testable import FoundationModelsRouter

// The stubs this file builds on are the shared ones in
// `Helpers/RouterTestFixtures.swift`, at file scope in this target:
// `StubProbe`, `StubMetadataSource`, and `StubEmbeddingContainer`. Other
// suites use them too, so they are not defined again here. This file adds
// only what the residency suites need beyond them: a load spy, a spying
// loader, a canned container, the footprint constants, and a router factory.

/// Counts every load and every eviction a router routes through its loader,
/// keyed by the exact ``ModelRef`` (revision-sensitive), so a test can prove
/// that a dedup happened (one load for two profiles) or did not (one load for
/// each distinct ref or revision).
///
/// Shared by the residency suites (`PooledResidencyTests`,
/// `CrossRouterResidencyTests`). A test that builds two routers gives each
/// router its own spy, so the test can tell which router's loader ran.
actor LoadSpy {
    /// Every generation-model load, in load order.
    private(set) var llmLoads: [ModelRef] = []

    /// Every embedder load, in load order.
    private(set) var embedderLoads: [ModelRef] = []

    /// How many containers this spy's loader evicted.
    private(set) var evictions = 0

    /// Records one generation-model load.
    ///
    /// - Parameter ref: The ref the loader was asked for.
    func recordLLMLoad(_ ref: ModelRef) { llmLoads.append(ref) }

    /// Records one embedder load.
    ///
    /// - Parameter ref: The ref the loader was asked for.
    func recordEmbedderLoad(_ ref: ModelRef) { embedderLoads.append(ref) }

    /// Records one eviction.
    func recordEviction() { evictions += 1 }
}

/// A stand-in generation container that returns a canned response that names
/// the ref it was loaded for, so a test can prove two sessions hit the same
/// (or different) resident model.
struct CannedLLMContainer: LoadedLLMContainer {
    /// The text every session of this container answers with.
    let canned: String

    /// Creates the container a ``SpyingModelLoader`` vends for `ref`.
    ///
    /// - Parameter ref: The ref the container stands in for.
    init(ref: ModelRef) {
        canned = Self.reply(for: ref)
    }

    /// The canned answer a session over the container loaded for `ref` gives.
    ///
    /// - Parameter ref: The ref the container was loaded for.
    /// - Returns: The answer text.
    static func reply(for ref: ModelRef) -> String {
        "from-\(ref.stringValue)"
    }

    func makeSession(instructions: String?) -> any LanguageModelSessionBackend {
        StubSessionBackend(responseText: canned)
    }

    func makeSession(transcript: Transcript) -> any LanguageModelSessionBackend {
        StubSessionBackend(responseText: canned)
    }
}

/// A ``ModelLoader`` that reports every load and eviction to a ``LoadSpy``
/// and vends a ``CannedLLMContainer`` for each generation ref and a
/// ``StubEmbeddingContainer`` (the shared stub in
/// `Helpers/RouterTestFixtures.swift`) for each embedder ref. No download,
/// no GPU.
///
/// Distinct from the shared ``StubModelLoader`` in the same fixtures file,
/// which vends one fixed container and counts nothing.
struct SpyingModelLoader: ModelLoader {
    /// The spy every load and eviction is reported to.
    let spy: LoadSpy

    /// The embedding dimension every stub embedder reports.
    let dimension: Int

    /// Optional override so a concurrency test can vend its own container
    /// instead of the plain ``CannedLLMContainer``.
    var llmContainer: (@Sendable (ModelRef) -> any LoadedLLMContainer)?

    /// When set, `loadLLM` for exactly this ref signals `entrySignal` (proving
    /// it has been reached) and then awaits `releaseGate` before it returns: a
    /// deterministic suspension window for a test that exercises what can
    /// interleave with an in-flight `resolve()`.
    var gatedRef: ModelRef?

    /// The semaphore `loadLLM` signals when it reaches `gatedRef`.
    var entrySignal: AsyncSemaphore?

    /// The semaphore `loadLLM` awaits before it returns `gatedRef`.
    var releaseGate: AsyncSemaphore?

    func loadLLM(
        ref: ModelRef,
        slot: ModelSlot,
        context: Int,
        reporting: @escaping @Sendable (DownloadProgress) -> Void
    ) async throws -> any LoadedLLMContainer {
        await spy.recordLLMLoad(ref)
        reporting(DownloadProgress(bytesDownloaded: 1, bytesTotal: 1))
        if ref == gatedRef, let entrySignal, let releaseGate {
            entrySignal.signal()
            await releaseGate.wait()
        }
        if let llmContainer { return llmContainer(ref) }
        return CannedLLMContainer(ref: ref)
    }

    func loadEmbedder(
        ref: ModelRef,
        slot: ModelSlot,
        reporting: @escaping @Sendable (DownloadProgress) -> Void
    ) async throws -> any LoadedEmbeddingContainer {
        await spy.recordEmbedderLoad(ref)
        reporting(DownloadProgress(bytesDownloaded: 1, bytesTotal: 1))
        // The shared embedder stub from `Helpers/RouterTestFixtures.swift`.
        return StubEmbeddingContainer(dimension: dimension)
    }

    func preload(container: any LoadedModelContainer) async throws {}

    func evict(container: any LoadedModelContainer) async {
        await spy.recordEviction()
    }
}

/// The footprint arithmetic and the router factory the residency suites
/// share. The canned metadata is ``RouterTestFixtures/rawMetadata``: a 2-layer
/// attention shape with a single 10 MB weight shard, so footprints are the
/// same well-understood magnitude every other suite in this target uses
/// (`generationSlotMarginedFootprint` is about 14_516_583 bytes,
/// `embeddingSlotMarginedFootprint` is 12_000_000 bytes at the default
/// 8192-token context; see `ResolveTests`).
enum ResidencyFixtures {
    /// One generation model's margined footprint at the default context:
    /// weights plus one session KV cache.
    static let generationModelFootprint: Int64 = 14_516_583

    /// One embedder's margined footprint: weights only.
    static let embeddingModelFootprint: Int64 = 12_000_000

    /// How many generation slots one trio profile has: standard and flash.
    static let generationSlotsPerTrio: Int64 = 2

    /// How many models one trio profile (standard, flash, embedding) loads.
    static let modelsPerTrio = 3

    /// One full trio's margined footprint at the default context: one
    /// ``generationModelFootprint`` for each generation slot, plus the
    /// embedding model.
    static let oneTrioFootprint: Int64 =
        generationModelFootprint * generationSlotsPerTrio + embeddingModelFootprint

    /// Headroom added on top of a whole number of trio footprints when sizing
    /// a test router's simulated RAM, so a budget meant to fit exactly N
    /// trios is not rejected by an off-by-a-few-bytes rounding difference
    /// between this constant's footprint arithmetic and the joint fit's own.
    static let headroomBufferBytes: Int64 = 1_000

    /// The `× 1.2` margined KV cache of ONE generation session at the default
    /// 8192-token context for the canned 2-layer config (raw 2_097_152 bytes):
    /// the extra steady-state cost each generation slot beyond the first adds
    /// on a shared resident model, and exactly what ``JointFit`` charges a
    /// second generation slot naming an already-charged reference.
    static let sessionKVMarginedBytes: Int64 = 2_516_583

    /// The whole reservation ``JointFit`` makes for a trio whose standard and
    /// flash slots name ONE reference: that reference's weights plus one KV
    /// cache, the second slot's own KV cache (``sessionKVMarginedBytes``), and
    /// the embedding model.
    static let sharedPairTrioFootprint: Int64 =
        generationModelFootprint + sessionKVMarginedBytes + embeddingModelFootprint

    /// The whole reservation a later profile is charged when it resolves an
    /// already-resident trio again: one session KV cache for each of its
    /// generation slots (its own new sessions materialize new caches on the
    /// shared containers) and zero for the reused embedder.
    static let reusedTrioCharge: Int64 = sessionKVMarginedBytes * generationSlotsPerTrio

    /// The whole reservation a later profile is charged when it reuses a
    /// resident trio's generation model and embedder but brings its own flash
    /// model: one session KV cache on the reused generation model, its own
    /// flash model's whole footprint, and zero for the reused embedder.
    static let reuseWithOwnFlashCharge: Int64 = sessionKVMarginedBytes + generationModelFootprint

    /// A working context below ``ProfileDefinition/defaultContext``, for the
    /// profile that names an already-resident repo at a second context. The
    /// context is not part of the ``ResidencyKey``: the loader does not size
    /// a container by it, so the same repo at this context shares the
    /// resident container and is charged one session KV cache at this
    /// context.
    static let steppedDownContext = 4096

    /// The `× 1.2` margined KV cache of ONE generation session at
    /// ``steppedDownContext`` for the canned 2-layer config (raw 1_048_576
    /// bytes): what a profile at that context is charged when it reuses a
    /// resident generation model.
    static let steppedDownSessionKVMarginedBytes: Int64 = 1_258_292

    /// One generation model's margined footprint at ``steppedDownContext``:
    /// weights plus one session KV cache at that context.
    static let steppedDownGenerationModelFootprint: Int64 = 13_258_292

    /// The whole reservation a profile at ``steppedDownContext`` is charged
    /// when it reuses a resident trio's generation model and embedder but
    /// brings its own flash model: one session KV cache at its own context
    /// on the reused generation model, its own flash model's whole footprint
    /// at that context, and zero for the reused embedder.
    static let steppedDownReuseWithOwnFlashCharge: Int64 =
        steppedDownSessionKVMarginedBytes + steppedDownGenerationModelFootprint

    /// Builds a ``Router`` with `headroomReserve: 0` over a probe whose whole
    /// budget is `recommendedMaxWorkingSetSize`, so the host budget every
    /// resolve prices against is exactly that figure.
    ///
    /// The probe is the shared ``StubProbe`` and the metadata source is the
    /// shared ``StubMetadataSource``, both from
    /// `Helpers/RouterTestFixtures.swift`.
    ///
    /// - Parameters:
    ///   - spy: The spy the router's loader reports every load and eviction to.
    ///   - recommendedMaxWorkingSetSize: The simulated RAM, and so the host budget.
    ///   - cacheDir: The router's cache directory (a per-test temp dir).
    ///   - pool: The resident-model pool. Defaults to a fresh pool, so two
    ///     routers share residents only when a test passes one pool to both.
    ///   - maxConcurrentForks: The in-flight fork ceiling the router mints for
    ///     every key it loads.
    ///   - samplingMode: The decoding strategy the router passes to every
    ///     backend it makes, or `nil` (the default) for the provider default.
    ///   - llmContainer: An override for the container each generation ref gets.
    ///   - gatedRef: The ref whose load suspends. See ``SpyingModelLoader/gatedRef``.
    ///   - entrySignal: Signalled when the gated load is reached.
    ///   - releaseGate: Awaited before the gated load returns.
    /// - Returns: The router.
    static func makeRouter(
        spy: LoadSpy,
        recommendedMaxWorkingSetSize: Int64,
        cacheDir: URL,
        pool: ModelPool = ModelPool(),
        maxConcurrentForks: Int = defaultMaxConcurrentForks,
        samplingMode: GenerationOptions.SamplingMode? = nil,
        llmContainer: (@Sendable (ModelRef) -> any LoadedLLMContainer)? = nil,
        gatedRef: ModelRef? = nil,
        entrySignal: AsyncSemaphore? = nil,
        releaseGate: AsyncSemaphore? = nil
    ) -> Router {
        Router(
            headroomReserve: 0,
            maxConcurrentForks: maxConcurrentForks,
            cacheDir: cacheDir,
            recorder: InMemoryRecorder(),
            // The shared probe stub from `Helpers/RouterTestFixtures.swift`.
            probe: StubProbe(
                chip: "Apple Test",
                totalRAM: recommendedMaxWorkingSetSize,
                recommendedMaxWorkingSetSize: recommendedMaxWorkingSetSize
            ),
            // The shared metadata stub from the same fixtures file.
            metadataSource: StubMetadataSource(raw: RouterTestFixtures.rawMetadata),
            loader: SpyingModelLoader(
                spy: spy, dimension: RouterTestFixtures.stubDimension, llmContainer: llmContainer,
                gatedRef: gatedRef, entrySignal: entrySignal, releaseGate: releaseGate
            ),
            samplingMode: samplingMode,
            pool: pool
        )
    }
}
