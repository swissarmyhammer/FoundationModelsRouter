import FoundationModelsExtras
import Synchronization

/// The serial executor of the signals of one session (`mailbox.md`,
/// section 5, "Decision: signals run one at a time, in order").
///
/// A signal call (``RoutedSession/cancel(_:)``, ``RoutedSession/cancelAll()``,
/// ``RoutedSession/replace(_:with:)``) makes a ``SignalID``, gives its work to
/// this executor, and returns the id at once. The executor runs the work of
/// each signal one at a time, in the order the calls came, each with the
/// origin ``Origin/signal(_:)`` of its id. The work of a signal starts when
/// the work of the signal before it ended. With no signal work that runs,
/// the work starts at once, after one task hop.
///
/// Part C of the mail plan adds the compaction as one more kind of signal
/// work: it is one more call of ``run(_:_:)``.
final class SignalExecutor: Sendable {
    /// The task of the last signal work that the executor got, or `nil`.
    /// Each new work waits for it, so the work runs in arrival order.
    private let last = Mutex<Task<Void, Never>?>(nil)

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
    func run(_ id: SignalID, _ work: @escaping @Sendable () async -> Void) {
        last.withLock { last in
            let earlier = last
            last = Task {
                await earlier?.value
                await OriginContext.$current.withValue(.signal(id)) {
                    await work()
                }
            }
        }
    }
}
