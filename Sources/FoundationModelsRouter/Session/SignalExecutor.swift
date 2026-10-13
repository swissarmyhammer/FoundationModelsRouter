import FoundationModelsExtras
import Synchronization

/// The serial executor of the signals of one session (`mailbox.md`,
/// section 5, "Decision: signals run one at a time, in order").
///
/// A signal call (``RoutedSession/cancel(_:)``, ``RoutedSession/cancelAll()``,
/// ``RoutedSession/replace(_:with:)``, ``RoutedSession/compact(prompt:budget:)``)
/// makes a ``SignalID``, gives its work to this executor, and returns the id
/// at once. An automatic compaction of an answer is one more signal of the
/// same kind. The executor runs the work of each signal one at a time, in
/// the order the calls came, each with the origin ``Origin/signal(_:)`` of
/// its id. The work of a signal starts when the work of the signal before it
/// ended. With no signal work that runs, the work starts at once, after one
/// task hop.
///
/// After ``close()``, the executor runs no more work: each signal that waits,
/// and each signal that comes later, runs only its `skipped` closure.
final class SignalExecutor: Sendable {
    /// The work of the executor.
    private struct State {
        /// The task of the last signal work that the executor got, or `nil`.
        /// Each new work waits for it, so the work runs in arrival order.
        var last: Task<Void, Never>?

        /// The count of the signals whose work waits or runs.
        var unfinished = 0

        /// The actions that run when no signal work waits or runs
        /// (``SignalExecutor/whenNoSignalWaits(_:)``).
        var idleActions: [@Sendable () -> Void] = []

        /// Whether ``SignalExecutor/close()`` ran.
        var isClosed = false

        /// Ends the count of one signal, and gives the actions that run now:
        /// each idle action when it was the last signal, else none.
        ///
        /// - Returns: The actions to run after the lock is released.
        mutating func finishOne() -> [@Sendable () -> Void] {
            unfinished -= 1
            guard unfinished == 0 else { return [] }
            defer { idleActions = [] }
            return idleActions
        }
    }

    /// The state of the executor.
    private let state = Mutex(State())

    /// Makes an executor with no work.
    init() {}

    /// Runs `work` after the work of each earlier signal, with the origin of
    /// the signal `id`. Does not wait.
    ///
    /// The order of the calls is the order of the work: the next task is
    /// made under the lock, so two calls from two tasks get a clear order.
    ///
    /// - Parameters:
    ///   - id: The id of the signal.
    ///   - work: The work of the signal.
    ///   - skipped: What runs in place of `work` when the executor closed
    ///     before the turn of this signal. The default does nothing.
    func run(
        _ id: SignalID,
        _ work: @escaping @Sendable () async -> Void,
        skipped: @escaping @Sendable () -> Void = {}
    ) {
        state.withLock { state in
            state.unfinished += 1
            let earlier = state.last
            state.last = Task { [self] in
                await earlier?.value
                if self.state.withLock({ $0.isClosed }) {
                    skipped()
                } else {
                    await OriginContext.$current.withValue(.signal(id)) {
                        await work()
                    }
                }
                for action in self.state.withLock({ $0.finishOne() }) {
                    action()
                }
            }
        }
    }

    /// Runs `action` when no signal work waits or runs: at once when the
    /// executor is idle, else after the end of the last signal work that
    /// waits or runs now, or that comes before that end.
    ///
    /// The end of a compaction resumes the mail queue through this call. A
    /// signal that came while the compaction ran (for example
    /// ``RoutedSession/cancelAll()``) thus does its work before the pump can
    /// take mail again, so queued mail never overtakes a signal that came
    /// before it.
    ///
    /// - Parameter action: The action. It must not suspend.
    func whenNoSignalWaits(_ action: @escaping @Sendable () -> Void) {
        let runsNow = state.withLock { state -> Bool in
            guard state.unfinished > 0 else { return true }
            state.idleActions.append(action)
            return false
        }
        if runsNow {
            action()
        }
    }

    /// Closes the executor: the work of a signal that waits, or that comes
    /// later, does not run. The work that runs now goes on to its end.
    ///
    /// The task of a signal reads the close before its work goes to the
    /// actor of the work. Thus work whose task read the executor before this
    /// call can come to its actor after this call. Work that must not start
    /// after the close of its session checks the close again on its actor
    /// (``RoutedSessionActor/performCompaction(_:_:)``).
    func close() {
        state.withLock { $0.isClosed = true }
    }
}
