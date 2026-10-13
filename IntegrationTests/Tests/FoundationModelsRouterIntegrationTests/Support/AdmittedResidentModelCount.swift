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
    /// Use this read only when the test itself releases the last hold. A
    /// session can keep its profile, and thus the holds of the profile, after
    /// its `respond` returns: a task of the session that retains the session
    /// can end after that return. For that case, use
    /// ``awaitNoResidentModel()``.
    ///
    /// - Throws: `CancellationError` when the test is cancelled.
    var admittedResidentModelCount: Int {
        get async throws { try await admit { $0.footprint.resident.count } }
    }

    /// Waits for the event that the pool has no resident model.
    ///
    /// The wait reads ``ModelPool/footprints``: the current footprint first,
    /// then the footprint after each change. Each release of a hold and the
    /// end of each evict call publish a new footprint. A model stays in the
    /// footprint until the evict call of its loader returns. Thus the wait
    /// ends after the last hold is released and each eviction ended, in any
    /// order of the tasks that keep a hold. The wait uses no clock.
    ///
    /// - Returns: `true` when the pool has no resident model, and `false`
    ///   when the calling task was cancelled before that.
    func awaitNoResidentModel() async -> Bool {
        for await footprint in footprints where footprint.resident.isEmpty {
            return true
        }
        return false
    }
}
