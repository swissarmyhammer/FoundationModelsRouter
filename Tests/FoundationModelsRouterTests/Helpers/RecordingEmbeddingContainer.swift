import Foundation

@testable import FoundationModelsRouter

/// A ``LoadedEmbeddingContainer`` stub that records the texts it receives, so
/// a test can read exactly what the router sent to the container.
///
/// Every call returns one short vector for each text. The lock makes the
/// recording safe when the router calls the container from other tasks.
final class RecordingEmbeddingContainer: LoadedEmbeddingContainer, @unchecked Sendable {
    /// The lock that guards `calls`.
    private let lock = NSLock()

    /// The backing store of ``received``.
    private var calls: [[String]] = []

    /// The texts of each ``embed(texts:)`` call, in call order.
    var received: [[String]] {
        lock.withLock { calls }
    }

    /// Records `texts` and returns one vector for each of them.
    ///
    /// - Parameter texts: The strings the router sent to the container.
    /// - Returns: One two-value vector per text.
    func embed(texts: [String]) async throws -> [[Float]] {
        lock.withLock { calls.append(texts) }
        return texts.map { _ in [0.0, 1.0] }
    }
}
