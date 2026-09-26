/// Thrown by ``AwaitedCondition/wait(until:)`` when the wait ended before the
/// state held, which happens only when the waiting task was cancelled — so the
/// test that caught it stops there instead of asserting on a state that never
/// came.
struct ConditionNeverHeld: Error {}

/// A state a test waits for when the code under test sends no event for it: a
/// reading asked again and again, with no deadline of its own.
///
/// ``AwaitedEvent`` is the first choice. Use this type only for a state that
/// no event names, such as a count that a submission changes when it joins a
/// list. ``BoundedWait`` asks the same kind of question, but its wall clock
/// then decides the result, so a machine busy enough to delay the change past
/// that clock turns a correct test red for want of CPU. Here the wait ends
/// when the state holds and on nothing else: a loaded machine makes the wait
/// longer and never wrong.
///
/// What ends a wait whose state never holds — the regression a test exists to
/// catch — is the `.timeLimit` trait on the test. The trait cancels the test,
/// and ``wait(until:)`` then stops reading and throws.
enum AwaitedCondition {
    /// Waits until `condition` holds, reading it as
    /// ``BoundedWait/poll(until:givingUpWhen:)`` does, and stopping only when
    /// the waiting task is cancelled.
    ///
    /// - Parameter condition: The state to wait for.
    /// - Throws: ``ConditionNeverHeld`` when the waiting task was cancelled
    ///   before the state held.
    static func wait(until condition: @Sendable () async -> Bool) async throws {
        guard await BoundedWait.poll(until: condition, givingUpWhen: { Task.isCancelled }) else {
            throw ConditionNeverHeld()
        }
    }
}
