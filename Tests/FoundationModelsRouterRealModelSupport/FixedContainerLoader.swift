import FoundationModelsExtras

/// A loader of the Extras model pool that gives one fixed container for each
/// key, and evicts nothing.
///
/// ``RealModelHarness`` gives it to the pool of the decision model of a
/// harness profile, so that the decision model reads the logits of the one
/// generation container that the caller loaded. The unit tests put a stub
/// container in a pool with it.
public struct FixedContainerLoader: PooledModelLoader {
    /// The container that each load gives.
    public let container: any Sendable

    /// Makes a loader that gives `container` for each key.
    ///
    /// - Parameter container: The container that each load gives.
    public init(container: any Sendable) {
        self.container = container
    }

    /// Gives ``container``.
    ///
    /// - Parameter key: The key to load. The loader ignores it.
    /// - Returns: ``container``.
    public func load(_ key: ModelPoolKey) async throws -> any Sendable {
        container
    }

    /// Evicts nothing: the caller owns the container.
    ///
    /// - Parameter container: The container to evict.
    public func evict(_ container: any Sendable) async {}
}
