import Synchronization

/// A resume-exactly-once rendezvous for a race whose competitors, and the
/// racer's own cancellation, can arrive in any order, also before the
/// continuation exists. The first of ``register(continuation:)`` and
/// ``resume(with:)`` records; the other resumes; every later call is a no-op.
final class RaceGate<Value: Sendable>: Sendable {
    /// This gate's state machine.
    private enum State {
        /// Neither ``register(continuation:)`` nor ``resume(with:)`` has run yet.
        case awaitingContinuation

        /// ``register(continuation:)`` ran first; this is the recorded continuation.
        case continuationRegistered(CheckedContinuation<Value, Never>)

        /// ``resume(with:)`` ran first; this is the value the registration resumes with.
        case resolvedBeforeContinuation(Value)

        /// The continuation has been resumed; every further call is a no-op.
        case resumed
    }

    /// The gate's state, guarded for the racing callers.
    private let state = Mutex<State>(.awaitingContinuation)

    /// Registers the continuation to resume, resuming it immediately when a
    /// competitor already resolved the race.
    /// - Parameter continuation: The continuation to resume exactly once.
    func register(continuation: CheckedContinuation<Value, Never>) {
        let immediateValue: Value? = state.withLock { current in
            switch current {
            case .awaitingContinuation:
                current = .continuationRegistered(continuation)
                return nil
            case .resolvedBeforeContinuation(let value):
                current = .resumed
                return value
            case .continuationRegistered, .resumed:
                return nil
            }
        }
        if let immediateValue {
            continuation.resume(returning: immediateValue)
        }
    }

    /// Resolves the race with `value`: resumes the registered continuation,
    /// records the value for a registration still to come, or no-ops when
    /// the race is already resolved.
    ///
    /// - Parameter value: The competitor's value.
    func resume(with value: Value) {
        let continuation: CheckedContinuation<Value, Never>? = state.withLock { current in
            switch current {
            case .awaitingContinuation:
                current = .resolvedBeforeContinuation(value)
                return nil
            case .continuationRegistered(let registered):
                current = .resumed
                return registered
            case .resolvedBeforeContinuation, .resumed:
                return nil
            }
        }
        continuation?.resume(returning: value)
    }
}
