import FoundationModelsExtras
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

    /// The running pass gave its first output token: the first text of its
    /// reasoning, of its response or of its tool-call arguments. `at` is when
    /// the session saw it. A pass reports it at most one time, and a pass
    /// that gives no output reports it never.
    case firstOutput(at: ContinuousClock.Instant)

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
        case .submissionStarted, .passStarted, .passEnded, .firstOutput:
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

        /// The number of passes that started and did not end yet.
        var openPasses = 0
    }

    /// The state, under one lock.
    private let state = Mutex(State())

    /// The clock of the stall watch of the session: the instants of the
    /// phases that this observer records, the instants that the session reads
    /// for its watch, and the sleep of the timer of the watch.
    ///
    /// The session gives the clock of its run plane (`RunPlane.clock`), so one
    /// clock drives the stall watch and the timers of the runs. The observer
    /// holds the clock because it records instants from tasks outside the
    /// session actor. One clock for both gives instants that agree.
    let clock: any RunClock

    /// Makes an observer with no phase and no wake.
    ///
    /// - Parameter clock: The clock of the instants and of the timer of the
    ///   stall watch. The default is the real time.
    init(clock: any RunClock = ContinuousRunClock()) {
        self.clock = clock
    }

    /// Reports each phase that a call records.
    ///
    /// ``record(_:)`` signals it after the phase is in the pending list and
    /// after it wakes the reader of the model call. Only the tests read it: a
    /// test reads the state of the session again after each recorded phase,
    /// for example until the pass before a tool body ended. The session
    /// itself reads the phases through ``takePhases()``.
    let phaseChanges = ChangeSignal()

    /// Reports each end of a pass. ``awaitNoOpenPass()`` waits on it.
    ///
    /// It reports each change of its waiters (``ChangeSignal/waiterChanges``),
    /// so a test can wait until a close of the session waits for an open pass.
    let passEnds = ChangeSignal(observingWaiters: true)

    /// The number of passes that started and did not end yet.
    var openPassCount: Int {
        state.withLock { $0.openPasses }
    }

    /// Records that the submission of the call waits behind another item.
    ///
    /// The caller is `RoutedSessionActor.run(_:on:reportingTo:onStart:)` (in
    /// `RoutedSessionActorAnswerExecution.swift`), which
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
    /// `RoutedSessionActorAnswerExecution.swift`). It calls this method first in
    /// the body of the item that it gives to
    /// ``GenerationQueue/submit(isolation:onQueued:_:)``, so the call runs on
    /// the task of the worker when the submission starts.
    func submissionStarted() {
        record(.submissionStarted(at: clock.now))
    }

    /// Records that a pass of the running submission started now.
    ///
    /// The caller is ``SessionLanguageModel/Executor/respond(to:model:streamingInto:)``,
    /// before the wrapped executor runs the pass.
    func passStarted() {
        state.withLock { $0.openPasses += 1 }
        record(.passStarted(at: clock.now))
    }

    /// Records that the pass ended, and signals ``passEnds``.
    ///
    /// The caller is ``SessionLanguageModel/Executor/respond(to:model:streamingInto:)``,
    /// in a `defer`, so every exit of the pass calls it. The pass watches of
    /// the pass ended before this call.
    func passEnded() {
        state.withLock { $0.openPasses -= 1 }
        record(.passEnded)
        passEnds.signal()
    }

    /// Records that the running pass gave its first output token now.
    ///
    /// The caller is the first-output watch of the backend of the session
    /// (`MLXFoundationModelsSessionBackend`), which reads the transcript of
    /// its session inside each pass and calls this method at the first read
    /// that holds more output text than the pass started with.
    func passProducedOutput() {
        record(.firstOutput(at: clock.now))
    }

    /// Waits until no pass is open, or until the calling task is cancelled.
    ///
    /// The framework resumes a cancelled model call before its pass ends, and
    /// the pass runs on a task of the framework. While that pass runs, it
    /// keeps the model of the session. ``RoutedSessionActor/close()`` waits
    /// here, after the pump ended, so no pass of a stopped model call runs
    /// when close returns.
    ///
    /// The wait is ``ChangeSignal/waitUntil(isolation:_:)`` on ``passEnds``,
    /// so a pass end that comes between the read of the count and the wait
    /// is not lost.
    func awaitNoOpenPass() async {
        _ = await passEnds.waitUntil { openPassCount == 0 }
    }

    /// Appends `phase`, wakes the reader of the model call in flight, and
    /// signals ``phaseChanges``.
    ///
    /// - Parameter phase: The phase to record.
    private func record(_ phase: GenerationCallPhase) {
        let continuation = state.withLock { state in
            state.pending.append(phase)
            return state.wake?.continuation
        }
        continuation?.yield()
        phaseChanges.signal()
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
