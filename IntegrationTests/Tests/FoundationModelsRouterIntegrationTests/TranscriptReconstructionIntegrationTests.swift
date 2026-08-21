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
/// through a fresh ``TranscriptTree``.
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
    /// A minimal ``LoadedEmbeddingContainer`` stand-in for the unused
    /// `.embedding` slot the ``LanguageModelProfile`` this suite builds must
    /// still carry — never exercised here, only present to satisfy the type.
    private struct UnusedEmbeddingContainer: LoadedEmbeddingContainer {
        let dimension = 1
        func embed(texts: [String]) async throws -> [[Float]] { [] }
    }

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

        let recorder = JSONLRecorder(directory: recordingsDir)
        let router = Router(cacheDir: cacheDir, recordingsDir: recordingsDir, recorder: recorder)

        func noopResolution(_ slot: ModelSlot) -> SlotResolution {
            SlotResolution(slot: slot, remainingBudgetBytes: 0, chosen: transcriptReconstructionTinyModel, considered: [])
        }
        // The same root-plus-writer pair `Router.makeDurableRecording` builds.
        // The session below is assembled by hand rather than vended from
        // `standard.makeSession()` — the test needs the backend itself, to
        // compare the reconstruction against the live `session.transcript` —
        // and lands its own sidecar all the same, because a session's sidecar
        // is its own job rather than its builder's (see `SessionSidecarOrigin`).
        func durableRecording(_ slot: ModelSlot) -> DurableRecording {
            DurableRecording(
                root: recordingsDir,
                sidecarWriter: SessionSidecarWriter(
                    slot: slot,
                    model: transcriptReconstructionTinyModel,
                    context: noopResolution(slot).contextTokens,
                    recordingLevel: .full,
                    profile: nil,
                    routerId: router.id
                )
            )
        }
        // Both generation handles wrap the one `container`, so both take the
        // one gate set it carries, as they would from a pool entry. Two sets
        // would let two generations run inside the one container at once.
        let generationGates = ResidentModelGates(maxConcurrentForks: defaultMaxConcurrentForks)
        let standard = RoutedLLM(
            slot: .standard,
            chosen: transcriptReconstructionTinyModel,
            footprintBytes: 0,
            resolution: noopResolution(.standard),
            container: container,
            routerId: router.id,
            recorder: recorder,
            durableRecording: durableRecording(.standard),
            gates: generationGates
        )
        let flash = RoutedLLM(
            slot: .flash,
            chosen: transcriptReconstructionTinyModel,
            footprintBytes: 0,
            resolution: noopResolution(.flash),
            container: container,
            routerId: router.id,
            recorder: recorder,
            durableRecording: durableRecording(.flash),
            gates: generationGates
        )
        let embedding = RoutedEmbedder(
            slot: .embedding,
            chosen: transcriptReconstructionTinyModel,
            footprintBytes: 0,
            resolution: noopResolution(.embedding),
            container: UnusedEmbeddingContainer(),
            routerId: router.id,
            recorder: recorder,
            durableRecording: durableRecording(.embedding),
            gates: ResidentModelGates(maxConcurrentForks: defaultMaxConcurrentForks)
        )
        let profile = LanguageModelProfile(
            definitionName: "test",
            standard: standard,
            flash: flash,
            embedding: embedding,
            router: router,
            residencyToken: .generate()
        )

        let sessionId = ULID.generate()
        let recordingDirectory = recordingsDir
            .appendingPathComponent(router.id.description, isDirectory: true)
            .appendingPathComponent(sessionId.description, isDirectory: true)

        let session = RoutedSessionActor(
            profile: profile,
            routerId: router.id,
            id: sessionId,
            parentId: nil,
            recordingDirectory: recordingDirectory,
            workingDirectory: recordingDirectory,
            backend: backend,
            slot: .standard,
            model: transcriptReconstructionTinyModel,
            recorder: recorder,
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
            routerId: router.id,
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
