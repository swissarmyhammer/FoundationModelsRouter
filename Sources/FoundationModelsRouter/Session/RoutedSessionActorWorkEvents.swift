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

/// How the end of one question (``SessionEvent/elicitationEnded(_:)``) goes
/// to the output. Each place that ends a question gives its own delivery,
/// and an end that waits for an answer on its way keeps that delivery
/// (``AskedQuestions``), so a late end goes out the same way as an end that
/// goes out at once.
enum QuestionEndDelivery: Sendable, Equatable {
    /// As a live event of the terminal of the run
    /// (``RoutedSessionActor/deliverLive(_:origin:)``): the output drops it
    /// when it drops the poster, and a running answer gets it in its sink.
    case runEvent(RunEventOrigin)

    /// To the session-scoped output, with this origin
    /// (``RoutedSessionActor/emitQuestionEnds(_:at:)``): the origin of the
    /// cancel-all signal, or ``Origin/system`` for ``RoutedSession/close()``.
    case session(Origin)
}

/// The result of one end check (``AskedQuestions/endQuestions(ofRun:notIn:via:)``).
struct QuestionEndCheck: Sendable, Equatable {
    /// The ids of the questions that ended now, in id order. The caller
    /// sends one end for each.
    var ended: [ULID] = []

    /// The ids of the questions whose end waits for an answer on its way, in
    /// id order. The caller waits until those answers returned
    /// (``AskedQuestions/hasAnswerOnItsWay(toAnyOf:)``) before the terminal
    /// event that the ends must come before.
    var deferred: [ULID] = []
}

