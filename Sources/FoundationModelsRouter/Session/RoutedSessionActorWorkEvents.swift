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
/// The session needs these facts for two reasons:
///
/// - A run that waits only for the user is no work only after its question
///   is on the output (``SessionEvent/elicitationRequested(_:)``). So the
///   work-end event never comes before the question that ends the work.
/// - Before the run plane gets an answer, the session must know whether the
///   answer resumes the run: a URL-mode accept does not resume it, and only
///   the completion of an accepted URL-mode question resumes it.
///
/// A question leaves the record when an answer resumes its run. A question
/// that a sweep rejected stays, so the record is bounded by the count of
/// the questions that the runs of the session asked.
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
    }

    /// The state of each recorded question, by its id.
    private var states: [ULID: State] = [:]

    /// Records the question of `request`.
    ///
    /// - Parameter request: The question that a run asked.
    mutating func noteAsked(_ request: ElicitationRequest) {
        states[request.elicitationId] = request.mode == .url ? .url : .form
    }

    /// Whether the journal recorded the question `id`.
    ///
    /// - Parameter id: The id of a question.
    /// - Returns: `true` when the question is in the record.
    func wasAsked(_ id: ULID) -> Bool {
        states[id] != nil
    }

    /// Records what the run plane did with an answer to the question `id`.
    /// A question whose run resumed is closed, so it leaves the record.
    ///
    /// - Parameters:
    ///   - id: The id of the question.
    ///   - outcome: What the run plane did with the answer.
    mutating func noteAnswered(_ id: ULID, outcome: QuestionAnswerOutcome) {
        switch outcome {
        case .resumedRun:
            states[id] = nil
        case .acceptedAwaitingCompletion:
            states[id] = .acceptedURL
        case .noQuestion:
            break
        }
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
        let state = states[id] ?? .form
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
    /// - Parameter event: The `.elicitation` event that the journal recorded.
    func noteQuestionAsked(_ event: OperationEvent) async {
        if let request = event.elicitation {
            askedQuestions.noteAsked(request)
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
