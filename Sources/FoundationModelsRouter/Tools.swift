import Foundation

/// # The shared-handle constructor pattern
///
/// This file holds small, real example tools that demonstrate the router's core
/// "built early and shared" goal: a ``Router`` resolves one
/// ``LanguageModelProfile`` — loading each slot's model **once** — and every
/// tool that needs generation or embedding takes the already-resolved handle
/// (``RoutedLLM`` / ``RoutedEmbedder``) in its constructor.
///
/// Pass the slot handle into a tool's initializer; do **not** re-resolve a
/// profile per tool. Because a handle is a reference to its one resident model,
/// many tools built from the same `profile.flash` (or `profile.standard` /
/// `profile.embedding`) all point at the identical loaded container — the model
/// is loaded once at resolve and reused, never reloaded when a tool is
/// constructed. A tool holds its handle and drives it (``RoutedLLM`` vends a
/// session with `makeSession`/`respond`; ``RoutedEmbedder`` embeds with
/// `embed`), so every call still flows through the recorder-bracketed
/// chokepoint the handle was born holding.
///
/// ```swift
/// let profile = try await router.resolve(profile: definition, reporting: progress)
/// // Both tools share profile.flash's one resident model — no second load.
/// let summarizer = SummarizeTool(model: profile.flash)
/// let titler = SummarizeTool(model: profile.flash)
/// let embedder = EmbedTool(model: profile.embedding)
/// ```

/// A tool that condenses text through an injected generation handle.
///
/// It holds the ``RoutedLLM`` a resolved ``LanguageModelProfile`` vends — pass
/// the handle in; do not re-resolve. Each ``summarize(_:)`` vends a fresh
/// ``RoutedSession`` over the shared resident model and runs one recorded
/// generation through it, so the call flows through the handle's chokepoint and
/// is stamped with its slot's provenance.
public struct SummarizeTool: Sendable {
    /// The injected generation handle, shared with any other tool built from the
    /// same profile slot.
    public let model: RoutedLLM

    /// The system instructions each vended session is given.
    private let instructions: String

    /// Creates a summarizer over a resolved generation handle.
    ///
    /// - Parameters:
    ///   - model: The ``RoutedLLM`` to summarize through; typically
    ///     `profile.standard` or `profile.flash`. Reused, never re-resolved.
    ///   - instructions: The system instructions for each summarize session.
    public init(
        model: RoutedLLM,
        instructions: String = "Summarize the following text concisely."
    ) {
        self.model = model
        self.instructions = instructions
    }

    /// Summarizes `text` by running one recorded generation through the shared
    /// resident model.
    ///
    /// - Parameter text: The text to condense.
    /// - Returns: The model's summary.
    /// - Throws: Any error thrown by the underlying generation.
    public func summarize(text: String) async throws -> String {
        let session = model.makeSession(instructions: instructions)
        return try await session.respond(to: text)
    }
}

/// A tool that embeds text through an injected embedding handle.
///
/// It holds the ``RoutedEmbedder`` a resolved ``LanguageModelProfile`` vends —
/// pass the handle in; do not re-resolve. Each ``embed(_:)`` runs one recorded
/// embedding through the shared resident model, stamped with the embedding
/// slot's provenance.
public struct EmbedTool: Sendable {
    /// The injected embedding handle, shared with any other tool built from the
    /// same profile's embedding slot.
    public let model: RoutedEmbedder

    /// Creates an embedder over a resolved embedding handle.
    ///
    /// - Parameter model: The ``RoutedEmbedder`` to embed through; typically
    ///   `profile.embedding`. Reused, never re-resolved.
    public init(model: RoutedEmbedder) {
        self.model = model
    }

    /// The length of every vector this tool produces.
    public var dimension: Int { model.dimension }

    /// Embeds each input string into a ``dimension``-length vector, recording the
    /// call through the shared resident model.
    ///
    /// - Parameter texts: The strings to embed.
    /// - Returns: One ``dimension``-length vector per input, in order.
    /// - Throws: Any error thrown by the underlying embedder.
    public func embed(texts: [String]) async throws -> [[Float]] {
        try await model.embed(texts: texts)
    }
}
