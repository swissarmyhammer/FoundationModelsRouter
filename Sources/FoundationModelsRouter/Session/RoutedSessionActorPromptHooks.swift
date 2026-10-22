import FoundationModelsExtras
import FoundationModelsHooks

/// ``RoutedSessionActor``'s prompt hooks: one `PrePrompt` for each user
/// message and each agent message before the model gets it, and one
/// `PostPrompt` when the mail ends.
///
/// The session screens a mail while the mail is in the queue:
///
/// - ``mail(_:)`` marks the mail as screening before the put
///   (``beginPromptScreen(of:)``), and runs its `PrePrompt` chain in the
///   helper task that wakes the pump (``screenPrompt(of:)``).
/// - The pump takes no mail from the first screening mail on
///   (``takeScreenedMail(admitting:)``), so the queue order stays. The take
///   and the work that holds the mail keep no suspension point between them.
/// - When the chain lets the mail go on, the text of the chain goes into the
///   mail, the mark goes, and the pump wakes. When the chain blocks the mail,
///   the mail leaves the queue with ``SessionEvent/cancelled(_:)``, and its
///   one `PostPrompt` is `blocked`.
/// - A replace is not screened. The body that a ``replace(_:with:)`` signal
///   gives a queued mail goes to the model as the caller gave it, with no
///   new `PrePrompt`, so a guard visitor does not see the replaced text. A
///   replace that comes while the chain runs wins over the text of the
///   chain (``notePromptReplace(of:)``), but a block of the chain still
///   blocks the mail. The mail still gets one `PostPrompt`.
/// - The terminal event of a mail that got a `PrePrompt` sends its
///   `PostPrompt` (``endPrompts(_:by:)``). A withdraw of a mail while its
///   chain runs ends the mail as now, and the session ignores the result of
///   the chain.
///
/// A session with no hooks, or whose dispatcher has no visitor, marks no
/// mail, and its pump does not change.
extension RoutedSessionActor {
    /// Marks `mail` as screening when it gets a `PrePrompt`: it is a user
    /// message or an agent message, and the dispatcher of the session has a
    /// visitor. ``mail(_:)`` calls it before the put of the mail.
    ///
    /// - Parameter mail: The mail that goes into the queue.
    /// - Returns: `true` when this call marked the mail. Then the caller runs
    ///   ``screenPrompt(of:)``, or ``dropPromptScreen(of:)`` when the queue
    ///   refuses the mail.
    nonisolated func beginPromptScreen(of mail: Mail) -> Bool {
        guard let hooks, mail.body.hookPromptText != nil, !hooks.routerHooks.dispatcher.isEmpty else {
            return false
        }
        return hooks.prompts.beginScreen(of: mail.id)
    }

    /// Records that a ``replace(_:with:)`` signal changed the body of the
    /// queued mail `id`. ``performReplace(_:with:)`` calls it after the
    /// change. A replace is not screened: it gets no `PrePrompt`. When the
    /// mail is screening, the replaced body wins over the text of its chain
    /// (``admitScreenedPrompt(_:text:)``).
    ///
    /// - Parameter id: The id of the mail.
    nonisolated func notePromptReplace(of id: MailID) {
        hooks?.prompts.noteReplace(of: id)
    }

    /// Removes the mark of a mail that the queue refused.
    ///
    /// - Parameter id: The id of the refused mail.
    nonisolated func dropPromptScreen(of id: MailID) {
        hooks?.prompts.forget(id)
    }

    /// Keeps the task that runs the chain of the mail `id`, so that a
    /// withdraw of the mail cancels the chain.
    ///
    /// - Parameters:
    ///   - task: The helper task that runs ``screenPrompt(of:)``.
    ///   - id: The id of the mail.
    nonisolated func keepPromptScreen(_ task: Task<Void, Never>, of id: MailID) {
        hooks?.prompts.keep(task, forScreenOf: id)
    }

