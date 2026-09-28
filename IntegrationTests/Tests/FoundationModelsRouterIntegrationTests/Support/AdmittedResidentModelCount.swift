import FoundationModelsRouter

extension ModelPool {
    /// The resident model count that the next admission job of the pool
    /// measures. A resolve makes the same measurement.
    ///
    /// The last release of a hold puts the eviction job of its model in the
    /// admission queue in the same step. Thus this admission job runs after
    /// the eviction of each release that came before the read, and the count
    /// does not include those models.
    ///
    /// - Throws: `CancellationError` when the test is cancelled.
    var admittedResidentModelCount: Int {
        get async throws { try await admit { $0.footprint.resident.count } }
    }
}
