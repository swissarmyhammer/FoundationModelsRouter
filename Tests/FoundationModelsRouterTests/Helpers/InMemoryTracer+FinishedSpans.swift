import InMemoryTracing

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
    func finishedSpans(named name: String) -> [FinishedInMemorySpan] {
        finishedSpans.filter { $0.operationName == name }
    }
}
