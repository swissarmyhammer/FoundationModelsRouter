import Foundation
import FoundationModels
import FoundationModelsRouterTestSupport
import Testing

@testable import FoundationModelsExtras
@testable import FoundationModelsRouter

/// One session over a ``BackgroundingBackend``, with what a test reads. The
/// suites that examine the work of a session (`SessionIdleWaitTests` and
/// `SessionWorkEventTests`) make their sessions here.
///
/// The start and the end of the session are the shared steps of
/// ``SessionFixtureLifecycle``. This fixture adds only the backend that the
/// container vends.
struct BackgroundingSessionFixture: Sendable {
    /// The session under test.
    let session: any RoutedSession

    /// The backend the session runs on.
    let backend: BackgroundingBackend

    /// The router that keeps the models of the session resident.
    let router: Router

    /// The temporary directory the router caches under.
    let directory: URL

    /// Makes a session with `tools` over the backend that `container` vends.
    ///
    /// - Parameters:
    ///   - prefix: The prefix of the temporary directory of the router.
    ///   - tools: The tools of the session.
    ///   - container: The container that vends the backend.
    ///   - mailOnlyAnswerLimit: The ``SessionConfiguration/mailOnlyAnswerLimit``
    ///     of the session.
    ///   - userPresence: The ``SessionConfiguration/userPresence`` of the
    ///     session.
    ///   - recordingsDir: The durable transcripts root of the router, or
    ///     `nil` (the default) for a router that records only in memory.
    /// - Returns: The fixture.
    /// - Throws: What the resolve of the profile throws, or when the
    ///   container vended no backend. Before it throws for the backend, it
    ///   ends the session that it started.
    static func make(
        prefix: String,
        tools: [any Tool],
        container: BackgroundingLLMContainer = BackgroundingLLMContainer(),
        mailOnlyAnswerLimit: Int = SessionConfiguration.defaultMailOnlyAnswerLimit,
        userPresence: UserPresence = .interactive,
        recordingsDir: URL? = nil
    ) async throws -> Self {
        let started = try await SessionFixtureLifecycle.start(
            over: container,
            configuration: SessionConfiguration(
                tools: tools, mailOnlyAnswerLimit: mailOnlyAnswerLimit, userPresence: userPresence),
            prefix: prefix, recordingsDir: recordingsDir)
        do {
            let backend = try #require(container.lastBackend)
            return Self(
                session: started.session, backend: backend, router: started.router, directory: started.directory)
        } catch {
            await SessionFixtureLifecycle.end(started, opening: [])
            throw error
        }
    }

    /// The session as its one concrete type, whose internal state a test
    /// reads.
    ///
    /// - Returns: The session actor.
    /// - Throws: When the session is not a ``RoutedSessionActor``.
    func sessionActor() throws -> RoutedSessionActor {
        try #require(session as? RoutedSessionActor)
    }

    /// Ends the fixture with ``SessionFixtureLifecycle/end(_:opening:)``:
    /// opens `gates`, closes the session, and removes the directory.
    ///
    /// - Parameter gates: The gates of the runs of the session.
    func end(opening gates: [RunLatch] = []) async {
        await SessionFixtureLifecycle.end(
            SessionFixtureLifecycle.Started(session: session, router: router, directory: directory), opening: gates)
    }

    /// Runs `body`, and then ends the fixture with ``end(opening:)``. The end
    /// comes also when `body` throws, so a test that fails leaves no session
    /// open and no run held on `gates`.
    ///
    /// - Parameters:
    ///   - gates: The gates of the runs of the session.
    ///   - body: The steps of the test.
    /// - Throws: What `body` throws.
    func endingAfter(opening gates: [RunLatch] = [], _ body: () async throws -> Void) async throws {
        do {
            try await body()
        } catch {
            await end(opening: gates)
            throw error
        }
        await end(opening: gates)
    }

    /// Ends the fixture with ``end(opening:)`` and then reads `feed` to its
    /// end. The close of the session finishes the feed.
    ///
    /// - Parameters:
    ///   - feed: The iterator of a feed of the session.
    ///   - gates: The gates of the runs of the session.
    /// - Returns: Each output that `feed` did not give yet, in order.
    func outputsToTheEnd(
        of feed: inout AsyncStream<SessionOutput>.Iterator, opening gates: [RunLatch]
    ) async -> [SessionOutput] {
        await end(opening: gates)
        return await SessionWorkEventTests.remainingOutputs(of: &feed)
    }
}
