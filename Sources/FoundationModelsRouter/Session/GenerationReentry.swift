import Foundation
import Synchronization

/// The queue that one submission goes to, and the model whose queue it is
/// (`generation-queue.md`, section 5.5, rule 2).
///
/// A ``ModelCallMark`` names the target of its submission, so the queue can
/// refuse a submission from inside an open submission on itself, and the
/// refusal can name the model.
struct SubmissionTarget: Sendable {
    /// The queue of the model.
    let queue: GenerationQueue

    /// The model whose queue ``queue`` is.
    let model: ModelRef
}

/// The mark of one model call of a session, published to the tasks of that
/// call as a task local.
///
/// The mark says which session the model call belongs to, whether that call
/// is still open, and the queue of its submission. The model is suspended in
/// a tool call whenever a tool body runs in the call, so "in the open model
/// call of this session" is "in a tool call of this session's own
/// submission". ``RoutedSessionActor`` reads the mark to refuse at once a
/// wait for an answer of the same session, which could come only after the
/// submission that waits for the tool (`generation-queue.md`, section 5.5,
/// rule 2), and to take a settled transcript at a tool-result boundary of its
/// own open model call. ``GenerationQueue`` reads it to refuse a submission
/// from inside an open submission on itself.
///
/// ``RoutedSessionActor/runCancellableModelCall(composedPrompt:submittingTo:_:)``
/// binds one mark around each model call, on the task that runs the
/// submission, and closes it (``close()``) when the call returns. A task that
/// outlives the call is then in no model call. A declared background run gets
/// a closed mark of the same session (``withBackgroundRunMark(_:)``): it runs
/// beside the call, not in it.
final class ModelCallMark: Sendable {
    /// The mark bound to the current task, or `nil` outside any model call. A
    /// task that inherits no task-locals does not see it.
    @TaskLocal static var current: ModelCallMark?

    /// The identity of the session whose model call this is.
    let sessionID: ULID

    /// The queue the submission of this model call went to, and its model, or
    /// `nil` when the backend of the call has no queue.
    let submission: SubmissionTarget?

    /// Whether the model call is still in flight.
    private let isOpen: Atomic<Bool>

    /// Creates the mark of one model call. The mark is open.
    ///
    /// - Parameters:
    ///   - sessionID: The identity of the session whose model call this is.
    ///   - submission: The queue the submission of the call goes to, and its
    ///     model, or `nil` (the default) when the call has no queue.
    init(sessionID: ULID, submission: SubmissionTarget? = nil) {
        self.sessionID = sessionID
        self.submission = submission
        isOpen = Atomic(true)
    }

    /// Creates a closed mark of the session and the submission that `call`
    /// belongs to.
    ///
    /// - Parameter call: The mark of the model call a background run started
    ///   from.
    private init(backgroundRunOf call: ModelCallMark) {
        sessionID = call.sessionID
        submission = call.submission
        isOpen = Atomic(false)
    }

    /// Whether the model call is still in flight.
    private var isInFlight: Bool {
        isOpen.load(ordering: .acquiring)
    }

    /// Whether this is the mark of a model call of `sessionID` that is still
    /// in flight.
    ///
    /// - Parameter sessionID: The session the caller asks about.
    /// - Returns: `true` when the model call belongs to that session and has
    ///   not returned.
    func isOpenModelCall(of sessionID: ULID) -> Bool {
        sessionID == self.sessionID && isInFlight
    }

    /// The target of this mark's submission, when that submission went to
    /// `queue` and is still open.
    ///
    /// - Parameter queue: The queue a new submission goes to.
    /// - Returns: The target, whose model names the queue, or `nil` when this
    ///   mark is closed or its submission went to another queue or to none.
    func openSubmission(on queue: GenerationQueue) -> SubmissionTarget? {
        guard let submission, submission.queue === queue, isInFlight else { return nil }
        return submission
    }

    /// Ends the mark, so nothing that outlives the model call is in that call.
    func close() {
        isOpen.store(false, ordering: .releasing)
    }

    /// Runs `body`, the body of a declared background run, under a closed mark
    /// of the session whose model call started the run. Outside any model call
    /// there is no mark, and `body` runs with none.
    ///
    /// The run keeps the session, but the mark is closed, so the run is in no
    /// model call. An answer it asks of that session is not refused: its
    /// message waits for a later submission of the session. A transcript read
    /// or a fork of that session gets the settled transcript at once, as from
    /// any other task. The queue does not refuse a submission of the run
    /// either: the run does not hold the worker of its model. Without this
    /// wrap, the run inherits the OPEN mark of the call, and each of those
    /// legal waits is refused.
    ///
    /// - Parameter body: The work of the background run.
    /// - Returns: Whatever `body` returns.
    static func withBackgroundRunMark<T>(_ body: () async -> T) async -> T {
        await $current.withValue(current.map(ModelCallMark.init(backgroundRunOf:))) {
            await body()
        }
    }
}
