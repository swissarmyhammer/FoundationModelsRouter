import FoundationModelsExtras
import Synchronization

/// The work state that the work events of a session reported last, and the
/// count of the begins of the leases of the own work of the session
/// (``RoutedSessionActor/workEvents``).
struct WorkEventState: Sendable {
    /// The work state that the last work event reported.
    enum Phase: Sendable, Equatable {
        /// No work event came yet, or the last one was
        /// ``SessionEvent/workEnded``.
        case idle

        /// The last work event was ``SessionEvent/workStarted``.
        case working

        /// ``RoutedSession/close()`` started. No work event comes any more.
        case closed
    }

    /// The work state that the last work event reported.
    var phase = Phase.idle

    /// The count of the begins of the leases of the own work of the session
    /// (``RoutedSessionActor/beginWork(_:id:)``). The check of the work end
    /// compares it before and after its read of the run plane, so a begin
    /// during the read stops the work-end event.
    var begins: UInt64 = 0
}

/// One answer of the user to an open question of a run.
enum QuestionAnswer: Sendable {
    /// The answer of ``RoutedSession/respond(elicitationId:response:)``.
    case response(ElicitationResponse)

    /// The completion of an accepted URL-mode question
    /// (``RoutedSession/complete(elicitationId:)``).
    case completion
}

/// What the run plane did with one answer of the user.
enum QuestionAnswerOutcome: Sendable, Equatable {
    /// The answer resumed the run that asked the question.
    case resumedRun

    /// The user accepted a URL-mode question. The run resumes at the
    /// completion of the question.
    case acceptedAwaitingCompletion

    /// The run plane had no question for the answer. Nothing occurred.
    case noQuestion
}

/// The questions of the runs of one session that the journal recorded and
/// that are possibly open, with the state of each one
/// (``RoutedSessionActor/askedQuestions``).
///
/// The session needs these facts for four reasons:
///
/// - A run that waits only for the user is no work only after its question
///   is on the output (``SessionEvent/elicitationRequested(_:)``). So the
///   work-end event never comes before the question that ends the work.
/// - Before the run plane gets an answer, the session must know whether the
///   answer resumes the run: a URL-mode accept does not resume it, and only
///   the completion of an accepted URL-mode question resumes it.
/// - The session sends ``SessionEvent/elicitationCompleted(_:)`` one time
///   for a URL-mode question whose flow completed (task ^rkh6k6m). The record
///   knows the mode of the question and the run mail that holds it
///   (``complete(_:postedBy:)``).
/// - The session sends ``SessionEvent/elicitationEnded(_:)`` one time for a
///   question that a cancel of the run plane ended with no answer of the
///   client (task ^fqb5rjr, ``end(_:)``).
///
/// The run plane of Extras decides how each question ends: an answer of the
/// client, a completion of its flow, or a cancel of the run plane. It posts
/// each completion and each end, and the record only makes sure that each
/// event goes out one time, for a question that the journal recorded. The
/// session makes no end of a question itself.
///
/// A question leaves the record when an answer resumes its run, when the run
/// plane posts its completion, or when the run plane posts its end. There is
/// one exception: the completion of an accepted URL-mode question through
/// the session keeps it, marked as completed, until the run plane posts that
/// completion to the journal. The completion and the post can come in each
/// order, so the post takes the question out, and a later answer finds no
/// question. Thus the record is bounded by the count of the questions that
/// the runs of the session asked.
struct AskedQuestions: Sendable {
    /// The state of one recorded question.
    enum State: Sendable, Equatable {
        /// A form-mode question.
        case form

        /// A URL-mode question that the user did not accept.
        case url

        /// A URL-mode question that the user accepted. Its run resumes at
        /// the completion of the question.
        case acceptedURL

        /// A URL-mode question whose flow the client completed through the
        /// session. The question waits only for the post of its completion
        /// (``AskedQuestions/complete(_:postedBy:)``), and that post always
        /// comes.
        case completed
    }

    /// One recorded question.
    private struct Question: Sendable {
        /// The state of the question.
        var state: State

        /// The id of the run mail that holds the question, or `nil` when the
        /// question made no mail (``RunEventOrigin/mailID``).
        let mailID: MailID?

        /// The requested schema of a form-mode question. `nil` for a
        /// URL-mode question.
        let requestedSchema: ElicitationRequestedSchema?

