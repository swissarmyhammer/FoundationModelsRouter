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
    /// How many cooperative yields ``spin(until:)`` gives a condition before it
    /// gives up.
    ///
    /// A timeout measured in scheduler hops rather than wall clock: high enough
    /// that a state change a test genuinely orders behind a handful of task
    /// suspensions always lands, low enough that a condition which never holds
    /// gives up in well under a second instead of hanging the suite.
    static let yieldLimit = 100_000

    /// Spins cooperatively until `condition` holds or ``yieldLimit`` yields
    /// elapse, so a scheduler-ordered state change is observed without a sleep —
    /// and a condition that never holds ends the wait rather than hanging the
    /// suite.
    ///
    /// - Parameter condition: The state change to wait for.
    static func spin(until condition: @Sendable () async -> Bool) async {
        for _ in 0..<yieldLimit {
            if await condition() { return }
            await Task.yield()
        }
    }

    /// Whether `condition` held inside ``spin(until:)``'s bound, recording an
    /// issue naming `label` when it never did.
    ///
    /// The one bounded observation every wait in these tests is built from: spin
    /// for the condition, read it once more, then report rather than wait on
    /// something that is never going to happen. Nothing here is specific to a
    /// semaphore, a task, or a turn, so each of those observes through this.
    ///
    /// - Parameters:
    ///   - label: What should have happened, named in the recorded issue.
    ///   - condition: The observable effect that says it happened.
    /// - Returns: Whether the condition held inside the bound.
    static func conditionReached(_ label: String, when condition: @Sendable () async -> Bool) async -> Bool {
        await spin(until: condition)
        guard await condition() else {
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
