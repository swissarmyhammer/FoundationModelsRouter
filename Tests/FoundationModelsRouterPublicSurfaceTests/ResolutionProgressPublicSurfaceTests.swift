import Foundation
import FoundationModels
import Testing

import FoundationModelsRouter

/// Holds the per-slot surface of ``ResolutionProgress`` to the access level a
/// consumer outside this package needs (task ^5545bna): `slots`, each slot's
/// `state`, `chosen`, `bytesDownloaded`, `bytesTotal` and `progressFraction`,
/// and the overall `fraction`.
///
/// The import is plain, with no `@testable`, and no file of this target
/// imports the library `@testable`, so the compiler is the first assertion
/// here: a member that loses `public` stops this file from compiling before a
/// single test runs. The body then drives one resolve over a stub loader that
/// reports known byte counts, and reads each count back through
/// `progress.slots` — the read a CLI download bar makes.
@Suite("ResolutionProgress per-slot surface over a plain import")
struct ResolutionProgressPublicSurfaceTests {
    /// The temp-directory prefix the cache directory of this suite is built
    /// with, so a leaked directory is attributable to this suite.
    private static let tempDirPrefix = "ResolutionProgressPublicSurfaceTests"

    /// The canned `config.json` payload behind ``rawMetadata`` — a tiny,
    /// valid model config the resolver can size.
    private static let configJSON = Data(
        """
        {
            "num_hidden_layers": 2,
            "num_attention_heads": 8,
            "num_key_value_heads": 2,
            "head_dim": 16,
            "hidden_size": 128
        }
        """.utf8)

    /// The canned repo file-tree payload behind ``rawMetadata`` — one
    /// plausible weights file the resolver can size.
    private static let treeJSON = Data(
        """
        [
            {"type": "file", "path": "model.safetensors", "size": 10000000}
        ]
        """.utf8)

    /// The canned repo metadata the stub metadata source serves for every
    /// candidate.
    private static var rawMetadata: RawRepoMetadata {
        RawRepoMetadata(configJSON: configJSON, treeJSON: treeJSON)
    }

    /// The physical RAM the stub probe reports: ample, so the tiny model of
    /// ``rawMetadata`` always fits.
    private static let totalRAMBytes: Int64 = 64 << 30

    /// The GPU working set the stub probe reports.
    private static let recommendedMaxWorkingSetBytes: Int64 = 48 << 30

    /// The embedding dimension the stub embedder reports.
    private static let embeddingDimension = 8

    /// The bytes the stub loader reports as downloaded for a generation model.
    private static let generationBytesDownloaded: Int64 = 512

    /// The total bytes the stub loader reports for a generation model.
    private static let generationBytesTotal: Int64 = 2_048

    /// The bytes the stub loader reports as downloaded for the embedding model.
    private static let embeddingBytesDownloaded: Int64 = 96

    /// The total bytes the stub loader reports for the embedding model.
    private static let embeddingBytesTotal: Int64 = 256

    /// The one download observation the stub loader reports for each
    /// generation slot.
    private static let generationDownload = DownloadProgress(
        bytesDownloaded: generationBytesDownloaded, bytesTotal: generationBytesTotal)

    /// The one download observation the stub loader reports for the embedding
    /// slot.
    private static let embeddingDownload = DownloadProgress(
        bytesDownloaded: embeddingBytesDownloaded, bytesTotal: embeddingBytesTotal)

    /// The one candidate of the `standard` slot.
    private static let standardRef: ModelRef = "org/std-a"

    /// The one candidate of the `flash` slot.
    private static let flashRef: ModelRef = "org/flash-a"

    /// The one candidate of the `embedding` slot.
    private static let embeddingRef: ModelRef = "org/emb-a"

    /// The test profile: one candidate for each slot, so the chosen model of
    /// each slot is known before the resolve runs.
    private static let profile = ProfileDefinition(
        name: "public-surface",
        description: "one candidate for each slot",
        standard: [standardRef],
        flash: [flashRef],
        embedding: [embeddingRef]
    )

    /// A ``MachineProbe`` that reports fixed hardware facts.
    private struct FixedProbe: MachineProbe {
        let chip: String
        let totalRAM: Int64
        let recommendedMaxWorkingSetSize: Int64
    }

    /// A ``MetadataSource`` that answers every fetch with one canned payload.
    private struct CannedMetadataSource: MetadataSource {
        /// The payload every fetch returns.
        let raw: RawRepoMetadata

        func fetchRawMetadata(repo: String, revision: String?) async throws -> RawRepoMetadata {
            raw
        }
    }

    /// A ``LoadedEmbeddingContainer`` that embeds every text as a zero vector
    /// of the configured dimension.
    private struct ZeroEmbedder: LoadedEmbeddingContainer {
        let dimension: Int

