import Foundation
import FoundationModels
import Testing

@testable import FoundationModelsExtras
@testable import FoundationModelsRouter

/// Exercises elicitation phase 4 (task ^wknsjvq): a question of a subagent
/// goes up to the user level by level (``SubagentQuestionRelay``), the
/// answer goes down to the run that asked, and an end with no answer ends
/// the question one time at each level.
///
/// Each test runs a root session whose ``SubagentJobTool`` run forks the
/// root, relays the questions of the fork, and mails the fork one message.
/// The same tool asks the question in the leaf, or relays again in a middle
/// level (``SubagentRelayBox``). Everything runs against the scripted
/// ``BackgroundingBackend``, so the suite needs no network and no GPU. The
/// tests read the order of the outputs, not a clock.
@Suite("A question of a subagent goes up level by level, and its answer or its end goes down")
struct SubagentQuestionRelayTests {
    // MARK: - Constants

    /// The agent name of the child of the root.
    private static let reviewer = "reviewer"

    /// The agent name of the child of the middle level.
    private static let linter = "linter"

    /// The count of the children of a test with two relaying levels.
    private static let twoLevels = 2

    /// The count of an event that comes one time.
    private static let once = 1

    /// The accepted answer to the form question of the leaf.
    private static let acceptedForm = ElicitationResponse.accept(content: ["ok": .boolean(true)])

    // MARK: - Helpers

    /// A root session whose child asked one question, with the feeds of
    /// both read up to that question.
    private struct OneLevel {
        /// The fixture of the root.
        let fixture: SubagentRelayFixture

        /// The relaying level of the root.
        let rootStep: SubagentRelayStep

        /// The child session.
        let child: any RoutedSession

        /// The feed of the root, after the outputs up to the question.
        var rootFeed: AsyncStream<SessionOutput>.Iterator

        /// The feed of the child, after the outputs up to the question.
        var childFeed: AsyncStream<SessionOutput>.Iterator

        /// The outputs of the root up to and including the question.
        let rootOutputs: [SessionOutput]

        /// The `.elicitation` event of the question at the root.
        let rootQuestion: OperationEvent

        /// The `.elicitation` event of the question in the child.
        let childQuestion: OperationEvent

        /// The id of the question.
        var questionId: ULID {
            get throws { try #require(childQuestion.elicitation).elicitationId }
        }

        /// The root session.
        var root: any RoutedSession { fixture.session }
    }

    /// Starts a root whose child asks one question, and reads both feeds up
    /// to that question.
    ///
    /// - Parameters:
    ///   - step: The question of the child.
    ///   - rootStep: The relaying level of the root.
    /// - Returns: The root, its child and the feeds.
    /// - Throws: What the fixture throws, or when a feed has no question.
    private static func askOneLevel(
        _ step: SubagentAskStep = SubagentAskStep(), rootStep: SubagentRelayStep = SubagentRelayStep(agentName: reviewer)
    ) async throws -> OneLevel {
        let fixture = try await SubagentRelayFixture.make(root: rootStep, children: [.ask(step)])
        var rootFeed = await fixture.session.streamSessionEvents().makeAsyncIterator()
        try await fixture.start()
        let child = try #require(try await fixture.box.waitForChildren(once).first)
        var childFeed = child.feed.makeAsyncIterator()
        let childOutputs = await outputsThroughQuestion(&childFeed)
        let rootOutputs = await outputsThroughQuestion(&rootFeed)
        return OneLevel(
            fixture: fixture, rootStep: rootStep, child: child.session, rootFeed: rootFeed, childFeed: childFeed,
            rootOutputs: rootOutputs, rootQuestion: try firstQuestion(in: rootOutputs),
            childQuestion: try firstQuestion(in: childOutputs))
    }

    /// Reads `feed` up to and including the next question.
    ///
    /// - Parameter feed: The iterator of a feed.
    /// - Returns: The outputs read.
    private static func outputsThroughQuestion(_ feed: inout AsyncStream<SessionOutput>.Iterator) async
        -> [SessionOutput]
    {
        await SessionWorkEventTests.outputs(from: &feed, through: SessionEventCase.elicitationRequested.matches)
    }

