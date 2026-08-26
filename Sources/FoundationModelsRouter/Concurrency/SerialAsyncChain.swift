/// A strict-FIFO chain of asynchronous deliveries, owned by one actor.
/// ``enqueue(body:)`` fixes a delivery's place synchronously on the owning
/// actor; the returned task starts only after every earlier one finishes.
/// Store it as actor-isolated state so the enqueue stays synchronous.
struct SerialAsyncChain {
    /// The most recently enqueued delivery, or `nil` before the first one.
    private var tail: Task<Void, Never>?

    /// Chains `body` behind whatever is already in flight.
    ///
    /// - Parameter body: The delivery to run once every earlier one has finished.
    /// - Returns: The chained delivery, for the caller to await when needed.
    mutating func enqueue(body: @escaping @Sendable () async -> Void) -> Task<Void, Never> {
        let previous = tail
        let chained = Task {
            await previous?.value
            await body()
        }
        tail = chained
        return chained
    }
}
