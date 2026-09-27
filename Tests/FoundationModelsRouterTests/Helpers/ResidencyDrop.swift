import FoundationModelsExtras

@testable import FoundationModelsRouter

/// Dropping a test's own reference to a resolved profile, which is how a test
/// ends a residency.
extension Optional where Wrapped == LanguageModelProfile {
    /// Clears this reference to the resolved profile.
    ///
    /// Pooled residency is owned by ARC. Each handle of a profile keeps the
    /// ``ModelHold``s of the profile, and the last release of a hold starts
    /// the eviction of its model. A test therefore ends a residency by
    /// clearing the references it holds, and then waits for the eviction with
    /// ``FoundationModelsExtras/ModelPool/settle(until:)``, rather than by
    /// calling a cleanup method.
    ///
    /// The clearing goes through this method, and not through a bare `= nil`,
    /// because a local variable that is only ever written draws a compiler
    /// warning. Application code needs none of this: there the reference
    /// simply goes out of scope.
    mutating func dropReference() {
        self = nil
    }
}

extension ModelPool {
    /// Waits until the footprint of the pool satisfies `condition`, and until
    /// the eviction job that made it so has ended.
    ///
    /// The last release of a hold removes the hold at once, but the pool
    /// submits the eviction of the model from a detached task. So the
    /// eviction is not done when the drop returns. The pool publishes a
    /// footprint after each eviction, when the loader has evicted the model.
    /// The first footprint of the stream is the current one, and it can show
    /// a model that a running eviction job removed before its loader ended.
    /// Thus one empty admission job follows: it starts only after that
    /// eviction job ends.
    ///
    /// - Parameter condition: The footprint to wait for, for example no
    ///   resident model.
    /// - Throws: `CancellationError` when the test task is cancelled.
    func settle(until condition: @Sendable (ModelPoolFootprint) -> Bool) async throws {
        for await footprint in footprints where condition(footprint) { break }
        try await admit { _ in }
    }
}
