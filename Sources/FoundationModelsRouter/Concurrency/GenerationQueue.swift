/// The work queue of one resident model: one worker runs the items of the
/// model one at a time, first in first out (`generation-queue.md`, section
/// 5.3).
///
/// An item is one submission to Foundation: one whole SDK call
/// (`LanguageModelSession.respond` or `streamResponse`), with all of its steps.
/// The steps are the generation passes and the tool bodies that the SDK runs
/// between them. One GPU runs one generation at a time, so all the
/// submissions on one model go through this one queue. A submission holds the
/// worker for all of its steps, so a tool body holds the model for every other
/// session on it (section 5.5). A tool that starts long work is a background
/// tool: it returns at once, and its result comes back to its session as mail.
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
/// resident container is one pool entry. Each backend the container makes
/// names this queue (``LanguageModelSessionBackend/generationQueue``), and the
/// session of that backend submits each of its SDK calls to it. Two different
/// models have two queues and generate at the same time.
///
/// A container with no executor seam (a ``LoadedLLMContainer`` whose backend
/// is not a `LanguageModelSession` over a `LanguageModel`) can own a queue of
/// its own. Its backend then names that queue, or submits each scripted call
/// through ``submit(isolation:_:)`` itself, so its queue behavior is testable
/// without MLX.
///
/// A submission from a task inside an open submission on the same queue could
/// never run: it waits behind the submission of its own caller. The queue
/// refuses it at once with
/// ``GenerationQueueError/waitInsideOpenSubmission(model:)``.
///
/// A cancel of the submitter reaches its item. A waiting item leaves the list
/// at once and never runs, and its submitter gets `CancellationError`. A
/// running item gets the cancel on the task that runs it. So
/// ``RoutedSession/cancel()`` ends the wait of a submission at
/// once.
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
    ///   - body: One submission.
    /// - Returns: What `body` returns.
    /// - Throws: ``GenerationQueueError/waitInsideOpenSubmission(model:)`` when
    ///   the calling task is inside an open submission on this queue,
    ///   `CancellationError` when the calling task is cancelled before its item
    ///   runs, or what `body` throws.
    public func submit<T: Sendable>(
        isolation: isolated (any Actor)? = #isolation,
        _ body: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await submit(isolation: isolation, onQueued: {}, body)
    }

    /// ``submit(isolation:_:)``, which also calls `onQueued` when the item
    /// must wait: the worker runs another item.
    ///
    /// An item that finds the worker idle never calls `onQueued`. A session
    /// uses it to report the wait of its submission
    /// (``SessionEvent/submissionQueued(_:)``).
    ///
    /// - Parameters:
    ///   - isolation: The actor isolation of the caller, which defaults to
    ///     the caller's own. The caller waits and resumes there.
    ///   - onQueued: Called on the worker when the item joins the list behind
    ///     another item.
    ///   - body: One submission.
    /// - Returns: What `body` returns.
    /// - Throws: ``GenerationQueueError/waitInsideOpenSubmission(model:)`` when
    ///   the calling task is inside an open submission on this queue,
    ///   `CancellationError` when the calling task is cancelled before its item
    ///   runs, or what `body` throws.
    func submit<T: Sendable>(
        isolation: isolated (any Actor)? = #isolation,
        onQueued: @Sendable () -> Void,
        _ body: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try refuseWaitInsideOpenSubmission()
        let ticket = GenerationWorker.Ticket()
        let worker = worker
        return try await withTaskCancellationHandler {
            try await worker.submit(ticket, onQueued: onQueued, body)
        } onCancel: {
            ticket.markCancelled()
            Task { await worker.cancel(ticket) }
        }
    }

    /// Refuses a wait for this queue from a task inside an open submission on
    /// this queue: an in-band tool body of a running item. An item of that
    /// task could run only after the item of that tool body ends, which waits
    /// for it (`generation-queue.md`, section 5.5, rule 2).
    ///
    /// ``submit(isolation:onQueued:_:)`` calls it for each submission. Each
    /// helper of a session that waits for an answer calls it on the task of
    /// its caller (``RoutedSessionActor/refuseWaitInsideOpenSubmission()``),
    /// so a wait for the answer of a session over this queue is refused too,
    /// also when that session is busy.
    ///
    /// The mark that this check reads is set by
    /// ``RoutedSessionActor/runCancellableModelCall(composedPrompt:submittingTo:_:)``.
    /// For each model call, it makes an open ``ModelCallMark`` that names the
    /// ``SubmissionTarget`` (this queue and its model), and its submission
    /// binds that mark to ``ModelCallMark/current`` around the SDK call, on
    /// the task of the worker. The SDK gives the mark to each in-band tool
    /// body of the call. The mark closes when the model call returns.
    ///
    /// A background run has a closed mark (``ModelCallMark/withBackgroundRunMark(_:)``),
    /// so it is not refused.
    ///
    /// - Throws: ``GenerationQueueError/waitInsideOpenSubmission(model:)``.
    func refuseWaitInsideOpenSubmission() throws {
        guard let open = ModelCallMark.current?.openSubmission(on: self) else { return }
        throw GenerationQueueError.waitInsideOpenSubmission(model: open.model)
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
