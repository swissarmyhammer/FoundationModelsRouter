import FoundationModelsExtras

/// The session whose submission runs the current task.
///
/// A session binds it around each model call that it submits, next to
/// ``SessionOwnWork``. The SDK gives it to each tool body that it runs inside
/// the call, and each run body that a tool body starts with `Task {}` gets
/// it too. A task that `Task.detached` starts does not get it.
/// ``SubagentQuestionTarget/current`` reads it.
enum SubagentQuestionHost {
    /// The session of the current task, or `nil` outside the tool work of a
    /// session.
    @TaskLocal static var session: RoutedSessionActor?
}

/// The run of a Router session that drives a subagent: the place where a
/// ``SubagentQuestionRelay`` sends the questions of the subagent.
///
/// Read it with ``current`` in the tool call or the run body that drives the
/// subagent, and give it to ``SubagentQuestionRelay/start(child:agentName:target:)``.
/// Each question that the relay sends up links to the run that holds that
/// tool call or run body (`ToolContext.holdingRunToken`), so the
/// `correlationID` of the question at this level is the token of that run,
/// and a cancel of that run ends the question. For a call that a run mounts
/// with `ToolContext.mount(_:op:as:)`, that is the token of the mounting run,
/// not the completion token of the mounted call.
///
/// The target holds a strong reference to the session of the run. An owner
/// that keeps the target, for example in the request of a subagent run, must
/// drop it after the drive of the subagent ended. Else the target keeps the
/// parent session in memory after the parent closed.
public struct SubagentQuestionTarget: Sendable {
    /// The session of the run.
    let session: RoutedSessionActor

    /// The tool context of the run. A relayed question asks through it.
    let context: ToolContext

    /// The target of the tool call or the run body of the calling task, or
    /// `nil` when the task is no tool work of a Router session.
    public static var current: SubagentQuestionTarget? {
        guard let context = ToolContext.current, let session = SubagentQuestionHost.session,
            context.sessionID == session.id
        else { return nil }
        return SubagentQuestionTarget(session: session, context: context)
    }

    /// The user presence of the session of the target. Give it to the
    /// session of the subagent (``SessionConfiguration/userPresence``): a
    /// subagent of a headless session gets the cancel of each question at
    /// once, with no relay.
    public var userPresence: UserPresence {
        context.userPresence
    }

    /// The id of the session of the target.
    public var sessionID: ULID {
        session.id
    }
}

