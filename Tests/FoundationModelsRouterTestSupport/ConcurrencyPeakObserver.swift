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
/// is the event that wakes the wait, so the wait needs no clock and no poll. A
/// cancel of the waiting task also ends the wait (rule T1).
public actor ConcurrencyPeakObserver {
    /// The counts of the observer at one time, as a waiting test reads them.
    public struct Counts: Sendable {
        /// How many bodies are inside the section.
        public let active: Int

        /// How many bodies entered the section over the whole run.
        public let entered: Int
    }

    /// How many bodies are inside the section now.
    private var active = 0

    /// The largest number of bodies that were inside the section at one time.
    public private(set) var maximumActive = 0

    /// How many bodies entered the section over the whole run.
    public private(set) var enteredCount = 0

    /// The counts that the waits read, and the tasks that wait for a
    /// condition that did not hold yet.
    private let waits = ConditionWaitList(Counts(active: 0, entered: 0))

    /// Creates an observer that has seen no bodies yet.
    public init() {}

    /// Records one body that enters the section, and resumes each waiter
    /// whose condition now holds.
    public func enter() {
        active += 1
        enteredCount += 1
        maximumActive = max(maximumActive, active)
        publishCounts()
    }

    /// Records one body that leaves the section, and resumes each waiter
    /// whose condition now holds.
    public func exit() {
        active -= 1
        publishCounts()
    }

    /// Waits until `condition` holds for the counts of this observer, or
    /// until the waiting task is cancelled.
    ///
    /// The wait reads the counts at once, and again after each entry and
    /// each exit. A body that never enters keeps the wait open until a cancel.
    /// Thus a test that has a failure event wraps this wait in
    /// `RecordedWaitResult.wait(for:endingOnEndOf:)`, which cancels it when
    /// the failure event comes first (rule T1).
    ///
    /// - Parameter condition: Tells whether the counts are the counts that
    ///   the test waits for.
    /// - Throws: `CancellationError` when the waiting task was cancelled
    ///   before the condition held.
    public func waitUntil(_ condition: @escaping @Sendable (Counts) -> Bool) async throws {
        try await waits.wait(until: condition)
    }

    /// Gives the counts now to the waits, which resumes each waiter whose
    /// condition now holds.
    private func publishCounts() {
        let now = Counts(active: active, entered: enteredCount)
        waits.update { $0 = now }
    }
}
