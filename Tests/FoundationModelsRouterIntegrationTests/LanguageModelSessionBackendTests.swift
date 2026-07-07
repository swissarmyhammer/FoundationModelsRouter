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

    // MARK: - Transcript growth and fork seeding (exact counts)

    @Test("the transcript grows by exactly two entries (prompt + response) per turn across two respond() calls")
    func transcriptGrowsByTwoEntriesPerTurn() async throws {
        let container = try await makeContainer()
        // No instructions: an instructions-carrying session's transcript opens
        // with an extra `.instructions` entry, which would make the exact
        // per-turn arithmetic below (`.prompt` + `.response` == 2 entries/turn)
        // off by one. Omitting instructions isolates the count this test
        // checks to turn-driven entries only.
        let backend = try #require(
            container.makeSession(instructions: nil) as? MLXFoundationModelsSessionBackend
        )

        _ = try await backend.respond(to: "Say 'hi' briefly.", maxTokens: 64)
        _ = try await backend.respond(to: "Say 'hi' again, briefly.", maxTokens: 64)

        // Two turns × (one `.prompt` entry + one `.response` entry) == 4.
        #expect(backend.session.transcript.count == 4)
    }

    @Test("a fork taken after one turn begins holding exactly that turn's two transcript entries")
    func forkAfterOneTurnHasExactlyTwoEntries() async throws {
        let container = try await makeContainer()
        let parent = try #require(
            container.makeSession(instructions: nil) as? MLXFoundationModelsSessionBackend
        )

        _ = try await parent.respond(to: "Say 'hi' briefly.", maxTokens: 64)

        let child = try #require(parent.makeFork() as? MLXFoundationModelsSessionBackend)

        // One turn × (one `.prompt` entry + one `.response` entry) == 2.
        #expect(child.session.transcript.count == 2)
    }

    // MARK: - KV cache reuse across turns (the hard proof)

    @Test(
        "turn 2's usage.input.cachedTokenCount is positive and approximates everything turn 1 processed — the KV cache is reused, not recomputed"
    )
    func secondTurnReusesFirstTurnsKVCache() async throws {
        let container = try await makeContainer()
        let backend = try #require(
            container.makeSession(instructions: "You are a terse, literal assistant.")
                as? MLXFoundationModelsSessionBackend
        )

        _ = try await backend.respond(to: "My favorite color is teal. Reply with just \"OK\".", maxTokens: 64)
        let turn1Usage = backend.session.usage

        // Nothing could have been cached before the very first turn ever ran.
        #expect(turn1Usage.input.cachedTokenCount == 0)
        #expect(turn1Usage.input.totalTokenCount > 0)
        #expect(turn1Usage.output.totalTokenCount > 0)

        // Every token turn 1 processed — its prompt (including the
        // instructions entry) plus its own generated response — becomes part
        // of the growing transcript turn 2 sends as input, and should now be
        // served from cache rather than recomputed.
        let turn1ProcessedTokenCount = turn1Usage.input.totalTokenCount + turn1Usage.output.totalTokenCount

        _ = try await backend.respond(
            to: "What is my favorite color? Answer with just the color, lowercase.",
            maxTokens: 64
        )
        let turn2Usage = backend.session.usage

        // THE required proof: a zero cachedTokenCount here means the
        // executor-level KV-cache-reuse fix (tracked separately against the
        // vendored mlx-swift-lm fork) has not landed against the pinned
        // commit — a hard failure, not a warning, per this task's exit
        // criterion. This assertion is deliberately never weakened or made
        // non-fatal.
        #expect(
            turn2Usage.input.cachedTokenCount > 0,
            "turn 2 must reuse turn 1's KV cache; cachedTokenCount == 0 means no cache reuse happened"
        )

        // The cached count should approximate everything turn 1 processed —
        // allow generous slack for chat-template role markers and separator
        // tokens the framework re-renders between turns, which are not part
        // of either turn's own prompt/response token counts but do land in
        // the cached prefix.
        let tolerance = max(8, turn1ProcessedTokenCount / 4)
        #expect(
            abs(turn2Usage.input.cachedTokenCount - turn1ProcessedTokenCount) <= tolerance,
            """
            cachedTokenCount (\(turn2Usage.input.cachedTokenCount)) should approximate turn 1's total \
            processed tokens (\(turn1ProcessedTokenCount)) within \(tolerance)
            """
        )
    }

    // MARK: - Timing signal (best-effort, non-fatal)

    @Test(
        "turn 2 tends to be faster than turn 1 on a session with a long system instruction (heuristic timing signal, never fails CI)"
    )
    func secondTurnTendsToBeFasterThanFirst() async throws {
        let container = try await makeContainer()
        // A long instruction makes the fixed, cacheable prefix turn 2 should
        // reuse a much larger share of the input than a short one would, so a
        // real speed-up (if the cache is working) is more likely to be
        // visible above run-to-run noise on a tiny model.
        let longInstructions = String(
            repeating: "You are a careful, terse assistant who always answers in as few words as possible. ",
            count: 40
        )
        let backend = try #require(
            container.makeSession(instructions: longInstructions) as? MLXFoundationModelsSessionBackend
        )

        let turn1Start = Date()
        _ = try await backend.respond(to: "Say just 'OK'.", maxTokens: 32)
        let turn1Duration = Date().timeIntervalSince(turn1Start)

        let turn2Start = Date()
        _ = try await backend.respond(to: "Say just 'OK' again.", maxTokens: 32)
        let turn2Duration = Date().timeIntervalSince(turn2Start)

        // Heuristic/warning only: logged for a human to read, never asserted.
        // A ratio near (or above) 1.0 would be a signal worth investigating —
        // that the cache is not meaningfully speeding up turn 2 even if
        // `cachedTokenCount` reports reuse — but flaky wall-clock timing on
        // shared CI hardware must never fail this suite.
        let ratio = turn1Duration > 0 ? turn2Duration / turn1Duration : .nan
        print(
            "[secondTurnTendsToBeFasterThanFirst] turn1=\(turn1Duration)s turn2=\(turn2Duration)s ratio=\(ratio)"
        )
    }
}
