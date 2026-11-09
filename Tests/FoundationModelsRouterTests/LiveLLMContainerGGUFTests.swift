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

    /// A vocab-only Qwen 3.5 model: its vocabulary and its chat template.
    private static func makeModel() throws -> LlamaLanguageModel {
        try LlamaLanguageModel(
            gguf: LlamaCppTestFixtures.vocabURL(named: "qwen35"),
            options: LlamaLanguageModel.Options(contextSize: contextSize))
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
}

/// A pool loader that gives one `LlamaLanguageModel` for each key, as the
/// Extras `LlamaCppModelLoader` does for a GGUF reference.
private struct GGUFModelPoolLoader: PooledModelLoader {
    /// The model each load gives.
    let model: LlamaLanguageModel

    func load(_ key: ModelPoolKey) async throws -> any Sendable { model }

    func evict(_ container: any Sendable) async {}
}
