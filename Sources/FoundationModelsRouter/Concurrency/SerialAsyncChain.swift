/// A strict-FIFO chain of asynchronous deliveries, owned by one actor.
///
/// An actor serializes the *decisions* it makes but not the *awaits* it starts:
/// a method that suspends on a cross-actor call lets the next call in, so two
/// deliveries begun in a known order can finish in either one. Where that order
/// is part of the meaning — a run's progress reports must reach a sink before
/// its completion does, and a transcript's order is the record of when things
/// happened — the order has to be fixed before the first suspension.
///
/// This does that: ``enqueue(_:)`` decides a delivery's place in the queue
/// synchronously, on the owning actor, and hands back a task that will not
/// start its own work until every earlier one has finished. The caller may
/// await that task, so a delivery can still be observed to have completed
/// before the enqueuing call returns.
///
/// Stored as ordinary actor-isolated state (`private var chain =
/// SerialAsyncChain()`), which is what makes the enqueue synchronous.
struct SerialAsyncChain {
    /// The most recently enqueued delivery, or `nil` before the first one.
    private var tail: Task<Void, Never>?

    /// Chains `body` behind whatever is already in flight.
    ///
    /// - Parameter body: The delivery to run once every earlier one has
    ///   finished.
    /// - Returns: The chained delivery, for the caller to await when it needs
    ///   the work observed as done before it returns.
    mutating func enqueue(_ body: @escaping @Sendable () async -> Void) -> Task<Void, Never> {
        let previous = tail
        let chained = Task {
            await previous?.value
            await body()
        }
        tail = chained
        return chained
    }
}
