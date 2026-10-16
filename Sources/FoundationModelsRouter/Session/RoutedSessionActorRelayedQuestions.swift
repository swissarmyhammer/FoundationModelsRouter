import FoundationModelsExtras

/// The questions that the relays of subagents sent up to the runs of one
/// session, and the work state of the child of each relay
/// (``RoutedSessionActor/relayedQuestions``).
///
/// A ``SubagentQuestionRelay`` sends each question of its child up to the
/// run of this session that drives the child. The task of that question
/// (T_q) asks the same question in this session, and it waits for the
/// answer. The table records each such question until its task settled, so
/// the task knows what it must do in the child when it resumes:
///
/// - The user answered at this level, or the completion came here: the task
///   gives the answer, or the completion, to the child.
/// - The run plane of this session ended the question (a cancel of the run,
///   ``RoutedSession/cancelAll()`` or ``RoutedSession/close()``): the task
///   ends the copy of the question in the child with the same response.
/// - The child ended or completed its copy first: the relay sent that end or
///   that completion up, and the task does nothing in the child.
///
/// The table also keeps the work state of the child of each relay. The idle
/// check reads it: an open run that waits only for the user is still work
/// while the child of a relay of that run works.
///
/// A question leaves the table when its task settled (``settle(_:resumedWith:)``),
/// and a relay leaves it when the relay read the end of the feed of its child
/// (``closeRelay(_:)``). Thus the table is bounded by the count of the open
/// questions and the open relays.
struct RelayedQuestions: Sendable {
    /// What happened to one relayed question at this level.
    enum State: Sendable, Equatable {
        /// The question is open, or the user answered it at this level.
        case open

        /// The run plane of this session ended the question with this
        /// response.
        case endedHere(ElicitationResponse)

        /// The child ended its copy of the question, and the relay ends the
        /// copy of this session with the same response.
        case endedBelow

        /// The child completed its copy of the URL-mode question, and the
        /// relay completes the copy of this session.
        case completedBelow
    }

    /// What the task of a relayed question does in the child when it
    /// resumes (``settle(_:resumedWith:)``).
    enum ChildCopyAction: Sendable, Equatable {
        /// The task does nothing in the child.
        case nothing

        /// The task gives this answer to the child
        /// (``RoutedSession/respond(elicitationId:response:)``).
        case answer(ElicitationResponse)

        /// The task completes the accepted URL-mode question of the child
        /// (``RoutedSession/complete(elicitationId:)``).
        case complete

        /// The task ends the copy of the question in the child with this
        /// response.
        case end(ElicitationResponse)
    }

    /// One relayed question.
    private struct Question: Sendable {
        /// The id of the relay that sent the question up.
        let relay: ULID

        /// Whether the question is a URL-mode question.
        let isURL: Bool

        /// What happened to the question at this level.
        var state = State.open

        /// Whether the journal of this session recorded the question.
        var isRecorded = false
    }

    /// The work state of the child of one relay.
    private struct Relay: Sendable {
        /// The completion token of the run of this session that the relay
        /// sends the questions to.
        let runToken: String

        /// Whether the child works now: its last work event was
        /// ``SessionEvent/workStarted``.
        var childWorks: Bool
    }

    /// Each relayed question whose task did not settle, by its id.
    private var questions: [ULID: Question] = [:]

    /// Each open relay, by its id.
    private var relays: [ULID: Relay] = [:]

    // MARK: - Relays

    /// Records a relay that starts to send the questions of its child to the
    /// run `runToken`.
    ///
    /// - Parameters:
    ///   - relay: The id of the relay.
    ///   - runToken: The completion token of the run of this session.
    ///   - childWorks: Whether the child works when the relay starts.
    mutating func openRelay(_ relay: ULID, runToken: String, childWorks: Bool) {
        relays[relay] = Relay(runToken: runToken, childWorks: childWorks)
    }