    /// Runs the `PrePrompt` chain of a screening mail, and acts on its
    /// outcome. A mail that left the queue before or while the chain ran
    /// keeps its end, and the outcome changes nothing.
    ///
    /// - Parameter mail: The mail, as ``mail(_:)`` put it in the queue.
    nonisolated func screenPrompt(of mail: Mail) async {
        guard let hooks, let text = mail.body.hookPromptText, hooks.prompts.beginPrompt(of: mail.id) else { return }
        let outcome = await hooks.routerHooks.dispatcher.pre(
            PrePrompt(mailID: mail.id.description, text: text), session: hooks.session)
        switch outcome {
        case .proceed(let event), .approved(let event):
            // For now, an approval has the same effect as a proceed.
            await admitScreenedPrompt(mail, text: event.text)
        case .blocked(let reason):
            blockScreenedPrompt(mail.id, reason: reason, hooks: hooks)
        }
    }

    /// Lets a screening mail go on with the text of its chain: the text goes
    /// into the queued mail, and the transcript records the new body
    /// (``MailRecord/replaced(_:body:)``). Then the mark goes, and the pump
    /// wakes.
    ///
    /// A replace is not screened, and it wins over the chain: when a
    /// ``replace(_:with:)`` signal changed the mail while the chain ran
    /// (``PromptHookLedger/isReplaced(_:)``), the replaced body stays, and
    /// the session ignores the text of the chain. This function and
    /// ``performReplace(_:with:)`` both run on this actor, so a replace
    /// cannot come between the check and the change of the body.
    ///
    /// - Parameters:
    ///   - mail: The mail, as ``mail(_:)`` put it in the queue.
    ///   - text: The final text of the chain.
    private func admitScreenedPrompt(_ mail: Mail, text: String) {
        guard let hooks, hooks.prompts.isScreening(mail.id) else { return }
        if !hooks.prompts.isReplaced(mail.id), let body = mail.body.replacingHookPromptText(with: text),
            body != mail.body, outbox.queue.replace(mail.id, with: body)
        {
            recordMail([.replaced(mail.id, body: body)])
        }
        guard hooks.prompts.endScreen(of: mail.id) else { return }
        stateChanges.signal()
        wakePump()
    }

    /// Withdraws a screening mail that its chain blocked: the mail leaves the
    /// queue, its one `PostPrompt` is `blocked`, and its terminal event is
    /// ``SessionEvent/cancelled(_:)``, as for each withdrawn mail. The mark
    /// goes before that terminal event, so the event sends no second
    /// `PostPrompt`.
    ///
    /// - Parameters:
    ///   - id: The id of the mail.
    ///   - reason: The reason of the block.
    ///   - hooks: The hooks of the session.
    private nonisolated func blockScreenedPrompt(_ id: MailID, reason: String, hooks: SessionHooks) {
        // The mark stays until the cancel, so the pump cannot take the mail
        // between the two.
        guard hooks.prompts.isScreening(id), outbox.queue.cancel(id) != nil else { return }
        hooks.prompts.forget(id)
        postPrompt(id, outcome: .blocked(reason: reason), hooks: hooks)
        settleCancelledMail([id])
    }

    /// Sends the one `PostPrompt` of the mail `id` to the dispatcher of the
    /// session.
    ///
    /// - Parameters:
    ///   - id: The id of the mail.
    ///   - outcome: How the mail ended.
    ///   - hooks: The hooks of the session.
    private nonisolated func postPrompt(_ id: MailID, outcome: PromptOutcome, hooks: SessionHooks) {
        hooks.routerHooks.dispatcher.post(
            PostPrompt(mailID: id.description, outcome: outcome), session: hooks.session)
    }

