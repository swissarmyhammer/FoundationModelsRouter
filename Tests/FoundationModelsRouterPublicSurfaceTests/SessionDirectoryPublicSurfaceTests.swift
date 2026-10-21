import Foundation
import FoundationModelsExtras
import Testing

import FoundationModelsRouter

/// Holds ``Router/sessionDirectory`` to the access level a consumer outside
/// this package needs (ROUTER-3). A host reads the router's directory as the
/// Extras `SessionDirectory` port and queries it.
///
/// The import is plain, with no `@testable`, so a member that loses `public`
/// stops this file from compiling before a single test runs.
@Suite("Router.sessionDirectory over a plain import")
struct SessionDirectoryPublicSurfaceTests {
    /// The port a consumer such as the `sessions` tool holds.
    private static func port(of router: Router) -> any SessionDirectory {
        router.sessionDirectory
    }

    @Test("a consumer queries the router's directory as a SessionDirectory")
    func aConsumerQueriesTheDirectoryAsThePort() async throws {
        let router = Router(pool: ModelPool())
        let directory = Self.port(of: router)

        let sessions = try await directory.sessions(matching: SessionQuery())
        let summary = try await directory.summary(of: ULID.generate())

        #expect(sessions.isEmpty)
        #expect(summary == nil)
    }
}
