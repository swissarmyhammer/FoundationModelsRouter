import FoundationModelsExtras

/// The origin of the work that runs now on a task: the value that each
/// output event of a session reads (`mailbox.md`, section 4).
///
/// The pump sets ``Origin/mail(_:)`` with the ids of the batch when it starts
/// an answer. A compaction sets ``Origin/signal(_:)``. Work that no mail and
/// no signal started keeps ``Origin/system``. A child task inherits the
/// value, thus a tool body and a background run that an answer starts keep
/// the origin of that answer. A task that inherits no task-local, for
/// example the worker of a ``GenerationQueue``, gets the value bound again
/// by the code that starts it.
///
/// No call site gives the origin to an event by hand.
/// ``RoutedSessionActor/emitSessionScopedEvent(_:)`` reads it.
enum OriginContext {
    /// The origin of the work of the current task.
    @TaskLocal static var current: Origin = .system
}

/// One output event of a session, with the origin of the work that sent it.
///
/// ``RoutedSession/streamSessionEvents()`` gives each output event in this
/// form. The cases of ``SessionEvent`` do not change, so a `switch` over
/// ``event`` stays valid.
public struct SessionOutput: Sendable, Equatable {
    /// The work that sent the event: the mail of an answer, a signal, or the
    /// session itself.
    public let origin: Origin

    /// The event.
    public let event: SessionEvent

    /// Makes one output event.
    ///
    /// - Parameters:
    ///   - origin: The work that sent the event.
    ///   - event: The event.
    public init(origin: Origin, event: SessionEvent) {
        self.origin = origin
        self.event = event
    }
}

extension Origin {
    /// Whether this origin is the mail `id`: an answer to a batch that holds
    /// `id`.
    ///
    /// - Parameter id: The id of one mail.
    /// - Returns: `true` when the origin is ``Origin/mail(_:)`` and its set
    ///   holds `id`.
    public func contains(_ id: MailID) -> Bool {
        guard case .mail(let ids) = self else { return false }
        return ids.contains(id)
    }
}