    /// Sends the `PostPrompt` of each mail that `event` ended and that got a
    /// `PrePrompt`. ``emitSessionScopedEvent(_:failure:audience:)`` calls it
    /// for each event, with the ids that the output of the session ended.
    /// The output ends each id one time only, so each mail gets one
    /// `PostPrompt`.
    ///
    /// - Parameters:
    ///   - ended: The keys that `event` ended.
    ///   - event: The event that the session sent.
    nonisolated func endPrompts(_ ended: [SessionOutputHub.TerminalKey], by event: SessionEvent) {
        guard let hooks else { return }
        let outcome = Self.promptOutcome(of: event)
        for case .mail(let id) in ended {
            guard hooks.prompts.forget(id), let outcome else { continue }
            postPrompt(id, outcome: outcome, hooks: hooks)
        }
    }

    /// How the terminal event `event` ended its mail, as a `PostPrompt` reads
    /// it.
    ///
    /// - Parameter event: A terminal event of a mail.
    /// - Returns: The outcome, or `nil` for an event that ends a mail that
    ///   never got a `PrePrompt` in this process (``SessionEvent/lost(_:)``)
    ///   and for an event that ends no mail.
    static func promptOutcome(of event: SessionEvent) -> PromptOutcome? {
        switch event {
        case .answered:
            return .answered
        case .answerFailed(let failure):
            switch failure.reason {
            case .cancelled:
                return .cancelled
            case .error(let message):
                return .failed(message: message)
            }
        case .cancelled:
            return .cancelled
        default:
            return nil
        }
    }

    /// Takes queued mail with `rule`, up to the first screening mail: that
    /// mail and each mail after it stay in the queue, so the queue order
    /// stays. The take does not suspend.
    ///
    /// - Parameter rule: The batch rule or the join rule of the take
    ///   (``MailQueue/take(admitting:)``).
    /// - Returns: The taken mail, in queue order.
    nonisolated func takeScreenedMail(admitting rule: (_ candidate: Mail, _ batch: [Mail]) -> Bool) -> [Mail] {
        guard let prompts = hooks?.prompts else { return outbox.queue.take(admitting: rule) }
        var reachedAScreen = false
        return outbox.queue.take { candidate, batch in
            reachedAScreen = reachedAScreen || prompts.isScreening(candidate.id)
            return !reachedAScreen && rule(candidate, batch)
        }
    }

    /// The queued mail before the first screening mail, in queue order: the
    /// mail that ``takeScreenedMail(admitting:)`` can take now.
    nonisolated var screenedPendingMail: [Mail] {
        let pending = outbox.queue.pending
        guard let prompts = hooks?.prompts else { return pending }
        return Array(pending.prefix { !prompts.isScreening($0.id) })
    }
}

extension MailBody {
    /// The text that a `PrePrompt` carries: the prompt of a user message or
    /// the text of the sender of an agent message, with no header of the
    /// session directory (``AgentMessageContent``). The other kinds carry no
    /// model input text from outside the session, so they get no
    /// `PrePrompt`.
    var hookPromptText: String? {
        switch self {
        case .userMessage(let prompt, _):
            prompt
        case .agentMessage(let sender, let content):
            AgentMessageContent(parsing: content, from: sender).text
        case .runEvent, .elicitationAnswer, .catalogChange:
            nil
        }
    }

    /// This body with `text` in place of its ``hookPromptText``. An agent
    /// message keeps the header that the session directory wrote, so a hook
    /// can neither drop nor change the facts of the sender.
    ///
    /// - Parameter text: The new text.
    /// - Returns: The new body, or `nil` for a body with no ``hookPromptText``.
    func replacingHookPromptText(with text: String) -> MailBody? {
        switch self {
        case .userMessage(_, let options):
            .userMessage(prompt: text, options: options)
        case .agentMessage(let sender, let content):
            .agentMessage(
                from: sender,
                content: AgentMessageContent(header: AgentMessageContent(parsing: content, from: sender).header, text: text)
                    .encoded)
        case .runEvent, .elicitationAnswer, .catalogChange:
            nil
        }
    }
}
