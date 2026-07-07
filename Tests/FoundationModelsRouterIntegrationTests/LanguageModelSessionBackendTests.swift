import Foundation
import HuggingFace
import MLXHuggingFace
import MLXLMCommon
import Testing
import Tokenizers

@testable import FoundationModelsRouter

// MARK: - Gate

/// Reuses the same opt-in gating pattern as ``IntegrationTests``: unset (the
/// default, and on any CI/GPU-less box) this whole suite is skipped, so `swift
/// test` stays green without network or a GPU. Kept as its own private
/// constant rather than sharing ``IntegrationTests``' file-scoped one — Swift's
/// top-level `private` is file-scoped, not target-scoped.
private let sessionBackendIntegrationEnvVar = "FM_ROUTER_INTEGRATION_TESTS"

private var sessionBackendIntegrationEnabled: Bool {
    ProcessInfo.processInfo.environment[sessionBackendIntegrationEnvVar] != nil
}

/// The same deliberately tiny `mlx-community` generation model
/// ``IntegrationTests``' `TinyModels.generation` uses.
private let sessionBackendTinyModel: ModelRef = "mlx-community/SmolLM-135M-Instruct-4bit"

// MARK: - Suite

/// Gated real-model coverage for ``MLXFoundationModelsSessionBackend`` (the live
/// ``LanguageModelSessionBackend`` conformance in `LiveModelLoader.swift`).
///
/// This backend's whole reason to hold one `LanguageModelSession` per instance —
/// instead of rebuilding a fresh one per call, as it did before — is to
/// accumulate conversation state (the transcript) across turns, and to let
/// ``MLXFoundationModelsSessionBackend/makeFork()`` seed a child from that
/// accumulated transcript via `LanguageModelSession.init(model:tools:transcript:)`.
/// Both are only observable against a real, generating model — there is nothing
/// to assert GPU-free here (the GPU-free coverage in
/// `Tests/FoundationModelsRouterTests/LanguageModelSessionBackendTests.swift`
/// covers the schema-conversion seam instead). This suite loads the tiny model
/// directly through ``LiveModelLoader``, bypassing ``Router``/``RoutedSession``,
/// so the backend itself — not the one-backend-per-call path
/// ``RoutedSessionActor`` still drives today (see plan.md) — is what's under
/// test. `internal var session` on the backend exists specifically so this
/// `@testable import` can read `transcript.count` directly.
@Suite(
    "Gated real-model coverage: MLXFoundationModelsSessionBackend (milestone 7)",
    .serialized,
    .timeLimit(.minutes(15)),
    .enabled(if: sessionBackendIntegrationEnabled)
)
struct LanguageModelSessionBackendIntegrationTests {
    /// Loads the tiny model directly through a real ``LiveModelLoader`` and
    /// returns its concrete ``MLXFoundationModelsContainer``.
    private func makeContainer() async throws -> MLXFoundationModelsContainer {
        let loader = LiveModelLoader(
            downloader: #hubDownloader(),
            tokenizerLoader: #huggingFaceTokenizerLoader()
        )
        let loaded = try await loader.loadLLM(
            ref: sessionBackendTinyModel,
            slot: .standard,
            context: 512,
            reporting: { _ in }
        )
        return try #require(loaded as? MLXFoundationModelsContainer)
    }

    @Test("a second respond() call on the same backend sees the first turn's content in context")
    func secondRespondSeesPriorTurn() async throws {
        let container = try await makeContainer()
        let backend = try #require(
            container.makeSession(instructions: "You are a terse, literal assistant.")
                as? MLXFoundationModelsSessionBackend
        )

        _ = try await backend.respond(to: "My favorite color is teal. Reply with just \"OK\".", maxTokens: 64)
        let entriesAfterFirstTurn = backend.session.transcript.count
        #expect(entriesAfterFirstTurn > 0)

        // The proof this backend is conversation-preserving (not rebuilding a
        // fresh, context-free session per call, as it did before this change):
        // the second turn's answer must reflect the first turn's content.
        let secondReply = try await backend.respond(
            to: "What is my favorite color? Answer with just the color, lowercase.",
            maxTokens: 64
        )
        #expect(secondReply.lowercased().contains("teal"))

        // And the same session accumulated a second turn on top of the first,
        // rather than starting over.
        #expect(backend.session.transcript.count > entriesAfterFirstTurn)
    }

    @Test("makeFork() seeds the child's transcript from the parent's at fork time")
    func makeForkSeedsFromParentTranscript() async throws {
        let container = try await makeContainer()
        let parent = try #require(
            container.makeSession(instructions: "You are a terse, literal assistant.")
                as? MLXFoundationModelsSessionBackend
        )

        _ = try await parent.respond(to: "Remember the number 42.", maxTokens: 64)
        let parentEntryCountAtForkTime = parent.session.transcript.count

        let child = try #require(parent.makeFork() as? MLXFoundationModelsSessionBackend)

        // The child's session begins holding exactly the parent's entries as of
        // fork time — `LanguageModelSession.init(model:tools:transcript:)` seeded
        // it, not an empty/fresh transcript.
        #expect(child.session.transcript.count == parentEntryCountAtForkTime)

        // The transcript-count check above only proves the entry count matches;
        // it does not prove the fork can actually *see* the parent's prior-turn
        // content. Drive the fork with a real turn and assert its answer
        // reflects the number the parent was told to remember before the fork —
        // the same content-awareness proof ``secondRespondSeesPriorTurn`` above
        // uses for same-backend continuity, applied here across the fork
        // boundary.
        let childReply = try await child.respond(
            to: "What number should I remember? Answer with just the number.",
            maxTokens: 64
        )
        #expect(childReply.contains("42"))
        let childEntryCountAfterOwnTurn = child.session.transcript.count

        // The two then diverge independently: a further parent turn does not
        // retroactively change the child's already-seeded (and now
        // independently-grown) transcript.
        _ = try await parent.respond(to: "Remember the number 7 too.", maxTokens: 64)
        #expect(child.session.transcript.count == childEntryCountAfterOwnTurn)
    }
}
