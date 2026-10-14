import Foundation
import FoundationModels
import FoundationModelsRouterTestSupport
import Testing

@testable import FoundationModelsExtras
@testable import FoundationModelsRouter

/// One session over a ``BackgroundingBackend``, with what a test reads. The
/// suites that examine the work of a session (`SessionIdleWaitTests` and
/// `SessionWorkEventTests`) make their sessions here.
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
        let directory = RouterTestFixtures.makeTempDir(prefix: prefix)
        let (router, profile) = try await RouterTestFixtures.resolveStandardProfile(
            over: container, cacheDir: directory)
        let session = profile.standard.makeSession(
            configuration: SessionConfiguration(tools: tools, mailOnlyAnswerLimit: mailOnlyAnswerLimit))
        let backend = try #require(container.lastBackend)
        return Self(session: session, backend: backend, router: router, directory: directory)
    }

    /// Ends the fixture: opens `gates`, so no run body stays held, closes the
    /// session, and removes the directory.
    ///
    /// - Parameter gates: The gates of the runs of the session.
    func end(opening gates: [RunLatch] = []) async {
        for gate in gates {
            await gate.open()
        }
        await session.close()
        try? FileManager.default.removeItem(at: directory)
        withExtendedLifetime(router) {}
    }
}