        /// Whether a ``SubagentQuestionRelay`` sent the question up from a
        /// child (``ElicitationRequest/isRelayed``). An answer to it gives no
        /// answer mail to this session.
        let isRelayed: Bool

        /// Whether the question is a URL-mode question: its completion gives
        /// ``SessionEvent/elicitationCompleted(_:)``.
        var takesCompletion: Bool {
            switch state {
            case .url, .acceptedURL, .completed:
                return true
            case .form:
                return false
            }
        }
    }

    /// Each recorded question, by its id.
    private var questions: [ULID: Question] = [:]

    /// The count of the questions that the record took in
    /// (``noteAsked(_:mailID:)``) since the session started. A question that
    /// leaves the record does not decrease it. Thus a reader that reads the
    /// count before a suspension and again after it knows whether the journal
    /// recorded a question in that time
    /// (``RoutedSessionActor/finishFeedsAfterTheirQuestionsEnded()``).
    private(set) var recordedCount = 0

    /// Records the question of `request`, with the requested schema of a
    /// form-mode question.
    ///
    /// - Parameters:
    ///   - request: The question that a run asked.
    ///   - mailID: The id of the run mail that holds the question, or `nil`.
    mutating func noteAsked(_ request: ElicitationRequest, mailID: MailID?) {
        recordedCount += 1
        let isForm = request.mode == .form
        questions[request.elicitationId] = Question(
            state: isForm ? .form : .url, mailID: mailID, requestedSchema: isForm ? request.requestedSchema : nil,
            isRelayed: request.isRelayed)
    }

    /// Whether the recorded question `id` is a question that a
    /// ``SubagentQuestionRelay`` sent up from a child. Only the level whose
    /// own run asked a question mails the answer to its model.
    ///
    /// - Parameter id: The id of a question.
    /// - Returns: `true` when the record holds the question and a relay sent
    ///   it up.
    func isRelayed(_ id: ULID) -> Bool {
        questions[id]?.isRelayed ?? false
    }

    /// Takes the URL-mode question `id` out of the record, because the run
    /// plane posted the completion of its flow.
    ///
    /// The completion goes out only for a URL-mode question in the record.
    /// The question leaves the record, so a second post of the same
    /// completion gives nothing, and a later answer to it finds no question.
    ///
    /// - Parameters:
    ///   - id: The id of the question.
    ///   - poster: The origin of the work that posted the completion.
    /// - Returns: The origin of ``SessionEvent/elicitationCompleted(_:)``: the
    ///   run mail that holds the question, and `poster`. `nil` when no event
    ///   goes out.
    mutating func complete(_ id: ULID, postedBy poster: Origin) -> RunEventOrigin? {
        guard let question = questions[id], question.takesCompletion else { return nil }
        questions[id] = nil
        return RunEventOrigin(mailID: question.mailID, poster: poster)
    }

    /// Takes the question `id` out of the record, because the run plane
    /// posted its end: a cancel of the run plane ended it with no answer of
    /// the client.
    ///
    /// The question leaves the record, so a second post of the same end
    /// gives nothing.
    ///
    /// - Parameter id: The id of the question.
    /// - Returns: `true` when the question was in the record, and
    ///   ``SessionEvent/elicitationEnded(_:)`` goes out. `false` for a
    ///   question that the journal did not record.
    mutating func end(_ id: ULID) -> Bool {
        questions.removeValue(forKey: id) != nil
    }

    /// The answer to the question `id` that the session mails to the model
    /// (``MailBody/elicitationAnswer(id:response:)``). It is the answer that
    /// the run gets from ``ToolContext/elicit(_:)``.
    ///
    /// An accepted answer to a form-mode question whose content does not
    /// agree with the requested schema
    /// (``ElicitationRequestedSchema/validationFailure(of:)``) becomes a
    /// decline. Its reason is
    /// ``ElicitationRequestedSchema/invalidAnswerReasonPrefix`` followed by
    /// the failure. Each other answer does not change. An answer to a
    /// question with no recorded schema, for example a question that a run
    /// asked before a restore, does not change.
    ///
    /// - Parameters:
    ///   - id: The id of the question.
    ///   - response: The answer of the user.
    /// - Returns: `response`, or the decline that the run gets.
    func mailedResponse(answering id: ULID, with response: ElicitationResponse) -> ElicitationResponse {
        guard response.action == .accept,
            let schema = questions[id]?.requestedSchema,
            let failure = schema.validationFailure(of: response.content)
        else { return response }
        return .decline(reason: ElicitationRequestedSchema.invalidAnswerReasonPrefix + failure)
    }

