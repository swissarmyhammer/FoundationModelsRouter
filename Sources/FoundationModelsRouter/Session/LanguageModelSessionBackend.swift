import Foundation

/// A live session object vended by a ``LoadedLLMContainer`` factory.
///
/// Where a ``LoadedLLMContainer`` used to expose stateless, one-shot generation
/// methods directly, it now only *manufactures* backends through
/// ``LoadedLLMContainer/makeSession(instructions:)``; every generation call runs
/// through the backend it returns instead. This is the seam
/// ``RoutedSessionActor`` drives: a backend is born holding this session's
/// system instructions and — once a real conversation-preserving conformer
/// lands — accumulates conversation state (the transcript) across calls, so a
/// second ``respond(to:maxTokens:)`` sees the first turn's content the way a
/// real multi-turn chat does. ``makeFork()`` is the seam a
/// ``RoutedSession/fork(workingDirectory:)`` calls to produce a child backend
/// that begins from this session's accumulated transcript and then diverges
/// independently.
///
/// It is class-bound and `Sendable` so a session (an actor) can hold one across
/// isolation boundaries.
public protocol LanguageModelSessionBackend: AnyObject, Sendable {
    /// Generates a complete text response to a prompt.
    ///
    /// - Parameters:
    ///   - prompt: The prompt to respond to.
    ///   - maxTokens: The maximum number of tokens to generate, or `nil` to use
    ///     the backend's own default ceiling.
    /// - Returns: The model's complete text response.
    /// - Throws: If the generation fails.
    func respond(to prompt: String, maxTokens: Int?) async throws -> String

    /// Streams a text response to a prompt as it is produced.
    ///
    /// - Parameters:
    ///   - prompt: The prompt to respond to.
    ///   - maxTokens: The maximum number of tokens to generate, or `nil` to use
    ///     the backend's own default ceiling.
    /// - Returns: A stream of response fragments, finishing when generation
    ///   completes or throwing if it fails.
    func streamResponse(to prompt: String, maxTokens: Int?) -> AsyncThrowingStream<String, Error>

    /// Generates a complete, grammar-constrained text response.
    ///
    /// Guided output is whole-chunk: there is no constrained streaming variant.
    ///
    /// - Parameters:
    ///   - prompt: The prompt to respond to.
    ///   - grammar: The grammar constraining the output.
    ///   - maxTokens: The maximum number of tokens to generate, or `nil` to use
    ///     the backend's own default ceiling.
    /// - Returns: The constrained text response.
    /// - Throws: ``GuidedRequestError`` for an invalid grammar, or if the
    ///   generation fails.
    func respond(
        to prompt: String,
        following grammar: Grammar,
        maxTokens: Int?
    ) async throws -> String

    /// Produces a new backend seeded from this session's accumulated transcript.
    ///
    /// The returned backend begins with this session's conversation history and
    /// then diverges independently — the seam ``RoutedSession/fork(workingDirectory:)``
    /// runs through so a forked child sees its parent's turns so far without the
    /// two sharing any further state.
    ///
    /// - Returns: A new, independent backend seeded from this session's history.
    func makeFork() -> any LanguageModelSessionBackend
}
