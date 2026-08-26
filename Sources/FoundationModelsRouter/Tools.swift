import Foundation

/// Example tools that take an already-resolved slot handle in their initializer.
///
/// Pass `profile.flash`, `profile.standard`, or `profile.embedding` in. Tools
/// that share one handle share one resident model.

/// A tool that condenses text through an injected ``RoutedLLM``.
///
/// Each ``summarize(text:)`` runs one recorded generation in a fresh session.
struct SummarizeTool: Sendable {
    /// The injected generation handle.
    let model: RoutedLLM

    /// The system instructions each vended session is given.
    private let instructions: String

    /// Creates a summarizer over a resolved generation handle.
    ///
    /// - Parameters:
    ///   - model: The ``RoutedLLM`` to summarize through.
    ///   - instructions: The system instructions for each summarize session.
    init(
        model: RoutedLLM,
        instructions: String = "Summarize the following text concisely."
    ) {
        self.model = model
        self.instructions = instructions
    }

    /// Summarizes `text` with one recorded generation.
    ///
    /// - Parameter text: The text to condense.
    /// - Returns: The model's summary.
    /// - Throws: Any error thrown by the generation.
    func summarize(text: String) async throws -> String {
        let session = model.makeSession(instructions: instructions)
        return try await session.respond(to: text)
    }
}

/// A tool that embeds text through an injected ``RoutedEmbedder``.
struct EmbedTool: Sendable {
    /// The injected embedding handle.
    let model: RoutedEmbedder

    /// Creates an embedder over a resolved embedding handle.
    ///
    /// - Parameter model: The ``RoutedEmbedder`` to embed through.
    init(model: RoutedEmbedder) {
        self.model = model
    }

    /// The length of every vector this tool produces.
    var dimension: Int { model.dimension }

    /// Embeds each input string with one recorded call.
    ///
    /// - Parameter texts: The strings to embed.
    /// - Returns: One ``dimension``-length vector per input, in order.
    /// - Throws: Any error thrown by the embedder.
    func embed(texts: [String]) async throws -> [[Float]] {
        try await model.embed(texts: texts)
    }
}
