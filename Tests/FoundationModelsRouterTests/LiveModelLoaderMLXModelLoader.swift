import FoundationModelsExtras
import Testing

@testable import FoundationModelsRouter

extension LiveModelLoader {
    /// The Extras model loader that the public init of this live loader
    /// made. The suites that prove what the public init gives to the Extras
    /// loader — the cache folder, the token provider — read it here.
    ///
    /// - Returns: Its `MLXModelLoader`.
    /// - Throws: When the model loader is not an `MLXModelLoader`, which
    ///   means that a test init made the live loader.
    func requireMLXModelLoader() throws -> MLXModelLoader {
        try #require(modelLoader as? MLXModelLoader)
    }
}
