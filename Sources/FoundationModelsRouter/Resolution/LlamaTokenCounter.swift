import Foundation
import FoundationModels
import FoundationModelsLlamaCpp

/// The live ``TokenCounter`` of a GGUF model: it counts with the vocabulary of
/// the loaded `LlamaLanguageModel` (its `LlamaTokenizer`).
///
/// A transcript is rendered through the chat template of the model, the same
/// way the llama.cpp generation path renders it before a call. Each call reads
/// only the vocabulary, so a count runs from any thread while the model
/// generates.
struct LlamaTokenCounter: TokenCounter {
    /// The tokenizer of the loaded model.
    private let tokenizer: LlamaTokenizer

    /// Creates a counter over `tokenizer`.
    ///
    /// - Parameter tokenizer: The tokenizer of the loaded model.
    init(tokenizer: LlamaTokenizer) {
        self.tokenizer = tokenizer
    }

    /// The number of tokens `tokenizer` encodes `text` to, with no special
    /// tokens added. The tokenizer throws only for a text of more than
    /// `Int32.max` bytes, which counts as zero.
    func count(_ text: String) -> Int {
        (try? tokenizer.tokens(text).count) ?? 0
    }

    /// The number of tokens the chat template renders `transcript` to.
    ///
    /// - Throws: What the render of the chat template throws.
    func count(_ transcript: Transcript) throws -> Int {
        try tokenizer.renderedTokenCount(of: transcript)
    }

    /// The first `limit` tokens of `text`, decoded back to text. The
    /// tokenizer throws only for a text of more than `Int32.max` bytes, which
    /// keeps nothing.
    func prefix(of text: String, tokens limit: Int) -> String {
        (try? tokenizer.prefix(of: text, tokens: limit)) ?? ""
    }
}
