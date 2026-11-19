import Foundation
import FoundationModels
import Testing

import FoundationModelsRouter
import FoundationModelsRouterTestSupport

/// Holds ``RoutedModel/recordSession(from:configuration:)`` to the access
/// level a host outside this package needs (D209 (h)): a host writes a new
/// session recording from a model transcript that it made, with no live
/// session, and finds the session among the recorded sessions of its root.
///
/// The import is plain, with no `@testable`, so a member that loses `public`
/// stops this file from compiling before a single test runs. The resolve
/// runs over the stubs of the test-support target, and the write makes no
/// session of a model.
@Suite("Session recording from a transcript over a plain import")
struct RecordSessionPublicSurfaceTests {
    /// The temp-directory prefix of the folders of the suite, so a leaked
    /// folder names this suite.
    private static let tempDirPrefix = "RecordSessionPublicSurfaceTests"

    /// The physical RAM of the stub probe: ample, so the tiny model of
    /// ``PlainImportResolveStubs/rawMetadata`` always fits.
    private static let totalRAMBytes: Int64 = 64 << 30

    /// The GPU working set of the stub probe.
    private static let recommendedMaxWorkingSetBytes: Int64 = 48 << 30

    /// The length of each vector of the stub embedder.
    private static let embeddingDimension = 8

    /// The download observation of each model of the stub loader: complete.
    private static let completeDownload = DownloadProgress(bytesDownloaded: 1, bytesTotal: 1)

    /// The one candidate of each slot of ``profile``.
    private static let modelRef: ModelRef = "org/model"

    /// The profile of the suite: ``modelRef`` in each slot.
    private static let profile = ProfileDefinition(
        name: "public-surface",
        description: "one candidate for each slot",
        standard: [modelRef],
        flash: [modelRef],
        embedding: [modelRef],
        decision: [modelRef]
    )

    /// The title of the written session.
    private static let title = "Imported triage"

    /// The transcript of one turn that the host gives.
    private static let transcript = Transcript(entries: [
        .prompt(Transcript.Prompt(segments: [.text(Transcript.TextSegment(content: "list the open bugs"))])),
        .response(Transcript.Response(segments: [.text(Transcript.TextSegment(content: "none"))])),
    ])

    @Test("a host writes a session recording from a transcript and finds it in its recording root")
    func aHostWritesARecordingFromATranscript() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(Self.tempDirPrefix)-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let recordingRoot = folder.appendingPathComponent("sessions", isDirectory: true)
        let router = Router(
            cacheDir: folder.appendingPathComponent("cache", isDirectory: true),
            recordingsDir: folder.appendingPathComponent("recordings", isDirectory: true),
            probe: FixedMachineProbe(
                chip: "Apple Test",
                totalRAM: Self.totalRAMBytes,
                recommendedMaxWorkingSetSize: Self.recommendedMaxWorkingSetBytes),
            metadataSource: CannedMetadataSource(raw: PlainImportResolveStubs.rawMetadata),
            loader: ReportingLoader(
                generationDownload: Self.completeDownload,
                embeddingDownload: Self.completeDownload,
                dimension: Self.embeddingDimension),
            pool: ModelPool()
        )
        let resolved = try await router.resolve(profile: Self.profile, reporting: ResolutionProgress())

        let id = try await resolved.standard.recordSession(
            from: Self.transcript,
            configuration: SessionConfiguration(
                workingDirectory: folder, recordingRoot: recordingRoot, title: Self.title, origin: .client))

        let records = try RouterSessionDirectory.recordedSessions(in: recordingRoot)
        #expect(records.map(\.sessionId) == [id])
    }
}
