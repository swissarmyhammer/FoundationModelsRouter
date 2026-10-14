/// Counts how many bodies are inside one section of code at the same time, and
/// keeps the largest count it saw.
///
/// A test reads ``maximumActive`` to learn whether two bodies overlapped, so it
/// needs no sleep and no clock. A test reads ``enteredCount`` to make sure the
/// bodies really entered — a "no overlap" answer over a section that nothing
/// entered would be vacuous.
///
/// This is the one concurrency counter the test targets share. Every suite
/// that must measure overlap uses it, so the scaffolding lives in exactly one
/// place and cannot drift copy from copy. It lives in this support target
/// because more than one test target reads it, and SwiftPM cannot share source
/// between two test targets.
///
/// An `actor`, so two bodies that really did overlap can never lose an update
/// to a data race and report a smaller overlap than the run had.
///
/// A test waits for a count with ``waitUntil(_:)``. Each entry and each exit
/// is the event that wakes the wait, so the wait needs no clock and no poll.
public actor ConcurrencyPeakObserver {
    /// The counts of the observer at one time, as a waiting test reads them.
    public struct Counts: Sendable {
        /// How many bodies are inside the section.
        public let active: Int

        /// How many bodies entered the section over the whole run.
        public let entered: Int
    }

    /// One task that waits until its condition holds.
    private struct Waiter {
        /// The condition the task waits for.
        let condition: @Sendable (Counts) -> Bool

        /// Resumes the task.
        let continuation: CheckedContinuation<Void, Never>
    }

    /// How many bodies are inside the section now.
    private var active = 0

    /// The largest number of bodies that were inside the section at one time.
    public private(set) var maximumActive = 0

    /// How many bodies entered the section over the whole run.
    public private(set) var enteredCount = 0

    /// The tasks that wait for a condition that did not hold yet.
    private var waiters: [Waiter] = []

    /// Creates an observer that has seen no bodies yet.
    public init() {}

    /// The counts now.
    private var counts: Counts {
        Counts(active: active, entered: enteredCount)
    }

    /// Records one body that enters the section, and resumes each waiter
    /// whose condition now holds.
    public func enter() {
        active += 1
        enteredCount += 1
        maximumActive = max(maximumActive, active)
        resumeSatisfiedWaiters()
    }

    /// Records one body that leaves the section, and resumes each waiter
    /// whose condition now holds.
    public func exit() {
        active -= 1
        resumeSatisfiedWaiters()
    }

    /// Waits until `condition` holds for the counts of this observer.
    ///
    /// The wait reads the counts at once, and again after each entry and
    /// each exit. Nothing else ends the wait: a body that never enters keeps
    /// the test waiting, and a stack of the test process then shows the
    /// missing entry.
    ///
    /// - Parameter condition: Tells whether the counts are the counts that
    ///   the test waits for.
    public func waitUntil(_ condition: @escaping @Sendable (Counts) -> Bool) async {
        guard !condition(counts) else { return }
        await withCheckedContinuation { continuation in
            waiters.append(Waiter(condition: condition, continuation: continuation))
        }
    }

    /// Resumes and removes each waiter whose condition holds now.
    private func resumeSatisfiedWaiters() {
        let now = counts
        let satisfied = waiters.filter { $0.condition(now) }
        waiters.removeAll { $0.condition(now) }
        for waiter in satisfied {
            waiter.continuation.resume()
        }
    }
}
