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
public actor ConcurrencyPeakObserver {
    /// How many bodies are inside the section now.
    private var active = 0

    /// The largest number of bodies that were inside the section at one time.
    public private(set) var maximumActive = 0

    /// How many bodies entered the section over the whole run.
    public private(set) var enteredCount = 0

    /// Creates an observer that has seen no bodies yet.
    public init() {}

    /// Records one body that enters the section.
    public func enter() {
        active += 1
        enteredCount += 1
        maximumActive = max(maximumActive, active)
    }

    /// Records one body that leaves the section.
    public func exit() {
        active -= 1
    }
}
