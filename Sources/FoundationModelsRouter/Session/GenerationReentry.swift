import Foundation
import Synchronization

/// A refusal to do work that would re-enter a session that is already mid-turn.
///
/// A tool body may generate on a different session over the same model: the
/// turn of the tool holds no generation place while the tool body runs, so
/// each pass of the nested turn takes its place in the queue of the model.
/// A tool body that asks its own session for a second turn or a fork is
/// refused, because ``RoutedSessionActor/turnLock`` is held for the whole
/// turn and is not lent. A transcript read from inside the session's own tool
/// call is served without the lock (see
/// ``RoutedSessionActor/isInsideOwnTurnToolCall``).
enum SessionReentryError: Error, Equatable, LocalizedError {
    /// A tool body of `sessionID`'s own turn asked that session for another turn.
    case sameSessionTurnInFlight(sessionID: ULID)

    /// A tool body of `sessionID`'s own turn asked that session to fork. The
    /// conversation state is half-written mid-turn, so a child cannot be seeded.
    case forkDuringSameSessionTurn(sessionID: ULID)

    /// A localized message that describes the error.
    var errorDescription: String? {
        switch self {
        case .sameSessionTurnInFlight(let sessionID):
            return """
                Session \(sessionID) is already running a turn that invoked this tool, so it \
                cannot run another one. Generate on a different session over the same model \
                instead.
                """
        case .forkDuringSameSessionTurn(let sessionID):
            return """
                Session \(sessionID) is running a turn that invoked this tool, so its \
                conversation state is half-written and cannot be forked. Fork before the turn \
                starts, or fork a different session over the same model.
                """
        }
    }
}

/// The mark of one model call of a session, published to the tasks of that
/// call as a task local.
///
/// A turn holds no generation place outside its passes, so the mark lends
/// nothing. It says which session the model call belongs to, and whether that
/// call is still open. The model is suspended in a tool call whenever a tool
/// body runs in the call, so "in the open model call of this session" is "in a
/// tool call of this session's own turn". ``RoutedSessionActor`` reads the
/// mark to refuse a turn or a fork that a tool asks of the same session, whose
/// turn holds ``RoutedSessionActor/turnLock``, and to serve a transcript read
/// from inside that tool call without the lock.
///
/// ``RoutedSessionActor/runCancellableModelCall(composedPrompt:_:)`` binds
/// one mark around each model call, and closes it (``close()``) when the call
/// returns. A task that outlives the call is then in no model call. A declared
/// background run gets a closed mark of the same session
/// (``withBackgroundRunMark(_:)``): it runs beside the call, not in it.
final class ModelCallMark: Sendable {
    /// The mark bound to the current task, or `nil` outside any model call. A
    /// task that inherits no task-locals does not see it.
    @TaskLocal static var current: ModelCallMark?

    /// The identity of the session whose model call this is.
    let sessionID: ULID

    /// Whether the model call is still in flight.
    private let isOpen: Atomic<Bool>

    /// Creates the mark of one model call. The mark is open.
    ///
    /// - Parameter sessionID: The identity of the session whose model call
    ///   this is.
    init(sessionID: ULID) {
        self.sessionID = sessionID
        isOpen = Atomic(true)
    }

    /// Creates a closed mark of the session that `call` belongs to.
    ///
    /// - Parameter call: The mark of the model call a background run started
    ///   from.
    private init(backgroundRunOf call: ModelCallMark) {
        sessionID = call.sessionID
        isOpen = Atomic(false)
    }

    /// Whether this is the mark of a model call of `sessionID` that is still
    /// in flight.
    ///
    /// - Parameter sessionID: The session the caller asks about.
    /// - Returns: `true` when the model call belongs to that session and has
    ///   not returned.
    func isOpenModelCall(of sessionID: ULID) -> Bool {
        sessionID == self.sessionID && isOpen.load(ordering: .acquiring)
    }

    /// Ends the mark, so nothing that outlives the model call is in that call.
    func close() {
        isOpen.store(false, ordering: .releasing)
    }

    /// Runs `body`, the body of a declared background run, under a closed mark
    /// of the session whose model call started the run. Outside any model call
    /// there is no mark, and `body` runs with none.
    ///
    /// The run keeps the session, so a turn it asks of that session is refused
    /// with a clear error: the turn that started the run can still hold the
    /// turn lock, and a turn parked on it would stall without a sound. The run is no tool call the model is
    /// suspended in, so a transcript read or a fork of that session waits for
    /// the turn lock.
    ///
    /// - Parameter body: The work of the background run.
    /// - Returns: Whatever `body` returns.
    static func withBackgroundRunMark<T>(_ body: () async -> T) async -> T {
        await $current.withValue(current.map(ModelCallMark.init(backgroundRunOf:))) {
            await body()
        }
    }
}
