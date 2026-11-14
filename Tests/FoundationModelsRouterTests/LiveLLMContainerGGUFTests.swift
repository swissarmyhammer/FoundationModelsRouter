import Foundation
import FoundationModels
import FoundationModelsExtras
import FoundationModelsLlamaCpp
import LlamaCppTestFixtures
import Testing

@testable import FoundationModelsRouter

/// Proves that the live loader wraps a GGUF model: the Extras GGUF loader
/// gives a `LlamaLanguageModel`, and the router wraps it in the same live
/// container as an MLX model, with the context the model loaded at as its
/// window and the vocabulary of the model as its token counter.
///
/// No test loads weights. Each test builds the model over a vocab-only GGUF
/// fixture of llama.cpp, which holds the vocabulary and the chat template.
@Suite("Live container over a GGUF model")
struct LiveLLMContainerGGUFTests {
    /// The reference the container names.
    private static let ref: ModelRef = "org/model-GGUF/Q4_K_M"

    /// The context the model loads at. It is not the llama.cpp default, so
    /// the window tells that the container read it from the model.
    private static let contextSize = 8_192

    /// A text of many multi-byte characters, so a cut by tokens can fall
    /// inside a character.
    private static let multiByteText = "naïve café — 日本語のテキストを数える"

    /// The tokens the cut fixture keeps: fewer than `multiByteText` holds.
    private static let cutTokens = 5

    /// A vocab-only Qwen 3.5 model: its vocabulary, and the chat template of
    /// the GGUF unless `chatTemplate` names another.
    ///
    /// - Parameters:
    ///   - loadedContext: The context the model loads at.
    ///   - chatTemplate: The chat template the model renders with, or `nil`
    ///     for the chat template of the GGUF.
    /// - Returns: The model.
    /// - Throws: Whatever the model load throws.
    fileprivate static func makeModel(
        contextSize loadedContext: Int = contextSize, chatTemplate: String? = nil
    ) throws -> LlamaLanguageModel {
        try LlamaLanguageModel(
            gguf: LlamaCppTestFixtures.vocabURL(named: "qwen35"),
            options: LlamaLanguageModel.Options(contextSize: loadedContext),
            chatTemplate: chatTemplate)
    }

    @Test("the window of a GGUF container is the context the model loaded at")
    func windowIsTheLoadedContext() async throws {
        let container = try LiveLLMContainer.make(wrapping: Self.makeModel(), ref: Self.ref)

        #expect(container.contextWindow == Self.contextSize)
        #expect(container.ref == Self.ref)
        #expect(container.mlxModel == nil)
    }

    @Test("a GGUF container counts and cuts text with the vocabulary of the model")
    func tokenCounterReadsTheVocabulary() async throws {
        let model = try Self.makeModel()
        let container = try LiveLLMContainer.make(wrapping: model, ref: Self.ref)
        let tokenizer = try model.tokenizer()
        let text = "The quick brown fox jumps over the lazy dog."

        #expect(container.tokenCounter.count(text) == (try tokenizer.tokens(text).count))
        #expect(container.tokenCounter.count(text) > 1)
        #expect(container.tokenCounter.prefix(of: text, tokens: 0) == "")
        #expect(container.tokenCounter.prefix(of: text, tokens: 10_000) == text)
        #expect(container.tokenCounter.prefix(of: text, tokens: 2).count < text.count)
    }

