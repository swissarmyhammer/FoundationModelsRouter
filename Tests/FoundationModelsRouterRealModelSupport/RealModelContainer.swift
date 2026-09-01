import Foundation
import FoundationModels
import FoundationModelsRouter
import HuggingFace
import MLXHuggingFace
import MLXLMCommon
import Testing
import Tokenizers

/// The one way every gated suite puts a real model into its concrete
/// ``MLXFoundationModelsContainer``.
///
/// Nine suites each carried a private copy of the same three-step body: build a
/// ``LiveModelLoader`` over the fork's two Hub macros, load the `.standard`
/// slot, then narrow the returned `any LoadedLLMContainer` to the concrete
/// type. The copies had already drifted — seven load at ``RealModels/context``
/// with the provider's own decoding, one loads at its suite's own context with
/// greedy decoding, one at both — so each new suite copied whichever neighbour
/// it happened to read.
///
/// Exactly three things differed, and those three are this function's first
/// three parameters. A suite still states its own model, its own context and
/// its own decoding; nothing else about loading a real model is stated twice.
///
/// A fourth parameter followed, and it is not a difference between the nine
/// copies: ``load(ref:context:samplingMode:chatTemplateDate:)`` also pins the
/// date a chat template writes into its prompt. A suite that asserts on the
/// exact text a model wrote needs a prompt that does not move from one calendar
/// day to the next. See ``FoundationModelsRouter/PinnedDateTokenizerLoader``.
///
/// ## What is deliberately not a parameter
///
/// The `.standard` slot and the discarded progress callback stay fixed. All
/// nine callers passed exactly those, and a suite that needs another slot, or
/// needs to observe download progress, is asking for something this function
/// does not describe — ``IntegrationTests`` builds its own instrumented loader
/// stack for precisely that reason and is not a caller here.
public enum RealModelContainer {
    /// Loads `ref` and returns the concrete container behind it.
    ///
    /// - Parameters:
    ///   - ref: The model to download and load.
    ///   - context: The context length to size the model for. Defaults to
    ///     ``RealModels/context``, the budget the gated integration suites
    ///     request; a suite whose fixtures are sized against a different window
    ///     passes its own.
    ///   - samplingMode: The decoding strategy the loaded container generates
    ///     with. Defaults to `nil`, which leaves the provider's own default in
    ///     place, and that default samples. A suite that asserts on the exact
    ///     text a generation produces passes
    ///     ``FoundationModels/GenerationOptions/SamplingMode/greedy``: the
    ///     provider default draws at temperature `0.6` from MLX's
    ///     process-global PRNG, which seeds itself from the clock, so identical
    ///     code produced different transcripts on every run (task `f80n046`).
    ///     Argmax decoding consumes no randomness at all, which is what lets a
    ///     red run be attributed to the change under test.
    ///   - chatTemplateDate: The calendar date the model's chat template writes
    ///     into its prompt, written the way the template writes it. Defaults to
    ///     `nil`, which leaves the template reading the clock. A suite that
    ///     asserts on the exact text a generation produces passes a date:
    ///     greedy decoding pins the sampling but NOT the prompt, and the Llama
    ///     family stamps `Today Date: <today>` into every system header, so the
    ///     same code and the same weights answered differently on two calendar
    ///     days (task ^f0k3aah). See
    ///     ``FoundationModelsRouter/PinnedDateTokenizerLoader``.
    /// - Returns: The loaded container.
    /// - Throws: Whatever ``LiveModelLoader/loadLLM(ref:slot:context:reporting:)``
    ///   throws, or an expectation failure if what it loaded is not an
    ///   ``MLXFoundationModelsContainer``.
    // Only the suites in the IntegrationTests package call this.
    // Periphery reads only this package's index, thus it finds no caller.
    // periphery:ignore
    package static func load(
        ref: ModelRef,
        context: Int = RealModels.context,
        samplingMode: GenerationOptions.SamplingMode? = nil,
        chatTemplateDate: String? = nil
    ) async throws -> MLXFoundationModelsContainer {
        let loader = LiveModelLoader(
            downloader: #hubDownloader(),
            tokenizerLoader: tokenizerLoader(pinning: chatTemplateDate),
            samplingMode: samplingMode
        )
        let loaded = try await loader.loadLLM(
            ref: ref,
            slot: .standard,
            context: context,
            reporting: { _ in }
        )
        return try #require(loaded as? MLXFoundationModelsContainer)
    }

    /// The tokenizer loader ``load(ref:context:samplingMode:chatTemplateDate:)``
    /// builds its ``LiveModelLoader`` over.
    ///
    /// - Parameter chatTemplateDate: the date to pin, or `nil` to leave the
    ///   chat template reading the clock.
    /// - Returns: the Hub tokenizer loader, wrapped when a date is pinned.
    private static func tokenizerLoader(pinning chatTemplateDate: String?)
        -> any TokenizerLoader
    {
        let hub = #huggingFaceTokenizerLoader()
        guard let chatTemplateDate else { return hub }
        return PinnedDateTokenizerLoader(wrapping: hub, dateString: chatTemplateDate)
    }
}
