import Synchronization

/// One point in the life of a generation pass, as a
/// ``GenerationPassObserver`` records it (task ^ake8sax).
enum GenerationPassPhase: Sendable, Equatable {
    /// The pass joined the queue, because a pass of another session holds
    /// the place.
    case queued

    /// The pass took the place of the queue. `at` is when it took the place.
    /// `afterWait` is `true` when the pass joined the queue before it took
    /// the place, so the phase before this one was ``queued``.
    case started(at: ContinuousClock.Instant, afterWait: Bool)

    /// The pass left the queue: it gave its place back, or it left the wait
    /// with no place because its task was cancelled.
    case ended

    /// The event that tells the consumer of the session about this phase, or
    /// `nil` for a phase the consumer does not see.
    ///
    /// A pass that took a free place sends no event, so a consumer sees
    /// ``SessionEvent/passStarted`` only after a ``SessionEvent/passQueued``.
    var sessionEvent: SessionEvent? {
        switch self {
        case .queued:
            .passQueued
        case .started(_, let afterWait):
            afterWait ? .passStarted : nil
        case .ended:
            nil
        }
    }
}

/// A report of a backend's passes that the session of that backend installs
/// (`generation-queue.md`, section 2).
///
/// The wait for a queue place happens in the executor of the per-session
/// ``QueuedLanguageModel``, and not on the session actor. A task-local that the
/// session binds does not reach that executor through `LanguageModelSession`,
/// because the SDK can run the executor on another task. So the session gives
/// this observer to the per-session state of its wrapper
/// (``QueuedLanguageModelState/reportPasses(to:)``), and the executor calls it
/// at three points of each pass: the pass joins the queue, the pass takes the
/// place, and the pass leaves the queue.
///
/// The calls are synchronous and never suspend, so they cannot delay a pass.
/// Each call appends one ``GenerationPassPhase`` under a lock, in the order of
/// the calls, and wakes the reader of the model call in flight. The session
/// actor takes the phases in that order (``takePhases()``) and turns them into
/// its own state: the stall watch and the events of its consumer.
final class GenerationPassObserver: Sendable {
    /// The phases not yet taken, and the wake of the model call in flight.
    private struct State {
        /// The phases the executor recorded and the session did not take yet,
        /// in the order of the calls.
        var pending: [GenerationPassPhase] = []

        /// Whether the pass in flight joined the queue and did not take the
        /// place yet.
        var isWaiting = false

        /// The wake of the model call in flight: the id of that call and the
        /// continuation of its wake stream. `nil` between model calls.
        var wake: (callID: UInt64, continuation: AsyncStream<Void>.Continuation)?
    }

    /// The state, under one lock.
    private let state = Mutex(State())

    /// Records that the pass joined the queue.
    func passQueued() {
        record { state in
            state.isWaiting = true
            return .queued
        }
    }

    /// Records that the pass took the place of the queue now.
    func passStarted() {
        let now = ContinuousClock.now
        record { state in
            defer { state.isWaiting = false }
            return .started(at: now, afterWait: state.isWaiting)
        }
    }

    /// Records that the pass left the queue.
    func passEnded() {
        record { state in
            state.isWaiting = false
            return .ended
        }
    }

    /// Appends the phase `makePhase` gives, and wakes the reader of the model
    /// call in flight.
    ///
    /// - Parameter makePhase: Updates the state and gives the phase, under the
    ///   lock.
    private func record(_ makePhase: (inout State) -> GenerationPassPhase) {
        let continuation = state.withLock { state in
            state.pending.append(makePhase(&state))
            return state.wake?.continuation
        }
        continuation?.yield()
    }

    /// Takes every phase recorded since the last take, in the order of the
    /// calls.
    ///
    /// - Returns: The phases.
    func takePhases() -> [GenerationPassPhase] {
        state.withLock { state in
            defer { state.pending.removeAll() }
            return state.pending
        }
    }

    /// Opens the wake stream of the model call `callID`, and drops each phase
    /// that no model call took: it belongs to a pass that no call watches.
    ///
    /// The stream gives one element after each recorded phase. Elements that
    /// the reader did not read yet merge into one, so the reader takes every
    /// phase of the merged elements in one ``takePhases()``.
    ///
    /// - Parameter callID: The id of the model call that reads the stream.
    /// - Returns: The wake stream. It finishes at ``closeWakes(callID:)``.
    func openWakes(callID: UInt64) -> AsyncStream<Void> {
        let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let replaced = state.withLock { state in
            defer { state.wake = (callID, continuation) }
            state.pending.removeAll()
            return state.wake?.continuation
        }
        replaced?.finish()
        return stream
    }

    /// Finishes the wake stream of the model call `callID`, when that stream
    /// is still the open one.
    ///
    /// - Parameter callID: The id of the model call whose stream ends.
    func closeWakes(callID: UInt64) {
        let closed = state.withLock { state -> AsyncStream<Void>.Continuation? in
            guard let wake = state.wake, wake.callID == callID else { return nil }
            state.wake = nil
            return wake.continuation
        }
        closed?.finish()
    }
}

/// A session backend whose passes the session can observe: it runs its
/// `LanguageModelSession` over a per-session ``QueuedLanguageModel``.
///
/// ``MLXFoundationModelsSessionBackend`` conforms. A backend with no executor
/// seam does not conform, and its session sees no pass.
protocol GenerationPassReporting: AnyObject {
    /// Gives `observer` the passes of this backend from now on.
    ///
    /// - Parameter observer: The observer of the session that owns this
    ///   backend.
    func reportPasses(to observer: GenerationPassObserver)
}
