import FoundationModels

/// ``RoutedSessionActor``'s prompt-queue and elicitation-answer surface — the
/// typed capabilities ``RoutedSession`` requires over the session's own
/// internal ``outbox`` and ``mailbox``.
///
/// The protocol deliberately does not expose the two mechanism actors
/// themselves (task ^j0pp9yp): an app drives the queue and answers
/// elicitations through these typed methods alone, and the raw staging and
/// backgrounding machinery stays internal wiring. Every method here is a thin,
/// `nonisolated` delegation — the mechanism actors do their own
/// serialization, so nothing needs this session actor's isolation.
extension RoutedSessionActor {
    /// Stages a queued user prompt for a future turn — see
    /// ``RoutedSession/enqueue(prompt:)-(Transcript.Prompt)``.
    ///
    /// - Parameter prompt: The prompt to stage.
    /// - Returns: The stable id assigned to this queued prompt.
    @discardableResult
    nonisolated func enqueue(prompt: Transcript.Prompt) async -> SessionOutbox.ItemID {
        await outbox.enqueue(prompt: prompt)
    }

    /// A snapshot of every queued prompt, in FIFO dispatch order — see
    /// ``RoutedSession/pendingPrompts()``.
    ///
    /// - Returns: Each queued prompt's stable id paired with its current
    ///   content.
    nonisolated func pendingPrompts() async -> [(id: SessionOutbox.ItemID, prompt: Transcript.Prompt)] {
        await outbox.pending().prompts.map { (id: $0.id, prompt: $0.prompt) }
    }

    /// Cancels a still-pending queued prompt — see
    /// ``RoutedSession/cancel(id:)``.
    ///
    /// - Parameter id: The queued prompt's stable id.
    /// - Returns: Whether the prompt was still pending and was removed.
    @discardableResult
    nonisolated func cancel(id: SessionOutbox.ItemID) async -> SessionOutbox.PromptQueueMutationResult {
        await outbox.cancel(id: id)
    }

    /// Replaces a still-pending queued prompt's content in place — see
    /// ``RoutedSession/replace(id:prompt:)``.
    ///
    /// - Parameters:
    ///   - id: The queued prompt's stable id.
    ///   - prompt: The prompt's new content.
    /// - Returns: Whether the prompt was still pending and was updated.
    @discardableResult
    nonisolated func replace(id: SessionOutbox.ItemID, prompt: Transcript.Prompt) async -> SessionOutbox.PromptQueueMutationResult {
        await outbox.replace(id: id, prompt: prompt)
    }

    /// The waiting-plus-dispatched queued-prompt count — see
    /// ``RoutedSession/promptQueueDepth()``.
    ///
    /// - Returns: The current ``SessionOutbox/QueueDepth``.
    nonisolated func promptQueueDepth() async -> SessionOutbox.QueueDepth {
        await outbox.queueDepth()
    }

    /// Suspends until the session's staging area holds work for a future
    /// turn — see ``RoutedSession/awaitQueuedWork()``. Delegates to
    /// ``SessionOutbox/nextEvent()``, which resumes for a queued prompt
    /// exactly as it does for a pending event.
    nonisolated func awaitQueuedWork() async {
        await outbox.nextEvent()
    }

    /// Delivers the user's answer to a pending elicitation on this session —
    /// see ``RoutedSession/respond(elicitationId:response:)``.
    ///
    /// - Parameters:
    ///   - elicitationId: The pending elicitation's id, as text.
    ///   - response: The user's answer.
    /// - Returns: The ``SessionMailbox/ElicitationAnswerDelivery``.
    @discardableResult
    nonisolated func respond(elicitationId: String, response: ElicitationResponse) async -> SessionMailbox.ElicitationAnswerDelivery {
        await deliver(toElicitation: elicitationId, orReturn: .noPendingElicitation) {
            await mailbox.respond(elicitationId: $0, response)
        }
    }

    /// Signals that an accepted URL-mode elicitation's out-of-band flow
    /// finished — see ``RoutedSession/complete(elicitationId:)``.
    ///
    /// - Parameter elicitationId: The accepted URL-mode elicitation's id.
    /// - Returns: The ``SessionMailbox/ElicitationCompletionDelivery``.
    @discardableResult
    nonisolated func complete(elicitationId: String) async -> SessionMailbox.ElicitationCompletionDelivery {
        await deliver(toElicitation: elicitationId, orReturn: .noPendingElicitation) {
            await mailbox.complete(elicitationId: $0)
        }
    }

    /// Parses an inbound elicitation id and hands the parsed id to `delivery` —
    /// the one place either inbound elicitation route decides what an
    /// unparseable id means.
    ///
    /// ``respond(elicitationId:response:)`` and ``complete(elicitationId:)``
    /// both take the id as a `String`, because it reaches Router from a host
    /// app across a boundary that carries text, and both owe the MCP spec the
    /// same safe no-op when that text is not a ``ULID`` at all. Routing both
    /// through here keeps that one decision in one place: neither route can be
    /// changed to treat an unparseable id differently without the other
    /// following.
    ///
    /// - Parameters:
    ///   - elicitationId: The elicitation's id as the caller supplied it.
    ///   - unparseableResult: What to report when `elicitationId` is not a
    ///     parseable ``ULID`` — each route's own `noPendingElicitation`.
    ///   - delivery: Delivers the parsed id to this session's ``mailbox``.
    /// - Returns: Whatever `delivery` reported, or `unparseableResult` when the
    ///   id could not be parsed.
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
