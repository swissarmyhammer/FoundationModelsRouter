import Foundation
import FoundationModels
import FoundationModelsExtras
import Testing

import FoundationModelsRouter
import FoundationModelsRouterTestSupport

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
    /// `unknownAgent` (``StartRefusingLauncher``), so a start that reaches
    /// it shows the directory used it.
    struct AgentlessLauncher: StartRefusingLauncher {}

    /// A host launcher that builds each fork with its own tool surface
    /// (D205), through the public build of `SessionLaunchForkRequest`. It
    /// refuses each start and each restore (``StartRefusingLauncher``).
    struct ForkingHostLauncher: StartRefusingLauncher {
        /// Builds the fork of `request` with no tool.
        ///
        /// - Parameter request: The fork request of the directory.
        /// - Returns: The fork.
        /// - Throws: The error of the build.
        func forkSession(_ request: SessionLaunchForkRequest) async throws -> any RoutedSession {
            try await request.makeFork(tools: [])
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

    @Test("a host's fork launcher does not run for a source that the directory does not know")
    func aHostForkLauncherDoesNotRunForAnUnknownSource() async throws {
        let directory = Router(pool: ModelPool()).sessionDirectory
        await directory.use(launcher: ForkingHostLauncher())
        let unknown = ULID.generate()

        await #expect(throws: SessionDirectoryError.unknownSession(unknown)) {
            try await directory.fork(
                SessionForkRequest(sourceID: unknown, cut: .lastCompletedTurn, forker: .user(clientID: "host")))
        }
        await directory.shutdown()
    }

    /// A host launcher that gives the model of an import over the public
    /// type of the port (D209 (h)). It has no model to give, so it throws
    /// `unknownAgent` for the agent of the request.
    struct ImportingHostLauncher: StartRefusingLauncher {
        /// Throws `unknownAgent` for the agent of `request`.
        ///
        /// - Parameter request: The import request of the directory.
        /// - Returns: Nothing.
        /// - Throws: `SessionDirectoryError.unknownAgent` for the agent of
        ///   `request`.
        func importTarget(for request: SessionImportRequest) async throws -> SessionImportTarget {
            throw SessionDirectoryError.unknownAgent(request.agentID ?? unknownAgentID, nearNames: [])
        }
    }

    /// The import request of each import test.
    private static let importRequest = SessionImportRequest(
        agentID: unknownAgentID, workingDirectory: URL(fileURLWithPath: "/tmp", isDirectory: true),
        title: "Imported", provenance: SessionImportProvenance(
            agent: "codex", sourceID: "source-1", sourcePath: "/tmp/source-1.jsonl",
            importedAt: Date(timeIntervalSince1970: 0)))

    @Test("a host's launcher gives the model of an import of the router's directory")
    func aHostLauncherGetsTheImport() async throws {
        let directory = Router(pool: ModelPool()).sessionDirectory
        await directory.use(launcher: ImportingHostLauncher())

        await #expect(throws: SessionDirectoryError.unknownAgent(Self.unknownAgentID, nearNames: [])) {
            try await directory.importSession(Self.importRequest, transcript: Transcript())
        }
        await directory.shutdown()
    }

    @Test("a host's launcher with no import operation refuses the import")
    func aHostLauncherWithNoImportOperationRefusesTheImport() async throws {
        let directory = Router(pool: ModelPool()).sessionDirectory
        await directory.use(launcher: AgentlessLauncher())

        await #expect(throws: SessionDirectoryError.importUnsupported) {
            try await directory.importSession(Self.importRequest, transcript: Transcript())
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
