import FoundationModels
import Tracing

/// The message-queue and elicitation-answer surface of ``RoutedSessionActor``
/// (`generation-queue.md`, section 5.4). The queue methods add to, read and
/// change the caller messages in ``outbox``; the elicitation methods delegate
/// to ``mailbox``.
extension RoutedSessionActor {
    /// See ``RoutedSession/send(_:)-(Transcript.Prompt)``. Adds one caller
    /// message and wakes the pump. It waits for no submission and no answer.
    ///
    /// - Parameter prompt: The prompt of the message.
    /// - Returns: The id of the message.
    @discardableResult
    func send(_ prompt: Transcript.Prompt) async -> MessageID {
        let message = SessionMessage(
            id: MessageID(), prompt: prompt, requestedMaxTokens: nil, reader: .reply,
            serviceContext: ServiceContext.current, answer: PumpAnswer())
        await enqueue(message)
        return message.id
    }

    /// Adds `message` behind every caller message that waits, and wakes the
    /// pump.
    ///
    /// The message is open (``openMessages``) before it reaches ``outbox``,
    /// so ``cancel(message:)`` finds it at every point until its answer.
    ///
    /// - Parameter message: The message to add.
    func enqueue(_ message: SessionMessage) async {
        openMessages[message.id] = message.answer
        await attachOutboxJournalIfNeeded()
        await outbox.add(message: message)
        wakePump()
    }

    /// A snapshot of every caller message that waits, in the order the
    /// messages arrived.
    nonisolated func pendingMessages() async -> [(id: MessageID, prompt: Transcript.Prompt)] {
        await outbox.pending().messages.map { (id: $0.id, prompt: $0.prompt) }
    }

    /// Replaces the prompt of a caller message that waits.
    ///
    /// - Parameters:
    ///   - id: The id of the message.
    ///   - prompt: The new prompt.
    /// - Returns: Whether the message waited and was changed.
    @discardableResult
    nonisolated func replace(id: MessageID, prompt: Transcript.Prompt) async -> MessageQueueMutationResult {
        await outbox.replace(id: id, prompt: prompt)
    }

    /// The count of the waiting caller messages, and the ids of the messages
    /// of the running answer.
    func messageQueueDepth() async -> MessageQueueDepth {
        let waiting = await outbox.waitingMessageCount
        return MessageQueueDepth(waiting: waiting, running: (deliveredMessages ?? []).map(\.id))
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
