import Foundation
import FoundationModels
import HuggingFace
import MLXHuggingFace
import MLXLMCommon
import Testing
import Tokenizers

@testable import FoundationModelsRouter

// MARK: - Gate

/// Reuses the same opt-in gating pattern as ``IntegrationTests`` and
/// ``LanguageModelSessionBackendIntegrationTests``: unset (the default, and
/// on any CI/GPU-less box) this whole suite is skipped, so `swift test` stays
/// green without network or a GPU. Kept as its own private constant rather
/// than sharing another file's — Swift's top-level `private` is file-scoped,
/// not target-scoped.
private let transcriptReconstructionIntegrationEnvVar = "FM_ROUTER_INTEGRATION_TESTS"

private var transcriptReconstructionIntegrationEnabled: Bool {
    ProcessInfo.processInfo.environment[transcriptReconstructionIntegrationEnvVar] != nil
}

/// The same deliberately tiny `mlx-community` generation model
/// ``IntegrationTests``' `TinyModels.generation` uses.
private let transcriptReconstructionTinyModel: ModelRef = "mlx-community/SmolLM-135M-Instruct-4bit"

// MARK: - Suite

/// Gated real-model coverage for task dw0zx8k: reconstructing a real
/// `FoundationModels.Transcript` from recorded events end-to-end against a
/// live model, proving ``TranscriptTree/effectiveTranscript(forSession:registry:)``
/// against something more than stub-fabricated entries (see plan.md's
/// "Transcript fidelity" section, "Reconstruction end-to-end").
///
/// Builds a real ``RoutedSessionActor`` directly over an already-loaded tiny
/// model's backend (bypassing `Router.resolve(_:reporting:)`, which would
/// need a real `.flash`/`.embedding` download too) — the same technique
/// ``LanguageModelSessionBackendIntegrationTests`` uses, extended to record
/// into a durable `recordingsDir` so the on-disk transcript can be reloaded
/// through a fresh ``TranscriptTree``.
@Suite(
    "Gated real-model coverage: effectiveTranscript reconstruction (task dw0zx8k)",
    .serialized,
    .timeLimit(.minutes(15)),
    .enabled(if: transcriptReconstructionIntegrationEnabled)
)
struct TranscriptReconstructionIntegrationTests {
    /// Loads the tiny model directly through a real ``LiveModelLoader`` and
    /// returns its concrete ``MLXFoundationModelsContainer``.
    private func makeContainer() async throws -> MLXFoundationModelsContainer {
        let loader = LiveModelLoader(
            downloader: #hubDownloader(),
            tokenizerLoader: #huggingFaceTokenizerLoader()
        )
        let loaded = try await loader.loadLLM(
            ref: transcriptReconstructionTinyModel,
            slot: .standard,
            context: 512,
            reporting: { _ in }
        )
        return try #require(loaded as? MLXFoundationModelsContainer)
    }

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
        let container = try await makeContainer()
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
        // so it also writes the root's sidecar by hand, just as `makeSession`
        // does at vending.
        func durableRecording(_ slot: ModelSlot) -> DurableRecording {
            DurableRecording(
                root: recordingsDir,
                sidecarWriter: SessionSidecarWriter(
                    slot: slot,
                    model: transcriptReconstructionTinyModel,
                    context: noopResolution(slot).contextTokens,
                    recordingLevel: .full,
                    profile: nil
                )
            )
        }
        let standard = RoutedLLM(
            slot: .standard,
            chosen: transcriptReconstructionTinyModel,
            footprintBytes: 0,
            resolution: noopResolution(.standard),
            container: container,
            routerId: router.id,
            recorder: recorder,
            durableRecording: durableRecording(.standard)
        )
        let flash = RoutedLLM(
            slot: .flash,
            chosen: transcriptReconstructionTinyModel,
            footprintBytes: 0,
            resolution: noopResolution(.flash),
            container: container,
            routerId: router.id,
            recorder: recorder,
            durableRecording: durableRecording(.flash)
        )
        let embedding = RoutedEmbedder(
            slot: .embedding,
            chosen: transcriptReconstructionTinyModel,
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

        let sessionId = ULID.generate()
        let recordingDirectory = recordingsDir
            .appendingPathComponent(router.id.description, isDirectory: true)
            .appendingPathComponent(sessionId.description, isDirectory: true)

        // `makeSession` writes a vended root's sidecar before the session
        // exists to record anything into it; this hand-built root does the same
        // by hand, since `TranscriptTree.load` below refuses a transcript with
        // no sidecar beside it. A root carries no fork cut point.
        standard.sessionSidecarWriter?.write(
            instructions: nil,
            grammar: nil,
            forkedAtEntryCount: nil,
            to: recordingDirectory
        )

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
            serialGate: standard.serialGate,
            forkAdmissionGate: standard.forkAdmissionGate,
            holdsAdmissionPermit: false,
            persistedEntryCount: 0,
            // The vending handle's own writer, exactly as `makeSession` threads
            // it, so any fork taken from this session records its sidecar too.
            sessionSidecarWriter: standard.sessionSidecarWriter
        )

        return Harness(
            session: session,
            backend: backend,
            routerId: router.id,
            sessionId: sessionId,
            recordingsDir: recordingsDir,
            cacheDir: cacheDir
        )
    }

    /// Task dw0zx8k's core acceptance criterion, proved against a real
    /// model: after one live turn recorded at `full`, the `Transcript`
    /// ``TranscriptTree/effectiveTranscript(forSession:registry:)`` rebuilds
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

        _ = try await harness.session.respond(to: "Say 'hi' briefly.", maxTokens: 64)

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
    }
}
