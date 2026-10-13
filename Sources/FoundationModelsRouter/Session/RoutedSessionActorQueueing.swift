import FoundationModels
import FoundationModelsExtras
import Tracing

/// The message-queue and elicitation-answer surface of ``RoutedSessionActor``
/// (`generation-queue.md`, section 5.4). The queue methods post to, read and
/// change the caller messages in the mailbox ``SessionOutbox/messages``; the
/// elicitation methods delegate to ``mailbox``.
extension RoutedSessionActor {
    /// See ``RoutedSession/send(_:)-(Transcript.Prompt)``. Posts one caller
    /// message and wakes the pump. It waits for no submission and no answer.
    ///
    /// - Parameter prompt: The prompt of the message.
    /// - Returns: The correlation id of the message.
    @discardableResult
    func send(_ prompt: Transcript.Prompt) async -> MailID {
        let message = SessionMessage(
            prompt: prompt, requestedMaxTokens: nil, reader: .reply, serviceContext: ServiceContext.current)
        await enqueue(message)
        return message.mailID
    }

    /// Posts `message` behind every caller message that waits, records the
    /// new depth of the queue, and wakes the pump.
    ///
    /// The post, the record and the wake have no suspension point between
    /// them, and the pump takes a batch only on this actor. So a caller that
    /// installs its cancellation handler with no suspension point after this
    /// call finds its message still waiting when the handler runs.
    ///
    /// - Parameter message: The message to post.
    /// - Returns: The id that the mailbox gave the message, and its answer.
    @discardableResult
    func enqueue(_ message: SessionMessage) async -> (id: MessageID, answer: MailboxAnswer<String>) {
        await attachOutboxJournalIfNeeded()
        let posted = outbox.messages.post(message)
        recordMessageQueueDepth()
        wakePump()
        return posted
    }

    /// A snapshot of every caller message that waits, in the order the
    /// messages arrived.
    ///
    /// The read runs on this actor. The delivery letter of an answer that
    /// only mail starts (``PumpWork/mailDeliveryLetter``) waits only between
    /// its post and its take, with no suspension point between the two on
    /// this actor, so the snapshot never shows it.
    func pendingMessages() async -> [(id: MailID, prompt: Transcript.Prompt)] {
        outbox.messages.pending.map { (id: $0.message.mailID, prompt: $0.message.prompt) }
    }

    /// Replaces the prompt of a caller message that waits. The message is
    /// found by its correlation id, and replaced in the mailbox by the id
    /// that the mailbox gave it.
    ///
    /// - Parameters:
    ///   - id: The correlation id of the message.
    ///   - prompt: The new prompt.
    /// - Returns: Whether the message waited and was changed.
    @discardableResult
    nonisolated func replace(id: MailID, prompt: Transcript.Prompt) async -> MessageQueueMutationResult {
        guard let letter = outbox.messages.pending.first(where: { $0.message.mailID == id }) else {
            return .alreadySent
        }
        return outbox.replace(id: letter.id, prompt: prompt)
    }

    /// The mail that waits, by kind, and the correlation ids of the caller
    /// messages of the running answer (``deliveredMailIds``). The waiting
    /// caller messages are ``MailKind/userMessage``, and the run events that
    /// wait in ``outbox`` are ``MailKind/runEvent``.
    ///
    /// The delivery letter of an answer that only mail starts
    /// (``PumpWork/mailDeliveryLetter``) is no caller message. It never waits
    /// when this actor reads the mailbox (``pendingMessages()``), and the
    /// running answer carries no letter for it, so the depth never counts
    /// it. The read of the mailbox comes after the one suspension point, so
    /// both of its counts come from one moment on this actor.
    func mailQueueDepth() async -> MailQueueDepth {
        let runEvents = await outbox.pending().events.count
        let userMessages = outbox.messages.depth.waiting
        let counts: [MailKind: Int] = [.userMessage: userMessages, .runEvent: runEvents]
        return MailQueueDepth(
            waiting: userMessages + runEvents, depthByKind: counts.filter { $0.value > 0 },
            running: deliveredMailIds)
    }

    /// Delivers the user's answer to a pending elicitation on this session.
    /// - Returns: The ``ElicitationAnswerDelivery``.
    @discardableResult
    nonisolated func respond(elicitationId: String, response: ElicitationResponse) async -> ElicitationAnswerDelivery {
        await deliver(toElicitation: elicitationId, orReturn: .noPendingElicitation) {
            await mailbox.respond(elicitationId: $0, response)
        }
    }

    /// Signals that the out-of-band flow of an accepted URL-mode elicitation finished.
    /// - Returns: The ``ElicitationCompletionDelivery``.
    @discardableResult
    nonisolated func complete(elicitationId: String) async -> ElicitationCompletionDelivery {
        await deliver(toElicitation: elicitationId, orReturn: .noPendingElicitation) {
            await mailbox.complete(elicitationId: $0)
        }
    }

    /// Parses an inbound elicitation id and hands the parsed id to `delivery`.
    /// - Returns: The result of `delivery`, or `unparseableResult` when the id is not a ``ULID``.
    private nonisolated func deliver<Delivery>(
        toElicitation elicitationId: String,
        orReturn unparseableResult: Delivery,
        using delivery: (ULID) async -> Delivery
    ) async -> Delivery {
        guard let id = ULID(elicitationId) else {
            return unparseableResult
        }
        return await delivery(id)
    }
}
