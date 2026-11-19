import FoundationModelsExtras

/// The prompt text of one user-type mail that an answer of a session
/// delivered (D206), as the session tells the observer of its delivered
/// prompts (``RoutedSessionActor/observeDeliveredPrompts(_:)``).
///
/// ``RouterSessionDirectory`` is the observer: its recap maker
/// (``SessionRecapper``) keeps the user prompts of the turns since the last
/// recap of each session. No event of the session carries the text of a
/// prompt, so the session gives it here.
struct DeliveredPrompt: Sendable, Equatable {
    /// The id of the mail.
    let mail: MailID

    /// The prompt text of the mail (``Mail/promptText``).
    let text: String
}

extension RoutedSessionActor {
    /// The observer of the delivered prompts of a session.
    typealias DeliveredPromptObserver = @Sendable ([DeliveredPrompt]) -> Void

    /// Sets the one observer of the prompt text of each user-type mail that
    /// an answer of this session delivers. A later call replaces it.
    ///
    /// The session calls the observer synchronously when an answer takes its
    /// mail, and when mail joins a continuation of the answer
    /// (``reportDeliveredPrompts(of:)``), before the
    /// ``SessionEvent/mailDelivered(_:)`` events of that mail. Run mail and
    /// catalog notices are not user-type mail, so they give no prompt.
    ///
    /// - Parameter observer: The observer. It must not wait, and it must not
    ///   call the session.
    nonisolated func observeDeliveredPrompts(_ observer: @escaping DeliveredPromptObserver) {
        deliveredPromptObserver.withLock { $0 = observer }
    }

    /// Tells the observer of the delivered prompts
    /// (``observeDeliveredPrompts(_:)``) the prompt text of each user-type
    /// mail of `mail`. Mail with no user-type mail, or a session with no
    /// observer, calls nothing. The observer runs outside the lock that
    /// holds it.
    ///
    /// - Parameter mail: The mail that an answer delivers now, in take order.
    nonisolated func reportDeliveredPrompts(of mail: [Mail]) {
        let prompts = mail.filter(\.isUserMail).compactMap { item in
            item.promptText.map { DeliveredPrompt(mail: item.id, text: $0) }
        }
        guard !prompts.isEmpty, let observer = deliveredPromptObserver.withLock({ $0 }) else { return }
        observer(prompts)
    }
}
