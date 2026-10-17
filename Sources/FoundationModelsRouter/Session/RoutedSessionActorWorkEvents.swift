import FoundationModelsExtras
import Synchronization

/// The work state that the work events of a session reported last, and the
/// count of the work starts (``RoutedSessionActor/workEvents``).
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

    /// The count of the work starts (``RoutedSessionActor/noteWorkStarted()``).
    /// A check for the end of the work compares it before and after its reads,
    /// so a start during the reads stops the work-end event.
    var starts: UInt64 = 0
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

/// ``RoutedSessionActor``'s work events: ``SessionEvent/workStarted`` when the
/// session gets work while it had none, and ``SessionEvent/workEnded`` when
/// the session has no work any more. The rules of the work are the rules of
/// ``isIdle()``, so the work-end event comes when ``awaitIdle()`` can return
/// `true`.
///
/// Each place where work starts calls ``noteWorkStarted()`` before the first
/// output of the work: the start of an answer of the pump, the put of
/// user-type mail (``mail(_:)``), a requested compaction
/// (``compact(prompt:budget:)``), and an answer that resumes a run that waits
/// only for the user (``noteWorkStart(answering:with:)``).
///
/// Each change of the work that can end the work calls ``workDidChange()``
/// after the last output of the change: the end of the pump, the settlement
/// of a run, the end of a requested compaction, the end of a sweep, and a
/// question of a run. The check of the end (``reportWorkEndIfIdle()``) does
/// the reads of ``isIdle()``, and then, under the lock of ``workEvents``, the
/// last check of ``isIdle()``. Each start takes the same lock. Thus a start
/// never comes between the last check and the work-end event, and the events
/// come in turns.
extension RoutedSessionActor {
    /// Records that work starts, and sends ``SessionEvent/workStarted`` when
    /// the last work event said that the session had no work. It also counts
    /// the start, so a check of the end that read the session before this
    /// start sends no work-end event.
    ///
    /// The caller calls it before the first output of the work. After
    /// ``close()`` started, it sends nothing.
    nonisolated func noteWorkStarted() {
        workEvents.withLock { state in
            state.starts &+= 1
            guard state.phase == .idle else { return }
            state.phase = .working
            emitWorkEvent(.workStarted)
        }
    }

    /// Reports one change of the work of this session: to each
    /// ``awaitIdle()`` call that waits, and to the work events
    /// (``reportWorkEndIfIdle()``).
    func workDidChange() async {
        signalWorkChange()
        await reportWorkEndIfIdle()
    }

    /// Sends ``SessionEvent/workEnded`` when the last work event said that
    /// the session has work, and the session has no work now (``isIdle()``).
    ///
    /// The reads of the session suspend. The last check of ``isIdle()`` and
    /// the event come under the lock of ``workEvents``, and only when no work
    /// started during the reads (``WorkEventState/starts``).
    func reportWorkEndIfIdle() async {
        let startsBefore = workEvents.withLock { $0.phase == .working ? $0.starts : nil }
        guard let startsBefore, let snapshot = await readIdleState() else { return }
        workEvents.withLock { state in
            guard state.phase == .working, state.starts == startsBefore,
                isIdle(startedAt: snapshot.workId, reading: snapshot.reads)
            else { return }
            state.phase = .idle
            emitWorkEvent(.workEnded)
        }
    }

    /// Stops the work events: ``close()`` started, and no work event comes
    /// any more. ``endIdleWaits()`` calls it.
    func endWorkEvents() {
        workEvents.withLock { $0.phase = .closed }
    }

    /// Records that `answer` to the question `id` is about to go to the run
    /// plane, and notes the start of work (``noteWorkStarted()``) when the
    /// answer resumes the run that asks the question. The start comes before
    /// the run plane resumes the run, so it comes before each output of the
    /// resumed run.
    ///
    /// - Parameters:
    ///   - id: The id of the question.
    ///   - answer: The answer of the user.
    /// - Returns: `true` when this call noted a start of work.
    func noteWorkStart(answering id: ULID, with answer: QuestionAnswer) async -> Bool {
        let isOpen = await runPlane.openElicitations().contains { $0.elicitationId == id }
        guard isOpen, askedQuestions.resumesRun(answering: id, with: answer) else { return false }
        noteWorkStarted()
        return true
    }

    /// Records what the run plane did with an answer to the question `id`
    /// (``AskedQuestions/noteAnswered(_:outcome:)``). When
    /// ``noteWorkStart(answering:with:)`` noted a start and the run did not
    /// resume, for example because another answer came first, or because a
    /// cancel of the run plane ended the question first, the work changed
    /// back (``workDidChange()``).
    ///
    /// - Parameters:
    ///   - id: The id of the question.
    ///   - outcome: What the run plane did with the answer.
    ///   - startedWork: What ``noteWorkStart(answering:with:)`` returned.
    func noteAnswer(to id: ULID, outcome: QuestionAnswerOutcome, startedWork: Bool) async {
        askedQuestions.noteAnswered(id, outcome: outcome)
        guard startedWork, outcome != .resumedRun else { return }
        await workDidChange()
    }

    /// Records a question that a run asked, after its live event, and
    /// reports the change of the work: the run can now wait only for the
    /// user, and then it is no work (``isIdle(startedAt:reading:)`` reads
    /// ``askedQuestions``). The question mail starts no answer, so no end of
    /// the pump reports this change.
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
        await workDidChange()
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
