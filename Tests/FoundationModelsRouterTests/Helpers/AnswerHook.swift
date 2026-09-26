import Synchronization

/// The mid-generation closure a test installs, standing in for a tool the
/// SDK invokes *inside* the model call. It gets the prompt of the
/// submission, so one hook can serve several sessions and suspend only the
/// answer a test means to suspend.
///
/// A class, because a test and every backend it makes share one hook: the
/// test installs, replaces or clears the closure, and each backend reads it
/// from the isolation its submission runs on. The closure is behind a
/// ``Mutex``, so the type is `Sendable` with no unchecked claim.
final class AnswerHook: Sendable {
    /// The closure a backend runs in the middle of a model call.
    typealias MidAnswer = @Sendable (String) async throws -> Void

    /// The installed closure, or `nil` when the test installed none.
    private let installed = Mutex<MidAnswer?>(nil)

    /// The closure a backend runs in the middle of each model call, with the
    /// prompt of the submission, or `nil` for a model call with no tool.
    var midAnswer: MidAnswer? {
        get { installed.withLock { $0 } }
        set { installed.withLock { $0 = newValue } }
    }
}
