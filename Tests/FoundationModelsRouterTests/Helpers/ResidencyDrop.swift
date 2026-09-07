@testable import FoundationModelsRouter

/// Dropping a test's own reference to a resolved profile, which is how a test
/// ends a residency.
extension Optional where Wrapped == LanguageModelProfile {
    /// Clears this reference to the resolved profile.
    ///
    /// Pooled residency is owned by ARC. A ``Router`` evicts a model once
    /// nothing references it any more, and
    /// ``Router/resolve(profile:reporting:)`` gives back every dropped
    /// residency before it measures the host budget. A test therefore ends a
    /// residency by clearing the references it holds, and observes the
    /// eviction at the next resolve — the drain point — rather than by calling
    /// a cleanup method.
    ///
    /// The clearing goes through this method, and not through a bare `= nil`,
    /// because a local variable that is only ever written draws a compiler
    /// warning. Application code needs none of this: there the reference
    /// simply goes out of scope.
    mutating func dropReference() {
        self = nil
    }
}
