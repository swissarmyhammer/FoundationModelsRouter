import Synchronization

/// A resume-exactly-once rendezvous for a race whose competitors — and the
/// racer's own cancellation — can arrive in any order, including before the
/// continuation racing them exists (the ported `CancellationGate`).
///
/// Whichever of ``register(continuation:)``'s continuation or the first
/// ``resume(with:)`` happens first, the other's eventual call is what
/// actually resumes the continuation; every later resume is a no-op.
///
/// Two races are built on it, and each needs exactly this shape — a
/// continuation-based race, deliberately not a task group, because a group
/// implicitly awaits every child before returning and so could never abandon
/// the loser:
///
/// - `ToolRun`'s per-call timeout, which races the wrapped tool's
///   completion against a timeout window that progress resets.
/// - ``RoutedSessionActor/respond(to:maxTokens:)``'s run-plane drain, which
///   races a background run's settlement against a cancellation reaching the
///   draining call.
final class RaceGate<Value: Sendable>: Sendable {
    /// This gate's state machine.
    private enum State {
        /// Neither ``register(continuation:)`` nor ``resume(with:)`` has run yet.
        case awaitingContinuation

        /// ``register(continuation:)`` ran first; this is the continuation it
        /// recorded.
        case continuationRegistered(CheckedContinuation<Value, Never>)

        /// ``resume(with:)`` ran first, before any continuation existed;
        /// this is the value the eventual registration resumes with.
        case resolvedBeforeContinuation(Value)

        /// The continuation has been resumed; every further call is a
        /// no-op.
        case resumed
    }

    /// The gate's state, guarded for the racing callers.
    private let state = Mutex<State>(.awaitingContinuation)

    /// Registers the continuation to resume, resuming it immediately when a
    /// competitor already resolved the race.
    ///
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
