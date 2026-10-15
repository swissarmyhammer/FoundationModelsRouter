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
    /// The id is pending in the output (``SessionOutputHub/beginPending(_:)``)
    /// before the put. From the put on, the pump can take the mail and end
    /// it, so a wait for the id always finds it pending or in the ledger.
    ///
    /// The id must be new to the session: not in the queue, and not in the
    /// open answer. The open answer is read before the put and again after
    /// it, because the pump can take a mail with the same id between the
    /// two. A hit after the put, while this mail is still queued, cancels
    /// this mail again.
    ///
    /// A mail that stays in the queue is a change of ``stateChanges``.
    /// User-type mail that stays in the queue is work of the session, so
    /// its start is noted (``noteWorkStarted()``) before any output of the
    /// mail.
    ///
    /// The wake of the pump is a helper task (``helperTasks``), and the
    /// session reserves it before the put (``HelperTaskTracker/reserve()``).
    /// A put that comes before ``close()`` closes the queue thus comes after
    /// the reserve, so the drain of close waits until the wake ended, also
    /// when the wake starts after the drain began. After close began, the
    /// wake starts no pump (``wakePump()``).
    ///
    /// - Parameter mail: The mail to put in the queue.
    /// - Returns: The output of the mail, up to and including its terminal
    ///   event.
    /// - Throws: ``MailRefusal/duplicateID(_:)`` when the queue or the open
    ///   answer has the id, or ``MailRefusal/closed`` after ``close()``.
    nonisolated func mail(_ mail: Mail) throws -> MailSubscription<SessionOutput> {
        guard !openAnswerMail.contains(mail.id) else { throw MailRefusal.duplicateID(mail.id) }
        let (subscription, key) = outputHub.subscribe(to: mail.id)
        let madePending = outputHub.beginPending(.mail(mail.id))
        let arrival = helperTasks.reserve()
        do {
            try outbox.queue.put(mail)
        } catch {
            throw withdrawRefusedMail(
                mail.id, refusal: error, arrival: arrival, subscription: key, madePending: madePending)
        }
        if openAnswerMail.contains(mail.id), outbox.queue.cancel(mail.id) != nil {
            throw withdrawRefusedMail(
                mail.id, refusal: MailRefusal.duplicateID(mail.id), arrival: arrival, subscription: key,
                madePending: madePending)
        }
        if !mail.isRunMail {
            noteWorkStarted()
        }
        outbox.noteCallerContext(ServiceContext.current, for: mail.id)
        // The record comes before the wake of the pump, so the transcript
        // holds the arrival of the mail before its delivery.
        recordMail([.mailQueued(mail)])
        stateChanges.signal()
        _ = arrival.start { await self.mailDidArrive() }
        return subscription
    }

    /// Undoes what ``mail(_:)`` did for mail that the session refused: the
    /// reserved wake of the pump ends with no task, the subscription
    /// finishes, and the pending record of the id ends when this call made
    /// it. A record that other mail with the same id made stays, because that
    /// mail still waits for its terminal event.
    ///
    /// Each refusal path of ``mail(_:)`` throws the result, so all the paths
    /// do the same cleanup.
    ///
    /// - Parameters:
    ///   - id: The id of the refused mail.
    ///   - refusal: The error that refused the mail.
    ///   - arrival: The reserved wake of the pump. This call ends it.
    ///   - key: The key of the subscription of the refused mail.
    ///   - madePending: Whether ``mail(_:)`` made the id pending.
    /// - Returns: `refusal`, for the caller to throw.
    private nonisolated func withdrawRefusedMail(
        _ id: MailID,
        refusal: any Error,
        arrival: consuming HelperTaskTracker.Reservation,
        subscription key: ULID,
        madePending: Bool
    ) -> any Error {
        arrival.cancel()
        outputHub.unsubscribe(key)
        if madePending {
            outputHub.endPending(.mail(id))
        }
        return refusal
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
    /// An answer that resumes a run that waits only for the user starts work
    /// of the session. The start is noted before the run plane gets the
    /// answer (``noteWorkStart(answering:with:)``), so it comes before each
    /// output of the resumed run.
    ///
    /// - Returns: The ``ElicitationAnswerDelivery``.
    @discardableResult
    nonisolated func respond(elicitationId: String, response: ElicitationResponse) async -> ElicitationAnswerDelivery {
        await deliverAnswer(
            toElicitation: elicitationId, .response(response), orReturn: .noPendingElicitation,
            outcome: QuestionAnswerOutcome.init
        ) { id in
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
    ///
    /// The completion resumes the run that asked the question, so it starts
    /// work of the session. The start is noted before the run plane gets
    /// the completion (``noteWorkStart(answering:with:)``).
    ///
    /// - Returns: The ``ElicitationCompletionDelivery``.
    @discardableResult
    nonisolated func complete(elicitationId: String) async -> ElicitationCompletionDelivery {
        await deliverAnswer(
            toElicitation: elicitationId, .completion, orReturn: .noPendingElicitation,
            outcome: QuestionAnswerOutcome.init
        ) { id in
            await runPlane.complete(elicitationId: id)
        }
    }

    /// The steps that ``respond(elicitationId:response:)`` and
    /// ``complete(elicitationId:)`` share. It parses the inbound id, records
    /// that the answer is on its way to the run plane
    /// (``beginAnswer(to:)``), notes the start of work when `answer` resumes
    /// the run that asks the question (``noteWorkStart(answering:with:)``),
    /// gives the parsed id to `runPlaneCall`, and then records what the run
    /// plane did (``noteAnswer(to:outcome:startedWork:)``).
    ///
    /// A question that ended with no answer of the client
    /// (``SessionEvent/elicitationEnded(_:)``) takes no answer: the answer
    /// does not go to the run plane, and the call gives `noQuestionResult`.
    ///
    /// It is internal, not private, so a test can give a `runPlaneCall` that
    /// waits at a gate: the answer is then on its way while the test ends
    /// the question.
    ///
    /// - Parameters:
    ///   - elicitationId: The inbound id of the question.
    ///   - answer: The answer of the user.
    ///   - noQuestionResult: The result when the id is not a ``ULID``, or
    ///     when the question ended with no answer of the client.
    ///   - outcome: What the result of `runPlaneCall` did with the run.
    ///   - runPlaneCall: The call to the run plane, and each step that comes
    ///     directly after it.
    /// - Returns: The result of `runPlaneCall`, or `noQuestionResult`.
    nonisolated func deliverAnswer<Delivery>(
        toElicitation elicitationId: String,
        _ answer: QuestionAnswer,
        orReturn noQuestionResult: Delivery,
        outcome: (Delivery) -> QuestionAnswerOutcome,
        through runPlaneCall: (ULID) async -> Delivery
    ) async -> Delivery {
        guard let id = ULID(elicitationId), await beginAnswer(to: id) else {
            return noQuestionResult
        }
        let startedWork = await noteWorkStart(answering: id, with: answer)
        let delivery = await runPlaneCall(id)
        await noteAnswer(to: id, outcome: outcome(delivery), startedWork: startedWork)
        return delivery
    }
}
