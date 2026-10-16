import FoundationModelsExtras

/// The sessions whose own work the current task is (task ^3jpewc9).
///
/// A session binds this value around each model call that it submits, on the
/// task of the submission, as it binds the tool-result boundary
/// (`ToolResultAppendBoundary`). The SDK gives the value to each tool body that
/// it runs inside the call. A background run starts its body with `Task {}`
/// from inside the tool call, so the body of each run also has the value, and
/// so has each `Task {}` that a tool body or a run body starts. A task that
/// `Task.detached` starts does not get the value.
///
/// ``RoutedSession/close()`` reads it. Close waits for all work of the
/// session, and that work includes the caller when the caller is the own
/// work of the session. So for such a caller, close starts the close and
/// returns at once.
///
/// The value is a set, and the binding adds the id of its session to the set
/// that the task has: a task that runs the work of a session inside the work
/// of another session is the own work of both.
///
/// **Mail carries the value of its sender** (task ^hrkxav5). The pump of a
/// session is a detached task, so an answer gets no task-local of the caller
/// that sent its mail. So each mail records the value of its sender
/// (``SessionOutbox/noteCaller(_:for:)``), and each submission of the answer
/// that delivers the mail adds that value to its own binding
/// (``RoutedSessionActor/openAnswerCallerWork``). Thus
/// the answer of a child session that a tool of the parent asked for is the
/// own work of the child and also of the parent. A tool of the child that
/// closes the parent then does not wait for the tool of the parent, which
/// waits for the child. Mail from a host carries an empty set, and changes
/// nothing.
struct SessionOwnWork: Sendable {
    /// The own work of a task outside the work of each session: an empty
    /// set.
    static let none = SessionOwnWork(sessionIDs: [])

    /// The own work of the current task: ``none`` outside the work of a
    /// session.
    @TaskLocal static var current = none

    /// The ids of the sessions whose own work the task is.
    private let sessionIDs: Set<ULID>

    /// Whether the value names no session.
    var isEmpty: Bool {
        sessionIDs.isEmpty
    }

    /// Whether the task is the own work of the session of `sessionID`.
    ///
    /// - Parameter sessionID: The id of the session.
    /// - Returns: `true` when the task is the own work of that session.
    func contains(_ sessionID: ULID) -> Bool {
        sessionIDs.contains(sessionID)
    }

    /// The own work of each session of this value and of `other`.
    ///
    /// - Parameter other: The other value.
    /// - Returns: The union of the two sets.
    func union(_ other: SessionOwnWork) -> SessionOwnWork {
        SessionOwnWork(sessionIDs: sessionIDs.union(other.sessionIDs))
    }

    /// Runs `body` as the own work of the session of `sessionID`, of each
    /// session of `carried`, and also of each session whose own work the
    /// calling task is.
    ///
    /// - Parameters:
    ///   - sessionID: The id of the session.
    ///   - carried: The own work that the mail of the work carries from its
    ///     senders, or ``none``.
    ///   - body: The work.
    /// - Returns: What `body` returns.
    /// - Throws: What `body` throws.
    static func run<Result: Sendable>(
        as sessionID: ULID, carrying carried: SessionOwnWork, _ body: () async throws -> Result
    ) async throws -> Result {
        let work = current.union(carried).union(SessionOwnWork(sessionIDs: [sessionID]))
        return try await $current.withValue(work) {
            try await body()
        }
    }
}
