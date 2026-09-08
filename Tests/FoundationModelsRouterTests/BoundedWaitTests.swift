import Testing

@testable import FoundationModelsRouter

@Suite("BoundedWait ends every wait on a wall clock, never on a count of scheduler hops")
struct BoundedWaitTests {
    /// The share of ``BoundedWait/ceilingNanoseconds`` that passes before the
    /// late change below lands: one part in this many.
    ///
    /// Ten leaves the delay long past any run of scheduler hops a test orders a
    /// state change behind, and well inside the ceiling, whatever the ceiling
    /// becomes. A wait that counts hops gives up inside this span on a loaded
    /// machine; a wait that reads a clock does not.
    static let lateChangeCeilingDivisor: UInt64 = 10

    /// How long the late change below makes its waiter wait, on the clock the
    /// wait reads.
    static let lateChangeDelay: Duration = .nanoseconds(BoundedWait.ceilingNanoseconds / lateChangeCeilingDivisor)

    /// The decision this test records: it must survive a starved process.
    ///
    /// This suite exists to prove the wait is proof against load, so the premise
    /// of the test — the late change lands inside the ceiling — cannot itself
    /// rest on the scheduler. A first version signalled a semaphore from a second
    /// task after a `Task.sleep`, and a process starved for longer than the
    /// ceiling failed it: the sleep expired on time, but the task that signals
    /// got no thread before the deadline, so the wait correctly reported that no
    /// signal came. Moving that sleep onto the clock the wait reads does not
    /// change this, because no clock can give a second task a thread.
    ///
    /// So the late change is a reading of the clock the wait reads, made inside
    /// the wait's own condition. ``BoundedWait/spin(until:)`` reads the condition
    /// before it reads the deadline on every turn, so a turn that runs late still
    /// observes the change, however late it runs. The ceiling is what it always
    /// was; nothing here is raised to cover the cause.
    @Test("a change that lands late in wall-clock terms is still observed")
    func aLateChangeIsStillObserved() async {
        let landsAt = ContinuousClock.now.advanced(by: Self.lateChangeDelay)

        #expect(await BoundedWait.conditionReached("the late change", when: { ContinuousClock.now >= landsAt }))
    }

    @Test("a condition that never holds ends the wait, and never before a late change would have landed")
    func aConditionThatNeverHoldsEndsTheWaitAndNamesItself() async {
        let label = "the state change nothing ever makes"
        let started = ContinuousClock.now

        await withKnownIssue {
            #expect(await BoundedWait.conditionReached(label, when: { false }) == false)
        } matching: { issue in
            issue.comments.contains { $0.description.contains(label) }
        }

        #expect(started.duration(to: .now) >= Self.lateChangeDelay)
    }
}
