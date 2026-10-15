import Synchronization

/// Starts the helper tasks of one owner, and tells when each of them ended.
///
/// A session starts helper tasks that it does not wait for: the helper tasks
/// of its model calls (the stall watchdog, the reader of the pass reports,
/// and the repetition watch), the wake of the pump after a mail or after a
/// compaction, and the task of each signal (``SignalExecutor``). The owner
/// cancels a helper task, or lets it run to its end, and does not wait for
/// it. A helper task keeps strong references to the session, and thus to the
/// profile of the session and to the model handles of that profile.
/// ``RoutedSessionActor``'s drain (the wait of ``RoutedSession/close()``)
/// waits here until each helper task ended (``awaitNoLiveTask()``). Thus no
/// helper task keeps the profile when close returns.
///
/// A helper task counts as ended only after its task ended. The end of a task
/// releases what its operation captured before a wait for the value of the
/// task resumes. So a second task waits for the value of the helper task,
/// and only then counts the end and signals ``taskEnds``. That second task
/// keeps only the handle of the helper task and this tracker, nothing of the
/// session.
///
/// A helper task must end at its cancel, or end by itself, and must not wait
/// for the drain of its session. Else the drain waits forever.
final class HelperTaskTracker: Sendable {
    /// The number of helper tasks that started or that are reserved
    /// (``reserve()``), and that did not end yet.
    private let liveTasks = Mutex(0)

    /// Reports each end of a helper task. ``awaitNoLiveTask()`` waits on it.
    ///
    /// It reports each change of its waiters (``ChangeSignal/waiterChanges``),
    /// so a test can wait until a close of the session waits for a helper
    /// task.
    let taskEnds = ChangeSignal(observingWaiters: true)

    /// Makes a tracker with no helper task.
    init() {}

    /// The number of helper tasks that started or that are reserved, and that
    /// did not end yet.
    var liveTaskCount: Int {
        liveTasks.withLock { $0 }
    }

    /// Counts one helper task now, before it starts.
    ///
    /// A caller reserves before the step that makes the task necessary, when
    /// a wait can come between that step and the start of the task. Then the
    /// wait sees the count. For example, ``RoutedSessionActor/mail(_:)``
    /// reserves the wake of the pump before the put of the mail. A put that
    /// comes before the close of the queue thus comes after the reserve, and
    /// the drain of the close sees the count.
    ///
    /// - Returns: The reservation. The caller starts the task with it
    ///   (``Reservation/start(_:)``), or ends the count with it
    ///   (``Reservation/cancel()``). One of the two must come.
    func reserve() -> Reservation {
        liveTasks.withLock { $0 += 1 }
        return Reservation(tracker: self)
    }

    /// Starts `operation` on a new task, and counts that task until it ended.
    ///
    /// The new task inherits the priority and the task-locals of the calling
    /// task, as `Task.init` gives them. The caller cancels the task through
    /// the handle that this method gives.
    ///
    /// - Parameter operation: The work of the helper task. It must end at its
    ///   cancel.
    /// - Returns: The handle of the helper task.
    func start(_ operation: @escaping @Sendable () async -> Void) -> Task<Void, Never> {
        reserve().start(operation)
    }

    /// Waits until no helper task is live, or until the calling task is
    /// cancelled.
    ///
    /// The wait is ``ChangeSignal/waitUntil(isolation:_:)`` on ``taskEnds``,
    /// so an end that comes between the read of the count and the wait is not
    /// lost.
    func awaitNoLiveTask() async {
        _ = await taskEnds.waitUntil { liveTaskCount == 0 }
    }

    /// Ends the count of one helper task, and signals ``taskEnds``.
    fileprivate func endOne() {
        liveTasks.withLock { $0 -= 1 }
        taskEnds.signal()
    }

    /// One helper task that ``HelperTaskTracker/reserve()`` counts and that
    /// did not start yet.
    ///
    /// It cannot be copied, so one reservation starts at most one task, or
    /// ends at most one count.
    struct Reservation: ~Copyable {
        /// The tracker that counts the task.
        fileprivate let tracker: HelperTaskTracker

        /// Starts `operation` on a new task, and ends the count when that
        /// task ended.
        ///
        /// The new task inherits the priority and the task-locals of the
        /// calling task, as `Task.init` gives them.
        ///
        /// - Parameter operation: The work of the helper task. It must end at
        ///   its cancel.
        /// - Returns: The handle of the helper task.
        consuming func start(_ operation: @escaping @Sendable () async -> Void) -> Task<Void, Never> {
            let helper = Task { await operation() }
            Task { [tracker] in
                await helper.value
                tracker.endOne()
            }
            return helper
        }

        /// Ends the count with no task: the step that made the task
        /// necessary did not happen.
        consuming func cancel() {
            tracker.endOne()
        }
    }
}