        func embed(texts: [String]) async throws -> [[Float]] {
            texts.map { _ in [Float](repeating: 0, count: dimension) }
        }
    }

    /// A ``LoadedLLMContainer`` a resolve can hold resident and nothing can
    /// open a session over.
    ///
    /// The resolve under test loads, warms and holds a container; it never
    /// asks one for a session. A session request is therefore a programmer
    /// error in this suite, and each factory says so instead of vending a
    /// backend the test cannot measure.
    private struct ResolveOnlyContainer: LoadedLLMContainer {
        /// The message each factory traps with.
        private static let noSessionMessage =
            "ResolveOnlyContainer vends no session; the resolve under test never asks for one"

        func makeSession(instructions: String?) -> any LanguageModelSessionBackend {
            preconditionFailure(Self.noSessionMessage)
        }

        func makeSession(transcript: Transcript) -> any LanguageModelSessionBackend {
            preconditionFailure(Self.noSessionMessage)
        }
    }

    /// A ``ModelLoader`` that reports one known download observation for each
    /// model it loads, so the test can read the same bytes back through
    /// `progress.slots`.
    private struct ReportingLoader: ModelLoader {
        /// The observation reported for each generation model.
        let generationDownload: DownloadProgress

        /// The observation reported for the embedding model.
        let embeddingDownload: DownloadProgress

        /// The dimension of the embedder this loader vends.
        let dimension: Int

        func loadLLM(
            ref: ModelRef,
            slot: ModelSlot,
            context: Int,
            reporting: @escaping @Sendable (DownloadProgress) -> Void
        ) async throws -> any LoadedLLMContainer {
            reporting(generationDownload)
            return ResolveOnlyContainer()
        }

        func loadEmbedder(
            ref: ModelRef,
            slot: ModelSlot,
            reporting: @escaping @Sendable (DownloadProgress) -> Void
        ) async throws -> any LoadedEmbeddingContainer {
            reporting(embeddingDownload)
            return ZeroEmbedder(dimension: dimension)
        }

        func preload(container: any LoadedModelContainer) async throws {}
    }

    /// Reads one slot back through the public surface and holds it to the
    /// ready state, the model the profile named for it, and the byte counts
    /// the loader reported for it.
    ///
    /// - Parameters:
    ///   - slot: The slot to read.
    ///   - progress: The progress the resolve drove.
    ///   - chosen: The one candidate the profile named for `slot`.
    ///   - download: The observation the loader reported for `slot`.
    ///   - sourceLocation: The call site, so a failed expectation points at
    ///     the slot that failed.
    /// - Throws: When the slot is absent from `progress.slots`.
    @MainActor
    private static func expectSlotReadsBack(
        _ slot: ModelSlot,
        of progress: ResolutionProgress,
        chosen: ModelRef,
        download: DownloadProgress,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        let slotProgress = try #require(progress.slots[slot], sourceLocation: sourceLocation)
        #expect(slotProgress.state == .ready, sourceLocation: sourceLocation)
        #expect(slotProgress.chosen == chosen, sourceLocation: sourceLocation)
        #expect(slotProgress.bytesDownloaded == download.bytesDownloaded, sourceLocation: sourceLocation)
        #expect(slotProgress.bytesTotal == download.bytesTotal, sourceLocation: sourceLocation)
        #expect(slotProgress.progressFraction == 1, sourceLocation: sourceLocation)
    }

    @Test("a plain import reads each slot's state, chosen model and byte counts after a resolve")
    @MainActor
    func readsEverySlotBackAfterAResolve() async throws {
        let cacheDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(Self.tempDirPrefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: cacheDir) }

        let progress = ResolutionProgress()
        let router = Router(
            cacheDir: cacheDir,
            probe: FixedProbe(
                chip: "Apple Test",
                totalRAM: Self.totalRAMBytes,
                recommendedMaxWorkingSetSize: Self.recommendedMaxWorkingSetBytes),
            metadataSource: CannedMetadataSource(raw: Self.rawMetadata),
            loader: ReportingLoader(
                generationDownload: Self.generationDownload,
                embeddingDownload: Self.embeddingDownload,
                dimension: Self.embeddingDimension)
        )

        _ = try await router.resolve(profile: Self.profile, reporting: progress)

        #expect(progress.phase == .ready)
        #expect(progress.fraction == 1)
        #expect(Set(progress.slots.keys) == [.standard, .flash, .embedding])
        try Self.expectSlotReadsBack(
            .standard, of: progress, chosen: Self.standardRef, download: Self.generationDownload)
        try Self.expectSlotReadsBack(
            .flash, of: progress, chosen: Self.flashRef, download: Self.generationDownload)
        try Self.expectSlotReadsBack(
            .embedding, of: progress, chosen: Self.embeddingRef, download: Self.embeddingDownload)
    }
}
