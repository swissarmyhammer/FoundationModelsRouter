import Testing

/// Holds ``AwaitedCondition`` to the three properties every wait built on it
/// rests on: a state that already holds ends the wait at once, a state that
/// holds only after the ceiling of ``BoundedWait`` is still observed, and a
/// cancelled wait ends rather than reading a state that never changes.
///
/// The second is the difference from ``BoundedWait``: no clock ends this wait,
/// so a loaded machine makes it longer and never wrong. The third is what lets
/// a `.timeLimit` trait end a test whose state never holds.
///
/// `.timeLimit` here for the same reason: a regression in the type under test
/// would otherwise read a state forever and hang the whole run.
@Suite("AwaitedCondition ends a wait on the state itself, never on a clock", .timeLimit(.minutes(1)))
struct AwaitedConditionTests {
    /// How long after the ceiling of ``BoundedWait`` the late state holds: one
    /// second, so a wait that still gave up on that ceiling fails this suite.
    private static let pastTheBoundedCeiling = Duration.nanoseconds(BoundedWait.ceilingNanoseconds) + .seconds(1)

    @Test("a state that already holds ends the wait at once")
    func aStateThatAlreadyHoldsEndsTheWait() async {
        await #expect(throws: Never.self) { try await AwaitedCondition.wait(until: { true }) }
    }

    /// The late state is a reading of the clock, made inside the condition,
    /// for the reason `BoundedWaitTests` gives: a second task that makes the
    /// change could get no thread on a loaded machine, and the test would then
    /// read the load rather than the wait.
    @Test("a state that holds only after the ceiling of BoundedWait is still observed")
    func aStateThatHoldsPastTheBoundedCeilingIsObserved() async {
        let holdsAt = ContinuousClock.now.advanced(by: Self.pastTheBoundedCeiling)

        await #expect(throws: Never.self) {
            try await AwaitedCondition.wait(until: { ContinuousClock.now >= holdsAt })
        }
        #expect(ContinuousClock.now >= holdsAt)
    }

    @Test("a wait its own task cancels ends, rather than reading a state that never changes")
    func aCancelledWaitEnds() async throws {
        let reading = AwaitedEvent()
        let waiter = Task {
            try await AwaitedCondition.wait(until: {
                reading.signal()
                return false
            })
        }

        try await reading.wait()
        waiter.cancel()

        await #expect(throws: ConditionNeverHeld.self) { try await waiter.value }
    }
}
