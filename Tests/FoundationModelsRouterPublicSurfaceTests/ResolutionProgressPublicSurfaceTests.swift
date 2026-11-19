import Foundation
import FoundationModelsDecision
import Testing

import FoundationModelsRouter
import FoundationModelsRouterTestSupport

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

    /// The physical RAM the stub probe reports: ample, so the tiny model of
    /// ``PlainImportResolveStubs/rawMetadata`` always fits.
    private static let totalRAMBytes: Int64 = 64 << 30

    /// The GPU working set the stub probe reports.
    private static let recommendedMaxWorkingSetBytes: Int64 = 48 << 30

    /// The length of each vector that the stub embedder makes.
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

    /// The state of each decision session of the suite.
    private static let decisionState: DecisionState = "The build is red."

    /// The yes-or-no question of the decision test of the suite.
    private static let decisionQuestion = "Does the state report a failure?"

    /// The test profile: one candidate for each slot, so the chosen model of
    /// each slot is known before the resolve runs.
    private static let profile = ProfileDefinition(
        name: "public-surface",
        description: "one candidate for each slot",
        standard: [standardRef],
        flash: [flashRef],
        embedding: [embeddingRef],
        decision: [flashRef]
    )

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

    /// Resolves ``profile`` over ``ReportingLoader`` and
    /// ``CannedMetadataSource``, in a fresh pool.
    ///
    /// - Returns: The resolved profile and the progress that the resolve
    ///   drove.
    /// - Throws: The error of the resolve.
    @MainActor
    private static func resolve() async throws -> (profile: LanguageModelProfile, progress: ResolutionProgress) {
        let cacheDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(Self.tempDirPrefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: cacheDir) }

        let progress = ResolutionProgress()
        let router = Router(
            cacheDir: cacheDir,
            probe: FixedMachineProbe(
                chip: "Apple Test",
                totalRAM: Self.totalRAMBytes,
                recommendedMaxWorkingSetSize: Self.recommendedMaxWorkingSetBytes),
            metadataSource: CannedMetadataSource(raw: PlainImportResolveStubs.rawMetadata),
            loader: ReportingLoader(
                generationDownload: Self.generationDownload,
                embeddingDownload: Self.embeddingDownload,
                dimension: Self.embeddingDimension),
            pool: ModelPool()
        )

        let profile = try await router.resolve(profile: Self.profile, reporting: progress)
        return (profile, progress)
    }

    @Test("a plain import reads each slot's state, chosen model and byte counts after a resolve")
    @MainActor
    func readsEverySlotBackAfterAResolve() async throws {
        let (_, progress) = try await Self.resolve()

        #expect(progress.phase == .ready)
        #expect(progress.fraction == 1)
        #expect(Set(progress.slots.keys) == [.standard, .flash, .embedding, .decision])
        try Self.expectSlotReadsBack(
            .standard, of: progress, chosen: Self.standardRef, download: Self.generationDownload)
        try Self.expectSlotReadsBack(
            .flash, of: progress, chosen: Self.flashRef, download: Self.generationDownload)
        try Self.expectSlotReadsBack(
            .embedding, of: progress, chosen: Self.embeddingRef, download: Self.embeddingDownload)
    }

    // MARK: - The decision slot

    @Test("a plain import reads the decision slot ready, with the flash model and no bytes of its own")
    @MainActor
    func readsTheDecisionSlotBackAfterAResolve() async throws {
        let (_, progress) = try await Self.resolve()

        try Self.expectSlotReadsBack(
            .decision, of: progress, chosen: Self.flashRef,
            download: DownloadProgress(bytesDownloaded: 0, bytesTotal: 0))
    }

    @Test("a plain import makes a decision session about a state over the decision handle")
    @MainActor
    func makesADecisionSessionOverTheDecisionHandle() async throws {
        let (profile, _) = try await Self.resolve()

        #expect(profile.decision.makeSession(state: Self.decisionState).state == Self.decisionState)
    }

    @Test("a plain import conforms the TestSupport stub to the public decision container protocol")
    func stubDecisionContainerAnswersThroughThePublicProtocol() async throws {
        let container: any LoadedDecisionContainer = StubDecisionContainer(modelID: Self.flashRef.stringValue)
        let session = DecisionSession(model: container.decisionModel, state: Self.decisionState)

        #expect(
            try await session.probability(of: Self.decisionQuestion)
                == StubDecisionModel.probability(of: Self.decisionQuestion))
    }
}
