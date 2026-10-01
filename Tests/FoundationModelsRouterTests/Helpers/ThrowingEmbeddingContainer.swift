@testable import FoundationModelsRouter

/// A ``LoadedEmbeddingContainer`` stub whose every embed call throws one
/// given error, so a test can read what the embed span records for a failure.
///
/// ``HandBuiltProfileFixtures/makeProfile(definitionName:chosen:container:router:)``
/// always wraps a ``StubEmbeddingContainer``, which cannot fail. A test that
/// needs a failure builds its ``RoutedEmbedder`` over this container with
/// ``HandBuiltProfileFixtures/makeEmbedder(chosen:container:routerId:recorder:tracer:)``.
struct ThrowingEmbeddingContainer: LoadedEmbeddingContainer {
    /// The length the stub reports. The stub never makes a vector.
    let dimension: Int

    /// The error that each ``embed(texts:)`` call throws.
    let failure: any Error

    /// Throws ``failure`` and embeds nothing.
    ///
    /// - Parameter texts: The strings the caller asked to embed. The stub
    ///   ignores them.
    /// - Returns: Never returns.
    /// - Throws: ``failure``, always.
    func embed(texts: [String]) async throws -> [[Float]] {
        throw failure
    }
}
