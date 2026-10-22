import Foundation
import FoundationModelsExtras
import FoundationModelsRouterTestSupport
import Testing

@testable import FoundationModelsRouter

/// The work state and the last summary that ``RouterSessionDirectory`` keeps
/// for each live session (ROUTER-9): one feed task for each registered
/// session reads `streamSessionEvents()`, applies ``SessionStateTracking``,
/// and sends `stateChanged` for each change, after the `started` of the
/// session.
///
/// Each test runs a scripted backend, so the suite needs no network and no
/// GPU. A latch holds a turn open where a test reads the state during the
/// turn, so no read races the end of the turn.
@Suite("RouterSessionDirectory: the work state and the last summary of each live session")
struct RouterSessionDirectoryStateTests {
    /// The backend the scripted-turn tests drive.
    private typealias Backend = SessionMessagePumpTests.PumpProbeBackend

    /// A router over one scripted backend, and its directory.
    struct Fixture {
        /// The router that resolved ``profile``. It owns ``directory``.
        let router: Router

        /// The resolved profile the sessions come from.
        let profile: LanguageModelProfile

        /// The directory under test: the router's own.
        var directory: RouterSessionDirectory { router.sessionDirectory }

        /// Vends one session from the `.standard` slot of ``profile``. The
        /// vend registers it in ``directory``.
        ///
        /// - Returns: The vended session.
        func vend() -> any RoutedSession {
            profile.standard.makeSession(configuration: SessionConfiguration())
        }
    }

    // MARK: - Constants

    /// The prompt of each message the tests send. Over a
    /// ``BackgroundingSessionFixture`` it starts the run of each tool.
    private static let prompt = "run the job"

    /// The number of the first call of a scripted backend.
    private static let firstCall = 1

    /// The number of the call that continues a chain after a rejected tool
    /// call.
    private static let continuationCall = 2

    /// The events of a vend and of one held turn up to the state of the
    /// turn: `started`, then `stateChanged` to working.
    private static let eventsUpToTheTurn = 2

    /// The events of the end of a turn: `stateChanged` with the new last
    /// summary while the session still works, and `stateChanged` to idle.
    private static let eventsOfTheTurnEnd = 2

    /// An event no session sends, which a test sends to mark the end of what
    /// it reads.
    private static let marker = SessionDirectoryEvent.archived(id: ULID.generate())

    // MARK: - Helpers

    /// Makes a router over a scripted backend that follows `script`.
    ///
    /// - Parameter script: What each call of the backend does, by its
    ///   one-based number.
    /// - Returns: The fixture.
    private static func makeFixture(script: [Int: SessionMessagePumpTests.ScriptedCall]) async throws -> Fixture {
        let scratch = RouterTestFixtures.makeTempDir(prefix: "RouterSessionDirectoryStateTests")
        let (router, profile) = try await RouterTestFixtures.resolveStandardProfile(
            over: SessionMessagePumpTests.PumpProbeContainer(backend: Backend(script: script)),
            cacheDir: scratch.appendingPathComponent("cache"))
        return Fixture(router: router, profile: profile)
    }

    /// Makes a router over a scripted model with no script, for the tests
    /// that run no turn.
    ///
    /// - Returns: The fixture.
    private static func makeIdleFixture() async throws -> Fixture {
        let scratch = RouterTestFixtures.makeTempDir(prefix: "RouterSessionDirectoryStateTests")
        let (router, profile) = try await RouterTestFixtures.resolveStandardProfile(
            over: BasicLLMContainer(), cacheDir: scratch.appendingPathComponent("cache"))
        return Fixture(router: router, profile: profile)
    }

    /// The `stateChanged` of the session `id`.
    ///
    /// - Parameters:
    ///   - id: The session id.
    ///   - state: The new state.
    ///   - lastSummary: The last summary.
    /// - Returns: The event.
    private static func stateChanged(
        of id: ULID, to state: SessionState, lastSummary: String?
    ) -> SessionDirectoryEvent {
        .stateChanged(id: id, state: state, lastSummary: lastSummary)
    }

    /// The id of the session that `event` starts, or `nil` when `event` is
    /// not a `started`.
    ///
    /// - Parameter event: A directory event.
    /// - Returns: The session id.
    private static func startedSession(in event: SessionDirectoryEvent?) -> ULID? {
        guard case .started(let summary, _) = event else { return nil }
        return summary.id
    }

    /// Reads `events` up to and including the first event that `isLast`
    /// accepts.
    ///
    /// - Parameters:
    ///   - events: The iterator of a directory stream.
    ///   - isLast: The test of the last event to read.
    /// - Returns: Each event read, in order.
    private static func events(
        from events: inout AsyncStream<SessionDirectoryEvent>.Iterator,
        through isLast: (SessionDirectoryEvent) -> Bool
    ) async -> [SessionDirectoryEvent] {
        var read: [SessionDirectoryEvent] = []
        // Rule T1 quiet state: a directory that never sends the awaited event
        // hangs here, and the test never passes.
        while let event = await events.next() {
            read.append(event)
            if isLast(event) {
                break
            }
        }
        return read
    }

    // MARK: - Working and idle