    @Test("the shared TokenizerTokenCounter cuts text over a LlamaTokenizer as the tokenizer cuts it")
    func tokenizerTokenCounterCutsAsTheLlamaTokenizer() throws {
        let tokenizer = try Self.makeModel().tokenizer()
        let counter = TokenizerTokenCounter(tokenizer: tokenizer)

        #expect(
            counter.prefix(of: Self.multiByteText, tokens: Self.cutTokens)
                == (try tokenizer.prefix(of: Self.multiByteText, tokens: Self.cutTokens)))
    }

    @Test("a GGUF container counts a transcript through the chat template of the model")
    func transcriptCountRendersTheTemplate() async throws {
        let model = try Self.makeModel()
        let container = try LiveLLMContainer.make(wrapping: model, ref: Self.ref)
        let transcript = Transcript(entries: [
            .instructions(Transcript.Instructions(segments: [.text(.init(content: "Be brief."))], toolDefinitions: [])),
            .prompt(Transcript.Prompt(segments: [.text(.init(content: "Hello"))])),
        ])

        let count = try container.tokenCounter.count(transcript)

        #expect(count == (try model.tokenizer().renderedTokenCount(of: transcript)))
        #expect(count > container.tokenCounter.count("Be brief.Hello"))
    }

    /// The fixture chat template of Qwen 3.5, which supports thinking. The
    /// chat template of the vocab-only Qwen 3.5 GGUF has no thinking.
    private static let thinkingTemplateName = "Qwen3.5-4B"

    /// The vocab-only Qwen 3.5 model over ``thinkingTemplateName``: a model
    /// whose chat template supports thinking.
    private static func makeThinkingModel() throws -> LlamaLanguageModel {
        try makeModel(
            chatTemplate: String(contentsOf: LlamaCppTestFixtures.templateURL(named: thinkingTemplateName), encoding: .utf8))
    }

    /// The reasoning control of `model`, read as the live backend reads it: a
    /// cast of the raw model to ``ReasoningControlReporting``. A model that
    /// does not conform reports ``ReasoningControl/none``.
    private static func reasoningControl(of model: any FoundationModels.LanguageModel) async throws
        -> ReasoningControl
    {
        guard let reporting = model as? any ReasoningControlReporting else { return .none }
        return try await reporting.reasoningControl()
    }

    @Test("a GGUF model whose chat template supports thinking is switchable")
    func thinkingGGUFModelIsSwitchable() async throws {
        #expect(try await Self.reasoningControl(of: Self.makeThinkingModel()) == .switchable)
    }

    @Test("a GGUF model with no thinking in its chat template has no reasoning control")
    func plainGGUFModelHasNoReasoningControl() async throws {
        #expect(try await Self.reasoningControl(of: Self.makeModel()) == .none)
    }

    @Test("the first pass of a reasoning-off call on a thinking GGUF container states the no_think level")
    func reasoningOffCallOnAGGUFContainerStatesTheNoThinkLevel() async throws {
        let container = try LiveLLMContainer.make(wrapping: Self.makeThinkingModel(), ref: Self.ref)
        let backend = try #require(container.makeSession(instructions: nil) as? MLXFoundationModelsSessionBackend)

        let level = try await ReasoningOffRequest.$isRequested.withValue(true) {
            try await backend.firstPassReasoningLevel()
        }

        #expect(level == ReasoningOffRequest.reasoningLevel)
    }

    @Test("the live loader wraps the LlamaLanguageModel its model loader gives, and makes a session over it")
    func liveLoaderWrapsAGGUFModel() async throws {
        let model = try Self.makeModel()
        let loader = LiveModelLoader(reporting: { _ in }, modelLoader: GGUFModelPoolLoader(model: model))

        let loaded = try await loader.loadLLM(ref: Self.ref, slot: .standard, context: Self.contextSize, reporting: { _ in })

        let container = try #require(loaded as? LiveLLMContainer)
        #expect(container.model is LlamaLanguageModel)
        #expect(container.contextWindow == Self.contextSize)
        _ = container.makeSession(instructions: "Be brief.")
    }

    /// The context a resolve decides in the context tests. It is neither the
    /// llama.cpp default nor ``contextSize``, so the window tells that the
    /// model loaded at the context of the resolve.
    private static let resolvedContext = 16_384

    /// The weights the private pool counts for the GGUF model.
    private static let footprintBytes: Int64 = 1_000

    @Test("the live loader loads a GGUF model at the resolved context, and its container reports that window")
    func liveLoaderLoadsAGGUFModelAtTheResolvedContext() async throws {
        let loader = LiveModelLoader(reporting: { _ in }, modelLoader: ContextGGUFPoolLoader())

        let loaded = try await loader.loadLLM(
            ref: Self.ref, slot: .standard, context: Self.resolvedContext, reporting: { _ in })

        #expect(try #require(loaded as? LiveLLMContainer).contextWindow == Self.resolvedContext)
    }

    @Test("a router acquire of a GGUF model gives a container whose window is the resolved context")
    func routerAcquireOfAGGUFModelReportsTheResolvedContext() async throws {
        let loader = LiveModelLoader(reporting: { _ in }, modelLoader: ContextGGUFPoolLoader())
        let slotLoader = SlotPoolLoader(
            loader: loader, slot: .standard, context: Self.resolvedContext, reporting: { _ in })

        let hold = try await slotLoader.acquireHold(
            of: Self.ref, in: FoundationModelsExtras.ModelPool(), footprintBytes: Self.footprintBytes,
            sessionBytes: 0)

        let container = try await hold.generationContainer()

        #expect(try #require(container as? LiveLLMContainer).contextWindow == Self.resolvedContext)
    }
}

/// A pool loader that loads a GGUF model at the context of each key, and keys
/// each model at the context of the request, as the Extras
/// `LlamaCppModelLoader` does. A key with no context loads at the default of
/// llama.cpp. The model is the vocab-only Qwen 3.5 fixture.
private struct ContextGGUFPoolLoader: PooledModelLoader {
    func poolKey(for key: ModelPoolKey) async throws -> ModelPoolKey { key }

    func load(_ key: ModelPoolKey) async throws -> any Sendable {
        try LiveLLMContainerGGUFTests.makeModel(
            contextSize: key.contextSize ?? LlamaLanguageModel.Options().contextSize)
    }

    func evict(_ container: any Sendable) async {}
}

/// A pool loader that gives one `LlamaLanguageModel` for each key, as the
/// Extras `LlamaCppModelLoader` does for a GGUF reference.
private struct GGUFModelPoolLoader: PooledModelLoader {
    /// The model each load gives.
    let model: LlamaLanguageModel

    func load(_ key: ModelPoolKey) async throws -> any Sendable { model }

    func evict(_ container: any Sendable) async {}
}
