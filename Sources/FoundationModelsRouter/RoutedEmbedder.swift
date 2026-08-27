import Tracing

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
    /// Every call opens one OpenTelemetry span named
    /// `FoundationModelsRouter.embed`, of kind `client`, through
    /// ``RoutedModel/tracer`` — or through `InstrumentationSystem.tracer` when
    /// that is `nil`. Unbootstrapped, that resolves to a no-op tracer, so an
    /// application that does not trace pays nothing. `withSpan` records a
    /// thrown error on the span and rethrows it.
    ///
    /// The span carries four attributes, and their names are stable API:
    ///
    /// | Attribute | Value |
    /// |---|---|
    /// | `router.id` | The resolving router's recording root id. |
    /// | `model.ref` | The chosen model reference, in canonical string form. |
    /// | `embedding.input_count` | How many strings this call embeds. |
    /// | `embedding.dimension` | The length of each vector produced. |
    ///
    /// No input text and no vector ever reaches the span. A span leaves the
    /// process through whatever backend the host application bootstrapped, so
    /// the payload must stay free of the caller's own content.
    ///
    /// - Parameter texts: The strings to embed.
    /// - Returns: One ``dimension``-length vector per input, in order.
    /// - Throws: Any error thrown by the embedder container.
    public func embed(texts: [String]) async throws -> [[Float]] {
        try await (tracer ?? InstrumentationSystem.tracer)
            .withSpan("FoundationModelsRouter.embed", ofKind: .client) { span in
                span.attributes["router.id"] = routerId.description
                span.attributes["model.ref"] = chosen.stringValue
                span.attributes["embedding.input_count"] = texts.count
                span.attributes["embedding.dimension"] = dimension
                return try await container.embed(texts: texts)
            }
    }
}
