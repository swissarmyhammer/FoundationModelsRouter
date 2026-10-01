import Foundation
import FoundationModelsRouterTestSupport
import InMemoryTracing
import Testing
import Tracing

@testable import FoundationModelsRouter

/// Exercises card ^026kke5: every ``RoutedModel/embed(texts:)`` call opens one
/// OpenTelemetry span through `swift-distributed-tracing`.
///
/// Card ^p3x0bbb took the `.embedding` transcript event away, so an embed call
/// writes nothing to the transcript. A span is the replacement signal, and
/// this suite holds its whole contract: the operation name, the span kind, the
/// four attributes, the error status and the error type on a failure, and the
/// rule that no attribute carries an input text.
///
/// The router is built over stubs — a stub ``ModelLoader``, a stub embedding
/// container and an `InMemoryTracer` — so the suite needs no network, no GPU
/// and no bootstrapped tracing backend.
@Suite("Embed tracing")
struct EmbedTracingTests {
    /// The span name every embed call opens.
    private static let spanName = "FoundationModelsRouter.embed"

    /// The failure that the ``ThrowingEmbeddingContainer`` of the failing
    /// test throws.
    private enum EmbedFailure: Error {
        case refused
    }

    /// The embed spans `tracer` holds that have finished, in the order they
    /// finished.
    ///
    /// Filtered by name rather than counted over the whole tracer: a test that
    /// resolves its profile through the same tracer also gets that resolve's
    /// own span, with one load span under it for each slot it loaded.
    ///
    /// - Parameter tracer: The tracer the driven work reported to.
    /// - Returns: Every finished embed span.
    private static func finishedEmbedSpans(
        reportedTo tracer: InMemoryTracer
    ) -> [FinishedInMemorySpan] {
        tracer.finishedSpans.filter { $0.operationName == spanName }
    }

    /// Resolves the shared test profile over a stub loader and the supplied
    /// tracer.
    ///
    /// - Parameters:
    ///   - tracer: The tracer every handle of the resolved profile carries.
    ///   - cacheDir: The router's per-test cache directory.
    /// - Returns: The router and the profile resolved through it.
    private static func resolveProfile(
        tracer: any Tracer,
        cacheDir: URL
    ) async throws -> (router: Router, profile: LanguageModelProfile) {
        let router = RouterTestFixtures.makeRouter(
            cacheDir: cacheDir,
            loader: StubModelLoader(
                container: UndrivenLanguageModelContainer(),
                dimension: RouterTestFixtures.stubDimension
            ),
            tracer: tracer
        )
        let profile = try await router.resolve(
            profile: RouterTestFixtures.profile(), reporting: ResolutionProgress())
        return (router, profile)
    }

    @Test("one embed call emits one client span carrying the four documented attributes")
    func embedEmitsOneClientSpanWithAttributes() async throws {
        let dir = RouterTestFixtures.makeTempDir(prefix: "EmbedTracingTests")
        defer { try? FileManager.default.removeItem(at: dir) }

        let tracer = InMemoryTracer()
        let (router, profile) = try await Self.resolveProfile(tracer: tracer, cacheDir: dir)

        let vectors = try await profile.embedding.embed(texts: ["a", "b"])
        #expect(vectors.count == 2)

        let spans = Self.finishedEmbedSpans(reportedTo: tracer)
        try #require(spans.count == 1)
        let span = try #require(spans.first)
        #expect(span.operationName == Self.spanName)
        #expect(span.kind == .client)
        #expect(span.attributes.get("router.id") == .string(router.id.description))
        #expect(span.attributes.get("model.ref") == .string(profile.embedding.chosen.stringValue))
        #expect(span.attributes.get("embedding.input_count") == .int64(2))
        #expect(
            span.attributes.get("embedding.dimension")
                == .int64(Int64(RouterTestFixtures.stubDimension)))
        #expect(span.errors.isEmpty)
    }

    @Test("a failing embed rethrows the container's error and records its type on the one span")
    func embedFailureIsRecordedOnTheSpan() async throws {
        let dir = RouterTestFixtures.makeTempDir(prefix: "EmbedTracingTests")
        defer { try? FileManager.default.removeItem(at: dir) }

        let tracer = InMemoryTracer()
        let router = RouterTestFixtures.makeRouter(
            cacheDir: dir,
            loader: StubModelLoader(
                container: UndrivenLanguageModelContainer(),
                dimension: RouterTestFixtures.stubDimension
            ),
            tracer: tracer
        )
        let embedder = HandBuiltProfileFixtures.makeEmbedder(
            chosen: "org/emb-a",
            container: ThrowingEmbeddingContainer(
                dimension: RouterTestFixtures.stubDimension, failure: EmbedFailure.refused),
            routerId: router.id,
            tracer: tracer
        )

        await #expect(throws: EmbedFailure.refused) {
            _ = try await embedder.embed(texts: ["a"])
        }

        let spans = Self.finishedEmbedSpans(reportedTo: tracer)
        try #require(spans.count == 1)
        #expect(spans[0].failureType == "\(EmbedFailure.self)")
    }

    @Test("no span attribute carries any input text")
    func embedAttributesNeverCarryInputText() async throws {
        let dir = RouterTestFixtures.makeTempDir(prefix: "EmbedTracingTests")
        defer { try? FileManager.default.removeItem(at: dir) }

        let needle = "needle-7f3a"
        let tracer = InMemoryTracer()
        let (_, profile) = try await Self.resolveProfile(tracer: tracer, cacheDir: dir)

        _ = try await profile.embedding.embed(texts: [needle])

        let span = try #require(Self.finishedEmbedSpans(reportedTo: tracer).first)
        var rendered: [String] = []
        span.attributes.forEach { _, value in rendered.append(String(describing: value)) }
        #expect(rendered.allSatisfy { !$0.contains(needle) })
        #expect(!rendered.isEmpty)
    }
}