    /// Reads `feed` until each of `conditions` accepted one output, or until
    /// the feed finished.
    ///
    /// - Parameters:
    ///   - feed: The iterator of a feed.
    ///   - conditions: The tests of the events to read up to.
    /// - Returns: The outputs read.
    private static func outputs(
        from feed: inout AsyncStream<SessionOutput>.Iterator, throughEach conditions: [(SessionEvent) -> Bool]
    ) async -> [SessionOutput] {
        var read: [SessionOutput] = []
        while let output = await feed.next() {
            read.append(output)
            let events = read.map(\.event)
            if conditions.allSatisfy({ condition in events.contains(where: condition) }) {
                break
            }
        }
        return read
    }

    /// The `.elicitation` event of each question of `outputs`, in order.
    ///
    /// - Parameter outputs: Outputs of a session.
    /// - Returns: The questions.
    private static func questions(in outputs: [SessionOutput]) -> [OperationEvent] {
        outputs.compactMap { output in
            guard case .elicitationRequested(let event) = output.event else { return nil }
            return event
        }
    }

    /// The count of the completions of `outputs`.
    ///
    /// - Parameter outputs: Outputs of a session.
    /// - Returns: The count.
    private static func completionCount(in outputs: [SessionOutput]) -> Int {
        outputs.filter { SessionEventCase.elicitationCompleted.matches($0.event) }.count
    }

    /// Checks that no session of `sessions` takes an answer or a completion
    /// to the question `id` any more.
    ///
    /// - Parameters:
    ///   - id: The id of the question.
    ///   - sessions: The sessions of each level.
    private static func expectNoQuestion(_ id: ULID, at sessions: [any RoutedSession]) async {
        for session in sessions {
            #expect(await session.respond(elicitationId: id.description, response: .decline) == .noPendingElicitation)
            #expect(await session.complete(elicitationId: id.description) == .noPendingElicitation)
        }
    }

