import FoundationModels
import FoundationModelsExtras
import Tracing

/// The mail surface of ``RoutedSessionActor`` (`mailbox.md`, sections 4 and
/// 5): the ``MailSink`` requirement of ``RoutedSession``, the send of a
/// prompt, the reads of the mail queue, and the answers to an elicitation.
/// The queue is ``SessionOutbox/queue``; the elicitation methods also
/// delegate to ``runPlane``.
extension RoutedSessionActor {
    /// See ``RoutedSession/mail(_:)``. Subscribes to the output of the mail
    /// first, then puts the mail in the queue, so the caller loses no event
    /// of it. Then it wakes the pump.
    ///
    /// The id must be new to the session: not in the queue, and not in the
    /// open answer. The open answer is read before the put and again after
    /// it, because the pump can take a mail with the same id between the
    /// two. A hit after the put, while this mail is still queued, cancels
    /// this mail again.
    ///
    /// - Parameter mail: The mail to put in the queue.
    /// - Returns: The output of the mail, up to and including its terminal
    ///   event.
    /// - Throws: ``MailRefusal/duplicateID(_:)`` when the queue or the open
    ///   answer has the id, or ``MailRefusal/closed`` after ``close()``.
    nonisolated func mail(_ mail: Mail) throws -> MailSubscription<SessionOutput> {
        guard !openAnswerMail.contains(mail.id) else { throw MailRefusal.duplicateID(mail.id) }
        let (subscription, key) = outputHub.subscribe(to: mail.id)
        do {
            try outbox.queue.put(mail)
        } catch {
            outputHub.unsubscribe(key)
            throw error
        }
        if openAnswerMail.contains(mail.id), outbox.queue.cancel(mail.id) != nil {
            outputHub.unsubscribe(key)
            throw MailRefusal.duplicateID(mail.id)
        }
        outbox.noteCallerContext(ServiceContext.current, for: mail.id)
        // The record comes before the wake of the pump, so the transcript
        // holds the arrival of the mail before its delivery.
        recordMail([.mailQueued(mail)])
        Task { await self.mailDidArrive() }
        return subscription
    }

    /// Records the new depth of the queue and wakes the pump, after
    /// ``mail(_:)`` put a mail in the queue.
    private func mailDidArrive() {
        recordMailQueueDepth()
        wakePump()
    }

    /// See ``RoutedSession/send(_:)-(Transcript.Prompt)``. Sends one user
    /// message in reply mode, with the text of the `.text` segments of
    /// `prompt`, joined with no separator. It waits for no submission and no
    /// answer.
    ///
    /// - Parameter prompt: The prompt of the message.
    /// - Returns: The id of the mail.
    /// - Throws: ``PromptRefusal/noTextSegment`` when `prompt` has no `.text`
    ///   segment, because the session sends only the text of a prompt to the
    ///   model; ``MailRefusal/closed`` when the call comes after ``close()``.
    @discardableResult
    nonisolated func send(_ prompt: Transcript.Prompt) throws -> MailID {
        let hasText = prompt.segments.contains { segment in
            guard case .text = segment else { return false }
            return true
        }
        guard hasText else { throw PromptRefusal.noTextSegment }
        let text = TranscriptEntryMapper.flattenedText(prompt)
        let message = Mail(sender: .user, body: .userMessage(prompt: text, options: UserMessageOptions()))
        _ = try mail(message)
        return message.id
    }

    /// See ``RoutedSession/pendingMessages()``. The queued mail of all
    /// kinds, in queue order.
    func pendingMessages() -> [Mail] {
        outbox.queue.pending
    }

    /// See ``RoutedSession/mailQueueDepth()``. The queued mail by kind
    /// (``MailQueue/depthByKind``), and the ids of the mail of the open
    /// answer (``openAnswerMail``). The count of the queued mail is the sum
    /// of the counts of each kind, so both come from one read of the queue.
    func mailQueueDepth() -> MailQueueDepth {
        let depthByKind = outbox.queue.depthByKind
        return MailQueueDepth(
            waiting: depthByKind.values.reduce(0, +), depthByKind: depthByKind, running: openAnswerMail.all)
    }

    /// Delivers the user's answer to a pending elicitation on this session.
    ///
    /// When the run plane delivered the answer to the waiting run, the
    /// answer also goes to the session as ``MailBody/elicitationAnswer(id:response:)``
    /// mail, as if the user made one more post (`mailbox.md`, section 5). It
    /// is user-type mail, so it starts an answer.
    ///
    /// - Returns: The ``ElicitationAnswerDelivery``.
    @discardableResult
    nonisolated func respond(elicitationId: String, response: ElicitationResponse) async -> ElicitationAnswerDelivery {
        await deliver(toElicitation: elicitationId, orReturn: .noPendingElicitation) { id in
            let delivery = await runPlane.respond(elicitationId: id, response)
            if delivery == .delivered {
                postElicitationAnswer(id: id, response: response)
            }
            return delivery
        }
    }

    /// Puts the answer to the elicitation `id` in the queue as
    /// ``MailBody/elicitationAnswer(id:response:)`` mail, with the sender
    /// ``MailSender/elicitation(_:)``.
    ///
    /// - Parameters:
    ///   - id: The id of the elicitation.
    ///   - response: The answer of the user.
    private nonisolated func postElicitationAnswer(id: ULID, response: ElicitationResponse) {
        let answer = Mail(sender: .elicitation(id), body: .elicitationAnswer(id: id, response: response))
        // The mail has a new id, so the session refuses it only after
        // ``close()``. Then no answer reads it anymore, and the run already
        // has the answer.
        _ = try? mail(answer)
    }

    /// Signals that the out-of-band flow of an accepted URL-mode elicitation finished.
    /// - Returns: The ``ElicitationCompletionDelivery``.
    @discardableResult
    nonisolated func complete(elicitationId: String) async -> ElicitationCompletionDelivery {
        await deliver(toElicitation: elicitationId, orReturn: .noPendingElicitation) {
            await runPlane.complete(elicitationId: $0)
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