/// Sends the questions of one subagent session to its parent, one level up,
/// and sends the answers back down (elicitation phase 4).
///
/// The relay reads the feed of the child (``RoutedSession/streamSessionEvents()``)
/// in order:
///
/// - For each ``SessionEvent/elicitationRequested(_:)`` of the child, it asks
///   the same question in the run of the target
///   (`ElicitationRequest.relayed(by:askedBy:)`): the same `elicitationId`,
///   the agent name in front of the agent path, and the tool of the asking
///   run as the source. The parent sends its own
///   ``SessionEvent/elicitationRequested(_:)``. The relayed question makes no
///   run mail in the parent, so the model of the parent does not see it. The
///   journal of the parent keeps the question, and the context that a
///   restore of the parent gives to the model leaves it out
///   (``ContextRenderer/context(of:)``, rule R5). The relay reads the next
///   event of the child only after the parent recorded the question.
/// - An answer of the user at the parent goes down to the child
///   (``RoutedSession/respond(elicitationId:response:)``), and only the level
///   whose own run asked the question mails the answer to its model. A
///   URL-mode accept goes down at once, and a completion goes down or comes
///   up, so each level sends one ``SessionEvent/elicitationCompleted(_:)``.
/// - An end with no answer ends the question one time at each level: an end
///   in the child comes up (`RunPlane.endElicitation(_:with:)`, origin
///   ``Origin/system`` at the parent), and an end at the parent goes down to
///   the child with the same response. When the feed of the child ends, each
///   question that is still open ends at the parent with a cancel that gives
///   `RunPlane.runCancelledReason`.
/// - The work events of the child keep the session of the target working
///   while the child works (``RoutedSession/awaitIdle()``), also while the
///   run of the target waits only for the user, and also after a sweep of
///   ``RoutedSession/cancelAll()`` settled that run while the child still
///   works.
///
/// A known race: an answer at the parent and an end in the child can cross.
/// Then the parent gives ``ElicitationAnswerDelivery/delivered`` and the child
/// sends ``SessionEvent/elicitationEnded(_:)``. The run of the child gets the
/// end, and the answer goes no further. Each level still has exactly one
/// outcome for the question.
///
/// The wait after a question goes up does not stop when the parent starts
/// its close. The reason: the journal of the parent records a question also
/// after ``RoutedSession/close()`` started. If the wait stops before the
/// question is open in the run plane of the parent, the end of the feed of
/// the child can find no question to end. The question then stays open at
/// the parent, its task never resumes, and ``finish()`` never returns. Thus
/// the relay waits until the parent recorded the question or the task of
/// the question settled. A close of the parent then ends the question at the
/// parent through the close path of the parent, and the task of the question
/// ends the copy in the child with the same response
/// (`RunPlane.endElicitation(_:with:)`). The wait also stops when the close
/// of the parent ended: after that, nothing in the parent records or settles
/// the question, and the relay reads on to the end of the feed of the child.
///
/// `ToolContext.elicit(_:)` does not throw an error today. If it throws for a
/// relayed question, the relay writes an error log in the
/// `SubagentQuestionRelay` log category and ends the question with a cancel
/// that gives `RunPlane.runCancelledReason`, as for a stopped run. The reason:
/// the relay must always settle the task of the question, so that the child
/// copy ends and ``finish()`` returns.
///
/// A known limit: a child that is not a Router session gets no
/// ``SessionEvent/elicitationEnded(_:)`` when the parent ends its question.
/// Its copy of the question gets the response of the end through
/// ``RoutedSession/respond(elicitationId:response:)``. Such a child also
/// counts as work until its first ``SessionEvent/workEnded``.
///
/// The relay never closes a session and never waits for an answer of the
/// child. Close the child first, and then call ``finish()``.
public final class SubagentQuestionRelay: Sendable {
    /// The task that reads the feed of the child to its end, and waits for
    /// the task of each question that it sent up.
    private let reading: Task<Void, Never>

    /// Makes a relay over its reading task.
    ///
    /// - Parameter reading: The task that reads the feed of the child.
    private init(reading: Task<Void, Never>) {
        self.reading = reading
    }

    /// Subscribes to the events of `child` before it returns, and starts to
    /// relay its questions to the run of `target`.
    ///
    /// Call it before the first mail of `child`, while the run of `target` is
    /// open. A question that the relay sends up after the run settled links
    /// to a run that is closed.
    ///
    /// A target whose session is headless (``SubagentQuestionTarget/userPresence``
    /// is not `.interactive`) gets no relay: no user can answer at that level.
    /// Give the child the user presence of the target, so the child is
    /// headless too, and each question of the child gets its cancel at once
    /// in the child. The caller then drives the child with no relay and calls
    /// no ``finish()``.
    ///
    /// - Parameters:
    ///   - child: The session of the subagent.
    ///   - agentName: The name of the subagent. The relay puts it in front of
    ///     the agent path of each question.
    ///   - target: The run of the parent that drives the subagent.
    /// - Returns: The relay, or `nil` when the session of `target` is
    ///   headless.
    public static func start(
        child: any RoutedSession, agentName: String, target: SubagentQuestionTarget
    ) async -> SubagentQuestionRelay? {
        guard target.userPresence == .interactive else { return nil }
        let subscription = await subscribe(to: child)
        let relay = await target.session.openRelay(child: child, childWorks: subscription.childWorks)
        let link = SubagentQuestionLink(child: child, agentName: agentName, target: target, relay: relay)
        // Detached: the relay gets no task-local of the run that starts it,
        // so no origin and no mark of that run reaches the work of the relay.
        let reading = Task.detached { await link.read(subscription.feed) }
        return SubagentQuestionRelay(reading: reading)
    }