    /// Records the work state of the child of `relay`.
    ///
    /// - Parameters:
    ///   - relay: The id of the relay.
    ///   - works: Whether the child works now.
    mutating func noteChild(of relay: ULID, works: Bool) {
        relays[relay]?.childWorks = works
    }

    /// Takes the relay out of the table: it read the end of the feed of its
    /// child.
    ///
    /// - Parameter relay: The id of the relay.
    mutating func closeRelay(_ relay: ULID) {
        relays[relay] = nil
    }

    /// The completion tokens of the runs of this session that a relay with
    /// a working child sends to. Such a run is work, also while it waits
    /// only for the user.
    var runTokensWithWorkingChild: Set<String> {
        Set(relays.values.filter(\.childWorks).map(\.runToken))
    }

    // MARK: - Questions

    /// Records a question that `relay` sends up, before its task asks it in
    /// this session.
    ///
    /// - Parameters:
    ///   - request: The question, as the child asked it.
    ///   - relay: The id of the relay.
    mutating func noteRelayed(_ request: ElicitationRequest, by relay: ULID) {
        questions[request.elicitationId] = Question(relay: relay, isURL: request.mode == .url)
    }

    /// Records that the journal of this session recorded the question `id`.
    ///
    /// - Parameter id: The id of a question.
    /// - Returns: `true` when the question is a relayed question of the
    ///   table.
    mutating func noteRecorded(_ id: ULID) -> Bool {
        guard questions[id] != nil else { return false }
        questions[id]?.isRecorded = true
        return true
    }

    /// Whether the relay of the question `id` can read the next event of its
    /// child: the journal of this session recorded the question, or the task
    /// of the question settled. Then an end of the question in the child
    /// finds the question open in the run plane of this session, or already
    /// ended.
    ///
    /// - Parameter id: The id of a question.
    /// - Returns: `true` when the question is recorded or not in the table.
    func isRecordedOrSettled(_ id: ULID) -> Bool {
        questions[id]?.isRecorded ?? true
    }

    /// The relay of the open question `id`.
    ///
    /// - Parameter id: The id of a question.
    /// - Returns: The id of the relay, or `nil` when the question is not in
    ///   the table, or did not stay open.
    func relay(ofOpen id: ULID) -> ULID? {
        guard let question = questions[id], question.state == .open else { return nil }
        return question.relay
    }

    /// Records that the run plane of this session ended the open question
    /// `id` with `response`. A question that ended or completed below keeps
    /// its state.
    ///
    /// - Parameters:
    ///   - id: The id of the question.
    ///   - response: The response that the run plane gave.
    mutating func noteEndedHere(_ id: ULID, with response: ElicitationResponse) {
        guard questions[id]?.state == .open else { return }
        questions[id]?.state = .endedHere(response)
    }

    /// Records that the child ended its copy of the open question `id`.
    ///
    /// - Parameter id: The id of the question.
    /// - Returns: `true` when the question was open: the relay then ends the
    ///   copy of this session.
    mutating func noteEndedBelow(_ id: ULID) -> Bool {
        mark(id, as: .endedBelow)
    }

    /// Records that the child completed its copy of the open URL-mode
    /// question `id`.
    ///
    /// - Parameter id: The id of the question.
    /// - Returns: `true` when the question was open: the relay then completes
    ///   the copy of this session.
    mutating func noteCompletedBelow(_ id: ULID) -> Bool {
        mark(id, as: .completedBelow)
    }

    /// Records that the feed of the child of `relay` ended: each open
    /// question of the relay ended below.
    ///
    /// - Parameter relay: The id of the relay.
    /// - Returns: The ids of the questions that were open. The relay ends the
    ///   copy of each one in this session.
    mutating func endFeed(of relay: ULID) -> [ULID] {
        let open = questions.filter { $0.value.relay == relay && $0.value.state == .open }.map(\.key)
        for id in open {
            questions[id]?.state = .endedBelow
        }
        return open
    }