/// The questions of the runs of one session that the journal recorded and
/// that are possibly open, with the state of each one
/// (``RoutedSessionActor/askedQuestions``).
///
/// The session needs these facts for three reasons:
///
/// - A run that waits only for the user is no work only after its question
///   is on the output (``SessionEvent/elicitationRequested(_:)``). So the
///   work-end event never comes before the question that ends the work.
/// - Before the run plane gets an answer, the session must know whether the
///   answer resumes the run: a URL-mode accept does not resume it, and only
///   the completion of an accepted URL-mode question resumes it.
/// - The session sends ``SessionEvent/elicitationEnded(_:)`` for a question
///   that ended with no answer of the client (task ^fqb5rjr). The record
///   knows which questions an answer of the client resumed, and which
///   answers of the client are on their way to the run plane.
///
/// A question leaves the record when an answer resumes its run. A question
/// that ended with no answer of the client stays, marked as ended, so a later
/// answer to it goes no further and it gets no second end. Thus the record
/// is bounded by the count of the questions that the runs of the session
/// asked.
///
/// An answer of the client and the end of a question by the run plane can
/// come at the same time. The run plane decides which one comes first, and
/// the session learns it only when the answer returns from the run plane.
/// Thus an end check does not end a question that has an answer on its way:
/// it keeps the delivery of its end (``Question/deferredEnd``), and the
/// question is no longer open. A later end check and a later answer do not
/// touch it, so the first end check owns its one end. When the answers
/// returned and the run plane had no question for them, the question ended
/// with no answer of the client, and ``noteAnswered(_:outcome:)`` gives that
/// delivery. When an answer resumed the run, the client answered, and no end
/// comes. The end check waits until the answers returned
/// (``hasAnswerOnItsWay(toAnyOf:)``) before the terminal event that the end
/// must come before. An answer returns with no wait for a terminal event, so
/// this wait ends.
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

        /// The question ended with no answer of the client, and the session
        /// sent its end. An answer to it goes no further.
        case ended
    }

    /// One recorded question.
    private struct Question: Sendable {
        /// The state of the question.
        var state: State

        /// The completion token of the run that asks the question. For a
        /// question of a mounted call, the token of the mounting run.
        let runToken: String

        /// The requested schema of a form-mode question. `nil` for a
        /// URL-mode question.
        let requestedSchema: ElicitationRequestedSchema?

        /// The count of the answers of the client that are on their way to
        /// the run plane (``beginAnswer(to:)``).
        var answersOnTheirWay = 0

        /// The delivery of the end of the question, when an end check found
        /// the question gone from the run plane while an answer was on its
        /// way. `nil` when no end check found that.
        var deferredEnd: QuestionEndDelivery?

        /// Whether the question is still open for the session: it did not
        /// end with no answer of the client, and its end does not wait for
        /// an answer on its way.
        var isOpen: Bool {
            state != .ended && deferredEnd == nil
        }
    }

    /// Each recorded question, by its id.
    private var questions: [ULID: Question] = [:]

    /// Records the question of `request`, with the requested schema of a
    /// form-mode question.
    ///
    /// - Parameters:
    ///   - request: The question that a run asked.
    ///   - runToken: The completion token of the run that asks it.
    mutating func noteAsked(_ request: ElicitationRequest, runToken: String) {
        let isForm = request.mode == .form
        questions[request.elicitationId] = Question(
            state: isForm ? .form : .url, runToken: runToken, requestedSchema: isForm ? request.requestedSchema : nil)
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

    /// Whether an end check found the question `id` gone while an answer was
    /// on its way, and its end now waits for that answer. Only the tests
    /// read it, after a change of ``RoutedSessionActor/stateChanges``.
    ///
    /// - Parameter id: The id of a question.
    /// - Returns: `true` when the end of the question waits for an answer.
    func hasDeferredEnd(of id: ULID) -> Bool {
        questions[id]?.deferredEnd != nil
    }

    /// Whether the record has an open question of the run of `runToken`.
    /// An end check reads the run plane only when this is `true`.
    ///
    /// - Parameter runToken: The completion token of a run.
    /// - Returns: `true` when a question of that run did not end yet, and
    ///   its end does not wait for an answer on its way.
    func hasOpenQuestions(ofRun runToken: String) -> Bool {
        questions.values.contains { $0.isOpen && $0.runToken == runToken }
    }

    /// Whether an answer of the client to one of the questions `ids` is still
    /// on its way to the run plane. An end check that deferred the ends of
    /// `ids` waits until this is `false`: then each of those ends went out,
    /// or an answer resumed the run and no end comes.
    ///
    /// - Parameter ids: The ids of questions.
    /// - Returns: `true` when a question of `ids` that is still in the record
    ///   has an answer on its way.
    func hasAnswerOnItsWay(toAnyOf ids: [ULID]) -> Bool {
        ids.contains { (questions[$0]?.answersOnTheirWay ?? 0) > 0 }
    }

    /// Whether an end check holds the end of a question for an answer on its
    /// way, whichever check owns that end: the journal at the terminal of a
    /// run, a cancel-all signal, or ``RoutedSession/close()``. Close waits
    /// until this is `false` before the feeds end: then each such end went
    /// out, or an answer resumed the run and no end comes.
    var hasDeferredEnds: Bool {
        questions.values.contains { $0.deferredEnd != nil }
    }

    /// Records that an answer of the client to the question `id` goes to the
    /// run plane now.
    ///
    /// - Parameter id: The id of the question.
    /// - Returns: `false` when the question ended with no answer of the
    ///   client, or its end waits for an answer that is already on its way:
    ///   the answer must not go to the run plane. `true` otherwise, also for
    ///   a question that is not in the record.
    mutating func beginAnswer(to id: ULID) -> Bool {
        guard let question = questions[id] else { return true }
        guard question.isOpen else { return false }
        questions[id]?.answersOnTheirWay += 1
        return true
    }

    /// Records what the run plane did with an answer to the question `id`.
    /// A question whose run resumed is closed, so it leaves the record.
    ///
    /// - Parameters:
    ///   - id: The id of the question.
    ///   - outcome: What the run plane did with the answer.
    /// - Returns: The delivery of the end of the question, when an end check
    ///   found the question gone while this answer was on its way, the
    ///   answer did not resume the run, and no other answer is on its way.
    ///   The caller sends the end through this delivery. `nil` otherwise.
    mutating func noteAnswered(_ id: ULID, outcome: QuestionAnswerOutcome) -> QuestionEndDelivery? {
        guard var question = questions[id] else { return nil }
        question.answersOnTheirWay = max(question.answersOnTheirWay - 1, 0)
        switch outcome {
        case .resumedRun:
            questions[id] = nil
            return nil
        case .acceptedAwaitingCompletion:
            question.state = .acceptedURL
        case .noQuestion:
            break
        }
        let end = question.answersOnTheirWay == 0 ? question.deferredEnd : nil
        if end != nil {
            question.state = .ended
            question.deferredEnd = nil
        }
        questions[id] = question
        return end
    }

    /// Ends each open question of the run of `runToken` that is not in
    /// `openIds`, or of each run when `runToken` is `nil`. A question with an
    /// answer on its way does not end now: it keeps `delivery` for its end
    /// (``noteAnswered(_:outcome:)``), and it is no longer open.
    ///
    /// - Parameters:
    ///   - runToken: The completion token of the run, or `nil` for each run.
    ///   - openIds: The ids of the questions that are still open on the run
    ///     plane.
    ///   - delivery: How the end of each question goes to the output.
    /// - Returns: The questions that ended now, and the questions whose end
    ///   waits for an answer on its way.
    mutating func endQuestions(
        ofRun runToken: String?, notIn openIds: Set<ULID>, via delivery: QuestionEndDelivery
    ) -> QuestionEndCheck {
        let candidates = questions.filter { id, question in
            question.isOpen && !openIds.contains(id) && (runToken == nil || question.runToken == runToken)
        }
        var check = QuestionEndCheck()
        for (id, question) in candidates.sorted(by: { $0.key < $1.key }) {
            if question.answersOnTheirWay > 0 {
                questions[id]?.deferredEnd = delivery
                check.deferred.append(id)
            } else {
                questions[id]?.state = .ended
                check.ended.append(id)
            }
        }
        return check
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
    ///   completion of an accepted URL-mode question. `false` for a question
    ///   that ended.
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

    /// Records what the run plane did with an answer to the question `id`.
    /// When ``noteWorkStart(answering:with:)`` noted a start and the run did
    /// not resume, for example because another answer came first, the work
    /// changed back (``workDidChange()``).
    ///
    /// When an end check found the question gone while the answer was on its
    /// way, and the answer did not resume the run, the run plane ended the
    /// question first: the session sends its end now, through the delivery
    /// that the end check kept (``AskedQuestions/noteAnswered(_:outcome:)``,
    /// ``sendQuestionEnds(_:via:)``). Then it reports the return of the
    /// answer (``questionAnswerReturns``), so the end check that waits for it
    /// sends its terminal event after the end.
    ///
    /// - Parameters:
    ///   - id: The id of the question.
    ///   - outcome: What the run plane did with the answer.
    ///   - startedWork: What ``noteWorkStart(answering:with:)`` returned.
    func noteAnswer(to id: ULID, outcome: QuestionAnswerOutcome, startedWork: Bool) async {
        if let delivery = askedQuestions.noteAnswered(id, outcome: outcome) {
            sendQuestionEnds([id], via: delivery)
        }
        questionAnswerReturns.signal()
        guard startedWork, outcome != .resumedRun else { return }
        await workDidChange()
    }

    /// Records a question that a run asked, after its live event, and
    /// reports the change of the work: the run can now wait only for the
    /// user, and then it is no work (``isIdle(startedAt:reading:)`` reads
    /// ``askedQuestions``). The question mail starts no answer, so no end of
    /// the pump reports this change.
    ///
    /// - Parameter event: The `.elicitation` event that the journal recorded.
    func noteQuestionAsked(_ event: OperationEvent) async {
        if let request = event.elicitation {
            askedQuestions.noteAsked(request, runToken: event.correlationID)
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
