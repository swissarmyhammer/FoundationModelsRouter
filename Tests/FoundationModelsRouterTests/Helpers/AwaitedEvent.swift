import Synchronization

/// Thrown by ``AwaitedEvent/wait()`` when the wait ended without the event,
/// which happens only when the waiting task was cancelled — so the test that
/// caught it stops there instead of asserting on something that never happened.
struct EventNeverArrived: Error {}

/// A one-shot event a test waits *on*, rather than polls a proxy of.
///
/// ``BoundedWait`` answers a different question. It asks a non-suspending
/// question again and again until a wall-clock ceiling says no. That ceiling is
/// then the measure of progress, so a machine busy enough to delay the work
/// under measurement past the ceiling turns a correct test red for want of CPU
/// (task ^q8cnmb2). Here the wait ends on the event and on nothing else: the
/// producer resumes the waiter, so a loaded machine makes the wait longer and
/// never wrong.
///
/// Nothing bounds that wait from the inside, and nothing should — an event that
/// never arrives is the regression a test exists to catch, and only the test
/// author knows how long the work is allowed to take. What ends such a wait is
/// the `.timeLimit` trait on the test, and ``wait()`` is written so that trait
/// can do its job: the suspension is cancellation-aware, so a cancelled test
/// unwinds here instead of hanging the whole run.
///
/// ``AsyncSemaphore`` cannot serve in its place, and must not be changed to.
/// Its ``AsyncSemaphore/wait()`` is documented as running to completion even
/// under cancellation, and the gates it guards depend on that: a permit an
/// acquire abandoned half way is a permit nothing ever gives back. So the two
/// are opposites rather than near neighbours — a counting FIFO gate that ignores
/// cancellation, and a latching one-shot that honours it. A test observing a
/// moment reaches for this type, and leaves the semaphore to the code under
/// test.
///
/// A `Mutex` rather than an `actor` for the reason ``AsyncSemaphore`` gives:
/// the check and the suspend have to be one step, or an event arriving between
/// them is lost. An actor would also make ``signal()`` `async`, and the
/// producers that reach it — a synchronous closure the model call runs, a
/// stream's termination handler — have no `await` to spend.
///
/// The one precondition is a single waiter: at most one task may be suspended in
/// ``wait()`` at a time. Every event a test uses this for — one producer naming
/// one moment, one test task watching for it — has exactly that shape.
final class AwaitedEvent: Sendable {
    /// What has happened to this event so far, as one value: the three states
    /// exclude one another, so no pair of them can disagree.
    private enum State {
        /// Nobody has sent the event, and nobody is waiting for it.
        case unsent

        /// A task is suspended in ``AwaitedEvent/wait()``, holding the
        /// continuation ``AwaitedEvent/signal()`` resumes.
        case waiting(CheckedContinuation<Bool, Never>)

        /// The event has been sent. It stays sent.
        case arrived
    }

    /// The state, guarded so that check-and-suspend is atomic.
    private let state = Mutex(State.unsent)

    /// Sends the event, resuming a suspended waiter if there is one.
    ///
    /// Idempotent: the event stays sent, so a ``wait()`` that comes afterwards
    /// returns at once rather than waiting for a second signal that never comes.
    func signal() {
        let waiter = state.withLock { state -> CheckedContinuation<Bool, Never>? in
            let resumable: CheckedContinuation<Bool, Never>?
            switch state {
            case .waiting(let continuation):
                resumable = continuation
            case .unsent, .arrived:
                resumable = nil
            }
            state = .arrived
            return resumable
        }
        waiter?.resume(returning: true)
    }

    /// Waits for the event.
    ///
    /// Returns as soon as the event has been sent, whether that happened before
    /// this call or while it was suspended. The continuation is resumed exactly
    /// once: the waiter is either resumed inside the lock's decision or enqueued
    /// there, never both.
    ///
    /// - Throws: ``EventNeverArrived`` when the waiting task was cancelled
    ///   before the event arrived.
    func wait() async throws {
        let arrived = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                let outcome = state.withLock { state -> Bool? in
                    switch state {
                    case .arrived:
                        return true
                    case .waiting:
                        preconditionFailure("AwaitedEvent allows a single waiter")
                    case .unsent:
                        // Read inside the lock, so a cancellation racing this
                        // call either loses the race and is answered here, or
                        // wins it and finds the continuation enqueued below.
                        if Task.isCancelled { return false }
                        state = .waiting(continuation)
                        return nil
                    }
                }
                if let outcome { continuation.resume(returning: outcome) }
            }
        } onCancel: {
            let waiter = state.withLock { state -> CheckedContinuation<Bool, Never>? in
                guard case .waiting(let continuation) = state else { return nil }
                state = .unsent
                return continuation
            }
            waiter?.resume(returning: false)
        }
        guard arrived else { throw EventNeverArrived() }
    }
}