    /// Takes the question `id` out of the table, because its task resumed
    /// with `response`.
    ///
    /// - Parameters:
    ///   - id: The id of the question.
    ///   - response: The response that the task got in this session.
    /// - Returns: What the task does in the child.
    mutating func settle(_ id: ULID, resumedWith response: ElicitationResponse) -> ChildCopyAction {
        guard let question = questions.removeValue(forKey: id) else { return .nothing }
        switch question.state {
        case .open:
            return question.isURL && response.action == .accept ? .complete : .answer(response)
        case .endedHere(let ended):
            return .end(ended)
        case .endedBelow, .completedBelow:
            return .nothing
        }
    }

    /// Moves the open question `id` to `state`.
    ///
    /// - Parameters:
    ///   - id: The id of the question.
    ///   - state: The new state.
    /// - Returns: `true` when the question was open.
    private mutating func mark(_ id: ULID, as state: State) -> Bool {
        guard questions[id]?.state == .open else { return false }
        questions[id]?.state = state
        return true
    }
}

extension ElicitationRequest {
    /// Whether a ``SubagentQuestionRelay`` sent this question up from a
    /// child: its agent path is not empty. Only a relay sets the path
    /// (`ElicitationRequest.relayed(by:askedBy:)`).
    var isRelayed: Bool {
        !agentPath.isEmpty
    }
}

/// ``RoutedSessionActor``'s side of the relays of subagent questions
/// (elicitation phase 4): the table of the relayed questions
/// (``relayedQuestions``), the child of each relay (``relayChildren``), and
/// the work events that the work of a child gives this session.
///
/// A ``SubagentQuestionRelay`` calls these methods. Each one changes the
/// table in one step on this actor, so a check of the work
/// (``isIdle(startedAt:reading:)``) reads one state of the table.
extension RoutedSessionActor {
    /// Records a relay that starts to send the questions of `child` to the
    /// run `runToken` of this session.
    ///
    /// - Parameters:
    ///   - child: The child session.
    ///   - runToken: The completion token of the run that drives the child.
    ///   - childWorks: Whether the child works when the relay starts.
    /// - Returns: The id of the relay.
    func openRelay(child: any RoutedSession, runToken: String, childWorks: Bool) -> ULID {
        let relay = ULID.generate()
        relayedQuestions.openRelay(relay, runToken: runToken, childWorks: childWorks)
        relayChildren[relay] = child
        return relay
    }

    /// Records a new work state of the child of `relay`, and reports it as
    /// work of this session. When the child starts to work, this session
    /// notes a start of work (``noteWorkStarted()``): a run that waits only
    /// for the user is work again while its child works. When the child
    /// stops, the change can end the work of this session
    /// (``workDidChange()``).
    ///
    /// - Parameters:
    ///   - relay: The id of the relay.
    ///   - works: Whether the child works now.
    func noteChild(of relay: ULID, works: Bool) async {
        relayedQuestions.noteChild(of: relay, works: works)
        guard works else {
            await workDidChange()
            return
        }
        noteWorkStarted()
    }

    /// Takes `relay` out of the table, after it read the end of the feed of
    /// its child and each question that it sent up settled. The end of the
    /// relay can end the work of this session (``workDidChange()``).
    ///
    /// - Parameter relay: The id of the relay.
    func closeRelay(_ relay: ULID) async {
        relayedQuestions.closeRelay(relay)
        relayChildren[relay] = nil
        await workDidChange()
    }

    /// Records a question that `relay` sends up, before its task asks it in
    /// this session (``RelayedQuestions/noteRelayed(_:by:)``).
    ///
    /// - Parameters:
    ///   - request: The question, as the child asked it.
    ///   - relay: The id of the relay.
    func noteRelayed(_ request: ElicitationRequest, by relay: ULID) {
        relayedQuestions.noteRelayed(request, by: relay)
    }

