import Foundation
import Synchronization

/// A refusal to do work that would re-enter a session that is already mid-turn.
///
/// A tool body may generate on a different session over the same model; it
/// runs on the permit its caller's turn holds (see ``GenerationPermitLoan``).
/// A tool body that asks its own session for a second turn or a fork is
/// refused, because ``RoutedSessionActor/turnLock`` is held for the whole
/// turn and is not lent. A transcript read from inside the session's own tool
/// call is served without the lock (see
/// ``RoutedSessionActor/isInsideOwnTurnToolCall``).
public enum SessionReentryError: Error, Equatable, LocalizedError {
    /// A tool body of `sessionID`'s own turn asked that session for another turn.
    case sameSessionTurnInFlight(sessionID: ULID)

    /// A tool body of `sessionID`'s own turn asked that session to fork. The
    /// conversation state is half-written mid-turn, so a child cannot be seeded.
    case forkDuringSameSessionTurn(sessionID: ULID)

    /// A localized message that describes the error.
    public var errorDescription: String? {
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

/// The generation permit a turn in flight holds, published to that turn's model
/// call as a task local.
///
/// A nested generation from a tool body runs on this loan instead of a permit
/// of its own. The loan is read, never spent: a borrowing turn takes no permit
/// and returns none, so the gate's count does not change.
///
/// A permit is lent only while two conditions hold: the lender holds its
/// permit, and the lender has a ``Window`` open on the loan through
/// ``withGenerationLent(across:_:)``. A ``Window/toolCall`` is the in-band
/// await the model is suspended on. A ``Window/backgroundRun`` is the life of
/// a body a declared background tool started; it overlaps the turn. Once the
/// model call returns, the loan is closed (``close()``), and a run that
/// outlives it takes a permit of its own.
final class GenerationPermitLoan: Sendable {
    /// The loan bound to the current task, or `nil` outside any turn's model
    /// call. A task that inherits no task-locals does not see it.
    @TaskLocal static var current: GenerationPermitLoan?

    /// The two kinds of window a turn opens on its loan.
    enum Window: Sendable {
        /// An in-band tool call the turn is awaiting: the model is suspended.
        case toolCall

        /// The life of a body a declared background tool started: the turn is not suspended.
        case backgroundRun
    }

    /// The gate the lending turn's permit came from, compared by identity.
    private let gate: AsyncSemaphore

    /// The lending session's identity.
    let sessionID: ULID

    /// State that can change while the model call runs, guarded as a unit.
    private struct State {
        /// Whether the lending turn holds its permit right now.
        var holdsPermit: Bool

        /// How many tool calls the lending turn is awaiting.
        var toolCallDepth: Int

        /// How many background runs the lending turn started are still going.
        var backgroundRunCount: Int

        /// Whether the loan has been closed.
        var isClosed: Bool

        /// Whether any window is open on the loan.
        var hasOpenWindow: Bool {
            toolCallDepth > 0 || backgroundRunCount > 0
        }

        /// Moves the count of open `window`s by `delta`.
        mutating func adjustCount(of window: Window, by delta: Int) {
            switch window {
            case .toolCall: toolCallDepth += delta
            case .backgroundRun: backgroundRunCount += delta
            }
        }
    }

    private let state: Mutex<State>

    /// Creates the loan for one model call.
    ///
    /// - Parameters:
    ///   - gate: The gate the lending turn's permit came from.
    ///   - sessionID: The lending session's identity.
    ///   - holdsPermit: Whether that turn holds a permit as the call begins.
    ///     A turn that itself borrowed one passes `true`.
    init(gate: AsyncSemaphore, sessionID: ULID, holdsPermit: Bool) {
        self.gate = gate
        self.sessionID = sessionID
        self.state = Mutex(
            State(holdsPermit: holdsPermit, toolCallDepth: 0, backgroundRunCount: 0, isClosed: false))
    }

    /// Whether a turn over `gate` may run on this loan's permit.
    ///
    /// - Parameter gate: The gate the asking turn would otherwise wait on.
    /// - Returns: `true` when this loan covers that gate, is open, and the
    ///   lender holds its permit with a window open on it.
    func lends(over gate: AsyncSemaphore) -> Bool {
        guard gate === self.gate else { return false }
        return state.withLock { !$0.isClosed && $0.holdsPermit && $0.hasOpenWindow }
    }

    /// Whether the lending turn belongs to `sessionID` and is suspended in a
    /// tool call. The permit is not required. A ``Window/backgroundRun``
    /// does not count.
    ///
    /// - Parameter sessionID: The session the caller asks about.
    /// - Returns: `true` when this loan's turn is that session's own and is
    ///   awaiting a tool call.
    func isSuspendedInToolCall(ofSession sessionID: ULID) -> Bool {
        guard sessionID == self.sessionID else { return false }
        return state.withLock { !$0.isClosed && $0.toolCallDepth > 0 }
    }

    /// Records whether the lending turn holds its permit.
    func setHoldsPermit(to holdsPermit: Bool) {
        state.withLock { $0.holdsPermit = holdsPermit }
    }

    /// Records that the lending turn has opened one more `window`.
    func enter(_ window: Window) {
        state.withLock { $0.adjustCount(of: window, by: 1) }
    }

    /// Records that one `window` the lending turn had open has closed.
    func leave(_ window: Window) {
        state.withLock { $0.adjustCount(of: window, by: -1) }
    }

    /// Ends the loan, so nothing that outlives the model call can borrow on it.
    func close() {
        state.withLock {
            $0.holdsPermit = false
            $0.isClosed = true
        }
    }
}

/// Runs `body` with the enclosing turn's generation permit lent across
/// `window`. Outside any model call there is no loan, and `body` simply runs.
///
/// - Parameters:
///   - window: The kind of window `body` runs inside.
///   - body: The work the permit is lent across.
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
