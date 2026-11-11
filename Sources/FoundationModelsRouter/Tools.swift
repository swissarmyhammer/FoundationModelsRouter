import Foundation
import FoundationModelsDecision

/// Example tools that take an already-resolved slot handle in their initializer.
///
/// Pass `profile.flash`, `profile.standard`, `profile.embedding`, or
/// `profile.decision` in. Tools that share one handle share one resident model.

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

    /// Embeds each input string with one recorded call.
    ///
    /// - Parameter texts: The strings to embed.
    /// - Returns: One vector per input, in order.
    /// - Throws: Any error thrown by the embedder.
    func embed(texts: [String]) async throws -> [[Float]] {
        try await model.embed(texts: texts)
    }
}

/// A tool that answers one yes-or-no question through an injected
/// ``RoutedDecider``.
///
/// Each ``probability(of:about:)`` makes a fresh decision session. A decision
/// writes nothing to the transcript.
struct DecideTool: Sendable {
    /// The injected decision handle.
    let model: RoutedDecider

    /// Creates a decider over a resolved decision handle.
    ///
    /// - Parameter model: The ``RoutedDecider`` to decide through.
    init(model: RoutedDecider) {
        self.model = model
    }

    /// Gives the probability of "yes" to one yes-or-no question about a state.
    ///
    /// - Parameters:
    ///   - question: The yes-or-no question.
    ///   - state: The state that the question is about.
    /// - Returns: The probability of "yes", from 0 to 1.
    /// - Throws: Any error thrown by the decision model.
    func probability(of question: String, about state: DecisionState) async throws -> Double {
        try await model.makeSession(state: state).probability(of: question)
    }
}
