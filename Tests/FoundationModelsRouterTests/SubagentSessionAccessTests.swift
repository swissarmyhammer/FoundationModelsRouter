import Foundation
import FoundationModels
import FoundationModelsExtras
import Synchronization
import Testing

@testable import FoundationModelsRouter

/// Exercises `RouterSessionDirectory.session(id:)`: a host
/// gets the live session of any session in the directory, also a sub-agent
/// session at any depth, and uses it to read the feed of that session and to
/// answer its questions.
///
/// The directory is flat: each vended or restored session has one entry. So
/// a chain of three sessions follows the same rule at every level. The
/// entry holds the session weakly, so the accessor does not keep it alive.
///
/// The question tests use the relay fixtures of ``SubagentQuestionRelayTests``
/// (``SubagentRelayFixture``). Everything runs against the scripted
/// ``BackgroundingBackend``, so the suite needs no network and no GPU.
@Suite("A host gets the live session of a sub-agent session from the directory")
struct SubagentSessionAccessTests {
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

    /// A child session that a host got from the directory the moment the
    /// session was made, with a feed that was open before the first mail of
    /// the child.
    private struct AccessedChild: Sendable {
        /// The session that ``RouterSessionDirectory/session(id:)`` gave.
        let session: any RoutedSession

        /// A feed of that session.
        let feed: AsyncStream<SessionOutput>
    }

    /// Collects the children that a host got through
    /// ``RouterSessionDirectory/session(id:)``, as a host does when it reads
    /// the `started` event of a sub-agent session.
    private final class AccessLog: Sendable {
        /// The children, in the order they were made.
        private let children = Mutex<[AccessedChild]>([])

        /// Makes a child of `parent`, as the relay fixtures do, then gets
        /// that child from the directory by its id, and opens a feed of the
        /// session that the directory gave.
        ///
        /// - Parameter parent: The session of the relaying run.
        /// - Returns: The child.
        /// - Throws: When `parent` is not a session actor, or the directory
        ///   gives no session for the child.
        func makeChild(of parent: any RoutedSession) async throws -> any RoutedSession {
            let child = try SubagentRelayBox.subagentChild(of: parent)
            let directory = try #require((parent as? RoutedSessionActor)?.profile.standard.sessionDirectory)
            let accessed = try #require(directory.session(id: child.id))
            let feed = await accessed.streamSessionEvents()
            children.withLock { $0.append(AccessedChild(session: accessed, feed: feed)) }
            return child
        }

        /// The first child, or `nil` when no child exists yet.
        var first: AccessedChild? { children.withLock { $0.first } }
    }

    /// Makes a root session with one child that asks one question, and a log
    /// of the children that the host got from the directory.
    ///
    /// - Parameter rootStep: The relaying level of the root.
    /// - Returns: The fixture and the log.
    /// - Throws: What the fixture throws.
    private static func makeAskingFixture(
        rootStep: SubagentRelayStep
    ) async throws -> (fixture: SubagentRelayFixture, log: AccessLog) {
        let log = AccessLog()
        let fixture = try await SubagentRelayFixture.make(
            root: rootStep, children: [.ask(SubagentAskStep())], makeChild: { try await log.makeChild(of: $0) })
        return (fixture, log)
    }

    /// Reads `feed` up to and including the next question, or the next settle
    /// of a run (rule T1).
    ///
    /// - Parameter feed: The iterator of a feed.
    /// - Returns: The outputs read.
    private static func outputsThroughQuestion(_ feed: inout AsyncStream<SessionOutput>.Iterator) async
        -> [SessionOutput]
    {
        // Rule T1 quiet state: a feed with no question and no settle hangs here; the gate holds the root run.
        await SessionWorkEventTests.outputs(
            from: &feed,
            through: { SessionEventCase.elicitationRequested.matches($0) || SessionEventCase.runSettled.matches($0) })
    }

