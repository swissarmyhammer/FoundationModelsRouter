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
    /// - Returns: The id of the message.
    @discardableResult
    func send(_ prompt: Transcript.Prompt) async -> MessageID {
        let message = SessionMessage(
            prompt: prompt, requestedMaxTokens: nil, reader: .reply, serviceContext: ServiceContext.current)
        return await enqueue(message).id
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
    /// - Returns: The id of the message, and its answer.
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
    func pendingMessages() async -> [(id: MessageID, prompt: Transcript.Prompt)] {
        outbox.messages.pending.map { (id: $0.id, prompt: $0.message.prompt) }
    }

    /// Replaces the prompt of a caller message that waits.
    ///
    /// - Parameters:
    ///   - id: The id of the message.
    ///   - prompt: The new prompt.
    /// - Returns: Whether the message waited and was changed.
    @discardableResult
    nonisolated func replace(id: MessageID, prompt: Transcript.Prompt) async -> MessageQueueMutationResult {
        outbox.replace(id: id, prompt: prompt)
    }

    /// The count of the waiting caller messages, and the ids of the messages
    /// of the running answer. The delivery letter of an answer that only mail
    /// starts (``PumpWork/mailDeliveryLetter``) is no caller message, so the
    /// depth leaves it out. It never waits when this actor reads the depth
    /// (``pendingMessages()``).
    func messageQueueDepth() async -> MessageQueueDepth {
        let depth = outbox.messages.depth
        let deliveryLetter = pumpWork?.mailDeliveryLetter
        return MessageQueueDepth(waiting: depth.waiting, running: depth.running.filter { $0 != deliveryLetter })
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
