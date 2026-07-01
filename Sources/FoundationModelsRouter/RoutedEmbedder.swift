import Foundation

/// A failure producing embeddings from a resident model.
public enum EmbeddingError: Error, Equatable {
    /// The live ``EmbedderModelContainer`` embedding pipeline is not wired yet —
    /// real vectors land in the gated integration suite (milestone 7). The unit
    /// suite exercises the surface through a stub embedder instead.
    case notWiredForLiveInference
}

/// The recorded embedding access surface on the embedding handle.
///
/// ``RoutedEmbedder`` is `RoutedModel<any LoadedEmbeddingContainer>`, so the
/// embedding-only API arrives here as a container-constrained extension — it is
/// invisible on the generation handle ``RoutedLLM``. The computation runs
/// through the loaded container (a stub in unit tests, real `MLXEmbedders` in
/// the live container), and every call records one ``TranscriptEvent/Kind/embedding``
/// event through the recorder the handle was born holding.
extension RoutedModel where Container == any LoadedEmbeddingContainer {
    /// The length of every embedding vector this model produces.
    public var dimension: Int { container.dimension }

    /// Embeds each input string into a ``dimension``-length vector, recording the
    /// call to the transcript.
    ///
    /// The computation runs through the resident embedder container. On success
    /// exactly one ``TranscriptEvent/Kind/embedding`` event is appended to the
    /// recorder — stamped with this handle's ``RoutedModel/routerId``, the
    /// `.embedding` slot, the chosen model, and the measured duration. Recording
    /// is best-effort: the recorder swallows any sink failure (see
    /// ``TranscriptRecorder``), so a failed write is logged, never surfaced, and
    /// `embed` still returns its vectors. A failure in the embedding computation
    /// itself propagates and records nothing.
    ///
    /// - Parameter texts: The strings to embed.
    /// - Returns: One ``dimension``-length vector per input, in order.
    /// - Throws: Any error thrown by the embedder container.
    public func embed(_ texts: [String]) async throws -> [[Float]] {
        let started = Date()
        let vectors = try await container.embed(texts)
        let ms = Int(Date().timeIntervalSince(started) * 1_000)

        await recorder.append(
            TranscriptEvent.Partial(
                routerId: routerId,
                sessionId: .generate(),
                slot: .embedding,
                model: chosen,
                kind: .embedding,
                // The embedded inputs are the event's body, subject to the same
                // recording-level and redaction gating as prompt/response text.
                text: texts.joined(separator: "\n"),
                ms: ms
            ),
            to: nil
        )

        return vectors
    }
}