    /// Checks the one end of the question of `level` at the root and in the
    /// child, each with its origin. Then checks that no level takes an answer
    /// or a completion to the question any more.
    ///
    /// - Parameters:
    ///   - level: The root and its child.
    ///   - rootOutputs: The outputs of the root that hold the end.
    ///   - childOutputs: The outputs of the child that hold the end.
    ///   - rootOrigin: The origin of the end at the root.
    ///   - childOrigin: The origin of the end in the child.
    ///   - sourceLocation: The place of the call, for the failure.
    /// - Returns: The position of the end at the root and in the child.
    /// - Throws: When the outputs of a level hold no end.
    @discardableResult
    private static func expectOneEndAtEachLevel(
        of level: OneLevel, rootOutputs: [SessionOutput], childOutputs: [SessionOutput],
        rootOrigin: Origin = .system, childOrigin: Origin = .system,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws -> (root: Int, child: Int) {
        let id = try level.questionId
        let rootEnd = try PendingElicitationFixtures.soleEnd(in: rootOutputs, of: id, sourceLocation: sourceLocation)
        let childEnd = try PendingElicitationFixtures.soleEnd(in: childOutputs, of: id, sourceLocation: sourceLocation)
        #expect(rootEnd.origin == rootOrigin, sourceLocation: sourceLocation)
        #expect(childEnd.origin == childOrigin, sourceLocation: sourceLocation)
        await expectNoQuestion(id, at: [level.root, level.child])
        return (rootEnd.position, childEnd.position)
    }

    /// The test of a question with the id `id`.
    ///
    /// - Parameter id: The id of a question.
    /// - Returns: A test that accepts ``SessionEvent/elicitationRequested(_:)`` of that question.
    private static func isQuestion(_ id: ULID) -> (SessionEvent) -> Bool {
        { event in
            guard case .elicitationRequested(let question) = event else { return false }
            return question.elicitation?.elicitationId == id
        }
    }

    // MARK: - The question goes up

    /// The production change that makes this test fail: no relay, or a relay
    /// that gives the question a new id or no path.
    @Test("a question of a child shows on the root one time, with the same id, the path, the source and the relaying run")
    func aChildQuestionGoesUpOneTimeWithThePathAndTheSameId() async throws {
        var level = try await Self.askOneLevel()
        let rest = await SessionWorkEventTests.outputs(throughNextWorkEnd: &level.rootFeed)

        let request = try #require(level.rootQuestion.elicitation)
        let relayingRuns = try await level.fixture.sessionActor().runPlane.backgroundRuns().map(\.completionToken)
        #expect(Self.questions(in: level.rootOutputs + rest).count == Self.once)
        #expect(request.elicitationId == (try level.questionId))
        #expect(request.agentPath == [Self.reviewer])
        #expect(request.source == SubagentJobTool.toolName)
        #expect(relayingRuns == [level.rootQuestion.correlationID])
        #expect(rest.last?.event == .workEnded)
        await level.fixture.end(opening: [level.rootStep.gate])
    }

    /// The production change that makes this test fail: a relay that does
    /// not put its agent in front of the path that the level below gave.
    @Test("a question of a grandchild gets the agent of each level in its path")
    func aGrandchildQuestionGetsEachLevelInThePath() async throws {
        let rootStep = SubagentRelayStep(agentName: Self.reviewer)
        let middleStep = SubagentRelayStep(agentName: Self.linter)
        let fixture = try await SubagentRelayFixture.make(
            root: rootStep, children: [.relay(middleStep), .ask(SubagentAskStep())])
        var rootFeed = await fixture.session.streamSessionEvents().makeAsyncIterator()
        try await fixture.start()
        let children = try await fixture.box.waitForChildren(Self.twoLevels)
        var middleFeed = try #require(children.first).feed.makeAsyncIterator()
        var leafFeed = try #require(children.last).feed.makeAsyncIterator()

        let leafQuestion = try firstQuestion(in: await Self.outputsThroughQuestion(&leafFeed))
        let middleQuestion = try firstQuestion(in: await Self.outputsThroughQuestion(&middleFeed))
        let rootQuestion = try firstQuestion(in: await Self.outputsThroughQuestion(&rootFeed))

        let leafId = try #require(leafQuestion.elicitation).elicitationId
        #expect(try #require(middleQuestion.elicitation).agentPath == [Self.linter])
        #expect(try #require(rootQuestion.elicitation).agentPath == [Self.reviewer, Self.linter])
        #expect(try #require(rootQuestion.elicitation).source == SubagentJobTool.toolName)
        #expect(try #require(middleQuestion.elicitation).elicitationId == leafId)
        #expect(try #require(rootQuestion.elicitation).elicitationId == leafId)
        await fixture.end(opening: [rootStep.gate, middleStep.gate])
    }

    /// The production change that makes this test fail: an outbox that makes
    /// run mail of a relayed question, so the model of the relaying level
    /// reads the question in its next prompt.
    @Test("a relaying level keeps the question in its feed but out of the prompt of its model")
    func aRelayingLevelKeepsTheQuestionOutOfThePromptOfItsModel() async throws {
        let level = try await Self.askOneLevel()

        let rootOrigin = try #require(level.rootOutputs.last).origin
        let waitingQuestions = await level.root.pendingMessages().filter { $0.runEvent?.kind == .elicitation }
        #expect(rootOrigin == .system)
        #expect(waitingQuestions.isEmpty)
        await level.fixture.end(opening: [level.rootStep.gate])
    }

    /// The production change that makes this test fail: a relay that sends
    /// the question up while the session of the target is headless, or that
    /// does not give the child the cancel that the target got at once.
    @Test("a headless target gives the question of an interactive child a cancel at once, and shows no question")
    func aHeadlessTargetGivesTheChildQuestionACancelAtOnce() async throws {
        let rootStep = SubagentRelayStep(agentName: Self.reviewer)
        let fixture = try await SubagentRelayFixture.make(
            root: rootStep, children: [.ask(SubagentAskStep())], userPresence: .headless,
            makeChild: { parent in
                let tools = try #require(parent as? RoutedSessionActor).originalTools
                return parent.profile.standard.makeSession(
                    configuration: SessionConfiguration(tools: tools, userPresence: .interactive))
            })
        var rootFeed = await fixture.session.streamSessionEvents().makeAsyncIterator()
        try await fixture.start()

        let answers = try await fixture.box.waitForAnswers(Self.once)
        await rootStep.gate.open()
        let rootOutputs = await SessionWorkEventTests.outputs(
            from: &rootFeed, through: SessionEventCase.runSettled.matches)

        #expect(answers == [.cancel(reason: RunPlane.noUserPresentReason)])
        #expect(fixture.box.targets.map(\.userPresence) == [.headless])
        #expect(Self.questions(in: rootOutputs).isEmpty)
        await fixture.end()
    }

    // MARK: - The answer goes down

    /// The production change that makes this test fail: a relaying level
    /// that mails the answer to its own model, as the level that asked
    /// does.
    @Test("a root answer reaches the run that asked, and only that level gets the answer as mail")
    func aRootAnswerReachesTheRunThatAskedAndMailsOnlyThatLevel() async throws {
        let laterAnswers = RunLatch()
        let rootStep = SubagentRelayStep(agentName: Self.reviewer)
        let middleStep = SubagentRelayStep(agentName: Self.linter)
        let fixture = try await SubagentRelayFixture.make(
            root: rootStep, children: [.relay(middleStep), .ask(SubagentAskStep())],
            container: BackgroundingLLMContainer(holdLaterAnswers: laterAnswers))
        var rootFeed = await fixture.session.streamSessionEvents().makeAsyncIterator()
        try await fixture.start()
        let children = try await fixture.box.waitForChildren(Self.twoLevels)
        let middle = try #require(children.first)
        let leaf = try #require(children.last)
        var middleFeed = middle.feed.makeAsyncIterator()
        var leafFeed = leaf.feed.makeAsyncIterator()
        let id = try #require(try firstQuestion(in: await Self.outputsThroughQuestion(&rootFeed)).elicitation)
            .elicitationId

        let delivery = await fixture.session.respond(elicitationId: id.description, response: Self.acceptedForm)
        let answers = try await fixture.box.waitForAnswers(Self.once)
        let leafActor = try #require(leaf.session as? RoutedSessionActor)
        let leafBackend = try #require(await leafActor.backend as? BackgroundingBackend)
        let answerText = try #require(
            Mail(sender: .elicitation(id), body: .elicitationAnswer(id: id, response: Self.acceptedForm)).promptText)
        try await leafBackend.changes.wait(until: { leafBackend.receivedPrompts.contains { $0.contains(answerText) } })
        let rootDepth = await fixture.session.mailQueueDepth()
        let middleDepth = await middle.session.mailQueueDepth()
        await fixture.end(opening: [laterAnswers, rootStep.gate, middleStep.gate])
        let outputs =
            await SessionWorkEventTests.remainingOutputs(of: &rootFeed)
            + SessionWorkEventTests.remainingOutputs(of: &middleFeed)
            + SessionWorkEventTests.remainingOutputs(of: &leafFeed)

        #expect(delivery == .delivered)
        #expect(answers == [Self.acceptedForm])
        // The run mail of the pending envelope of each relaying run waits for
        // the next answer of its level, so only the answer mail is counted.
        #expect(rootDepth.depthByKind[.elicitationAnswer] == nil)
        #expect(rootDepth.running.isEmpty)
        #expect(middleDepth.depthByKind[.elicitationAnswer] == nil)
        #expect(middleDepth.running.isEmpty)
        #expect(PendingElicitationFixtures.ends(in: outputs).isEmpty)
    }