    /// Whether the journal recorded the question `id`.
    ///
    /// - Parameter id: The id of a question.
    /// - Returns: `true` when the question is in the record.
    func wasAsked(_ id: ULID) -> Bool {
        questions[id] != nil
    }

    /// Whether a question of `ids` is still in the record. A question whose
    /// completion post or end post is on its way stays in the record until
    /// the journal handles that post, so a stop of the session waits until
    /// this is `false` (``RoutedSessionActor/awaitQuestionPosts(of:)``).
    ///
    /// - Parameter ids: The ids of questions.
    /// - Returns: `true` when the record holds a question of `ids`.
    func holdsQuestion(amongAnyOf ids: [ULID]) -> Bool {
        ids.contains(where: wasAsked)
    }

    /// Records what the run plane did with an answer to the question `id`.
    /// A question whose run resumed is closed, so it leaves the record. The
    /// completion of an accepted URL-mode question is the exception: the
    /// question stays as ``State/completed`` until the run plane posts the
    /// completion (``complete(_:postedBy:)``).
    ///
    /// - Parameters:
    ///   - id: The id of the question.
    ///   - outcome: What the run plane did with the answer.
    mutating func noteAnswered(_ id: ULID, outcome: QuestionAnswerOutcome) {
        guard let question = questions[id] else { return }
        switch outcome {
        case .resumedRun:
            questions[id] = Self.questionAfterItsRunResumed(question)
        case .acceptedAwaitingCompletion where question.state == .url:
            questions[id]?.state = .acceptedURL
        case .acceptedAwaitingCompletion, .noQuestion:
            break
        }
    }

    /// The record of `question` after an answer resumed its run.
    ///
    /// - Parameter question: The question.
    /// - Returns: `nil`: the question leaves the record. For an accepted
    ///   URL-mode question, the question as ``State/completed``, until the
    ///   run plane posts its completion.
    private static func questionAfterItsRunResumed(_ question: Question) -> Question? {
        guard question.state == .acceptedURL else { return nil }
        var completed = question
        completed.state = .completed
        return completed
    }

    /// Whether `answer` to the open question `id` resumes the run that asks
    /// it.
    ///
    /// - Parameters:
    ///   - id: The id of an open question.
    ///   - answer: The answer of the user.
    /// - Returns: `true` for each answer to a form-mode question, also to a
    ///   question that is not in the record yet, for a decline or a cancel
    ///   of a URL-mode question that the user did not accept, and for the
    ///   completion of an accepted URL-mode question.
    func resumesRun(answering id: ULID, with answer: QuestionAnswer) -> Bool {
        let state = questions[id]?.state ?? .form
        switch answer {
        case .response(let response):
            return state == .form || (state == .url && response.action != .accept)
        case .completion:
            return state == .acceptedURL
        }
    }
}

/// The kinds of the leases that the own work of a session holds in its work
/// registry (``RoutedSessionActor/workRegistry``). The tooling gives the
/// kinds of the tool work (`WorkKind.backgroundRun` and the others).
extension WorkKind {
    /// An answer of the pump: from the take of its mail to its terminal
    /// event, with each submission and each continuation of it. A short
    /// lease of a tool inside the answer thus never ends the work.
    public static let generation = WorkKind("generation")

    /// One queued mail that can start an answer: user-type mail, and run mail
    /// that can start a submission by itself (a terminal or a message of a
    /// background run). The lease begins before the put of the mail, and
    /// ends when the mail leaves the queue for good (it is delivered,
    /// withdrawn or cancelled) or goes on hold. Held mail starts no answer
    /// by itself, so it holds no lease.
    public static let mail = WorkKind("mail")

    /// A requested compaction (``RoutedSession/compact(prompt:budget:)``),
    /// from the request to the end of the compaction, or to its skip at a
    /// close.
    public static let compaction = WorkKind("compaction")

    /// The work of the children of the relays of the session
    /// (``SubagentQuestionRelay``): open while the child of one relay works.
    /// The child is a session of its own with a registry of its own. This
    /// lease is only the view of this session on that work.
    public static let relayedChild = WorkKind("relayedChild")

    /// An answer or a completion of the user that resumes a run that waits
    /// only for the user, from before the run plane gets it until the run
    /// plane resumed the run. The resumed run holds its own lease after that.
    public static let questionAnswer = WorkKind("questionAnswer")