    /// Waits until the relay read the feed of the child to its end, and each
    /// question that it sent up ended. Close the child first. A cancel of
    /// the calling task does not end the wait.
    public func finish() async {
        await reading.value
    }

    /// Subscribes to the feed of `child`, and reads whether the child works
    /// now.
    ///
    /// For a Router session, the feed and the work state come from one step
    /// (``RoutedSessionActor/feedWithWorkPhase()``), so the relay gets each
    /// work event after that state. A child that is not a Router session
    /// counts as work until its first ``SessionEvent/workEnded``.
    ///
    /// - Parameter child: The session of the subagent.
    /// - Returns: The feed, and whether the child works. A Router session
    ///   that started its close gives a feed that is already finished.
    private static func subscribe(
        to child: any RoutedSession
    ) async -> (feed: AsyncStream<SessionOutput>, childWorks: Bool) {
        guard let router = child as? RoutedSessionActor else {
            return (await child.streamSessionEvents(), true)
        }
        let (feed, phase) = router.feedWithWorkPhase()
        guard let feed else {
            return (AsyncStream { $0.finish() }, false)
        }
        return (feed, phase == .working)
    }
}

/// The work of one ``SubagentQuestionRelay``: it reads the feed of the child
/// and acts on the parent, and the task of each relayed question acts on the
/// child.
///
/// The parent session keeps the facts of the relay in its table
/// (``RoutedSessionActor/relayedQuestions``), and changes them in one step
/// for each call, so the relay holds no state of its own.
struct SubagentQuestionLink: Sendable {
    /// The session of the subagent.
    let child: any RoutedSession

    /// The name of the subagent in the agent path.
    let agentName: String

    /// The run of the parent that drives the subagent.
    let target: SubagentQuestionTarget

    /// The id of the relay in the table of the parent.
    let relay: ULID

    /// The parent session.
    private var parent: RoutedSessionActor {
        target.session
    }

    /// Reads `feed` to its end, and then ends each question that is still
    /// open at the parent. It returns after the task of each question that it
    /// sent up settled, and the parent took the relay out of its table.
    ///
    /// - Parameter feed: The feed of the child.
    func read(_ feed: AsyncStream<SessionOutput>) async {
        await withDiscardingTaskGroup { group in
            for await output in feed {
                await handle(output.event, in: &group)
            }
            await endOpenQuestions()
        }
        await parent.closeRelay(relay)
    }

    /// Acts on one event of the child. Only the questions, their ends, their
    /// completions and the work events of the child matter to the relay.
    ///
    /// - Parameters:
    ///   - event: The event of the child.
    ///   - group: The group of the tasks of the relayed questions.
    private func handle(_ event: SessionEvent, in group: inout DiscardingTaskGroup) async {
        switch event {
        case .elicitationRequested(let question):
            await sendUp(question, in: &group)
        case .elicitationEnded(let end):
            await endAtParent(end)
        case .elicitationCompleted(let completion):
            await completeAtParent(completion.elicitationId)
        case .workStarted:
            await parent.noteChild(of: relay, works: true)
        case .workEnded:
            await parent.noteChild(of: relay, works: false)
        default:
            // Each other event of the child is output of its own work. The
            // parent sees that work only through the questions and the work
            // events.
            return
        }
    }

    /// Sends the question of `event` up: records it in the table of the
    /// parent, starts its task, and waits until the parent recorded it or
    /// its task settled.
    ///
    /// - Parameters:
    ///   - event: The `.elicitation` event of the child.
    ///   - group: The group of the tasks of the relayed questions.
    private func sendUp(_ event: OperationEvent, in group: inout DiscardingTaskGroup) async {
        guard let request = event.elicitation else { return }
        await parent.noteRelayed(request, by: relay)
        let relayed = request.relayed(by: agentName, askedBy: event.tool)
        group.addTask { await ask(relayed) }
        await parent.awaitRelayedQuestionRecorded(request.elicitationId)
    }

