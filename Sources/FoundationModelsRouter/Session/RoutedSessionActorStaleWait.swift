import Foundation
import FoundationModelsExtras

/// ``RoutedSessionActor``'s nudge after a waiting status with nothing
/// pending (task ^4sg1ev1).
///
/// A model posts a waiting status (``PendingRunEnvelope/waitingStatusPrefix``)
/// when only background work is left, and the result of that work starts
/// the model again. When nothing of the session is pending
/// (``hasPendingOperation()``), no result can come, and the wait is stale:
/// the model waits on work whose result it already has. On flint4
/// django-13447 (2026-11-14), the root got the result of its review agent as a
/// tool output, then wrote "Waiting on the review double-check agent" in the
/// next pass, and the answer ended before the committer ran. So such an answer
/// goes on one more time with ``staleWaitPrompt``. The nudge runs once in each
/// answer, so a model that waits again ends the answer.
extension RoutedSessionActor {
    /// The prompt of the submission that goes on after a stale wait.
    static let staleWaitPrompt = """
        Nothing is pending. The result of each piece of work that you started is above. \
        Do not wait. Continue the task.
        """

    /// Whether the answer that ended with `response` gets the nudge: the
    /// text opens with the waiting status, nothing of the session is
    /// pending, and the answer did not get the nudge yet. A `true` result
    /// uses up the nudge of the answer.
    ///
    /// - Parameter response: The final text of the attempt.
    /// - Returns: `true` when the answer goes on with ``staleWaitPrompt``.
    func staleWaitNudgeIsDue(response: String) async -> Bool {
        guard !staleWaitNudged,
            response.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix(PendingRunEnvelope.waitingStatusPrefix)
        else { return false }
        guard await !hasPendingOperation(), !staleWaitNudged else { return false }
        staleWaitNudged = true
        return true
    }
}
