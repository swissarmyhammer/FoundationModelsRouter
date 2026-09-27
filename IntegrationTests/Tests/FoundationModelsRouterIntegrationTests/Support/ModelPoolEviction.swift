import FoundationModelsRouter

extension ModelPool {
    /// The resident model count of this pool after the pool evicts its last
    /// model.
    ///
    /// The drop of the last hold of a model does not evict the model at once.
    /// The pool submits the eviction job from a detached task, so the eviction
    /// is not done when the drop returns. This function reads
    /// ``ModelPool/footprints`` until a footprint has no resident model. Then
    /// it runs an empty admission job as a barrier: the barrier starts only
    /// after each eviction job that the pool queued before it ends.
    ///
    /// - Returns: The resident model count.
    /// - Throws: `CancellationError` when the test is cancelled.
    func residentModelCountOnceEvicted() async throws -> Int {
        for await footprint in footprints where footprint.resident.isEmpty {
            break
        }
        try Task.checkCancellation()
        try await admit { _ in }
        return residentModelCount
    }
}