    /// The production change that makes this test fail: a relaying level
    /// that keeps a URL accept to itself, so the leaf has no accepted
    /// question to complete, or a relay that does not send the completion
    /// of the leaf up.
    @Test("a URL accept at the root goes down at once, and the completion of the leaf comes up one time at each level")
    func aURLAcceptGoesDownAtOnceAndTheLeafCompletionComesUp() async throws {
        var level = try await Self.askOneLevel(SubagentAskStep(asksForURL: true))
        let id = try level.questionId

        let accepted = await level.root.respond(elicitationId: id.description, response: .accept(content: nil))
        let leafContext = try #require(level.fixture.box.askContexts.first)
        let completed = await leafContext.complete(elicitationId: id)
        let answers = try await level.fixture.box.waitForAnswers(Self.once)
        let rootOutputs = await SessionWorkEventTests.outputs(
            from: &level.rootFeed, through: SessionEventCase.elicitationCompleted.matches)
        await level.fixture.end(opening: [level.rootStep.gate])
        let rootRest = await SessionWorkEventTests.remainingOutputs(of: &level.rootFeed)
        let childOutputs = await SessionWorkEventTests.remainingOutputs(of: &level.childFeed)

        #expect(accepted == .acceptedAwaitingCompletion)
        #expect(completed == .completed)
        #expect(answers == [.accept(content: nil)])
        #expect(Self.completionCount(in: rootOutputs + rootRest) == Self.once)
        #expect(Self.completionCount(in: childOutputs) == Self.once)
        #expect(PendingElicitationFixtures.ends(in: rootOutputs + rootRest + childOutputs).isEmpty)
    }