    /// Runs `body` with the standard profile over a durable recording root,
    /// and the session directory of its router.
    ///
    /// - Parameter body: The work to run.
    private static func withDirectory(
        _ body: (LanguageModelProfile, RouterSessionDirectory) async throws -> Void
    ) async throws {
        try await SessionFactsFixtures.withRecordingProfile(prefix: "SubagentSessionAccessTests") { profile in
            try await body(profile, try #require(profile.standard.sessionDirectory))
        }
    }

    // MARK: - A chain of three sessions

    /// The production change that makes this test fail: an accessor that
    /// finds only a root, or only the direct child of a root.
    @Test("a chain of three sessions: the directory gives the same live session at every level")
    func aChainOfThreeSessionsIsFoundAtEveryLevel() async throws {
        let rootStep = SubagentRelayStep(agentName: Self.reviewer)
        let middleStep = SubagentRelayStep(agentName: Self.linter)
        let fixture = try await SubagentRelayFixture.make(
            root: rootStep, children: [.relay(middleStep), .ask(SubagentAskStep())])
        defer { await fixture.end(opening: [rootStep.gate, middleStep.gate]) }
        try await fixture.start()
        let children = try await fixture.box.waitForChildren(Self.twoLevels)
        let directory = fixture.base.router.sessionDirectory

        let sessions = [fixture.session, try #require(children.first).session, try #require(children.last).session]
        let found = sessions.map { directory.session(id: $0.id) }

        #expect(zip(found, sessions).allSatisfy { $0 === $1 })
    }

    /// The production change that makes this test fail: an accessor that
    /// looks up an id that was never registered, and gives a session.
    @Test("an id that no session has gives nil")
    func anUnknownIdGivesNil() async throws {
        try await Self.withDirectory { _, directory in
            #expect(directory.session(id: ULID.generate()) == nil)
        }
    }

    // MARK: - Close and release

    /// The production change that makes this test fail: an accessor that
    /// keeps a closed session in its answer.
    @Test("a closed session gives nil, also while the host still holds it")
    func aClosedSessionGivesNil() async throws {
        try await Self.withDirectory { profile, directory in
            let session = profile.standard.makeSession(configuration: SessionConfiguration())
            let beforeClose = directory.session(id: session.id)

            await session.close()

            #expect(beforeClose === session)
            #expect(directory.session(id: session.id) == nil)
        }
    }

    /// The production change that makes this test fail: an accessor that
    /// stores the session strongly, so a session that nobody holds never
    /// deallocates.
    @Test("the accessor does not keep a session alive: a released session deallocates and gives nil")
    func theAccessorDoesNotRetainTheSession() async throws {
        try await Self.withDirectory { profile, directory in
            var session: (any RoutedSession)? = profile.standard.makeSession(configuration: SessionConfiguration())
            let id = try #require(session?.id)
            let feed = try #require(directory.stateFeed(of: id))
            weak let probe = session
            #expect(directory.session(id: id) != nil)

            session = nil
            // Rule T1 quiet state: a session that something holds never ends its feed task, and this wait hangs.
            await feed.value

            #expect(probe == nil)
            #expect(directory.session(id: id) == nil)
        }
    }

    // MARK: - A restored session

    /// The production change that makes this test fail: a restore that
    /// registers its session in a way that the accessor does not read.
    @Test("a restored session is found by its id")
    func aRestoredSessionIsFound() async throws {
        try await Self.withDirectory { profile, directory in
            let recorded = profile.standard.makeSession(configuration: SessionConfiguration())
            await recorded.close()

            let restored = try await profile.standard.restoreSession(id: recorded.id)
            let found = directory.session(id: restored.session.id)

            #expect(found === restored.session)
            await restored.session.close()
        }
    }

    // MARK: - The question of a child

    /// The production change that makes this test fail: an accessor that
    /// gives a session whose feed does not carry the question of the child
    /// with its original id.
    @Test("the feed of the session from the directory carries the question of the child with the id of the root copy")
    func theChildFeedCarriesTheQuestionWithTheOriginalId() async throws {
        let rootStep = SubagentRelayStep(agentName: Self.reviewer)
        let (fixture, log) = try await Self.makeAskingFixture(rootStep: rootStep)
        defer { await fixture.end(opening: [rootStep.gate]) }
        var rootFeed = await fixture.session.streamSessionEvents().makeAsyncIterator()
        try await fixture.start()
        _ = try await fixture.box.waitForChildren(Self.once)
        var childFeed = try #require(log.first).feed.makeAsyncIterator()

        let childQuestion = try firstQuestion(in: await Self.outputsThroughQuestion(&childFeed))
        let rootQuestion = try firstQuestion(in: await Self.outputsThroughQuestion(&rootFeed))

        #expect(try #require(childQuestion.elicitation).elicitationId == (try #require(rootQuestion.elicitation).elicitationId))
    }

    /// The production change that makes this test fail: a session from the
    /// directory whose answer does not reach the run of the child.
    @Test("an answer through the session from the directory reaches the run of the child, which then continues")
    func anAnswerThroughTheChildReachesTheChildRun() async throws {
        let rootStep = SubagentRelayStep(agentName: Self.reviewer)
        let (fixture, log) = try await Self.makeAskingFixture(rootStep: rootStep)
        defer { await fixture.end(opening: [rootStep.gate]) }
        try await fixture.start()
        _ = try await fixture.box.waitForChildren(Self.once)
        let accessed = try #require(log.first)
        var childFeed = accessed.feed.makeAsyncIterator()
        let id = try #require(
            try firstQuestion(in: await Self.outputsThroughQuestion(&childFeed)).elicitation
        ).elicitationId

        let delivery = await accessed.session.respond(elicitationId: id.description, response: Self.acceptedForm)
        let answers = try await fixture.box.waitForAnswers(Self.once)

        #expect(delivery == .delivered)
        #expect(answers == [Self.acceptedForm])
    }

    /// The production change that makes this test fail: an answer through
    /// the child that leaves the relayed copy in the parent open after the
    /// relaying run ended, or that ends it more than one time. The copy ends
    /// when the relay ends (the feed of the child ends with the close of the
    /// child), with a cancel that gives the reason of a stopped run. It does
    /// not end at the moment of the answer through the child.
    @Test("an answer through the child: the copy in the parent ends one time, when the relay ends")
    func anAnswerThroughTheChildEndsTheParentCopyOneTime() async throws {
        let rootStep = SubagentRelayStep(agentName: Self.reviewer)
        let (fixture, log) = try await Self.makeAskingFixture(rootStep: rootStep)
        defer { await fixture.end(opening: [rootStep.gate]) }
        var rootFeed = await fixture.session.streamSessionEvents().makeAsyncIterator()
        try await fixture.start()
        _ = try await fixture.box.waitForChildren(Self.once)
        let accessed = try #require(log.first)
        var childFeed = accessed.feed.makeAsyncIterator()
        let id = try #require(
            try firstQuestion(in: await Self.outputsThroughQuestion(&childFeed)).elicitation
        ).elicitationId
        _ = await Self.outputsThroughQuestion(&rootFeed)

        _ = await accessed.session.respond(elicitationId: id.description, response: Self.acceptedForm)
        _ = try await fixture.box.waitForAnswers(Self.once)
        await rootStep.gate.open()
        // The relaying run settles after the close of the child, whatever happened to the copy.
        let rootOutputs = await SessionWorkEventTests.outputs(
            from: &rootFeed, through: SessionEventCase.runSettled.matches)

        let ends = PendingElicitationFixtures.ends(in: rootOutputs)
        #expect(ends.map(\.end.elicitationId) == [id])
        #expect(await fixture.session.openElicitationIds().isEmpty)
    }