    /// The production change that makes this test fail: a summary that
    /// keeps `idle` for a live session, as before ROUTER-9.
    @Test("during a held turn the summary gives working, and after it idle with the reply as the last summary")
    func aTurnIsWorkingAndItsEndIsIdleWithTheReply() async throws {
        let latch = RunLatch()
        let fixture = try await Self.makeFixture(script: [Self.firstCall: .hold(latch)])
        var events = fixture.directory.events().makeAsyncIterator()
        let session = fixture.vend()
        defer {
            await latch.open()
            await session.close()
        }
        let reply = Backend.answer(ofCall: Self.firstCall)

        _ = try session.send(Self.prompt)
        let upToTheTurn = await events.next(count: Self.eventsUpToTheTurn)
        let during = try #require(try await fixture.directory.summary(of: session.id))
        await latch.open()
        let turnEnd = await events.next(count: Self.eventsOfTheTurnEnd)
        let after = try #require(try await fixture.directory.summary(of: session.id))

        #expect(upToTheTurn.last == Self.stateChanged(of: session.id, to: .working, lastSummary: nil))
        #expect(during.state == .working)
        #expect(
            turnEnd == [
                Self.stateChanged(of: session.id, to: .working, lastSummary: reply),
                Self.stateChanged(of: session.id, to: .idle, lastSummary: reply),
            ])
        #expect(after.state == .idle)
        #expect(after.lastSummary == reply)
        #expect(after.updatedAt > session.id.timestamp)
    }

    /// The production change that makes this test fail: the literal spec
    /// mapping, where `submissionEnded` gives idle. The rejected first
    /// submission then reports idle before the continuation answers.
    @Test("a turn of two submissions reports started first, one stateChanged for each change, and no idle before its answer")
    func aTurnOfTwoSubmissionsReportsNoIdleBeforeItsAnswer() async throws {
        let latch = RunLatch()
        await latch.open()
        let fixture = try await Self.makeFixture(script: [Self.firstCall: .holdThenReject(latch)])
        var events = fixture.directory.events().makeAsyncIterator()
        let session = fixture.vend()
        defer { await session.close() }
        let reply = Backend.answer(ofCall: Self.continuationCall)

        _ = try session.send(Self.prompt)
        let received = await Self.events(from: &events) { event in
            event == Self.stateChanged(of: session.id, to: .idle, lastSummary: reply)
        }
        fixture.directory.emit(Self.marker)
        let afterTheTurn = await events.next(count: 1)

        #expect(Self.startedSession(in: received.first) == session.id)
        #expect(
            Array(received.dropFirst()) == [
                Self.stateChanged(of: session.id, to: .working, lastSummary: nil),
                Self.stateChanged(of: session.id, to: .working, lastSummary: reply),
                Self.stateChanged(of: session.id, to: .idle, lastSummary: reply),
            ])
        #expect(afterTheTurn == [Self.marker])
    }

    // MARK: - Needs input

    /// The state of a `stateChanged` event, or `nil` for another event.
    ///
    /// - Parameter event: A directory event.
    /// - Returns: The state.
    private static func state(in event: SessionDirectoryEvent?) -> SessionState? {
        guard case .stateChanged(_, let state, _) = event else { return nil }
        return state
    }

    /// The production change that makes this test fail: a work end that
    /// gives idle while the question of a run is open. The run asks, and
    /// then the session sends its work end; that idle then comes before the
    /// working of the answer to the question.
    @Test("while the question of a run is open the summary gives needsInput, and its answer gives working")
    func anOpenQuestionGivesNeedsInput() async throws {
        let askGate = RunLatch()
        let returnGate = RunLatch()
        let fixture = try await BackgroundingSessionFixture.make(
            prefix: "RouterSessionDirectoryStateTests",
            tools: [SessionWorkEventTests.AskingTool(asksForURL: false, askGate: askGate, returnGate: returnGate)])
        defer { await fixture.end(opening: [askGate, returnGate]) }
        let directory = fixture.router.sessionDirectory
        var events = directory.events().makeAsyncIterator()
        var feed = await fixture.session.streamSessionEvents().makeAsyncIterator()
        let id = fixture.session.id

        // Up to the work end that comes after the question of the run.
        _ = try await SessionWorkEventTests.outputsUpToTheQuestion(of: fixture, askGate: askGate, feed: &feed)
        _ = await Self.events(from: &events) { Self.state(in: $0) == .needsInput }
        let asking = try #require(try await directory.summary(of: id))
        let question = try #require(await fixture.session.openElicitationIds().first)
        _ = await fixture.session.respond(elicitationId: question, response: .decline)
        let afterTheAnswer = await events.next(count: 1)

        #expect(asking.state == .needsInput)
        #expect(Self.state(in: afterTheAnswer.first) == .working)
    }

    // MARK: - The feed task

    /// The production change that makes this test fail: a feed task that
    /// holds the session strongly, or a session whose feed never ends when
    /// it is released without `close()`.
    @Test("a session released without close deallocates, and its feed task ends")
    func aReleasedSessionEndsItsFeed() async throws {
        let fixture = try await Self.makeIdleFixture()
        var session: (any RoutedSession)? = fixture.vend()
        weak let released = session
        let id = try #require(session?.id)
        let feed = try #require(fixture.directory.stateFeed(of: id))

        session = nil
        // Rule T1 quiet state: a feed that never ends hangs here.
        await feed.value

        #expect(released == nil)
        #expect(try await fixture.directory.summary(of: id) == nil)
    }

    @Test("close ends the feed task of the session")
    func closeEndsTheFeed() async throws {
        let fixture = try await Self.makeIdleFixture()
        let session = fixture.vend()
        let feed = try #require(fixture.directory.stateFeed(of: session.id))

        await session.close()
        // Rule T1 quiet state: a feed that never ends hangs here.
        await feed.value

        #expect(fixture.directory.stateFeed(of: session.id) == nil)
    }

    @Test("a second registration of a live session keeps its one feed task")
    func aSecondRegistrationKeepsTheFeed() async throws {
        let fixture = try await Self.makeIdleFixture()
        let session = fixture.vend()
        defer { await session.close() }
        let first = try #require(fixture.directory.stateFeed(of: session.id))

        fixture.directory.register(session, kind: .root, parentID: nil)

        #expect(fixture.directory.stateFeed(of: session.id) == first)
    }
}
