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
    /// The date every gated suite pins into its prompt, written the way a
    /// Llama chat template writes it.
    ///
    /// Greedy decoding pins the SAMPLING. It does not pin the PROMPT. The
    /// Llama 3.2 chat template writes `Today Date: <today>` into the system
    /// header of every call. It takes that date from `strftime_now`, which the
    /// Jinja engine answers from `Date()` and the local time zone. So the same
    /// code and the same weights answered differently on two calendar days
    /// (task ^f0k3aah). A test that passes today and fails tomorrow with no
    /// change is not a test.
    ///
    /// The value is the template's OWN fallback. It is the date the template
    /// assigns when `strftime_now` is undefined:
    ///
    /// ```
    /// {%- if not date_string is defined %}
    ///     {%- if strftime_now is defined %}
    ///         {%- set date_string = strftime_now("%d %b %Y") %}
    ///     {%- else %}
    ///         {%- set date_string = "26 Jul 2024" %}
    /// ```
    ///
    /// So the constant is the template's own. It is not a date chosen because
    /// it made a run green. The template reads `date_string` FIRST, so stating
    /// the value stops `strftime_now` running at all.
    ///
    /// One constant rather than one per suite. Three gated suites pin the
    /// date, and each of them would otherwise repeat this value and this
    /// reason. Each suite still records its OWN measured numbers in its own
    /// doc comment.
    ///
    /// It reaches every family the loader knows, and not the Llama family
    /// alone. `Muse-Glimmer-30B-4bit` reads `current_date` rather than
    /// `date_string`, and it reads it only when the conversation carries no
    /// system message. ``FoundationModelsRouter/PinnedDateTokenizerLoader``
    /// states this value under both names, so a Muse Glimmer prompt takes it
    /// too (task ^g8rywv2). That prompt then writes the date in the Llama
    /// family's shape rather than the `%Y-%m-%d` shape Muse Glimmer's own
    /// fallback writes; what the pin owes each suite is a date that does not
    /// move, and one value does that under either shape.
    public static let chatTemplateFallbackDate = "26 Jul 2024"

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