    // MARK: - An end with no answer

    /// The production change that makes this test fail: a relay that does
    /// not send the end of the child up, so the root keeps an open question
    /// whose run in the child ended.
    @Test("a cancel of the asking run in the child ends the question one time at each level")
    func aRunCancelInTheChildEndsTheQuestionOneTimeAtEachLevel() async throws {
        var level = try await Self.askOneLevel()
        let childActor = try #require(level.child as? RoutedSessionActor)
        let cancelling = Origin.mail([MailID()])

        _ = await OriginContext.$current.withValue(cancelling) {
            await childActor.runPlane.cancel(completionToken: level.childQuestion.correlationID)
        }
        let childOutputs = await SessionWorkEventTests.outputs(
            from: &level.childFeed, through: SessionEventCase.runSettled.matches)
        let rootOutputs = await SessionWorkEventTests.outputs(
            from: &level.rootFeed, through: SessionEventCase.elicitationEnded.matches)

        let ends = try await Self.expectOneEndAtEachLevel(
            of: level, rootOutputs: rootOutputs, childOutputs: childOutputs, childOrigin: cancelling)
        #expect(ends.child < (try position(ofFirst: .runSettled, in: childOutputs)))
        #expect(firstPosition(in: rootOutputs, where: SessionEventCase.runSettled.matches) == nil)
        await level.fixture.end(opening: [level.rootStep.gate])
    }

    /// The production change that makes this test fail: a relaying level
    /// that does not end the copy of the question in the child when its own
    /// copy ended, so the run of the child waits on a question that nobody
    /// can answer.
    @Test("cancelAll() of the root ends the question one time at each level, before its signalDone")
    func cancelAllOfTheParentEndsEachLevelOneTime() async throws {
        var level = try await Self.askOneLevel()

        let signal = level.root.cancelAll()
        let rootOutputs = await Self.outputs(
            from: &level.rootFeed, throughEach: [{ $0 == .signalDone(signal) }, SessionEventCase.runSettled.matches])
        let childOutputs = await SessionWorkEventTests.remainingOutputs(of: &level.childFeed)

        let ends = try await Self.expectOneEndAtEachLevel(
            of: level, rootOutputs: rootOutputs, childOutputs: childOutputs, rootOrigin: .signal(signal))
        #expect(ends.root < (try position(of: .signalDone(signal), in: rootOutputs)))
        #expect(ends.root < (try position(ofFirst: .runSettled, in: rootOutputs)))
        await level.fixture.end()
    }

    /// The production change that makes this test fail: a close of the root
    /// that does not reach the copy of the question in the child.
    @Test("close() of the root ends the question one time at each level, before each feed ends")
    func closeOfTheParentEndsEachLevelBeforeEachFeedEnds() async throws {
        var level = try await Self.askOneLevel()

        await level.root.close()
        let rootOutputs = await SessionWorkEventTests.remainingOutputs(of: &level.rootFeed)
        let childOutputs = await SessionWorkEventTests.remainingOutputs(of: &level.childFeed)

        try await Self.expectOneEndAtEachLevel(of: level, rootOutputs: rootOutputs, childOutputs: childOutputs)
        await level.fixture.end()
    }

