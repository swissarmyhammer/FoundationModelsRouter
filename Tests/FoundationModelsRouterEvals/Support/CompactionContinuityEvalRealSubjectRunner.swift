import Foundation
import HuggingFace
import MLXHuggingFace
import MLXLMCommon
import Tokenizers

@testable import FoundationModelsRouter

/// Loads ``CompactionEvalRealModel`` at most once and reuses it across every
/// sample's ``run(steps:finalInstruction:prompt:budget:)`` call, driving a
/// real, full ``RoutedSession`` (task 8213x39's auto-compaction opt-in) per
/// call rather than the bare `Compactor.compact` + one-shot session recipe
/// ``CompactionEvalRealSubjectRunner`` uses — this evaluation needs the whole
/// session surface (``RoutedLLM/makeSession(instructions:workingDirectory:tools:budget:compactionPrompt:)``,
/// ``RoutedSession/streamEvents(to:maxTokens:)``, and its durable recording)
/// to drive a genuinely multi-step, auto-compacting conversation, not just
/// one fold-then-ask call.
///
/// Builds a fresh ``LanguageModelProfile``/``Router`` per call over the one
/// cached, already-loaded ``MLXFoundationModelsContainer`` — the same
/// manual-harness technique ``CompactionRoundTripIntegrationTests.buildProfile``
/// uses (reimplemented here since that type lives in a different test target
/// with no dependency in either direction) — so every sample gets its own
/// isolated recording root without paying for a second model download.
actor CompactionContinuityEvalRealSubjectRunner {
    private var loaded: MLXFoundationModelsContainer?

    /// A minimal ``LoadedEmbeddingContainer`` stand-in for the unused
    /// `.embedding` slot every ``LanguageModelProfile`` built here must still
    /// carry — never exercised, only present to satisfy the type. Mirrors
    /// `CompactionRoundTripIntegrationTests.UnusedEmbeddingContainer`.
    private struct UnusedEmbeddingContainer: LoadedEmbeddingContainer {
        let dimension = 1
        func embed(texts: [String]) async throws -> [[Float]] { [] }
    }

    /// The resident container, loading it on first access and caching it for
    /// every later call.
    ///
    /// - Returns: The cached container, if one was already loaded, or the
    ///   newly-loaded and now-cached container otherwise.
    /// - Throws: ``CompactionContinuityEvaluationError/unexpectedContainerType``
    ///   if the loaded container is not an `MLXFoundationModelsContainer`, or
    ///   whatever error ``LiveModelLoader/loadLLM(ref:slot:context:reporting:)``
    ///   throws while resolving/loading ``CompactionEvalRealModel/ref``.
    private func container() async throws -> MLXFoundationModelsContainer {
        if let loaded { return loaded }
        let loader = LiveModelLoader(
            downloader: #hubDownloader(),
            tokenizerLoader: #huggingFaceTokenizerLoader()
        )
        let container = try await loader.loadLLM(
            ref: CompactionEvalRealModel.ref,
            slot: .standard,
            context: CompactionEvalRealModel.context,
            reporting: { _ in }
        )
        guard let mlxContainer = container as? MLXFoundationModelsContainer else {
            throw CompactionContinuityEvaluationError.unexpectedContainerType
        }
        loaded = mlxContainer
        return mlxContainer
    }

    /// Builds a real ``LanguageModelProfile`` directly over `container`, with
    /// a fresh, isolated recording root — the same manual-harness technique
    /// `CompactionRoundTripIntegrationTests.buildProfile` uses, minus the
    /// restore-across-two-routers machinery this evaluation doesn't need
    /// (every sample is driven start to finish within one call).
    private func buildProfile(
        container: MLXFoundationModelsContainer,
        cacheDir: URL,
        recordingsDir: URL
    ) -> LanguageModelProfile {
        let recorder = JSONLRecorder(directory: recordingsDir)
        let router = Router(cacheDir: cacheDir, recordingsDir: recordingsDir, recorder: recorder)

        func noopResolution(_ slot: ModelSlot) -> SlotResolution {
            SlotResolution(
                slot: slot,
                remainingBudgetBytes: 0,
                chosen: CompactionEvalRealModel.ref,
                considered: [],
                contextTokens: CompactionEvalRealModel.context
            )
        }
        func durableRecording(_ slot: ModelSlot) -> DurableRecording {
            DurableRecording(
                root: recordingsDir,
                sidecarWriter: SessionSidecarWriter(
                    slot: slot,
                    model: CompactionEvalRealModel.ref,
                    context: noopResolution(slot).contextTokens,
                    recordingLevel: .full,
                    profile: nil
                )
            )
        }
        // `.standard` and `.flash` differ only in which slot they're stamped
        // with — both share the same resident `container`, so a single
        // helper builds either from its slot alone.
        func makeRoutedLLM(_ slot: ModelSlot) -> RoutedLLM {
            RoutedLLM(
                slot: slot,
                chosen: CompactionEvalRealModel.ref,
                footprintBytes: 0,
                resolution: noopResolution(slot),
                container: container,
                routerId: router.id,
                recorder: recorder,
                durableRecording: durableRecording(slot)
            )
        }
        let standard = makeRoutedLLM(.standard)
        let flash = makeRoutedLLM(.flash)
        let embedding = RoutedEmbedder(
            slot: .embedding,
            chosen: CompactionEvalRealModel.ref,
            footprintBytes: 0,
            resolution: noopResolution(.embedding),
            container: UnusedEmbeddingContainer(),
            routerId: router.id,
            recorder: recorder,
            durableRecording: durableRecording(.embedding)
        )
        return LanguageModelProfile(
            definitionName: "compaction-continuity-eval",
            standard: standard,
            flash: flash,
            embedding: embedding,
            router: router,
            residencyToken: .generate()
        )
    }

    /// Runs one sample's real subject work (task 4ce0a1k): opens a fresh
    /// session over the resident model vended with `prompt`/`budget`, drives
    /// every one of `steps` through it in order, then asks
    /// `finalInstruction` — counting every ``SessionEvent/compaction(_:)``
    /// this drives, wherever in the sequence it lands, and reading the
    /// session's own durable recording afterward to report how many entries
    /// it actually persisted.
    ///
    /// - Parameters:
    ///   - steps: The setup/filler steps to send, in order, before
    ///     `finalInstruction`.
    ///   - finalInstruction: The final step, whose reply is `finalAnswer`.
    ///   - prompt: The compaction prompt to vend the session with.
    ///   - budget: The auto-compaction budget to vend the session with.
    /// - Returns: The final answer, the total fold count and last fold's
    ///   token counts (zero if none ran), the durable recording's own
    ///   persisted entry count, and the resolved model's name.
    /// - Throws: Whatever ``container()`` throws while loading the resident
    ///   model, or whatever a step's `streamEvents(to:maxTokens:)` throws.
    func run(
        steps: [String],
        finalInstruction: String,
        prompt: CompactionPrompt,
        budget: TokenBudget
    ) async throws -> (
        finalAnswer: String, foldCount: Int, tokensBefore: Int, tokensAfter: Int, recordedEntryCount: Int,
        modelName: String
    ) {
        let container = try await self.container()
        let cacheDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CompactionContinuityEval-cache-\(UUID().uuidString)", isDirectory: true)
        let recordingsDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CompactionContinuityEval-recordings-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: cacheDir)
            try? FileManager.default.removeItem(at: recordingsDir)
        }

        let profile = buildProfile(container: container, cacheDir: cacheDir, recordingsDir: recordingsDir)
        let session = profile.standard.makeSession(
            instructions: "You are a helpful assistant in an ongoing conversation.",
            budget: budget,
            compactionPrompt: prompt
        )

        // A free function, not a nested closure capturing this method's own
        // mutable locals: a nested closure that both hops across the
        // `session` actor (via `await session.streamEvents`) and mutates
        // this actor-isolated method's own local `var`s trips Swift 6's
        // stricter concurrency checking ("sending risks causing data
        // races") even though every call here is fully sequential — so each
        // step's own fold accounting is returned and folded into the
        // running totals by the caller instead.
        func driveStep(
            _ session: RoutedSession, _ text: String
        ) async throws -> (reply: String, foldCount: Int, tokensBefore: Int, tokensAfter: Int) {
            var reply = ""
            var stepFoldCount = 0
            var stepTokensBefore = 0
            var stepTokensAfter = 0
            let stream = await session.streamEvents(to: text, maxTokens: 64)
            for try await event in stream {
                switch event {
                case .textDelta(let fragment):
                    reply += fragment
                case .compaction(let result):
                    stepFoldCount += 1
                    stepTokensBefore = result.tokensBefore
                    stepTokensAfter = result.tokensAfter
                default:
                    break
                }
            }
            return (reply, stepFoldCount, stepTokensBefore, stepTokensAfter)
        }

        var foldCount = 0
        var lastTokensBefore = 0
        var lastTokensAfter = 0

        func accumulate(_ stepResult: (reply: String, foldCount: Int, tokensBefore: Int, tokensAfter: Int)) {
            foldCount += stepResult.foldCount
            if stepResult.foldCount > 0 {
                lastTokensBefore = stepResult.tokensBefore
                lastTokensAfter = stepResult.tokensAfter
            }
        }

        for step in steps {
            accumulate(try await driveStep(session, step))
        }
        let finalStepResult = try await driveStep(session, finalInstruction)
        accumulate(finalStepResult)
        let finalAnswer = finalStepResult.reply

        let routerDirectory = recordingsDir.appendingPathComponent(profile.standard.routerId.description, isDirectory: true)
        let tree = try TranscriptTree.load(under: routerDirectory)
        let fullHistory = try tree.effectiveTranscript(forSession: session.id, view: .fullHistory)

        return (
            finalAnswer: finalAnswer,
            foldCount: foldCount,
            tokensBefore: lastTokensBefore,
            tokensAfter: lastTokensAfter,
            recordedEntryCount: fullHistory.count,
            modelName: CompactionEvalRealModel.ref.stringValue
        )
    }

    /// Evicts the resident model, if one was ever loaded — called once after
    /// the gated `@Test` has read its ``EvaluationResult``, mirroring
    /// ``CompactionEvalRealSubjectRunner/evictIfLoaded()``.
    func evictIfLoaded() async {
        guard let loaded else { return }
        await loaded.model.evict()
    }
}
