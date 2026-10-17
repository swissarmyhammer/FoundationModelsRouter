import Foundation
import FoundationModelsRouterTestSupport

@testable import FoundationModelsExtras
@testable import FoundationModelsRouter

/// The steps that the session fixtures of the tests share: the start of a
/// session over a container, in a new temporary directory, and the end of
/// that session.
///
/// Each step is in this one place, so the fixtures cannot drift apart.
/// ``BackgroundingSessionFixture`` uses both steps.
/// ``NoOpToolCallSessionFixture`` uses both steps for a vended session, and
/// only the end step for a restored session.
enum SessionFixtureLifecycle {
    /// One session that a fixture started, with what its end needs.
    struct Started: Sendable {
        /// The session.
        let session: any RoutedSession

        /// The router that keeps the models of the session resident.
        let router: Router

        /// The temporary directory the router caches under.
        let directory: URL
    }

    /// Makes a new temporary directory, resolves the standard test profile
    /// over `container` in it, and makes a session with `configuration`.
    ///
    /// - Parameters:
    ///   - container: The container that vends the backend.
    ///   - configuration: The configuration of the session.
    ///   - prefix: The prefix of the temporary directory, so a directory
    ///     that stays shows the suite that made it.
    ///   - recordingsDir: The durable transcripts root of the router, or
    ///     `nil` (the default) for a router that records only in memory. The
    ///     end of the session does not remove this directory: the test owns
    ///     it.
    /// - Returns: The session, its router and its directory.
    /// - Throws: What the resolve of the profile throws. Before it throws, it
    ///   removes the directory.
    static func start(
        over container: any LoadedLLMContainer, configuration: SessionConfiguration, prefix: String,
        recordingsDir: URL? = nil
    ) async throws -> Started {
        let directory = RouterTestFixtures.makeTempDir(prefix: prefix)
        let (router, profile) = try await RouterTestFixtures.removingDirectoryOnThrow(directory) {
            try await RouterTestFixtures.resolveStandardProfile(
                over: container, cacheDir: directory, recordingsDir: recordingsDir)
        }
        let session = profile.standard.makeSession(configuration: configuration)
        return Started(session: session, router: router, directory: directory)
    }

    /// Ends a session that ``start(over:configuration:prefix:recordingsDir:)`` started:
    /// opens `gates`, so no run body stays held, closes the session, and
    /// removes the directory. The router stays alive until the end.
    ///
    /// - Parameters:
    ///   - started: The session, its router and its directory.
    ///   - gates: The gates of the runs of the session.
    static func end(_ started: Started, opening gates: [RunLatch]) async {
        await started.end(opening: gates)
        withExtendedLifetime(started.router) {}
    }

    /// Opens `gates`, so no work of the session stays held, and then closes
    /// `session`.
    ///
    /// This is the one gate-open-then-close teardown of the tests. A test
    /// calls it from one `defer`, so the held work ends also when the test
    /// throws (rule T1). The order is the part that matters: a close waits
    /// for the end of each held work, so a gate that opens after the close
    /// holds the close for ever. Each step is idempotent, so a test can also
    /// open a gate or close the session in its body.
    ///
    /// - Parameters:
    ///   - session: The session to close, or `nil` when the test dropped it.
    ///     The gates open also then.
    ///   - gates: The gates of the held work of the session.
    static func close(_ session: (any RoutedSession)?, opening gates: [RunLatch]) async {
        for gate in gates {
            await gate.open()
        }
        await session?.close()
    }
}

/// A test fixture that owns one session and the temporary directory that the
/// router of the session caches under.
///
/// The extension gives each such fixture the same two teardown steps (rule
/// T1): ``end(opening:)`` for the `defer` of a test, and
/// ``endingOnThrow(isolation:_:)`` for a helper step that runs after the make
/// and can throw.
protocol SessionDirectoryFixture {
    /// The session of the fixture.
    var session: any RoutedSession { get }

    /// The temporary directory that the router of the session caches under.
    var directory: URL { get }
}

extension SessionDirectoryFixture {
    /// Opens `gates`, closes the session with
    /// ``SessionFixtureLifecycle/close(_:opening:)``, and then removes the
    /// directory.
    ///
    /// A test calls it from one `defer` right after it gets the fixture, so
    /// the session closes also when the test throws (rule T1).
    ///
    /// - Parameter gates: The gates of the held work of the session. The
    ///   default is no gate.
    func end(opening gates: [RunLatch] = []) async {
        await SessionFixtureLifecycle.close(session, opening: gates)
        try? FileManager.default.removeItem(at: directory)
    }

    /// Runs `body`, and when `body` throws, closes the session and removes
    /// the directory before it throws the error again.
    ///
    /// A helper that makes the fixture and then does a step that can throw
    /// calls it for that step: the caller gets no fixture to end when the
    /// helper throws. When `body` returns, the session stays open, and the
    /// caller ends the fixture with ``end(opening:)``.
    ///
    /// - Parameters:
    ///   - isolation: The isolation of the caller. `body` runs there.
    ///   - body: The step that can throw.
    /// - Returns: What `body` returns.
    /// - Throws: What `body` throws, after the close and the removal.
    func endingOnThrow<Value>(
        isolation: isolated (any Actor)? = #isolation,
        _ body: () async throws -> Value
    ) async throws -> Value {
        try await RouterTestFixtures.removingDirectoryOnThrow(
            isolation: isolation, directory, alsoOnThrow: { await session.close() }, body)
    }
}

/// A started session has the same teardown steps, so
/// ``SessionFixtureLifecycle/end(_:opening:)`` uses ``SessionDirectoryFixture/end(opening:)``.
extension SessionFixtureLifecycle.Started: SessionDirectoryFixture {}
