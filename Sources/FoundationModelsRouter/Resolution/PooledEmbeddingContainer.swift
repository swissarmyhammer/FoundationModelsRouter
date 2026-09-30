import FoundationModelsExtras

/// The embedding container of a ``RoutedEmbedder``: an Extras
/// ``PooledEmbedder`` over the hold of the embedding slot.
///
/// The first loader of a key gives the container of all holds of that key, so
/// the container of the hold can come from a loader that is not the router's
/// (the registry, the multitool). The router therefore uses it through the
/// Extras embed protocol only, never by a cast to ``LoadedEmbeddingContainer``.
/// Each ``embed(texts:)`` call is one job in the work queue of the model.
struct PooledEmbeddingContainer: LoadedEmbeddingContainer {
    /// The embedder over the hold.
    private let embedder: PooledEmbedder

    /// The length of each vector: the dimension of the container of the hold.
    /// ``PooledEmbedder`` gives no dimension, so the init reads it one time
    /// from the container.
    let dimension: Int

    /// Makes the container of an embedding hold.
    ///
    /// - Parameter hold: A hold of an embedding model.
    /// - Throws: ``PooledEmbedderError/notAnEmbedding(key:containerType:)``
    ///   when the container of `hold` does not conform to ``PooledEmbedding``.
    init(hold: ModelHold) throws {
        guard let embedding = hold.container as? any PooledEmbedding else {
            throw PooledEmbedderError.notAnEmbedding(
                key: hold.key, containerType: String(describing: type(of: hold.container)))
        }
        embedder = try PooledEmbedder(hold: hold)
        dimension = embedding.dimension
    }

    /// Gives one vector for each text, in the order of `texts`.
    ///
    /// - Parameter texts: The texts.
    /// - Returns: One vector for each text.
    /// - Throws: What the work queue or the model throws.
    func embed(texts: [String]) async throws -> [[Float]] {
        try await embedder.embed(texts: texts)
    }
}