    /// The production change that makes this test fail: a relaying level
    /// that does not end the copy in the child with
    /// `RunPlane.endElicitation(_:with:)` when the close of the parent ended
    /// its own copy. Then the child sends no end while it is open, and its
    /// later close finds no question to end.
    ///
    /// The relaying run holds the child open on a close gate, so only the
    /// relay can end the copy in the child. The asking run in the child
    /// resumes only after the end of the child went out, so its answer shows
    /// that the end came while the child was still open.
    @Test("close() of the root ends the child copy through the relay while the child is open, and finish() returns")
    func closeOfTheParentEndsTheChildCopyWhileTheChildIsOpen() async throws {
        let closeGate = RunLatch()
        var level = try await Self.askOneLevel(
            rootStep: SubagentRelayStep(agentName: Self.reviewer, closeGate: closeGate))
        let childActor = try #require(level.child as? RoutedSessionActor)
        let root = level.root

        let closing = Task { await root.close() }
        let answers = try await level.fixture.box.waitForAnswers(Self.once)
        let childWasClosed = await childActor.isClosed
        let childOpen = await level.child.openElicitationIds()
        let finishedBeforeTheChildClosed = level.fixture.box.finishedRelays
        await closeGate.open()
        await closing.value
        let finished = try await level.fixture.box.waitForFinishedRelays(Self.once)
        let rootOutputs = await SessionWorkEventTests.remainingOutputs(of: &level.rootFeed)
        let childOutputs = await SessionWorkEventTests.remainingOutputs(of: &level.childFeed)

        try await Self.expectOneEndAtEachLevel(of: level, rootOutputs: rootOutputs, childOutputs: childOutputs)
        #expect(answers == [PendingElicitationFixtures.runCancelled])
        #expect(childWasClosed == false)
        #expect(childOpen.isEmpty)
        #expect(finishedBeforeTheChildClosed == 0)
        #expect(finished == Self.once)
        await level.fixture.end()
    }

    /// The production change that makes this test fail: a relay whose run
    /// settles before the copy of the question in the child ended, or a
    /// relaying level that leaves that copy open.
    @Test("a cancel of the relaying run ends the root question with the origin of the cancel, before its runSettled")
    func aCancelOfTheRelayingRunEndsTheParentQuestionBeforeItsRunSettled() async throws {
        var level = try await Self.askOneLevel()
        let rootActor = try level.fixture.sessionActor()
        let cancelling = Origin.mail([MailID()])

        _ = await OriginContext.$current.withValue(cancelling) {
            await rootActor.runPlane.cancel(completionToken: level.rootQuestion.correlationID)
        }
        let rootOutputs = await SessionWorkEventTests.outputs(
            from: &level.rootFeed, through: SessionEventCase.runSettled.matches)
        let childOutputs = await SessionWorkEventTests.remainingOutputs(of: &level.childFeed)

        let ends = try await Self.expectOneEndAtEachLevel(
            of: level, rootOutputs: rootOutputs, childOutputs: childOutputs, rootOrigin: cancelling)
        #expect(ends.root < (try position(ofFirst: .runSettled, in: rootOutputs)))
        await level.fixture.end()
    }

    /// The production change that makes this test fail: a relay that does
    /// not end the open questions at the end of the feed of its child, so
    /// the relaying run settles while its own copy of the question is open.
    @Test("a close of the child ends its question, and the root copy ends before the relaying run settles")
    func closeOfTheChildEndsTheParentCopyBeforeTheRunSettled() async throws {
        var level = try await Self.askOneLevel()

        await level.rootStep.gate.open()
        let childOutputs = await SessionWorkEventTests.remainingOutputs(of: &level.childFeed)
        let rootOutputs = await SessionWorkEventTests.outputs(
            from: &level.rootFeed, through: SessionEventCase.runSettled.matches)

        let ends = try await Self.expectOneEndAtEachLevel(
            of: level, rootOutputs: rootOutputs, childOutputs: childOutputs)
        #expect(ends.root < (try position(ofFirst: .runSettled, in: rootOutputs)))
        await level.fixture.end()
    }

    // MARK: - Waiting only for the user

    /// The production change that makes this test fail: a parent that counts
    /// the relaying run as work while its child waits only for the user.
    @Test("a parent is idle while its child waits only for the user")
    func aParentIsIdleWhileItsChildWaitsOnlyForTheUser() async throws {
        var level = try await Self.askOneLevel()

        let rest = await SessionWorkEventTests.outputs(throughNextWorkEnd: &level.rootFeed)
        let isIdle = await level.root.awaitIdle()

        #expect(rest.last?.event == .workEnded)
        #expect(isIdle)
        await level.fixture.end(opening: [level.rootStep.gate])
    }

