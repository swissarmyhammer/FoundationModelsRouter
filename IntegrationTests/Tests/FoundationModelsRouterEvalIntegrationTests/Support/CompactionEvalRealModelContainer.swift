import Foundation
import FoundationModels
import HuggingFace
import MLXHuggingFace
import MLXLMCommon
import Tokenizers

@testable import FoundationModelsRouter
@testable import FoundationModelsRouterEvalSupport

/// The one way a gated eval tier in this target puts its real model into a
/// concrete ``MLXFoundationModelsContainer``.
///
/// Both real-subject runners carried the same three-step body: build a
/// ``LiveModelLoader`` over the fork's two Hub macros, load the `.standard`
/// slot at the tier's own context, then narrow the returned
/// `any LoadedLLMContainer` to the concrete type. What differed between them
/// is this function's parameters — since task ^m03heaa that includes the
/// model itself, because the fact-retention tiers resolve
/// ``CompactionEvalRealModel`` while the continuity tier resolves
/// ``CompactionContinuityRealModel``. The load's own progress lines were a
/// difference once, and they are no longer one: both tiers state the load
/// now (task ^aktsp2e), so this function emits them.
///
/// Caching the loaded container is deliberately NOT here. That is per-runner
/// state — each runner holds one model resident across its own samples — and it
/// stays with the runner.
///
/// ## Why this is not `RealModelContainer`
///
/// `Tests/FoundationModelsRouterIntegrationTests/Support/RealModelContainer.swift`
/// is the same consolidation for the integration target, and this target cannot
/// call it. A helper returning ``MLXFoundationModelsContainer`` needs
/// `@testable import FoundationModelsRouter`, because that type is internal to
/// the router, and `@testable` reaches only a LEAF test target.
///
/// Measured against this package rather than assumed. Adding the MLX and Hub
/// products to `FoundationModelsRouterTestSupport` and putting the helper there
/// builds clean under `swift build --build-tests` — a `public` function may even
/// return the internal type. It then breaks `swift build -c release`, which
/// compiles that target and gets `unable to resolve Swift module dependency to a
/// compatible module: 'FoundationModelsRouter'`, because a release build of the
/// router carries no testability. Declaring that target a `.testTarget` does not
/// rescue it: SwiftPM accepts the declaration, but release still compiles it and
/// still fails, while the leaf test targets are not compiled in release at all.
/// SwiftPM cannot share source between two leaf test targets, so each module
/// keeps one loader, and neither keeps two.
enum CompactionEvalRealModelContainer {
    /// Loads a tier's real model and returns the concrete container behind
    /// it, timing the load on its own two progress lines.
    ///
    /// The load is stated apart from the samples, so it is never charged to the
    /// first one. A tier that spends its whole limit here leaves the started
    /// line and no returned line, which is the trail
    /// ``gatedEvalSuiteTimeLimitMinutes`` exists to bound.
    ///
    /// - Parameters:
    ///   - ref: The model to resolve — ``CompactionEvalRealModel/ref`` for the
    ///     fact-retention tiers, ``CompactionContinuityRealModel/ref`` for the
    ///     continuity tier. The load's two progress lines name it.
    ///   - context: The maximum context window, in tokens, to load `ref`
    ///     with — the matching `context` constant beside each `ref`.
    ///   - samplingMode: The decoding strategy the loaded container generates
    ///     with. Defaults to `nil`, which leaves the provider's own default in
    ///     place, and that default samples. A tier whose score reads the exact
    ///     text a generation produced passes
    ///     ``FoundationModels/GenerationOptions/SamplingMode/greedy``: the
    ///     provider default draws at temperature `0.6` from MLX's process-global
    ///     PRNG, which seeds itself from the clock, so identical code scored
    ///     differently on every run (task `f80n046`). Argmax decoding consumes no
    ///     randomness at all, which is what lets a red run be attributed to the
    ///     change under test.
    ///   - unexpectedContainerType: The error to throw when the loader resolves
    ///     something other than an ``MLXFoundationModelsContainer``. Each tier
    ///     owns a domain error of its own — see
    ///     ``CompactionEvaluationError/unexpectedContainerType`` and
    ///     ``CompactionContinuityEvaluationError/unexpectedContainerType`` — and
    ///     passing one in keeps both cases with a thrower.
    /// - Returns: The loaded container.
    /// - Throws: `unexpectedContainerType` if what was loaded is not an
    ///   ``MLXFoundationModelsContainer``, or whatever
    ///   ``LiveModelLoader/loadLLM(ref:slot:context:reporting:)`` throws while
    ///   resolving and loading `ref`.
    static func load(
        ref: ModelRef,
        context: Int,
        samplingMode: GenerationOptions.SamplingMode? = nil,
        unexpectedContainerType: any Error
    ) async throws -> MLXFoundationModelsContainer {
        let modelName = ref.stringValue
        CompactionEvalProgressLog.emit(CompactionEvalProgressLog.makeModelLoadStartedLine(ref: modelName))
        let startedAt = Date()
        let loader = LiveModelLoader(
            downloader: #hubDownloader(),
            tokenizerLoader: #huggingFaceTokenizerLoader(),
            samplingMode: samplingMode
        )
        let loaded = try await loader.loadLLM(
            ref: ref,
            slot: .standard,
            context: context,
            reporting: { _ in }
        )
        guard let container = loaded as? MLXFoundationModelsContainer else {
            throw unexpectedContainerType
        }
        CompactionEvalProgressLog.emit(
            CompactionEvalProgressLog.makeModelLoadReturnedLine(
                ref: modelName, seconds: Date().timeIntervalSince(startedAt)))
        return container
    }
}
