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
    /// - Returns: The fixture.
    /// - Throws: What the resolve of the profile throws.
    static func make(
        prefix: String,
        tools: [any Tool],
        container: BackgroundingLLMContainer = BackgroundingLLMContainer(),
        mailOnlyAnswerLimit: Int = SessionConfiguration.defaultMailOnlyAnswerLimit
    ) async throws -> Self {
        let started = try await SessionFixtureLifecycle.start(
            over: container,
            configuration: SessionConfiguration(tools: tools, mailOnlyAnswerLimit: mailOnlyAnswerLimit),
            prefix: prefix)
        let backend = try #require(container.lastBackend)
        return Self(session: started.session, backend: backend, router: started.router, directory: started.directory)
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
}
