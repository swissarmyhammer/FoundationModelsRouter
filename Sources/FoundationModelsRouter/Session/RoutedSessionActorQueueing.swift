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
    /// User-type mail in the queue is work of the session: it holds one
    /// `WorkKind.mail` lease from before the put
    /// (``SessionOutbox/beginMailWork(_:)``) until it leaves the queue for
    /// good. So ``SessionEvent/workStarted`` comes before any output of the
    /// mail. A refused mail ends the lease that this call began.
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
        // The lease begins before the put: from the put on, the pump can take
        // the mail and end the lease.
        let leased = mail.isUserMail && outbox.beginMailWork(mail.id)
        // The screening mark comes before the put too: the pump never takes
        // a mail whose `PrePrompt` chain did not end.
        let screened = beginPromptScreen(of: mail)
        do {
            try outbox.queue.put(mail)
        } catch {
            throw withdrawRefusedMail(
                mail.id, refusal: error, arrival: arrival, subscription: key, madePending: madePending,
                leased: leased, screened: screened)
        }
        if openAnswerMail.contains(mail.id), outbox.queue.cancel(mail.id) != nil {
            throw withdrawRefusedMail(
                mail.id, refusal: MailRefusal.duplicateID(mail.id), arrival: arrival, subscription: key,
                madePending: madePending, leased: leased, screened: screened)
        }
        reportWorkStartIfBusy()
        outbox.noteCaller(
            SessionOutbox.MailCaller(serviceContext: ServiceContext.current, ownWork: SessionOwnWork.current),
            for: mail.id)
        // The record comes before the wake of the pump, so the transcript
        // holds the arrival of the mail before its delivery.
        recordMail([.mailQueued(mail)])
        stateChanges.signal()
        // A screening mail runs its `PrePrompt` chain in the same helper
        // task, after the wake: the pump takes no mail from it on until the
        // chain ends.
        let arrivalTask = arrival.start {
            await self.mailDidArrive()
            if screened {
                await self.screenPrompt(of: mail)
            }
        }
        if screened {
            keepPromptScreen(arrivalTask, of: mail.id)
        }
        return subscription
    }

    /// Undoes what ``mail(_:)`` did for mail that the session refused: the
    /// reserved wake of the pump ends with no task, the subscription
    /// finishes, and the pending record, the lease and the screening mark of
    /// the id end when ``mail(_:)`` made them. A record that other mail with
    /// the same id made stays, because that mail still waits for its terminal
    /// event.
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
    ///   - leased: Whether ``mail(_:)`` began the lease of the id.
    ///   - screened: Whether ``mail(_:)`` marked the id as screening.
    /// - Returns: `refusal`, for the caller to throw.
    private nonisolated func withdrawRefusedMail(
        _ id: MailID,
        refusal: any Error,
        arrival: consuming HelperTaskTracker.Reservation,
        subscription key: ULID,
        madePending: Bool,
        leased: Bool,
        screened: Bool
    ) -> any Error {
        arrival.cancel()
        outputHub.unsubscribe(key)
        if madePending {
            outputHub.endPending(.mail(id))
        }
        if leased {
            outbox.endMailWork([id])
        }
        if screened {
            dropPromptScreen(of: id)
        }
        return refusal
    }

    /// Records the arrival of a catalog-change mail that the outbox put in
    /// the queue (``SessionOutbox/post(catalogNotice:)``): its
    /// ``MailRecord/mailQueued(_:)`` record, a change of ``stateChanges``,
    /// and the new depth of the queue. It wakes no pump: the mail starts no
    /// answer, and it rides the next submission that other mail starts.
    ///
    /// - Parameter mail: The catalog-change mail.
    func catalogNoticeDidArrive(_ mail: Mail) {
        recordMail([.mailQueued(mail)])
        stateChanges.signal()
        recordMailQueueDepth()
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
    /// The mail carries the answer that the run gets
    /// (``AskedQuestions/mailedResponse(answering:with:)``). The run plane
    /// gets the answer of the user unchanged, and ``ToolContext/elicit(_:)``
    /// declines an accepted form answer that does not agree with the
    /// requested schema. For such an answer the mail carries the same
    /// decline, not the content. Thus the model and the run see the same
    /// answer.
    ///
    /// An answer that resumes a run that waits only for the user starts work
    /// of the session. Its lease begins before the run plane gets the
    /// answer (``deliverAnswer(toElicitation:_:orReturn:outcome:through:)``),
    /// so the work-start event comes before each output of the resumed run.
    ///
    /// A question that a ``SubagentQuestionRelay`` sent up from a child
    /// (``AskedQuestions/isRelayed(_:)``) gives no answer mail at this level:
    /// only the level whose own run asked the question mails the answer to
    /// its model. The answer resumes the task of the relay, which gives the
    /// answer to the child. A URL-mode accept does not resume that task, so
    /// it goes down to the child at once (``sendAcceptDown(answering:with:)``).
    ///
    /// - Returns: The ``ElicitationAnswerDelivery``.
    @discardableResult
    nonisolated func respond(elicitationId: String, response: ElicitationResponse) async -> ElicitationAnswerDelivery {
        await deliverAnswer(
            toElicitation: elicitationId, .response(response), orReturn: .noPendingElicitation,
            outcome: QuestionAnswerOutcome.init
        ) { id in
            // Read before the run plane gets the answer: a question whose
            // run resumes leaves the record after this call.
            let mailed = await mailedResponse(answering: id, with: response)
            let isRelayed = await askedQuestions.isRelayed(id)
            let delivery = await runPlane.respond(elicitationId: id, response)
            if delivery == .delivered, !isRelayed {
                postElicitationAnswer(id: id, response: mailed)
            }
            if delivery == .acceptedAwaitingCompletion {
                await sendAcceptDown(answering: id, with: response)
            }
            return delivery
        }
    }

    /// The answer to the question `id` that the session mails to the model
    /// (``AskedQuestions/mailedResponse(answering:with:)``).
    ///
    /// - Parameters:
    ///   - id: The id of the question.
    ///   - response: The answer of the user.
    /// - Returns: `response`, or the decline that the run gets.
    private func mailedResponse(answering id: ULID, with response: ElicitationResponse) -> ElicitationResponse {
        askedQuestions.mailedResponse(answering: id, with: response)
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
    /// work of the session. Its lease begins before the run plane gets the
    /// completion (``deliverAnswer(toElicitation:_:orReturn:outcome:through:)``).
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
    /// ``complete(elicitationId:)`` share. It parses the inbound id. When
    /// `answer` resumes the run that asks the question
    /// (``answerResumesRun(_:with:)``), it begins a `WorkKind.questionAnswer`
    /// lease (``beginWork(_:id:)``), so ``SessionEvent/workStarted`` comes
    /// before each output of the resumed run. It gives the parsed id to
    /// `runPlaneCall`, records what the run plane did
    /// (``noteAnswer(to:outcome:)``), and then ends the lease.
    ///
    /// The run plane decides whether the answer finds its question. A
    /// question that a cancel of the run plane ended
    /// (``SessionEvent/elicitationEnded(_:)``) is not open any more, so the
    /// run plane gives the answer `noPendingElicitation`.
    ///
    /// - Parameters:
    ///   - elicitationId: The inbound id of the question.
    ///   - answer: The answer of the user.
    ///   - noQuestionResult: The result when the id is not a ``ULID``.
    ///   - outcome: What the result of `runPlaneCall` did with the run.
    ///   - runPlaneCall: The call to the run plane, and each step that comes
    ///     directly after it.
    /// - Returns: The result of `runPlaneCall`, or `noQuestionResult`.
    private nonisolated func deliverAnswer<Delivery>(
        toElicitation elicitationId: String,
        _ answer: QuestionAnswer,
        orReturn noQuestionResult: Delivery,
        outcome: (Delivery) -> QuestionAnswerOutcome,
        through runPlaneCall: (ULID) async -> Delivery
    ) async -> Delivery {
        guard let id = ULID(elicitationId) else {
            return noQuestionResult
        }
        let resumesRun = await answerResumesRun(id, with: answer)
        let lease = resumesRun ? beginWork(.questionAnswer, id: id.description) : nil
        // The resumed run holds its own lease from the resume on. An answer
        // that did not resume the run ends the work of this lease alone.
        defer { lease?.end() }
        let delivery = await runPlaneCall(id)
        await noteAnswer(to: id, outcome: outcome(delivery))
        return delivery
    }
}
