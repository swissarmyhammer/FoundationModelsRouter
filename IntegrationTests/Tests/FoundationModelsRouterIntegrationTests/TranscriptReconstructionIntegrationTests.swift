import Foundation
import FoundationModels
import FoundationModelsRouterTestSupport
import Testing

@testable import FoundationModelsRouter
@testable import FoundationModelsRouterRealModelSupport

/// The same real `mlx-community` generation model the rest of this target's
/// gated suites use for the `.standard` slot.
private let transcriptReconstructionTinyModel: ModelRef = RealModels.standard

// MARK: - Suite

/// Gated real-model coverage for task dw0zx8k: reconstructing a real
/// `FoundationModels.Transcript` from recorded events end-to-end against a
/// live model, proving ``TranscriptTree/effectiveTranscript(forSession:view:)``
/// against something more than stub-fabricated entries (see plan.md's
/// "Transcript fidelity" section, "Reconstruction end-to-end").
///
/// Builds a real ``RoutedSessionActor`` directly over an already-loaded tiny
/// model's backend (bypassing `Router.resolve(_:reporting:)`, which would
/// need a real `.flash`/`.embedding` download too) — the same technique
/// ``LanguageModelSessionBackendIntegrationTests`` uses, extended to record
/// into a durable `recordingsDir` so the on-disk transcript can be reloaded
/// through a fresh ``TranscriptTree``. The profile under that session comes
/// from ``RealModelHarness``, which every real-model suite of this target
/// shares; this suite's own copy of that build was folded onto it (task
/// ^zz6kam0).
///
/// The three runs of 2026-08-20 measured this suite's one test at 19.7, then
/// 24.1, then 17.1 seconds. The limit is now the shared
/// ``integrationTestBudgetMinutes``, which replaces the 15 minutes this suite
/// stated before; see it for the whole three-run table.
@Suite(
    "Gated real-model coverage: effectiveTranscript reconstruction (task dw0zx8k)",
    .serialized,
    .timeLimit(.minutes(integrationTestBudgetMinutes)),
    .exclusiveRealModel
)
struct TranscriptReconstructionIntegrationTests {
    private struct Harness {
        let session: RoutedSessionActor
        let backend: MLXFoundationModelsSessionBackend
        let container: MLXFoundationModelsContainer
        let routerId: ULID
        let sessionId: ULID
        let recordingsDir: URL
        let cacheDir: URL
    }

    /// Builds a real ``RoutedSessionActor`` over a freshly loaded tiny model,
    /// recording at `.full` into a durable temp `recordingsDir` so its
    /// transcript can be reloaded through ``TranscriptTree/load(under:)``
    /// after the turn completes.
    ///
    /// The profile comes from ``RealModelHarness/make(model:context:container:cacheDir:recordingsDir:routerId:)``
    /// and the session is assembled over its `.standard` handle. The hand-built
    /// copy this replaced named its profile `"test"`; the harness stamps its own
    /// name, and nothing reads the field.
    private func makeHarness() async throws -> Harness {
        let container = try await RealModelContainer.load(ref: transcriptReconstructionTinyModel)
        let backend = try #require(
            container.makeSession(instructions: nil) as? MLXFoundationModelsSessionBackend
        )

        let recordingsDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "TranscriptReconstructionIntegrationTests-\(UUID().uuidString)", isDirectory: true)
        let cacheDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TranscriptReconstructionIntegrationTests-cache-\(UUID().uuidString)", isDirectory: true)

        let profile = RealModelHarness.make(
            model: transcriptReconstructionTinyModel,
            // The window this suite's own hand-built profile resolved at before
            // it moved onto the harness: it stated no `contextTokens` at all, so
            // every slot took `SlotResolution`'s own default. Stated explicitly
            // here, because the harness has no default of its own to inherit.
            context: ProfileDefinition.defaultContext,
            container: container,
            cacheDir: cacheDir,
            recordingsDir: recordingsDir
        )
        let standard = profile.standard

        let sessionId = ULID.generate()
        let recordingDirectory = recordingsDir
            .appendingPathComponent(standard.routerId.description, isDirectory: true)
            .appendingPathComponent(sessionId.description, isDirectory: true)

        // Assembled by hand rather than vended from `standard.makeSession()` —
        // the test needs the backend itself, to compare the reconstruction
        // against the live `session.transcript` — and it lands its own sidecar
        // all the same, because a session's sidecar is its own job rather than
        // its builder's (see `SessionSidecarOrigin`). Every piece it takes
        // comes off the handle the harness built, so the session records
        // through the same recorder and the same root-plus-writer
        // ``DurableRecording`` pair `Router.makeDurableRecording` builds.
        let session = RoutedSessionActor(
            profile: profile,
            routerId: standard.routerId,
            id: sessionId,
            parentId: nil,
            recordingDirectory: recordingDirectory,
            workingDirectory: recordingDirectory,
            backend: backend,
            slot: .standard,
            model: transcriptReconstructionTinyModel,
            recorder: standard.recorder,
            instructions: nil,
            grammar: nil,
            generationGate: standard.generationGate,
            forkAdmissionGate: standard.forkAdmissionGate,
            holdsAdmissionPermit: false,
            persistedEntryCount: 0,
            historyOrdinal: 0,
            // A new root under the vending handle's durable recording, exactly
            // as `makeSession` names it: this session writes its own sidecar
            // before it can record anything — which `TranscriptTree.load` below
            // requires — and so does any fork taken from it.
            sidecarOrigin: .new(under: standard.durableRecording)
        )

        return Harness(
            session: session,
            backend: backend,
            container: container,
            routerId: standard.routerId,
            sessionId: sessionId,
            recordingsDir: recordingsDir,
            cacheDir: cacheDir
        )
    }

    /// Task dw0zx8k's core acceptance criterion, proved against a real
    /// model: after one live turn recorded at `full`, the `Transcript`
    /// ``TranscriptTree/effectiveTranscript(forSession:view:)`` rebuilds
    /// from disk has the same entry kinds and count — one-for-one, in order —
    /// as the live `LanguageModelSession`'s own `transcript` actually
    /// accumulated.
    @Test(
        "reconstructed Transcript entry kinds and count match the live session.transcript after one live turn"
    )
    func reconstructedTranscriptMatchesLiveSessionTranscript() async throws {
        let harness = try await makeHarness()
        defer {
            try? FileManager.default.removeItem(at: harness.recordingsDir)
            try? FileManager.default.removeItem(at: harness.cacheDir)
        }

        _ = try await harness.session.respond(to: "Say 'hi' briefly.", maxTokens: GatedRealModelBudget.responseTokenCeiling)

        let liveEntries = Array(harness.backend.session.transcript)
        let liveKinds = liveEntries.map { TranscriptEntryMapper.event(from: $0).kind }

        let routerDirectory = harness.recordingsDir.appendingPathComponent(harness.routerId.description, isDirectory: true)
        let tree = try TranscriptTree.load(under: routerDirectory)
        let reconstructed = try tree.effectiveTranscript(forSession: harness.sessionId)
        let reconstructedEntries = Array(reconstructed)
        let reconstructedKinds = reconstructedEntries.map { TranscriptEntryMapper.event(from: $0).kind }

        #expect(reconstructedKinds == liveKinds)
        #expect(reconstructedEntries.count == liveEntries.count)
        #expect(!reconstructedEntries.isEmpty)

        await harness.container.model.evict()
    }
}