    /// The production change that makes this test fail: "an open question
    /// means no work" with no flag for the work of the child.
    @Test("a parent is not idle while its child works with an open question")
    func aParentIsNotIdleWhileItsChildWorksWithAnOpenQuestion() async throws {
        let besideRun = RunLatch()
        var level = try await Self.askOneLevel(SubagentAskStep(besideRun: besideRun))

        let isIdleWhileTheChildWorks = try await level.fixture.sessionActor().isIdle()
        await besideRun.open()
        let rest = await SessionWorkEventTests.outputs(throughNextWorkEnd: &level.rootFeed)

        #expect(isIdleWhileTheChildWorks == false)
        #expect(rest.last?.event == .workEnded)
        await level.fixture.end(opening: [level.rootStep.gate])
    }

    /// The production change that makes this test fail: a relaying level
    /// that notes no start of work before the answer goes down.
    @Test("a root answer starts the work of the root first, and then of the child")
    func aRootAnswerStartsTheWorkOfEachLevel() async throws {
        var level = try await Self.askOneLevel()
        _ = await SessionWorkEventTests.outputs(throughNextWorkEnd: &level.rootFeed)
        _ = await SessionWorkEventTests.outputs(throughNextWorkEnd: &level.childFeed)

        let delivery = await level.root.respond(
            elicitationId: try level.questionId.description, response: Self.acceptedForm)
        let rootNext = await level.rootFeed.next()
        let childNext = await level.childFeed.next()

        #expect(delivery == .delivered)
        #expect(rootNext == SessionOutput(origin: .system, event: .workStarted))
        #expect(childNext == SessionOutput(origin: .system, event: .workStarted))
        await level.fixture.end(opening: [level.rootStep.gate])
    }

    // MARK: - The open questions

    /// The production change that makes this test fail: a list that leaves
    /// out a relayed question, or that keeps a question after its end.
    @Test("openElicitationIds() lists a direct and a relayed question, and none after their ends")
    func openElicitationIdsListsDirectAndRelayedQuestions() async throws {
        var level = try await Self.askOneLevel()
        let relayedId = try level.questionId
        let rootActor = try level.fixture.sessionActor()
        let fakeRunGate = RunLatch()
        let token = await trackFakeRun(on: rootActor.runPlane, latch: fakeRunGate)
        let context = PendingElicitationFixtures.makeContext(
            for: level.root, postingTo: rootActor.outbox, completionToken: token)
        let directId = ULID.generate()
        let asking = Task {
            try await context.elicit(PendingElicitationFixtures.formRequest(elicitationId: directId))
        }
        _ = await SessionWorkEventTests.outputs(from: &level.rootFeed, through: Self.isQuestion(directId))

        let rootOpen = await level.root.openElicitationIds()
        let childOpen = await level.child.openElicitationIds()
        let signal = level.root.cancelAll()
        _ = await SessionWorkEventTests.outputs(from: &level.rootFeed, through: { $0 == .signalDone(signal) })
        let rootOpenAfter = await level.root.openElicitationIds()

        #expect(Set(rootOpen) == [relayedId.description, directId.description])
        #expect(childOpen == [relayedId.description])
        #expect(rootOpenAfter.isEmpty)
        #expect(try await asking.value == PendingElicitationFixtures.runCancelled)
        await level.fixture.end(opening: [fakeRunGate])
    }
}

/// Exercises the table of the relayed questions of one session
/// (``RelayedQuestions``): what the task of a relayed question does in the
/// child when the question ends at this level, and what the end of the feed
/// of a child ends.
@Suite("The table of the relayed questions decides what each question does in the child")
struct RelayedQuestionsTableTests {
    /// The token of the relaying run of each table.
    private static let runToken = "relaying-run"

    /// The cancel that ends a question with no answer.
    private static let ended = PendingElicitationFixtures.runCancelled

    /// A table with one relay and one relayed question of that relay.
    ///
    /// - Parameter request: The question. The default is a form-mode
    ///   question.
    /// - Returns: The table, the id of the question and the id of the relay.
    private static func tableWithOneQuestion(
        _ request: ElicitationRequest = MountFixtures.proceedRequest()
    ) -> (table: RelayedQuestions, id: ULID, relay: ULID) {
        var table = RelayedQuestions()
        let relay = ULID.generate()
        table.openRelay(relay, runToken: runToken, childWorks: false)
        table.noteRelayed(request, by: relay)
        return (table, request.elicitationId, relay)
    }

