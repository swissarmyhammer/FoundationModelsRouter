import Foundation
import FoundationModelsRouterTestSupport
import InMemoryTracing
import Tracing

@testable import FoundationModelsRouter

/// A routed session over one shared ``StubSessionBackend``, with the backend,
/// the resolved profile, the router that resolved it, and the directory the
/// router cached into.
///
/// A test ends the fixture with ``SessionDirectoryFixture/end(opening:)``.
struct StubBackendSessionFixture: SessionDirectoryFixture {
    /// The session the test drives its answers on.
    let session: any RoutedSession

    /// The backend that session runs on, so a test can make a later
    /// submission fail.
    let backend: StubSessionBackend

    /// The resolved profile, kept alive while the session runs, so a test can
    /// name the model the answer ran on.
    let profile: LanguageModelProfile

    /// The router that resolved the profile, so a test can name its
    /// recording root.
    let router: Router

    /// The temp directory the router cached into.
    /// ``SessionDirectoryFixture/end(opening:)`` removes it.
    let directory: URL

    /// Builds a router, a resolved profile and a session over one shared
    /// ``StubSessionBackend``.
    ///
    /// - Parameters:
    ///   - tempDirPrefix: The calling suite's name, so a leaked temp directory
    ///     is attributable.
    ///   - tracer: The tracer every handle of the resolved profile carries, or
    ///     `nil` to read `InstrumentationSystem.tracer` at call time.
    ///   - responseText: The canned text the backend answers every submission
    ///     with.
    ///   - usageIncrement: The token counts the backend meters on each
    ///     successful submission, or `nil` to report no usage at all.
    /// - Returns: The fixture.
    /// - Throws: Whatever profile resolution throws. Before it throws, it
    ///   removes the temp directory (rule T1).
    static func make(
        tempDirPrefix: String,
        tracer: (any Tracer)?,
        responseText: String,
        usageIncrement: (input: Int, output: Int)?
    ) async throws -> StubBackendSessionFixture {
        let directory = RouterTestFixtures.makeTempDir(prefix: tempDirPrefix)
        let backend = StubSessionBackend(responseText: responseText, usageIncrement: usageIncrement)
        let router = RouterTestFixtures.makeRouter(
            cacheDir: directory,
            loader: StubModelLoader(
                container: SharedBackendContainer(backend: backend),
                dimension: RouterTestFixtures.stubDimension
            ),
            tracer: tracer
        )
        let profile = try await RouterTestFixtures.removingDirectoryOnThrow(directory) {
            try await router.resolve(profile: RouterTestFixtures.profile(), reporting: ResolutionProgress())
        }
        return StubBackendSessionFixture(
            session: profile.standard.makeSession(),
            backend: backend,
            profile: profile,
            router: router,
            directory: directory)
    }
}

extension InMemoryTracer {
    /// The finished submission spans this tracer holds, in the order they
    /// finished.
    ///
    /// Filtered by name rather than counted over the whole tracer: a fixture's
    /// own ``Router/resolve(profile:reporting:)`` reports to the same tracer,
    /// and it opens a resolve span with one load span under it for each slot
    /// it loads.
    var finishedSubmissionSpans: [FinishedInMemorySpan] {
        finishedSpans.filter { $0.operationName == RouterTelemetry.SpanName.submission }
    }

    /// The finished submission spans whose cause is `cause`, in the order
    /// they finished.
    ///
    /// - Parameter cause: The cause of the submissions.
    /// - Returns: Those spans.
    func finishedSubmissionSpans(causedBy cause: SubmissionStart.Cause) -> [FinishedInMemorySpan] {
        finishedSubmissionSpans.filter {
            $0.attributes.get(RouterTelemetry.AttributeKey.submissionCause) == .string(cause.rawValue)
        }
    }
}
