import FoundationModelsExtras

/// What happened to one mail of a session, as the session tells the
/// observer of its mail (``RoutedSessionActor/observeMailFate(_:)``).
///
/// ``RouterSessionDirectory`` is the observer: it sends `messageDelivered`
/// for a directory message when the target gets it (D199 (f)), and it
/// forgets a message whose mail ended with no delivery.
enum MailFate: Sendable, Equatable {
    /// The pump took the mail into an answer
    /// (``SessionEvent/mailDelivered(_:)``). The model sees it from now on.
    case delivered(MailID)

    /// The mail ended with ``SessionEvent/cancelled(_:)`` or
    /// ``SessionEvent/lost(_:)``. A mail that a cancel stops in a running
    /// answer was delivered before.
    case cancelledOrLost(MailID)

    /// The fate that `event` tells, or `nil` for an event that tells no
    /// fate of a mail.
    ///
    /// - Parameter event: An event of the session.
    init?(_ event: SessionEvent) {
        switch event {
        case .mailDelivered(let id):
            self = .delivered(id)
        case .cancelled(let id), .lost(let id):
            self = .cancelledOrLost(id)
        case .textDelta, .textReset, .reasoningDelta, .toolCall, .toolStatus, .toolInvocation, .toolCallReport,
            .toolDisplay, .entryRecorded, .compactionStarted, .compaction, .compactionFailed, .discoveryPrimingFailed,
            .generationStalled, .submissionStarted, .submissionEnded, .answered, .answerFailed, .repetitionStopped,
            .reasoningStopped, .runSettled, .runMessage, .runProgress, .generationCall, .mailDeliveryPaused,
            .signalDone, .workStarted, .workEnded, .elicitationRequested, .elicitationEnded, .elicitationCompleted:
            return nil
        }
    }
}

extension RoutedSessionActor {
    /// The observer of the fate of each mail of a session.
    typealias MailFateObserver = @Sendable (MailFate) -> Void

    /// Sets the one observer of the fate of each mail of this session. A
    /// later call replaces it.
    ///
    /// The session calls the observer synchronously, before the event of
    /// the fate goes to any reader of the output of the session
    /// (``reportMailFate(of:)``). Thus what the observer sends for a
    /// delivered mail comes before each output of the answer that delivers
    /// it.
    ///
    /// - Parameter observer: The observer. It must not wait, and it must not
    ///   call the session.
    nonisolated func observeMailFate(_ observer: @escaping MailFateObserver) {
        mailFateObserver.withLock { $0 = observer }
    }

    /// Tells the observer of the mail (``observeMailFate(_:)``) the fate
    /// that `event` tells. An event that tells no fate, or a session with no
    /// observer, calls nothing. The observer runs outside the lock that
    /// holds it.
    ///
    /// - Parameter event: An event that the session is about to send.
    nonisolated func reportMailFate(of event: SessionEvent) {
        guard let fate = MailFate(event), let observer = mailFateObserver.withLock({ $0 }) else { return }
        observer(fate)
    }
}