    /// The production change that makes this test fail: a task that does not
    /// end the copy in the child when the question ended at this level.
    @Test("a question that ended at this level ends the copy in the child with the same response")
    func aQuestionThatEndedHereEndsTheChildCopy() {
        var (table, id, _) = Self.tableWithOneQuestion()

        table.noteEndedHere(id, with: Self.ended)

        #expect(table.settle(id, resumedWith: Self.ended) == .end(Self.ended))
    }

    /// The production change that makes this test fail: a task that ends or
    /// answers the copy in the child after the child ended it itself.
    @Test("a question that ended below does nothing in the child")
    func aQuestionThatEndedBelowDoesNothing() {
        var (table, id, _) = Self.tableWithOneQuestion()

        let firstEnd = table.noteEndedBelow(id)
        let secondEnd = table.noteEndedBelow(id)

        #expect(firstEnd)
        #expect(secondEnd == false)
        #expect(table.settle(id, resumedWith: Self.ended) == .nothing)
    }

    /// The production change that makes this test fail: a task that
    /// completes the copy in the child after the child completed it itself.
    @Test("a question that completed below does nothing in the child")
    func aQuestionThatCompletedBelowDoesNothing() {
        var (table, id, _) = Self.tableWithOneQuestion(ElicitationCompletedEventTests.urlRequest(ULID.generate()))

        let completed = table.noteCompletedBelow(id)

        #expect(completed)
        #expect(table.settle(id, resumedWith: .accept(content: nil)) == .nothing)
    }

    /// The production change that makes this test fail: a task that does not
    /// give the answer of the user to the child.
    @Test("an answer of the user goes to the child, and a URL accept completes the copy in the child")
    func anAnswerGoesDownAndAURLAcceptCompletes() {
        var (form, formId, _) = Self.tableWithOneQuestion()
        var (url, urlId, _) = Self.tableWithOneQuestion(ElicitationCompletedEventTests.urlRequest(ULID.generate()))

        #expect(form.settle(formId, resumedWith: .decline) == .answer(.decline))
        #expect(url.settle(urlId, resumedWith: .accept(content: nil)) == .complete)
    }

    /// The production change that makes this test fail: an end of the feed
    /// that leaves an open question of the relay open, or that ends a
    /// question of another relay.
    @Test("the end of the feed of a child ends each open question of its relay, and no other question")
    func theEndOfTheFeedEndsEachOpenQuestionOfItsRelay() {
        var (table, firstId, relay) = Self.tableWithOneQuestion()
        let second = MountFixtures.proceedRequest()
        let endedHere = MountFixtures.proceedRequest()
        let otherRelay = ULID.generate()
        let ofOtherRelay = MountFixtures.proceedRequest()
        table.noteRelayed(second, by: relay)
        table.noteRelayed(endedHere, by: relay)
        table.noteEndedHere(endedHere.elicitationId, with: Self.ended)
        table.openRelay(otherRelay, runToken: Self.runToken, childWorks: false)
        table.noteRelayed(ofOtherRelay, by: otherRelay)

        let ended = table.endFeed(of: relay)

        #expect(Set(ended) == [firstId, second.elicitationId])
        #expect(table.settle(firstId, resumedWith: Self.ended) == .nothing)
        #expect(table.settle(endedHere.elicitationId, resumedWith: Self.ended) == .end(Self.ended))
        #expect(table.settle(ofOtherRelay.elicitationId, resumedWith: .decline) == .answer(.decline))
    }

    /// The production change that makes this test fail: a table that does
    /// not keep the run of a relay as work while the child of the relay
    /// works.
    @Test("a relay whose child works keeps its run as work, until the child stops or the relay closes")
    func aRelayWithAWorkingChildKeepsItsRunAsWork() {
        var (table, _, relay) = Self.tableWithOneQuestion()

        let idle = table.runTokensWithWorkingChild
        table.noteChild(of: relay, works: true)
        let working = table.runTokensWithWorkingChild
        table.closeRelay(relay)

        #expect(idle.isEmpty)
        #expect(working == [Self.runToken])
        #expect(table.runTokensWithWorkingChild.isEmpty)
    }
}