    /// The task of one relayed question: asks it in the run of the target,
    /// and then does in the child what the table of the parent says
    /// (``RelayedQuestions/settle(_:resumedWith:)``).
    ///
    /// The work of the relay has the origin ``Origin/system`` at each level.
    ///
    /// - Parameter request: The relayed question.
    private func ask(_ request: ElicitationRequest) async {
        await OriginContext.$current.withValue(.system) {
            let response = await answer(to: request)
            let action = await parent.settleRelayedQuestion(request.elicitationId, resumedWith: response)
            await apply(action, to: request.elicitationId)
        }
    }

    /// Asks `request` in the run of the target, and waits for its answer.
    ///
    /// `ToolContext.elicit(_:)` throws no error now. A throw is not expected:
    /// the relay logs it, and the question then ends with the cancel of a
    /// stopped run.
    ///
    /// - Parameter request: The relayed question.
    /// - Returns: The answer of the user, the completion, or the end.
    private func answer(to request: ElicitationRequest) async -> ElicitationResponse {
        do {
            return try await target.context.elicit(request)
        } catch {
            assertionFailure("ToolContext.elicit threw for a relayed question")
            RouterTelemetry.makeLogger(.subagentQuestionRelay).error(
                "a relayed question threw; the question ends with the cancel of a stopped run",
                metadata: RouterTelemetry.errorMetadata(error).merging([
                    RouterTelemetry.LogMetadataKey.sessionId: "\(target.session.id.description)"
                ]) { _, new in new })
            return .cancel(reason: RunPlane.runCancelledReason)
        }
    }

    /// Does `action` in the child, for the question `id`.
    ///
    /// - Parameters:
    ///   - action: What the task does in the child.
    ///   - id: The id of the question.
    private func apply(_ action: RelayedQuestions.ChildCopyAction, to id: ULID) async {
        switch action {
        case .nothing:
            return
        case .answer(let response):
            _ = await child.respond(elicitationId: id.description, response: response)
        case .complete:
            _ = await child.complete(elicitationId: id.description)
        case .end(let response):
            await endInChild(id, with: response)
        }
    }

    /// Ends the copy of the question `id` in the child with `response`. The
    /// run plane of a Router child ends it and sends its
    /// ``SessionEvent/elicitationEnded(_:)``. A child that is not a Router
    /// session gets `response` as an answer, and sends no end.
    ///
    /// - Parameters:
    ///   - id: The id of the question.
    ///   - response: The decline or cancel of the end.
    private func endInChild(_ id: ULID, with response: ElicitationResponse) async {
        guard let router = child as? RoutedSessionActor else {
            _ = await child.respond(elicitationId: id.description, response: response)
            return
        }
        _ = await router.runPlane.endElicitation(id, with: response)
    }

    /// Ends the copy of the question at the parent, because the child ended
    /// its own copy with no answer. A question that did not stay open at the
    /// parent gets nothing.
    ///
    /// - Parameter end: The end in the child.
    private func endAtParent(_ end: ElicitationEnd) async {
        guard await parent.noteRelayedQuestionEndedBelow(end.elicitationId) else { return }
        await endAtParent(end.elicitationId, with: end.response)
    }

    /// Completes the copy of the URL-mode question at the parent, because the
    /// flow of the child completed. A question that did not stay open at the
    /// parent gets nothing.
    ///
    /// - Parameter id: The id of the question.
    private func completeAtParent(_ id: ULID) async {
        guard await parent.noteRelayedQuestionCompletedBelow(id) else { return }
        await OriginContext.$current.withValue(.system) {
            _ = await target.context.complete(elicitationId: id)
        }
    }

    /// Ends each question that is still open at the parent, because the feed
    /// of the child ended. The child closed, so its copies ended too.
    private func endOpenQuestions() async {
        for id in await parent.endRelayFeed(relay) {
            await endAtParent(id, with: .cancel(reason: RunPlane.runCancelledReason))
        }
    }

    /// Ends the open question `id` in the run plane of the parent with
    /// `response`, with the origin ``Origin/system``.
    ///
    /// - Parameters:
    ///   - id: The id of the question.
    ///   - response: The decline or cancel of the end.
    private func endAtParent(_ id: ULID, with response: ElicitationResponse) async {
        await OriginContext.$current.withValue(.system) {
            _ = await parent.runPlane.endElicitation(id, with: response)
        }
    }
}
