import FoundationModelsExtras
import Synchronization

/// The prompt hook state of one session: the mail whose `PrePrompt` chain
/// runs now ("screening" mail), and the mail that got a `PrePrompt` and waits
/// for its one `PostPrompt`.
///
/// A screening mail stays in the mail queue, and the pump takes no mail from
/// the first screening mail on (``RoutedSessionActor/takeScreenedMail(admitting:)``).
/// The life of one mail is:
///
/// 1. ``beginScreen(of:)`` before the put of the mail.
/// 2. ``beginPrompt(of:)`` when its chain starts: from now on the mail waits
///    for a `PostPrompt`.
/// 3. ``endScreen(of:)`` when its chain lets it go on, or ``forget(_:)`` when
///    the chain blocks it or the mail ends.
///
/// Each call holds one lock and does not suspend, so the pump can read
/// ``isScreening(_:)`` in the take rule, under the lock of the queue.
final class PromptHookLedger: Sendable {
    /// The state behind the lock.
    private struct State {
        /// The ids of the screening mail.
        var screening: Set<MailID> = []

        /// The task that runs the chain of each screening mail, when the
        /// session gave it (``keep(_:forScreenOf:)``).
        var screens: [MailID: Task<Void, Never>] = [:]

        /// The ids of the mail that got a `PrePrompt` and did not get its
        /// `PostPrompt` yet.
        var prompted: Set<MailID> = []
    }

    /// The state of the ledger.
    private let state = Mutex(State())

    /// Whether the `PrePrompt` chain of the mail `id` runs now, or waits to
    /// start.
    ///
    /// - Parameter id: The id of a mail.
    /// - Returns: `true` while the mail is screening.
    func isScreening(_ id: MailID) -> Bool {
        state.withLock { $0.screening.contains(id) }
    }

    /// Marks the mail `id` as screening. The session calls it before the put
    /// of the mail, so that the pump never sees the mail in the queue with no
    /// mark.
    ///
    /// - Parameter id: The id of the mail.
    /// - Returns: `false` when a mail with the same id is screening or waits
    ///   for its `PostPrompt`. Then this call changes nothing, and the queue
    ///   or the open answer refuses the mail.
    func beginScreen(of id: MailID) -> Bool {
        state.withLock { state in
            guard !state.screening.contains(id), !state.prompted.contains(id) else { return false }
            state.screening.insert(id)
            return true
        }
    }

    /// Keeps the task that runs the chain of the mail `id`, so that the end
    /// of the mail cancels it (``forget(_:)``). When the mail is not
    /// screening any more, this call cancels the task at once.
    ///
    /// - Parameters:
    ///   - task: The task that runs the chain.
    ///   - id: The id of the mail.
    func keep(_ task: Task<Void, Never>, forScreenOf id: MailID) {
        let isKept = state.withLock { state in
            guard state.screening.contains(id) else { return false }
            state.screens[id] = task
            return true
        }
        if !isKept {
            task.cancel()
        }
    }

    /// Records that the chain of the mail `id` starts, so that the mail
    /// waits for its `PostPrompt`.
    ///
    /// - Parameter id: The id of the mail.
    /// - Returns: `false` when the mail is not screening: it ended before
    ///   its chain started, and it gets no `PrePrompt`.
    func beginPrompt(of id: MailID) -> Bool {
        state.withLock { state in
            guard state.screening.contains(id) else { return false }
            state.prompted.insert(id)
            return true
        }
    }

    /// Ends the screen of the mail `id`: its chain let it go on. The mail
    /// still waits for its `PostPrompt`.
    ///
    /// - Parameter id: The id of the mail.
    /// - Returns: `false` when the mail was not screening: it ended while its
    ///   chain ran.
    func endScreen(of id: MailID) -> Bool {
        state.withLock { state in
            state.screens[id] = nil
            return state.screening.remove(id) != nil
        }
    }

    /// Forgets the mail `id`: the mail ended, its chain blocked it, or the
    /// queue refused it. A chain that still runs is cancelled, and the
    /// session ignores its result.
    ///
    /// - Parameter id: The id of the mail.
    /// - Returns: `true` when the mail got a `PrePrompt` and did not get its
    ///   `PostPrompt` yet. The caller then sends that `PostPrompt`.
    @discardableResult
    func forget(_ id: MailID) -> Bool {
        let (screen, wasPrompted) = state.withLock { state in
            state.screening.remove(id)
            return (state.screens.removeValue(forKey: id), state.prompted.remove(id) != nil)
        }
        screen?.cancel()
        return wasPrompted
    }
}
