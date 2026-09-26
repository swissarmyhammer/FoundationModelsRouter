import Synchronization

/// One point in the life of a model call, as a ``GenerationPassObserver``
/// records it (tasks ^ake8sax and ^1psqdm9): the wait and the start of its
/// submission, and the start and the end of each pass inside it.
enum GenerationCallPhase: Sendable, Equatable {
    /// The submission of the call joined the queue of its model behind
    /// another item, because the worker runs a submission of another session.
    case submissionQueued

    /// The worker of the queue started the submission of the call. `at` is
    /// when it started.
    case submissionStarted(at: ContinuousClock.Instant)

    /// A pass of the running submission started. `at` is when it started.
    case passStarted(at: ContinuousClock.Instant)

    /// The pass ended.
    case passEnded

    /// The event that tells the consumer of the session about this phase, or
    /// `nil` for a phase the consumer does not see.
    ///
    /// Only ``submissionQueued`` gives an event:
    /// ``SessionEvent/submissionQueued(_:)`` with the id of the open
    /// submission. The start of a submission reaches the consumer through
    /// `RoutedSessionActor.submissionDidStart()`, not through a phase. A
    /// pass gives no event. A summarizer call of a compaction has no open
    /// submission, so its phases give no event.
    ///
    /// - Parameter submission: The id of the open submission of the session,
    ///   or `nil` when no submission is open.
    /// - Returns: The event, or `nil`.
    func sessionEvent(submission: SubmissionID?) -> SessionEvent? {
        switch self {
        case .submissionQueued:
            submission.map(SessionEvent.submissionQueued)
        case .submissionStarted, .passStarted, .passEnded:
            nil
        }
    }
}

/// A report of the model calls of a session: the wait and the start of each
/// submission, and the start and the end of each pass inside it
/// (`generation-queue.md`, section 5.6).
///
/// The submission of a call runs on a task that the worker of the queue
/// makes, and the SDK runs each pass below it, maybe on a task of its own. A
/// task-local that the session binds reaches neither of them. So the session
/// gives this observer to the per-session state of the wrapper of its backend
/// (``SessionLanguageModelState/reportPasses(to:)``), and the executor calls
/// it at the start and the end of each pass. The session itself calls it when
/// its submission waits for the worker, and when the worker starts it.
///
/// The calls are synchronous and never suspend, so they cannot delay a pass.
/// Each call appends one ``GenerationCallPhase`` under a lock, in the order of
/// the calls, and wakes the reader of the model call in flight. The session
/// actor takes the phases in that order (``takePhases()``) and turns them into
/// its own state: the stall watch and the events of its consumer.
final class GenerationPassObserver: Sendable {
    /// The phases not yet taken, and the wake of the model call in flight.
    private struct State {
        /// The phases the calls recorded and the session did not take yet, in
        /// the order of the calls.
        var pending: [GenerationCallPhase] = []

        /// The wake of the model call in flight: the id of that call and the
        /// continuation of its wake stream. `nil` between model calls.
        var wake: (callID: UInt64, continuation: AsyncStream<Void>.Continuation)?
    }

    /// The state, under one lock.
    private let state = Mutex(State())

    /// Records that the submission of the call waits behind another item.
    ///
    /// The caller is `RoutedSessionActor.run(_:on:reportingTo:onStart:)` (in
    /// `RoutedSessionActorTurnExecution.swift`), which
    /// ``RoutedSessionActor/runCancellableModelCall(composedPrompt:submittingTo:_:)``
    /// uses for each model call. It gives this method to
    /// ``GenerationQueue/submit(isolation:onQueued:_:)`` as `onQueued`, so the
    /// worker calls it only when the item must wait.
    func submissionQueued() {
        record(.submissionQueued)
    }

    /// Records that the worker of the queue started the submission now.
    ///
    /// The caller is `RoutedSessionActor.run(_:on:reportingTo:onStart:)` (in
    /// `RoutedSessionActorTurnExecution.swift`). It calls this method first in
    /// the body of the item that it gives to
    /// ``GenerationQueue/submit(isolation:onQueued:_:)``, so the call runs on
    /// the task of the worker when the submission starts.
    func submissionStarted() {
        record(.submissionStarted(at: ContinuousClock.now))
    }

    /// Records that a pass of the running submission started now.
    ///
    /// The caller is ``SessionLanguageModel/Executor/respond(to:model:streamingInto:)``,
    /// before the wrapped executor runs the pass.
    func passStarted() {
        record(.passStarted(at: ContinuousClock.now))
    }

    /// Records that the pass ended.
    ///
    /// The caller is ``SessionLanguageModel/Executor/respond(to:model:streamingInto:)``,
    /// in a `defer`, so every exit of the pass calls it.
    func passEnded() {
        record(.passEnded)
    }

    /// Appends `phase`, and wakes the reader of the model call in flight.
    ///
    /// - Parameter phase: The phase to record.
    private func record(_ phase: GenerationCallPhase) {
        let continuation = state.withLock { state in
            state.pending.append(phase)
            return state.wake?.continuation
        }
        continuation?.yield()
    }

    /// Takes every phase recorded since the last take, in the order of the
    /// calls.
    ///
    /// - Returns: The phases.
    func takePhases() -> [GenerationCallPhase] {
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
/// `LanguageModelSession` over a per-session ``SessionLanguageModel``.
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