    /// The sweep of the background runs of ``RoutedSession/cancelAll()``,
    /// from its start to the journal of the terminal of each swept run.
    public static let sweep = WorkKind("sweep")
}

/// ``RoutedSessionActor``'s work events: ``SessionEvent/workStarted`` when the
/// session gets work while it had none, and ``SessionEvent/workEnded`` when
/// the session has no work any more. The work registry of the session
/// (``workRegistry``) decides: the session has work while one lease of the
/// registry is open.
///
/// The registry gives one `WorkTransition` for each change, and a task of the
/// session reads them in order (``observeWorkTransitions()``). A transition to
/// work sends ``SessionEvent/workStarted`` when the last work event said that
/// the session had no work. A transition to no work runs the check of the
/// work end (``reportWorkEndIfNoWork()``).
///
/// ``SessionEvent/workStarted`` comes before each output of the new work. The
/// task of the transitions can come late, so two more places send it at
/// once: the begin of each lease of the own work of the session
/// (``beginWork(_:id:)``), and each output of the session while the registry
/// has work (``reportWorkStartIfBusy()``).
///
/// ``SessionEvent/workEnded`` is the no-work event: it comes after each
/// output of the work that ended. Each lease ends after the last output of
/// its work, so the transition to no work comes after that output.
///
/// The phase of the work events and each work event are under the lock of
/// ``workEvents``, so the events come in turns, and ``SessionEvent/workStarted``
/// comes first.
extension RoutedSessionActor {
    /// Begins a lease of the own work of the session in the registry, and
    /// sends ``SessionEvent/workStarted`` when it is due. The caller calls it
    /// before the first output of the work, and ends the lease after the
    /// last output of the work, in a `defer` or at the one place where the
    /// work ends.
    ///
    /// The call also counts the begin (``WorkEventState/begins``). A check of
    /// the work end that read the run plane before this begin then sends no
    /// work-end event, because the work that this lease starts can resume a
    /// run and make a new question.
    ///
    /// - Parameters:
    ///   - kind: The kind of the work.
    ///   - id: The id of the work.
    /// - Returns: The lease.
    nonisolated func beginWork(_ kind: WorkKind, id: String) -> BackgroundWork {
        workEvents.withLock { $0.begins &+= 1 }
        let lease = workRegistry.begin(kind, id: id)
        reportWorkStartIfBusy()
        return lease
    }

    /// Sends ``SessionEvent/workStarted`` when the last work event said that
    /// the session had no work, and the registry has work now. After
    /// ``close()`` started, it sends nothing.
    nonisolated func reportWorkStartIfBusy() {
        workEvents.withLock { state in
            guard state.phase == .idle, workRegistry.hasWork else { return }
            state.phase = .working
            emitWorkEvent(.workStarted)
        }
    }

    /// Reads the transitions of the registry in order, until the registry
    /// closes, and reports each one (``workTransitioned(_:)``). The session
    /// starts this task one time, when it is made, before any lease begins.
    /// The task keeps no strong reference to the session between two
    /// transitions.
    nonisolated func observeWorkTransitions() {
        let transitions = workRegistry.transitions()
        Task { [weak self] in
            for await transition in transitions {
                await self?.workTransitioned(transition)
            }
        }
    }

    /// Reports one transition of the registry: a transition to work sends
    /// ``SessionEvent/workStarted`` when the last work event said that the
    /// session had no work, also when the work ended again since. A
    /// transition to no work runs the check of the work end. Each transition
    /// is a change of the work (``signalWorkChange()``).
    ///
    /// - Parameter transition: The transition.
    func workTransitioned(_ transition: WorkTransition) async {
        switch transition {
        case .workStarted:
            workEvents.withLock { state in
                guard state.phase == .idle else { return }
                state.phase = .working
                emitWorkEvent(.workStarted)
            }
        case .noWork:
            _ = await reportWorkEndIfNoWork()
        }
        signalWorkChange()
    }

