import FoundationModels

/// The prompt-queue and elicitation-answer surface of ``RoutedSessionActor``.
/// Each method delegates to the internal ``outbox`` or ``mailbox``.
extension RoutedSessionActor {
    /// Stages a queued user prompt for a future turn.
    /// - Returns: The stable id of the queued prompt.
    @discardableResult
    nonisolated func enqueue(prompt: Transcript.Prompt) async -> SessionOutbox.ItemID {
        await outbox.enqueue(prompt: prompt)
    }

    /// A snapshot of every queued prompt, in FIFO dispatch order.
    nonisolated func pendingPrompts() async -> [(id: SessionOutbox.ItemID, prompt: Transcript.Prompt)] {
        await outbox.pending().prompts.map { (id: $0.id, prompt: $0.prompt) }
    }

    /// Cancels a still-pending queued prompt.
    /// - Returns: Whether the prompt was still pending and was removed.
    @discardableResult
    nonisolated func cancel(id: SessionOutbox.ItemID) async -> SessionOutbox.PromptQueueMutationResult {
        await outbox.cancel(id: id)
    }

    /// Replaces the content of a still-pending queued prompt.
    /// - Returns: Whether the prompt was still pending and was updated.
    @discardableResult
    nonisolated func replace(id: SessionOutbox.ItemID, prompt: Transcript.Prompt) async -> SessionOutbox.PromptQueueMutationResult {
        await outbox.replace(id: id, prompt: prompt)
    }

    /// The waiting-plus-dispatched queued-prompt count.
    nonisolated func promptQueueDepth() async -> SessionOutbox.QueueDepth {
        await outbox.queueDepth()
    }

    /// Suspends until the outbox holds a queued prompt or a pending event.
    nonisolated func awaitQueuedWork() async {
        await outbox.nextEvent()
    }

    /// Delivers the user's answer to a pending elicitation on this session.
    /// - Returns: The ``SessionMailbox/ElicitationAnswerDelivery``.
    @discardableResult
    nonisolated func respond(elicitationId: String, response: ElicitationResponse) async -> SessionMailbox.ElicitationAnswerDelivery {
        await deliver(toElicitation: elicitationId, orReturn: .noPendingElicitation) {
            await mailbox.respond(elicitationId: $0, response)
        }
    }

    /// Signals that the out-of-band flow of an accepted URL-mode elicitation finished.
    /// - Returns: The ``SessionMailbox/ElicitationCompletionDelivery``.
    @discardableResult
    nonisolated func complete(elicitationId: String) async -> SessionMailbox.ElicitationCompletionDelivery {
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