    /// Waits until the journal of this session recorded the relayed question
    /// `id`, or until its task settled. The relay reads the next event of
    /// its child only after this wait, so an end of the question in the child
    /// finds the question open in ``runPlane``, or already ended.
    ///
    /// The journal also records a question after ``close()`` started, so the
    /// wait does not end at a close: an end of the wait before the question
    /// is open in ``runPlane`` can let the end of the feed of the child find
    /// no question, and the question then stays open.
    ///
    /// - Parameter id: The id of the question.
    func awaitRelayedQuestionRecorded(_ id: ULID) async {
        _ = await relayChanges.waitUntil { relayedQuestions.isRecordedOrSettled(id) }
    }

    /// Records that the child ended its copy of the relayed question `id`
    /// (``RelayedQuestions/noteEndedBelow(_:)``).
    ///
    /// - Parameter id: The id of the question.
    /// - Returns: `true` when the question was open: the relay then ends the
    ///   copy of this session.
    func noteRelayedQuestionEndedBelow(_ id: ULID) -> Bool {
        relayedQuestions.noteEndedBelow(id)
    }

    /// Records that the child completed its copy of the relayed URL-mode
    /// question `id` (``RelayedQuestions/noteCompletedBelow(_:)``).
    ///
    /// - Parameter id: The id of the question.
    /// - Returns: `true` when the question was open: the relay then completes
    ///   the copy of this session.
    func noteRelayedQuestionCompletedBelow(_ id: ULID) -> Bool {
        relayedQuestions.noteCompletedBelow(id)
    }

    /// Records that the feed of the child of `relay` ended
    /// (``RelayedQuestions/endFeed(of:)``).
    ///
    /// - Parameter relay: The id of the relay.
    /// - Returns: The ids of the questions of the relay that were open.
    func endRelayFeed(_ relay: ULID) -> [ULID] {
        relayedQuestions.endFeed(of: relay)
    }

    /// Takes the relayed question `id` out of the table, because its task
    /// resumed with `response`, and wakes each relay that waits for the
    /// question (``awaitRelayedQuestionRecorded(_:)``).
    ///
    /// - Parameters:
    ///   - id: The id of the question.
    ///   - response: The response that the task got in this session.
    /// - Returns: What the task does in the child.
    func settleRelayedQuestion(
        _ id: ULID, resumedWith response: ElicitationResponse
    ) -> RelayedQuestions.ChildCopyAction {
        let action = relayedQuestions.settle(id, resumedWith: response)
        relayChanges.signal()
        return action
    }

    /// Sends the URL-mode accept `response` of the relayed question `id`
    /// down to the child, after ``runPlane`` accepted it. The accept does not
    /// resume the task of the question, so this level sends it down at once:
    /// the child then accepts its copy, and a completion from below always
    /// finds the question of this session accepted.
    ///
    /// - Parameters:
    ///   - id: The id of the question.
    ///   - response: The accept of the user.
    func sendAcceptDown(answering id: ULID, with response: ElicitationResponse) async {
        guard let relay = relayedQuestions.relay(ofOpen: id), let child = relayChildren[relay] else { return }
        _ = await child.respond(elicitationId: id.description, response: response)
    }

    /// A feed of this session (``RoutedSession/streamSessionEvents()``), and
    /// the work state that the last work event reported, read in one step.
    /// Each work event goes out under the lock of ``workEvents``, and this
    /// call makes the feed under the same lock, so the feed gets each work
    /// event that comes after the state it returns.
    ///
    /// - Returns: The feed and the work state, or no feed when ``close()``
    ///   started: a feed made then can miss the end of the feeds.
    nonisolated func feedWithWorkPhase() -> (feed: AsyncStream<SessionOutput>?, phase: WorkEventState.Phase) {
        workEvents.withLock { state in
            guard state.phase != .closed else { return (nil, .closed) }
            return (outputHub.makeFeed(), state.phase)
        }
    }
}
