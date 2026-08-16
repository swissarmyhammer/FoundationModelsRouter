import Foundation
import Synchronization

/// A refusal to start a turn that would re-enter a session already mid-turn.
///
/// The router admits one kind of re-entry and refuses the other. A tool body
/// that generates on a **different** session over the same resident model runs
/// on the permit its caller's turn already holds (see ``GenerationPermitLoan``)
/// — nothing about that is unsound, because the caller's own generation is
/// suspended in the tool for the whole of it. A tool body that generates on
/// **its own** session is a different thing: that session's
/// ``RoutedSessionActor/turnLock`` is the correctness gate, held for the whole
/// turn so a session never has two turns writing one transcript, and it is not
/// lent to anybody. Before this error existed such a call simply parked on that
/// lock and never came back.
public enum SessionReentryError: Error, Equatable, LocalizedError {
    /// A tool body of `sessionID`'s own turn asked that same session for
    /// another turn.
    case sameSessionTurnInFlight(sessionID: ULID)

    /// A localized message describing what error occurred, for `LocalizedError`
    /// conformance.
    public var errorDescription: String? {
        switch self {
        case .sameSessionTurnInFlight(let sessionID):
            return """
                Session \(sessionID) is already running a turn that invoked this tool, so it \
                cannot run another one. Generate on a different session over the same model \
                instead.
                """
        }
    }
}

/// The generation permit a turn in flight holds, published to that turn's model
/// call as a task local so work the model starts can tell that the model is
/// already suspended on this session's behalf.
///
/// This is what makes a nested generation legal. The per-model
/// ``RoutedModel/generationGate`` is a throughput gate, not a safety one, and
/// it holds one permit for a whole turn — tool calls included. So a tool body
/// that generates on a second session over the same resident container used to
/// wait for a permit that only came back when the outer turn ended, and the
/// outer turn could not end until the tool returned (task ^1zt7vyg). A nested
/// generation is not a concurrent generation: the outer turn is suspended in
/// the tool, so one generation runs at a time, which is the same argument
/// ``RoutedSession/awaitingUser(_:)`` already makes for a wait on a person.
///
/// The loan is read, never spent. A borrowing turn takes no permit and returns
/// none — ``RoutedSessionActor/endTurn()`` signals only for a turn that really
/// holds one — so the gate's count is exactly what it was before the nested
/// turn ran. `AsyncSemaphore` has no ceiling to absorb a stray `signal()`, and
/// this design never issues one.
///
/// Two conditions have to hold together before a permit is lent, and both can
/// change during the model call:
///
/// - The lender still **holds** its permit. A turn parked in
///   ``RoutedSession/awaitingUser(_:)`` has handed its permit back, so there is
///   nothing to lend and a nested turn queues for one of its own.
/// - The lender is **inside a tool call it is awaiting**. That is what says the
///   model is suspended. The tool wrapping layers mark that window (see
///   ``withGenerationSuspendedForToolCall(_:)``); a run that detaches leaves it,
///   so background work a tool started cannot borrow a permit and generate
///   beside the turn that started it.
///
/// The one window this does not close: a detaching tool whose body starts a
/// nested generation inside the wait window and then detaches keeps its borrow
/// until that generation ends, so the two can overlap for that stretch. The
/// count stays exact, and the forfeit is the serialization only — the same
/// trade ``RoutedSession/awaitingUser(_:)`` records for a wait that overlaps a
/// turn it is not part of.
final class GenerationPermitLoan: Sendable {
    /// The loan bound to the current task, or `nil` outside any turn's model
    /// call — including inside a detached task started under one, which does
    /// not inherit task locals.
    @TaskLocal static var current: GenerationPermitLoan?

    /// The gate the lending turn's permit came from.
    ///
    /// Compared by identity: two handles over one pooled entry share one
    /// semaphore instance, and that shared instance is the whole reason a
    /// nested generation contends at all.
    private let gate: AsyncSemaphore

    /// The lending session's identity, which is what tells a re-entry onto the
    /// same session from a nested generation on a different one.
    let sessionID: ULID

    /// What can change while the model call runs, guarded as a unit so a read
    /// never sees half of a state change.
    private struct State {
        /// Whether the lending turn holds its permit right now.
        var holdsPermit: Bool

        /// How many tool calls the lending turn is awaiting.
        var toolCallDepth: Int
    }

    private let state: Mutex<State>

    /// Creates the loan for one model call.
    ///
    /// - Parameters:
    ///   - gate: The gate the lending turn's permit came from.
    ///   - sessionID: The lending session's identity.
    ///   - holdsPermit: Whether that turn holds a permit as the call begins. A
    ///     turn that itself borrowed one passes `true`: the permit exists, it
    ///     just belongs to a turn further out, and a tool of this turn may
    ///     nest on it exactly the same way.
    init(gate: AsyncSemaphore, sessionID: ULID, holdsPermit: Bool) {
        self.gate = gate
        self.sessionID = sessionID
        self.state = Mutex(State(holdsPermit: holdsPermit, toolCallDepth: 0))
    }

    /// Whether a turn over `gate` may run on this loan's permit instead of
    /// waiting for one of its own.
    ///
    /// - Parameter gate: The gate the asking turn would otherwise wait on.
    /// - Returns: `true` when this loan covers that gate and the lender is
    ///   suspended in a tool call while holding its permit.
    func lends(over gate: AsyncSemaphore) -> Bool {
        guard gate === self.gate else { return false }
        return state.withLock { $0.holdsPermit && $0.toolCallDepth > 0 }
    }

    /// Records whether the lending turn holds its permit.
    ///
    /// - Parameter holdsPermit: `true` once the turn has a permit, `false`
    ///   while it has handed one back.
    func setHoldsPermit(to holdsPermit: Bool) {
        state.withLock { $0.holdsPermit = holdsPermit }
    }

    /// Records that the lending turn has begun awaiting one more tool call.
    func enterToolCall() {
        state.withLock { $0.toolCallDepth += 1 }
    }

    /// Records that one tool call the lending turn was awaiting has ended.
    func leaveToolCall() {
        state.withLock { $0.toolCallDepth -= 1 }
    }

    /// Ends the loan, so nothing that outlives the model call can borrow on it.
    ///
    /// A detached run keeps the task local it inherited long after its turn's
    /// model call returned. Closing the loan rather than trusting that
    /// reference to go away is what keeps such a run out of the gate's
    /// bypass.
    func close() {
        state.withLock {
            $0.holdsPermit = false
            $0.toolCallDepth = 0
        }
    }
}

/// Runs `body` with the enclosing turn's generation permit marked lendable —
/// the tool-call window ``GenerationPermitLoan`` reads.
///
/// The tool wrapping layers call this around the await that actually suspends
/// the model, and never around work that continues after a call detaches: the
/// mark says "the model is suspended waiting for this", which stops being true
/// the moment the wrapper hands a pending envelope back and the turn resumes.
///
/// Outside any model call there is no loan to mark, and `body` simply runs.
///
/// - Parameter body: The awaited tool work.
/// - Returns: Whatever `body` returns.
/// - Throws: Rethrows any error thrown by `body`.
func withGenerationSuspendedForToolCall<T>(_ body: () async throws -> T) async rethrows -> T {
    guard let loan = GenerationPermitLoan.current else {
        return try await body()
    }
    loan.enterToolCall()
    defer { loan.leaveToolCall() }
    return try await body()
}
