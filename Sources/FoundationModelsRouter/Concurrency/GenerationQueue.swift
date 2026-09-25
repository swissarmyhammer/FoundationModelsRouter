/// The work queue of one resident model: one generation pass runs at a time
/// (`generation-queue.md`, section 2).
///
/// A pass is one call of `LanguageModelExecutor.respond`. One GPU runs one
/// generation at a time, so all the passes on one model wait in this one FIFO
/// queue. A session that runs a tool body or waits for a person holds no
/// place: the SDK ends an executor call before it runs the tool body of that
/// call (task ^8nqkten).
///
/// There is one queue for each pool entry. The live container
/// (``MLXFoundationModelsContainer``) makes the queue and owns it, and one
/// resident container is one pool entry. Each backend the container makes runs
/// its `LanguageModelSession` over its own ``QueuedLanguageModel``, and all
/// those wrappers share this queue. Two different models have two queues and
/// generate at the same time.
///
/// A container with no executor seam (a ``LoadedLLMContainer`` whose backend
/// is not a `LanguageModelSession` over a `LanguageModel`) gets no pass-level
/// gating from the wrapper. Such a container can own a queue of its own and run
/// each scripted pass in ``runPass(isolation:_:)``, so its queue behavior is
/// testable without MLX.
///
/// This queue is a different semaphore from the turn-long
/// ``RoutedModel/generationGate``. A turn holds that gate and then each of its
/// passes waits here. One semaphore for both would deadlock on the first pass.
public final class GenerationQueue: Sendable {
    /// The one place of the queue: a fair FIFO semaphore at value `1`.
    private let place = AsyncSemaphore(value: 1)

    /// Makes a queue with its one place free.
    public init() {}

    /// Waits for the place of the queue, runs `body`, and gives the place back.
    ///
    /// A caller cancelled while it waits leaves the queue at once, runs
    /// nothing, and takes no place. After the wait, the place is given back
    /// in a `defer`, whether `body` returns, throws, or is cancelled.
    ///
    /// - Parameters:
    ///   - isolation: The caller's actor isolation, which defaults to the
    ///     caller's own. `body` runs there, on the calling task.
    ///   - body: One generation pass.
    /// - Returns: What `body` returns.
    /// - Throws: `CancellationError` when the calling task is cancelled before
    ///   it gets the place, or what `body` throws.
    public func runPass<T>(
        isolation: isolated (any Actor)? = #isolation,
        _ body: () async throws -> T
    ) async throws -> T {
        try await place.withPermitUnlessCancelled(isolation: isolation, body)
    }

    /// The number of free places, `0` or `1`.
    ///
    /// Exposed for observability and deterministic testing; not part of the
    /// queue contract.
    var availablePlaces: Int { place.availablePermits }

    /// The number of passes that wait for the place.
    ///
    /// Exposed for observability and deterministic testing; not part of the
    /// queue contract.
    var waiterCount: Int { place.waiterCount }
}
