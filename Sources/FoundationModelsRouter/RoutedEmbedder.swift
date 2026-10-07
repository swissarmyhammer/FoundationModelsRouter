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
    /// Embeds each input string into one vector.
    ///
    /// The handle gives no vector length before the first call: the embedding
    /// model can load at its first call, and only then knows the length. Read
    /// the length from the `count` of a vector that this call returns.
    ///
    /// The computation runs through the resident embedder container and writes
    /// nothing to the transcript. A failure in the embedding computation
    /// propagates to the caller.
    ///
    /// Every call opens one OpenTelemetry span named
    /// ``RouterTelemetry/SpanName/embed``, of kind `client`, through the tracer
    /// ``RouterTelemetry/tracer(explicit:)`` resolves from ``RoutedModel/tracer``.
    /// Unbootstrapped, that resolves to a no-op tracer, so an application that
    /// does not trace pays nothing. When the container throws, the span gets
    /// the error status and the type of the error, never its description
    /// (``RouterTelemetry/withSpan(_:ofKind:tracer:isolation:_:)``), and the
    /// error is thrown again.
    ///
    /// The span carries up to four attributes, and their names are stable API:
    ///
    /// | Attribute | Value |
    /// |---|---|
    /// | `router.id` | The resolving router's recording root id. |
    /// | `model.ref` | The chosen model reference, in canonical string form. |
    /// | `embedding.input_count` | How many strings this call embeds. |
    /// | `embedding.dimension` | The length of the first vector produced. |
    ///
    /// The span gets `embedding.dimension` after the call returns. A call that
    /// throws, or that returns no vector, sets no `embedding.dimension`.
    ///
    /// No input text and no vector ever reaches the span. A span leaves the
    /// process through whatever backend the host application bootstrapped, so
    /// the payload must stay free of the caller's own content.
    ///
    /// - Parameter texts: The strings to embed.
    /// - Returns: One vector per input, in order.
    /// - Throws: Any error thrown by the embedder container.
    public func embed(texts: [String]) async throws -> [[Float]] {
        try await RouterTelemetry
            .withSpan(RouterTelemetry.SpanName.embed, ofKind: .client, tracer: tracer) { span in
                span.attributes[RouterTelemetry.AttributeKey.routerId] = routerId.description
                span.attributes[RouterTelemetry.AttributeKey.modelRef] = chosen.stringValue
                span.attributes[RouterTelemetry.AttributeKey.embeddingInputCount] = texts.count
                let vectors = try await container.embed(texts: texts)
                if let dimension = vectors.first?.count {
                    span.attributes[RouterTelemetry.AttributeKey.embeddingDimension] = dimension
                }
                return vectors
            }
    }
}
