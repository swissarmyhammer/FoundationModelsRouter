import Foundation
import FoundationModels
import InMemoryTracing
import Testing
import Tracing

@testable import FoundationModelsRouter

/// Exercises card ^m80y2d4: every session opens one span as it comes into
/// existence.
///
/// The span says which shape made the session through its own `session.origin`
/// attribute, so one query can separate the cost of a restore from the cost of
/// a vend.
///
/// The rule that no attribute carries the caller's own content lives in
/// ``TelemetryContentSafetyTests``, which names no span and therefore already
/// measures this one.
///
/// Everything runs over the stub loader and stub backends, so the suite needs
/// no network, no GPU and no bootstrapped tracing backend.
@Suite("Session creation tracing")
struct SessionCreationTracingTests {
    /// The span name every session opens as it is made.
    private static let spanName = "FoundationModelsRouter.session"

    /// The suite's temp-directory prefix, so a leaked directory is
    /// attributable.
    private static let tempDirPrefix = "SessionCreationTracingTests"

    /// The model reference the standard slot resolves to, which a session span
    /// names.
    private static let standardModelRef = "org/std-a"

    // MARK: - Fixtures

    /// A ``LoadedLLMContainer`` whose sessions answer with the stub backend's
    /// canned line.
    private struct AnsweringStubContainer: PlainTranscriptStubContainer {
        /// Builds a backend over a fresh stub session.
        ///
        /// - Parameter instructions: The session's system instructions, or `nil`.
        /// - Returns: The backend the vended session drives for its lifetime.
        func makeSession(instructions: String?) -> any LanguageModelSessionBackend {
            StubSessionBackend(instructions: instructions)
        }
    }

    /// Resolves a profile over the stub hardware and the stub loader, wired to
    /// report every span to `tracer`.
    ///
    /// - Parameters:
    ///   - workspace: The temp directories the router works under.
    ///   - tracer: The tracer every vended handle carries.
    /// - Returns: The resolved profile.
    /// - Throws: Whatever profile resolution throws.
    private static func makeProfile(
        workspace: TestDirectories,
        tracer: any Tracer
    ) async throws -> LanguageModelProfile {
        let router = RouterTestFixtures.makeRouter(
            cacheDir: workspace.cacheDir,
            recordingsDir: workspace.recordingsDir,
            recorder: JSONLRecorder(directory: workspace.recordingsDir),
            loader: StubModelLoader(
                container: AnsweringStubContainer(), dimension: RouterTestFixtures.stubDimension),
            tracer: tracer
        )
        return try await router.resolve(
            profile: RouterTestFixtures.profile(), reporting: ResolutionProgress())
    }

    /// The session spans `tracer` holds that have finished, in the order they
    /// finished.
    ///
    /// Filtered by name rather than counted over the whole tracer: a session
    /// made inside a submission shares its tracer with the spans that the
    /// submission opens.
    ///
    /// - Parameter tracer: The tracer the driven work reported to.
    /// - Returns: Every finished session span.
    private static func finishedSessionSpans(
        reportedTo tracer: InMemoryTracer
    ) -> [FinishedInMemorySpan] {
        tracer.finishedSpans.filter { $0.operationName == spanName }
    }

    // MARK: - A session vended over a resident model

    @Test("a vended session opens one internal span naming the router, the model and itself")
    func vendedSessionOpensOneSpanNamingItself() async throws {
        let workspace = TestDirectories(prefix: Self.tempDirPrefix)
        defer { workspace.remove() }

        let tracer = InMemoryTracer()
        let profile = try await Self.makeProfile(workspace: workspace, tracer: tracer)
        let session = profile.standard.makeSession()
        defer { await session.close() }

        let spans = Self.finishedSessionSpans(reportedTo: tracer)
        try #require(spans.count == 1)
        let span = try #require(spans.first)
        #expect(span.operationName == Self.spanName)
        #expect(span.kind == .internal)
        #expect(span.attributes.get("router.id") == .string(session.routerId.description))
        #expect(span.attributes.get("model.ref") == .string(Self.standardModelRef))
        #expect(span.attributes.get("session.id") == .string(session.id.description))
        #expect(span.attributes.get("session.origin") == .string("new"))
        // A vended root came from no session, so it names no parent.
        #expect(span.attributes.get("session.parent_id") == nil)
        #expect(span.errors.isEmpty)
    }
}
