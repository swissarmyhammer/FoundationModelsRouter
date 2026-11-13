import InMemoryTracing

/// The span filter that the unit tests and the integration tests share.
///
/// This module is where it can stand. `swift test` builds one `.xctest` for
/// each test target, and SwiftPM cannot share source between two test targets.
/// The nested `IntegrationTests/` package also cannot see a file of the unit
/// test target. ``TextFileLines`` and ``GatedWallClock`` are here for the same
/// reason.
extension InMemoryTracer {
    /// The finished spans of this tracer that have the operation name `name`,
    /// in the order that they finished.
    ///
    /// A test filters by name and does not count all of the spans of the
    /// tracer: other work that reports to the same tracer opens its own spans.
    /// For example, a resolve opens a resolve span and one load span for each
    /// slot that it loads.
    ///
    /// - Parameter name: The operation name of the spans.
    /// - Returns: Each finished span with that name.
    public func finishedSpans(named name: String) -> [FinishedInMemorySpan] {
        finishedSpans.filter { $0.operationName == name }
    }
}
