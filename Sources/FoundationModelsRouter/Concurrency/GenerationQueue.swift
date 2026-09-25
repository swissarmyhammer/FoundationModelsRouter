/// The work queue of one resident model: one worker runs the items of the
/// model one at a time, first in first out (`generation-queue.md`, section
/// 5.3).
///
/// An item is one generation pass: one call of
/// `LanguageModelExecutor.respond`. One GPU runs one generation at a time, so
/// all the passes on one model go through this one queue. A session that runs
/// a tool body or waits for a person has no item in the queue: the SDK ends an
/// executor call before it runs the tool body of that call (task ^8nqkten).
///
/// The queue is not a lock. A submitter gives the queue its item and waits
/// only for the result of that item. It never waits for a permission. The
/// ``GenerationWorker`` of the queue holds the list of the waiting items, and
/// its one worker task runs them in order, each on a task that it makes for
/// that item. A task that the worker makes inherits no task-local of the
/// submitter, so an item binds in its own closure each task-local that it
/// needs.
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
/// queue from the wrapper. Such a container can own a queue of its own and
/// submit each scripted pass through ``runPass(isolation:_:)``, so its queue
/// behavior is testable without MLX.
///
/// A cancel of the submitter reaches its item. A waiting item leaves the list
/// at once and never runs, and its submitter gets `CancellationError`. A
/// running item gets the cancel on the task that runs it. So
/// ``RoutedSession/cancelCurrentTurn()`` ends the wait of a pass at once.
public final class GenerationQueue: Sendable {
    /// The worker that holds the list and runs the items.
    private let worker = GenerationWorker()

    /// Makes an idle queue.
    public init() {}

    /// Submits `body` as one item, and waits for its result.
    ///
    /// `body` runs on a task that the worker makes, after every item that
    /// joined the queue before it. A submitter that is cancelled while its
    /// item waits gets `CancellationError` at once, and the item never runs.
    /// A submitter that is cancelled while its item runs cancels the task
    /// that runs it, and gets what `body` then gives.
    ///
    /// - Parameters:
    ///   - isolation: The actor isolation of the caller, which defaults to
    ///     the caller's own. The caller waits and resumes there.
    ///   - body: One generation pass.
    /// - Returns: What `body` returns.
    /// - Throws: `CancellationError` when the calling task is cancelled before
    ///   its item runs, or what `body` throws.
    public func runPass<T: Sendable>(
        isolation: isolated (any Actor)? = #isolation,
        _ body: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await runPass(isolation: isolation, onQueued: {}, body)
    }

    /// ``runPass(isolation:_:)``, which also calls `onQueued` when the item
    /// must wait: the worker runs another item (task ^ake8sax).
    ///
    /// An item that finds the queue idle never calls `onQueued`. The
    /// per-session ``QueuedLanguageModel`` uses it to report the wait to its
    /// session.
    ///
    /// - Parameters:
    ///   - isolation: The actor isolation of the caller, which defaults to
    ///     the caller's own. The caller waits and resumes there.
    ///   - onQueued: Called on the calling task when the item joins the list
    ///     behind another item.
    ///   - body: One generation pass.
    /// - Returns: What `body` returns.
    /// - Throws: `CancellationError` when the calling task is cancelled before
    ///   its item runs, or what `body` throws.
    func runPass<T: Sendable>(
        isolation: isolated (any Actor)? = #isolation,
        onQueued: @Sendable () -> Void,
        _ body: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let ticket = GenerationWorker.Ticket()
        let worker = worker
        return try await withTaskCancellationHandler {
            try await worker.submit(ticket, onQueued: onQueued, body)
        } onCancel: {
            ticket.markCancelled()
            Task { await worker.cancel(ticket) }
        }
    }

    /// Whether the worker runs, or is about to run, an item.
    ///
    /// Exposed for observability and deterministic testing; not part of the
    /// queue contract.
    var isRunning: Bool {
        get async { await worker.isRunning }
    }

    /// The number of items that wait for the worker.
    ///
    /// Exposed for observability and deterministic testing; not part of the
    /// queue contract.
    var waitingCount: Int {
        get async { await worker.waitingCount }
    }
}
