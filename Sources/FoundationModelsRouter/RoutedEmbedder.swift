/// The embedding access surface on the embedding handle.
///
/// ``RoutedEmbedder`` is `RoutedModel<any LoadedEmbeddingContainer>`, so the
/// embedding-only API arrives here as a container-constrained extension — it is
/// invisible on the generation handle ``RoutedLLM``. The computation runs
/// through the loaded container (a stub in unit tests, real `MLXEmbedders` in
/// the live container), and no call writes to the transcript: an embed is no
/// part of any session's conversation.
extension RoutedModel where Container == any LoadedEmbeddingContainer {
    /// The length of every embedding vector this model produces.
    public var dimension: Int { container.dimension }

    /// Embeds each input string into a ``dimension``-length vector.
    ///
    /// The computation runs through the resident embedder container and writes
    /// nothing to the transcript. A failure in the embedding computation
    /// propagates to the caller.
    ///
    /// - Parameter texts: The strings to embed.
    /// - Returns: One ``dimension``-length vector per input, in order.
    /// - Throws: Any error thrown by the embedder container.
    public func embed(texts: [String]) async throws -> [[Float]] {
        try await container.embed(texts: texts)
    }
}
