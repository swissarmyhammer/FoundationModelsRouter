import Foundation
import Tracing

@testable import FoundationModelsRouter

/// A routed session over a ``RejectingLanguageModel``, with the log that its
/// model writes into and the directory that the router cached into.
///
/// The session crosses the production backend and a real
/// `LanguageModelSession`, so a rejected tool call goes through the real
/// retry of the router, and no GPU is in the loop.
struct RejectingSessionFixture {
    /// The vended session a test drives its answer on.
    let session: RoutedSession

    /// The log of the transcript of each generation call.
    let log: RejectingModelLog

    /// The temp directory the router cached into, which the caller must remove.
    let directory: URL

    /// Builds a router and a session over a model that rejects its first
    /// `rejectionCount` generation calls.
    ///
    /// - Parameters:
    ///   - rejectionCount: How many calls end with a rejected tool call.
    ///   - tempDirPrefix: The calling suite's name, so a leaked temp directory
    ///     is attributable.
    ///   - tracer: The tracer every handle of the resolved profile carries, or
    ///     `nil` (the default) to read `InstrumentationSystem.tracer` at call
    ///     time.
    /// - Returns: The session, its log, and the temp directory.
    /// - Throws: Whatever profile resolution throws.
    static func make(
        rejectionCount: Int,
        tempDirPrefix: String,
        tracer: (any Tracer)? = nil
    ) async throws -> RejectingSessionFixture {
        let directory = RouterTestFixtures.makeTempDir(prefix: tempDirPrefix)
        let log = RejectingModelLog()
        let container = LiveBackendContainer(
            model: RejectingLanguageModel(rejectionCount: rejectionCount, log: log)
        )
        let router = RouterTestFixtures.makeRouter(
            cacheDir: directory,
            loader: StubModelLoader(container: container, dimension: RouterTestFixtures.stubDimension),
            tracer: tracer
        )
        let profile = try await router.resolve(
            profile: RouterTestFixtures.profile(), reporting: ResolutionProgress()
        )
        return RejectingSessionFixture(session: profile.standard.makeSession(), log: log, directory: directory)
    }
}
