import Foundation
import FoundationModelsExtras
import Testing

import FoundationModelsRouter

/// Holds ``SessionLauncher`` and the launcher calls of
/// ``RouterSessionDirectory`` to the access level a host outside this package
/// needs (ROUTER-8). A host conforms its own type to the port, gives it to
/// the router's directory, and releases it at shutdown.
///
/// The import is plain, with no `@testable`, so a member that loses `public`
/// stops this file from compiling before a single test runs.
@Suite("SessionLauncher over a plain import")
struct SessionLauncherPublicSurfaceTests {
    /// A host launcher that knows no agent: each start throws
    /// `unknownAgent`, so a start that reaches it shows the directory used it.
    struct AgentlessLauncher: SessionLauncher {
        /// Throws `unknownAgent` for each request.
        ///
        /// - Parameter request: The start request.
        /// - Returns: Nothing.
        /// - Throws: `SessionDirectoryError.unknownAgent` for
        ///   ``SessionLauncherPublicSurfaceTests/unknownAgentID``.
        func launchRootSession(for request: SessionStartRequest) async throws -> any RoutedSession {
            throw SessionDirectoryError.unknownAgent(SessionLauncherPublicSurfaceTests.unknownAgentID, nearNames: [])
        }

        /// Throws `unknownSession` for `id`.
        ///
        /// - Parameter id: The session id.
        /// - Returns: Nothing.
        /// - Throws: `SessionDirectoryError.unknownSession`.
        func restoreSession(id: ULID) async throws -> any RoutedSession {
            throw SessionDirectoryError.unknownSession(id)
        }
    }

    /// The agent id of the start, which the launcher does not know.
    private static let unknownAgentID = "no-such-agent"

    /// The start request of each test.
    private static let request = SessionStartRequest(
        agentID: unknownAgentID, firstMessage: "hello", origin: .client)

    @Test("a host's launcher gets the start of the router's directory")
    func aHostLauncherGetsTheStart() async throws {
        let directory = Router(pool: ModelPool()).sessionDirectory
        await directory.use(launcher: AgentlessLauncher())

        await #expect(throws: SessionDirectoryError.unknownAgent(Self.unknownAgentID, nearNames: [])) {
            try await directory.start(Self.request)
        }
        await directory.shutdown()
    }

    @Test("after shutdown, a start throws noLauncher")
    func afterShutdownAStartThrowsNoLauncher() async throws {
        let directory = Router(pool: ModelPool()).sessionDirectory
        await directory.use(launcher: AgentlessLauncher())

        await directory.shutdown()

        await #expect(throws: SessionDirectoryError.noLauncher) {
            try await directory.start(Self.request)
        }
    }
}
