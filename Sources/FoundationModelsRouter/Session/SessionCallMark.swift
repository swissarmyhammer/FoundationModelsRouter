import Synchronization

/// A task-local mark of one open model call of a session (task ^hga4td7).
///
/// The session binds a mark to ``current`` around each of its model calls,
/// in the task-local wrapper of the call, and closes the mark when the call
/// returns. Code inside the call, such as a tool body, sees the open mark.
/// The session reads it to refuse an in-band wait for an answer of its own
/// session: the pump of the session runs one answer at a time, so it cannot
/// start the next answer while a tool body runs inside the current one
/// (``RoutedSessionError/inBandWaitForOwnSession(sessionID:)``).
///
/// A task that a tool body starts with `Task {}` gets the same mark. The
/// mark is a reference, so it is closed for that task too when the model
/// call returns. Thus a background run that waits for its own session after
/// the call that started it ended is not refused.
final class SessionCallMark: Sendable {
    /// The mark of the current task, or `nil` outside a model call of a
    /// session.
    @TaskLocal static var current: SessionCallMark?

    /// The session of the model call.
    let sessionID: ULID

    /// Whether the model call has not returned yet.
    private let isOpen = Atomic(true)

    /// Makes an open mark for one model call of `sessionID`.
    ///
    /// - Parameter sessionID: The session of the model call.
    init(sessionID: ULID) {
        self.sessionID = sessionID
    }

    /// Whether this mark is open and belongs to `sessionID`.
    ///
    /// - Parameter sessionID: The session to compare.
    /// - Returns: `true` for an open mark of that session.
    func isOpenCall(of sessionID: ULID) -> Bool {
        sessionID == self.sessionID && isOpen.load(ordering: .acquiring)
    }

    /// Closes the mark when the model call returns.
    func close() {
        isOpen.store(false, ordering: .releasing)
    }
}