    /// The check of the work end. Sends ``SessionEvent/workEnded`` when the
    /// last work event said that the session has work, and the session has
    /// no work now: the registry has no open lease, and the journal recorded
    /// each open question of the runs.
    ///
    /// The run plane suspends the lease of a run when the run asks the user,
    /// before the question is on the output. The question is no work only
    /// after its ``SessionEvent/elicitationRequested(_:)``, so the check reads
    /// the open questions (`RunPlane.openElicitations()`), and the record of
    /// the question (``noteQuestionAsked(_:mailID:)``) runs the check again.
    ///
    /// The read of the questions suspends. The last check and the event come
    /// under the lock of ``workEvents``, and only when the registry still has
    /// no open lease and no lease of the own work began during the read
    /// (``WorkEventState/begins``). An answer of the user begins such a lease
    /// before the run plane resumes the run, so a run that resumed and asked
    /// a new question during the read stops the event. The next transition
    /// to no work runs the check again.
    ///
    /// - Returns: `true` when the session has no work now.
    @discardableResult
    func reportWorkEndIfNoWork() async -> Bool {
        let beginsBefore = workEvents.withLock { $0.begins }
        guard await isIdle() else { return false }
        return workEvents.withLock { state in
            guard state.begins == beginsBefore, !workRegistry.hasWork else { return false }
            if state.phase == .working {
                state.phase = .idle
                emitWorkEvent(.workEnded)
            }
            return true
        }
    }

    /// Stops the work events: ``close()`` started, and no work event comes
    /// any more. ``endIdleWaits()`` calls it.
    func endWorkEvents() {
        workEvents.withLock { $0.phase = .closed }
    }

    /// Whether `answer` to the question `id` resumes the run that asks it:
    /// the question is open in the run plane, and the answer is one that
    /// resumes the run (``AskedQuestions/resumesRun(answering:with:)``).
    ///
    /// - Parameters:
    ///   - id: The id of the question.
    ///   - answer: The answer of the user.
    /// - Returns: `true` when the answer resumes the run.
    func answerResumesRun(_ id: ULID, with answer: QuestionAnswer) async -> Bool {
        let isOpen = await runPlane.openElicitations().contains { $0.elicitationId == id }
        return isOpen && askedQuestions.resumesRun(answering: id, with: answer)
    }

    /// Records what the run plane did with an answer to the question `id`
    /// (``AskedQuestions/noteAnswered(_:outcome:)``).
    ///
    /// - Parameters:
    ///   - id: The id of the question.
    ///   - outcome: What the run plane did with the answer.
    func noteAnswer(to id: ULID, outcome: QuestionAnswerOutcome) {
        askedQuestions.noteAnswered(id, outcome: outcome)
    }

    /// Records a question that a run asked, after its live event, and runs
    /// the check of the work end (``reportWorkEndIfNoWork()``): the run can
    /// now wait only for the user, and then it is no work.
    ///
    /// A question that a ``SubagentQuestionRelay`` sent up is now recorded,
    /// so the relay can read the next event of its child
    /// (``awaitRelayedQuestionRecorded(_:)``).
    ///
    /// - Parameters:
    ///   - event: The `.elicitation` event that the journal recorded.
    ///   - mailID: The id of the run mail that holds the question, or `nil`
    ///     when the question made no mail.
    func noteQuestionAsked(_ event: OperationEvent, mailID: MailID?) async {
        if let request = event.elicitation {
            askedQuestions.noteAsked(request, mailID: mailID)
            if relayedQuestions.noteRecorded(request.elicitationId) {
                relayChanges.signal()
            }
        }
        await reportWorkEndIfNoWork()
        signalWorkChange()
    }

    /// Sends one work event to the output, with the origin
    /// ``Origin/system``.
    ///
    /// - Parameter event: ``SessionEvent/workStarted`` or
    ///   ``SessionEvent/workEnded``.
    private nonisolated func emitWorkEvent(_ event: SessionEvent) {
        OriginContext.$current.withValue(.system) {
            emitSessionScopedEvent(event)
        }
    }
}

extension QuestionAnswerOutcome {
    /// The outcome of an answer of ``RoutedSession/respond(elicitationId:response:)``.
    ///
    /// - Parameter delivery: What the run plane did with the answer.
    init(_ delivery: ElicitationAnswerDelivery) {
        switch delivery {
        case .delivered:
            self = .resumedRun
        case .acceptedAwaitingCompletion:
            self = .acceptedAwaitingCompletion
        case .noPendingElicitation:
            self = .noQuestion
        }
    }

    /// The outcome of a completion of ``RoutedSession/complete(elicitationId:)``.
    ///
    /// - Parameter delivery: What the run plane did with the completion.
    init(_ delivery: ElicitationCompletionDelivery) {
        switch delivery {
        case .completed:
            self = .resumedRun
        case .noPendingElicitation:
            self = .noQuestion
        }
    }
}
