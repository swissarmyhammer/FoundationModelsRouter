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

/// The mark of one model call of a turn in flight, published to that model
/// call as a task local.
///
/// A turn holds no generation place outside its passes, so the mark lends
/// nothing. It says which session the model call belongs to, and whether that
/// call is suspended in a tool call. ``RoutedSessionActor`` reads it to refuse
/// a turn or a fork that a tool asks of the same session, whose turn holds
/// ``RoutedSessionActor/turnLock``, and to serve a transcript read from inside
/// that tool call without the lock.
///
/// A ``Window/toolCall`` is the in-band await the model is suspended on, and
/// ``withGenerationLent(across:_:)`` opens it. Once the model call returns,
/// the mark is closed (``close()``), so a run that outlives the call is not in
/// a tool call of the turn. Task ^44y6ba4 replaces this type with a lighter
/// task local.
final class GenerationPermitLoan: Sendable {
    /// The mark bound to the current task, or `nil` outside any turn's model
    /// call. A task that inherits no task-locals does not see it.
    @TaskLocal static var current: GenerationPermitLoan?

    /// The kind of window a turn opens on its mark.
    enum Window: Sendable {
        /// An in-band tool call the turn is awaiting: the model is suspended.
        case toolCall
    }

    /// The identity of the session whose model call this is.
    let sessionID: ULID

    /// State that can change while the model call runs, guarded as a unit.
    private struct State {
        /// How many tool calls the turn is awaiting.
        var toolCallDepth = 0

        /// Whether the mark has been closed.
        var isClosed = false
    }

    /// The state, behind the lock that the tasks of the model call share.
    private let state = Mutex(State())

    /// Creates the mark for one model call.
    ///
    /// - Parameter sessionID: The identity of the session whose model call
    ///   this is.
    init(sessionID: ULID) {
        self.sessionID = sessionID
    }

    /// Whether the turn belongs to `sessionID` and is suspended in a tool
    /// call.
    ///
    /// - Parameter sessionID: The session the caller asks about.
    /// - Returns: `true` when this mark's turn is that session's own and is
    ///   awaiting a tool call.
    func isSuspendedInToolCall(ofSession sessionID: ULID) -> Bool {
        guard sessionID == self.sessionID else { return false }
        return state.withLock { !$0.isClosed && $0.toolCallDepth > 0 }
    }

    /// Records that the turn has opened one more `window`.
    ///
    /// - Parameter window: The kind of window that opened.
    func enter(_ window: Window) {
        switch window {
        case .toolCall: state.withLock { $0.toolCallDepth += 1 }
        }
    }

    /// Records that one `window` the turn had open has closed.
    ///
    /// - Parameter window: The kind of window that closed.
    func leave(_ window: Window) {
        switch window {
        case .toolCall: state.withLock { $0.toolCallDepth -= 1 }
        }
    }

    /// Ends the mark, so nothing that outlives the model call is in a tool
    /// call of the turn.
    func close() {
        state.withLock { $0.isClosed = true }
    }
}

/// Runs `body` inside a `window` of the enclosing model call's mark. Outside
/// any model call there is no mark, and `body` simply runs.
///
/// No generation place is lent across `body`: the turn holds none while its
/// tool runs. The name stays until task ^44y6ba4 replaces the mark.
///
/// - Parameters:
///   - window: The kind of window `body` runs inside.
///   - body: The work the window is open across.
/// - Returns: Whatever `body` returns.
/// - Throws: Rethrows any error thrown by `body`.
func withGenerationLent<T>(
    across window: GenerationPermitLoan.Window, _ body: () async throws -> T
) async rethrows -> T {
    guard let loan = GenerationPermitLoan.current else {
        return try await body()
    }
    loan.enter(window)
    defer { loan.leave(window) }
    return try await body()
}
