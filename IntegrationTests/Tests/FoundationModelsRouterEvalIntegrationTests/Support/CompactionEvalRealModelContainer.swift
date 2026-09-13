import Foundation
import FoundationModels
import HuggingFace
import MLXHuggingFace
import MLXLMCommon
import Tokenizers

@testable import FoundationModelsRouter
@testable import FoundationModelsRouterEvalSupport

/// A tier's real model, loaded, with the decoding strategy the tier pinned.
/// ``load(ref:context:samplingMode:unexpectedContainerType:)`` is the one way
/// a gated eval tier in this target puts its real model into a concrete
/// ``MLXFoundationModelsContainer``.
///
/// Both real-subject runners carried the same three-step body: build a
/// ``LiveModelLoader`` over the fork's two Hub macros, load the `.standard`
/// slot at the tier's own context, then narrow the returned
/// `any LoadedLLMContainer` to the concrete type. What differed between them
/// is this function's parameters — since task ^m03heaa that includes the
/// model itself, because the fact-retention tier resolves
/// ``CompactionEvalRealModel`` while the continuity tier resolves
/// ``CompactionContinuityRealModel``. The load's own progress lines were a
/// difference once, and they are no longer one: both tiers state the load
/// now (task ^aktsp2e), so this function emits them.
///
/// Caching the loaded container is deliberately NOT here. That is per-runner
/// state — each runner holds one model resident across its own samples — and it
/// stays with the runner.
///
/// ## Why the value carries the mode
///
/// The container stores no decoding strategy (`model-pool.md` §2.5, step B).
/// The mode belongs to the router, and each `makeSession(...samplingMode:)`
/// call names it. The fact-retention runner calls `makeSession` on the bare
/// ``container`` and has no router, so this value keeps the mode the tier
/// passed to ``load(ref:context:samplingMode:unexpectedContainerType:)``, and
/// the runner passes ``samplingMode`` into each call. The continuity runner
/// builds a profile and gives the mode to
/// ``RealModelHarness/make(model:context:container:samplingMode:cacheDir:recordingsDir:routerId:)``.
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
struct CompactionEvalRealModelContainer: Sendable {
    /// The loaded container. Each `makeSession` call on it must pass
    /// ``samplingMode``, because the container stores no mode of its own.
    let container: MLXFoundationModelsContainer

    /// The decoding strategy the tier loaded with, or `nil` for the provider
    /// default.
    let samplingMode: GenerationOptions.SamplingMode?

    /// Loads a tier's real model and returns the concrete container behind
    /// it with the pinned mode, timing the load on its own two progress lines.
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
    ///   - samplingMode: The decoding strategy the tier pins. The value is
    ///     kept on ``samplingMode``; the container stores no mode, so the
    ///     runner passes it into each `makeSession(...samplingMode:)` call or
    ///     into the profile it builds. Defaults to `nil`, which leaves the
    ///     provider's own default in place, and that default samples. A tier
    ///     whose score reads the exact text a generation produced passes
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
    /// - Returns: The loaded container and the pinned mode.
    /// - Throws: `unexpectedContainerType` if what was loaded is not an
    ///   ``MLXFoundationModelsContainer``, or whatever
    ///   ``LiveModelLoader/loadLLM(ref:slot:context:reporting:)`` throws while
    ///   resolving and loading `ref`.
    static func load(
        ref: ModelRef,
        context: Int,
        samplingMode: GenerationOptions.SamplingMode? = nil,
        unexpectedContainerType: any Error
    ) async throws -> CompactionEvalRealModelContainer {
        let modelName = ref.stringValue
        CompactionEvalProgressLog.emit(CompactionEvalProgressLog.makeModelLoadStartedLine(ref: modelName))
        let startedAt = Date()
        let loader = LiveModelLoader(
            downloader: #hubDownloader(),
            tokenizerLoader: #huggingFaceTokenizerLoader()
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
        return CompactionEvalRealModelContainer(container: container, samplingMode: samplingMode)
    }
}