    /// A host that answers at both levels: the child first, then the copy in
    /// the parent. This test records what happens today: an answer through
    /// the child does not reach the parent copy, so the parent copy stays
    /// open and still takes an answer (`.delivered`). The relay sends that
    /// answer down, and the child no longer has the question, so the run of
    /// the child keeps the first answer only.
    @Test("an answer at the child and then at the parent copy: the parent takes it, and the run of the child keeps the first answer")
    func anAnswerAtBothLevelsGivesTheChildRunTheFirstOnly() async throws {
        let rootStep = SubagentRelayStep(agentName: Self.reviewer)
        let (fixture, log) = try await Self.makeAskingFixture(rootStep: rootStep)
        defer { await fixture.end(opening: [rootStep.gate]) }
        var rootFeed = await fixture.session.streamSessionEvents().makeAsyncIterator()
        try await fixture.start()
        _ = try await fixture.box.waitForChildren(Self.once)
        let accessed = try #require(log.first)
        var childFeed = accessed.feed.makeAsyncIterator()
        let id = try #require(
            try firstQuestion(in: await Self.outputsThroughQuestion(&childFeed)).elicitation
        ).elicitationId
        _ = await Self.outputsThroughQuestion(&rootFeed)

        _ = await accessed.session.respond(elicitationId: id.description, response: Self.acceptedForm)
        _ = try await fixture.box.waitForAnswers(Self.once)
        let second = await fixture.session.respond(elicitationId: id.description, response: .decline)
        await rootStep.gate.open()
        _ = await SessionWorkEventTests.outputs(from: &rootFeed, through: SessionEventCase.runSettled.matches)

        #expect(fixture.box.answers == [Self.acceptedForm])
        #expect(second == .delivered)
    }
}
