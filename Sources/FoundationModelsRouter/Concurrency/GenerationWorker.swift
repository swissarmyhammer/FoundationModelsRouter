import Synchronization

/// The worker of one ``GenerationQueue``: an actor that holds the list of the
/// waiting items, and one worker task that runs them one at a time, first in
/// first out (`generation-queue.md`, section 5.3).
///
/// The worker is not a lock. A submitter adds its item and waits only for the
/// result of that item. While an item runs, the actor is free, so a new item
/// can join the list. The worker task ends when the list is empty, and the
/// next item starts a new one.
///
/// Each item runs on a detached task that the worker task makes for it. So a
/// cancel reaches that item and no other, and the item inherits no task-local
/// of its submitter. An item leaves the list only on this actor, and the code
/// that takes it out of the list is the only code that resumes its submitter.
/// So the continuation of each submitter resumes exactly one time, also when a
/// cancel and the start of the item race.
actor GenerationWorker {
    /// The identity of one item, the mark of its cancel, and the task that
    /// runs it.
    ///
    /// The cancel handler of the submitter sets the mark at once, on the task
    /// that cancels. The actor reads it, so an item whose submitter is
    /// cancelled leaves the count of waiting items and never starts, also
    /// before the actor takes the cancel. The mark also cancels the task that
    /// runs the item at once, with no hop to the actor: the item is a whole
    /// SDK call, and a stop of that call (a cancel, a compaction yield at a
    /// tool result) must reach it before the SDK starts its next pass.
    final class Ticket: Sendable {
        /// The mark of the cancel and the task that runs the item.
        private struct State {
            /// Whether the submitter of the item is cancelled.
            var isCancelled = false

            /// The task that runs the item, or `nil` before the item runs.
            var task: Task<Delivery, Never>?
        }

        /// The state, under one lock.
        private let state = Mutex(State())

        /// Whether the submitter of the item is cancelled.
        var isCancelled: Bool { state.withLock { $0.isCancelled } }

        /// Marks the item as cancelled, and cancels the task that runs it when
        /// it runs.
        func markCancelled() {
            let task = state.withLock { state -> Task<Delivery, Never>? in
                state.isCancelled = true
                return state.task
            }
            task?.cancel()
        }

        /// Records `task` as the task that runs the item, and cancels it when
        /// the submitter is cancelled already.
        ///
        /// - Parameter task: The task that runs the item.
        fileprivate func attach(_ task: Task<Delivery, Never>) {
            let isCancelled = state.withLock { state -> Bool in
                state.task = task
                return state.isCancelled
            }
            guard isCancelled else { return }
            task.cancel()
        }
    }

    /// Gives the submitter its result: a call that resumes the continuation
    /// of the submitter one time.
    fileprivate typealias Delivery = @Sendable () -> Void

    /// One item that waits for the worker task.
    private struct WaitingItem: Sendable {
        /// The identity of the item.
        let ticket: Ticket

        /// The priority of the submitter, which the task of the item gets.
        let priority: TaskPriority

        /// Runs the item, and gives back the delivery of its result. It
        /// never resumes the submitter itself.
        let run: @Sendable () async -> Delivery

        /// Resumes the submitter with `CancellationError`, for an item that
        /// leaves the list before it runs.
        let withdraw: Delivery
    }

    /// The item the worker task runs now.
    private struct RunningItem {
        /// The identity of the item.
        let ticket: Ticket

        /// The task that runs the item. A cancel of the submitter cancels it.
        let task: Task<Delivery, Never>
    }

    /// The items that wait, first in first out.
    private var waiting: [WaitingItem] = []

    /// The worker task while it runs, or `nil` when the worker is idle.
    private var workerTask: Task<Void, Never>?

    /// The item the worker task runs now, or `nil` between two items and
    /// when the worker is idle.
    private var running: RunningItem?

    /// Whether the worker task runs, or is about to run, an item.
    var isRunning: Bool { workerTask != nil }

    /// The number of items that wait for the worker task. An item whose
    /// submitter is cancelled does not count: it will never run.
    var waitingCount: Int { waiting.count { !$0.ticket.isCancelled } }

    /// Adds the item of `ticket` to the end of the list, starts the worker
    /// task when it is idle, and waits for the result of the item.
    ///
    /// The check for a cancel, the report of a wait and the append have no
    /// suspension point between them.
    ///
    /// - Parameters:
    ///   - ticket: The identity of the item.
    ///   - onQueued: Called when the item waits behind another item.
    ///   - body: The item.
    /// - Returns: What `body` returns.
    /// - Throws: `CancellationError` when the submitter is cancelled before
    ///   the item runs, or what `body` throws.
    func submit<T: Sendable>(
        _ ticket: Ticket,
        onQueued: @Sendable () -> Void,
        _ body: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            guard !Task.isCancelled, !ticket.isCancelled else {
                continuation.resume(throwing: CancellationError())
                return
            }
            if workerTask != nil {
                onQueued()
            }
            waiting.append(
                Self.makeItem(ticket, priority: Task.currentPriority, body: body, continuation: continuation))
            startWorkerTaskIfIdle()
        }
    }

    /// Takes the cancel of the item of `ticket`.
    ///
    /// A waiting item leaves the list, and its submitter gets
    /// `CancellationError`. A running item gets the cancel on its task. An
    /// item that ended, or that never joined the list, needs nothing.
    ///
    /// - Parameter ticket: The identity of the item.
    func cancel(_ ticket: Ticket) {
        if let index = waiting.firstIndex(where: { $0.ticket === ticket }) {
            waiting.remove(at: index).withdraw()
        } else if let running, running.ticket === ticket {
            running.task.cancel()
        }
    }

    /// Makes the list entry of one item.
    ///
    /// - Parameters:
    ///   - ticket: The identity of the item.
    ///   - priority: The priority of the submitter.
    ///   - body: The item.
    ///   - continuation: The continuation of the submitter.
    /// - Returns: The list entry.
    private static func makeItem<T: Sendable>(
        _ ticket: Ticket,
        priority: TaskPriority,
        body: @escaping @Sendable () async throws -> T,
        continuation: CheckedContinuation<T, any Error>
    ) -> WaitingItem {
        WaitingItem(
            ticket: ticket,
            priority: priority,
            run: {
                let result: Result<T, any Error>
                do {
                    result = .success(try await body())
                } catch {
                    result = .failure(error)
                }
                return { continuation.resume(with: result) }
            },
            withdraw: { continuation.resume(throwing: CancellationError()) })
    }

    /// Starts the worker task when no worker task runs.
    ///
    /// The worker task is detached, so it inherits no task-local and no
    /// priority of the submitter that started it.
    private func startWorkerTaskIfIdle() {
        guard workerTask == nil else { return }
        workerTask = Task.detached { await self.runWaitingItems() }
    }

    /// Runs each waiting item to its end, in order, until none waits.
    ///
    /// An item whose submitter is cancelled leaves the list and never starts.
    /// The worker task clears ``running`` before it resumes the submitter, so
    /// a submitter that has its result sees its item gone from the worker.
    /// The check for an empty list and the reset of ``workerTask`` have no
    /// suspension point between them, so an item that joins the list is
    /// always run.
    private func runWaitingItems() async {
        while !waiting.isEmpty {
            let item = waiting.removeFirst()
            guard !item.ticket.isCancelled else {
                item.withdraw()
                continue
            }
            let task = Task.detached(priority: item.priority) { await item.run() }
            item.ticket.attach(task)
            running = RunningItem(ticket: item.ticket, task: task)
            let deliver = await task.value
            running = nil
            deliver()
        }
        workerTask = nil
    }
}
