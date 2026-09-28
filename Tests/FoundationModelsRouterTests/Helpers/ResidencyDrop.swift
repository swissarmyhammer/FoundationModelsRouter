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
    /// clearing the references it holds, rather than by calling a cleanup
    /// method, and then reads ``FoundationModelsExtras/ModelPool/admittedFootprint``.
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
    /// The footprint that the next admission job of the pool measures. A
    /// resolve makes the same measurement.
    ///
    /// The last release of a hold puts the eviction job of its model in the
    /// admission queue in the same step. Thus this admission job runs after
    /// the eviction of each release that came before the read, and the
    /// footprint shows those models as gone.
    ///
    /// - Throws: `CancellationError` when the test task is cancelled.
    var admittedFootprint: ModelPoolFootprint {
        get async throws { try await admit { $0.footprint } }
    }
}
