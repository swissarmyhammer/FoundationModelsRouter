import Testing

@testable import FoundationModelsRouter

/// Thrown by ``BoundedWait/awaitSignal(_:named:)`` when the signal it waited for
/// never arrived, so the test that caught the fault stops there instead of
/// parking on a wait nothing can break.
struct SignalNeverArrived: Error {}

/// A bounded way to observe something a test would otherwise wait on with no way
/// out: a scheduler-ordered state change, or an ``AsyncSemaphore`` signal.
///
/// The bound is the whole point. ``AsyncSemaphore/wait()`` suspends on a
/// `CheckedContinuation<Void, Never>` and ignores cancellation by design, so a
/// signal that never comes parks its waiter forever and no cancellation and no
/// other task can unpark it. This test target sets no `.timeLimit` trait, and
/// SwiftPM offers no manifest-level way to set one, so such a wait hangs the
/// whole `swift test` run rather than failing the one test that caught the
/// fault.
///
/// What *is* breakable is the observation. ``AsyncSemaphore/availablePermits``
/// answers "has it been signalled yet?" without suspending, so a bounded spin
/// over that reading ends whether or not the signal ever comes. Entering
/// `wait()` only once a permit is provably there is then safe, because that
/// `wait()` takes the permit immediately instead of suspending — the two steps
/// are what makes the wait bounded, and they cannot be collapsed back into one.
///
/// The one precondition is that the semaphore has a single consumer: the test
/// task doing the observing. Nobody else may take the permit between the reading
/// and the `wait()`. Every semaphore a test uses purely as a signal — one
/// signaller, one waiter — has exactly that shape.
enum BoundedWait {
    /// The whole time ``spin(until:)`` gives a condition before it gives up.
    ///
    /// A wall-clock ceiling, not a count of scheduler hops. A count of hops
    /// measures how often the waiting task ran, never how long the wait lasted,
    /// so a loaded machine that gives the task making the change few slices
    /// lets the waiter spend the whole count while the change is still on its
    /// way. The bound is then a function of the load, and a correct test fails
    /// for want of CPU. A clock reads the same under load as it does idle.
    ///
    /// High enough that a change these tests genuinely order behind a few task
    /// suspensions always lands, low enough that a condition which never holds
    /// gives up in seconds instead of hanging the suite.
    ///
    /// The same span ``AnswerDrivenRun`` waits under, because it is the same
    /// bound: each asks a non-suspending question again and again until it
    /// answers yes.
    static let ceilingNanoseconds: UInt64 = 5_000_000_000

    /// How long ``spin(until:)`` sleeps between two readings of a condition,
    /// once its yields are spent.
    static let pollIntervalNanoseconds: UInt64 = 5_000_000

    /// How many cooperative yields ``spin(until:)`` spends before it begins to
    /// sleep between readings.
    ///
    /// A state change a test orders behind a handful of task suspensions lands
    /// inside these, so the ordinary wait costs microseconds rather than a poll
    /// interval. Past them the wait is blocked on something slower than the
    /// scheduler, and a sleep leaves the machine to the task that must make the
    /// change instead of spinning against it.
    static let yieldsBeforePolling = 1_000

    /// Whether `condition` held inside the bound: yielded for first, then
    /// polled for until ``ceilingNanoseconds`` elapse.
    ///
    /// A scheduler-ordered state change is observed without a sleep, a change
    /// that a loaded machine delays is still observed, and a condition that
    /// never holds ends the wait rather than hanging the suite.
    ///
    /// - Parameter condition: The state change to wait for.
    /// - Returns: Whether the condition held inside the bound.
    @discardableResult
    static func spin(until condition: @Sendable () async -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .nanoseconds(ceilingNanoseconds))
        for _ in 0..<yieldsBeforePolling {
            if await condition() { return true }
            await Task.yield()
        }
        while true {
            if await condition() { return true }
            if ContinuousClock.now >= deadline { return false }
            await waitOnePollInterval()
        }
    }

    /// Waits ``pollIntervalNanoseconds`` before the next reading of a condition.
    ///
    /// `Task.sleep` throws the moment the surrounding task is cancelled, and a
    /// cancelled wait must still end on the deadline rather than on a hot loop,
    /// so a sleep that cannot run becomes a yield. Cancellation never decides
    /// when a wait ends here; only the deadline does.
    private static func waitOnePollInterval() async {
        if (try? await Task.sleep(nanoseconds: pollIntervalNanoseconds)) == nil {
            await Task.yield()
        }
    }

    /// Whether `condition` held inside ``spin(until:)``'s bound, recording an
    /// issue naming `label` when it never did.
    ///
    /// The one bounded observation every wait in these tests is built from: spin
    /// for the condition, then report rather than wait on something that is
    /// never going to happen. Nothing here is specific to a semaphore, a task,
    /// or a turn, so each of those observes through this.
    ///
    /// - Parameters:
    ///   - label: What should have happened, named in the recorded issue.
    ///   - condition: The observable effect that says it happened.
    /// - Returns: Whether the condition held inside the bound.
    static func conditionReached(_ label: String, when condition: @Sendable () async -> Bool) async -> Bool {
        guard await spin(until: condition) else {
            Issue.record("\(label) was never observed inside the bound, so the code that makes it happen never ran")
            return false
        }
        return true
    }

    /// Whether `semaphore` carried a signal inside the bound, recording an issue
    /// naming `label` when it never did.
    ///
    /// The permit is left where it is, for a caller that only wants to know
    /// whether the thing it names happened. The observed reading is
    /// ``AsyncSemaphore/availablePermits``, which does not suspend, so the
    /// single-consumer precondition above is what a later `wait()` rests on.
    ///
    /// - Parameters:
    ///   - semaphore: A semaphore something else signals to report progress.
    ///   - label: What the signal means, named in the recorded issue.
    /// - Returns: Whether a permit appeared inside the bound.
    static func signalArrived(_ semaphore: AsyncSemaphore, named label: String) async -> Bool {
        await conditionReached(label, when: { semaphore.availablePermits > 0 })
    }

    /// Takes `semaphore`'s signal, once that signal is provably there — the
    /// bounded replacement for a bare `await semaphore.wait()` on a test task.
    ///
    /// - Parameters:
    ///   - semaphore: A semaphore something else signals to report progress.
    ///   - label: What the signal means, named in the recorded issue.
    /// - Throws: ``SignalNeverArrived`` when no signal came inside the bound,
    ///   after recording an issue naming `label`.
    static func awaitSignal(_ semaphore: AsyncSemaphore, named label: String) async throws {
        guard await signalArrived(semaphore, named: label) else {
            throw SignalNeverArrived()
        }
        await semaphore.wait()
    }
}
