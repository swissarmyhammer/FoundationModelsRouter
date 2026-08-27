import Foundation
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
/// four attributes, the error record on a failure, and the rule that no
/// attribute carries an input text.
///
/// The router is built over stubs — a stub ``ModelLoader``, a stub embedding
/// container and an `InMemoryTracer` — so the suite needs no network, no GPU
/// and no bootstrapped tracing backend.
@Suite("Embed tracing")
struct EmbedTracingTests {
    /// The span name every embed call opens.
    private static let spanName = "FoundationModelsRouter.embed"

    /// A ``LoadedEmbeddingContainer`` stub whose every embed call fails, so a
    /// test can read what the span records for a failure.
    ///
    /// ``HandBuiltProfileFixtures/makeProfile(definitionName:chosen:container:router:)``
    /// always wraps a ``StubEmbeddingContainer``, which cannot fail, so the
    /// failing test builds its ``RoutedEmbedder`` by hand over this container
    /// instead.
    private struct ThrowingEmbeddingContainer: LoadedEmbeddingContainer {
        /// The failure every ``embed(texts:)`` call raises.
        enum Failure: Error {
            case refused
        }

        /// The length the stub reports; no vector is ever produced.
        let dimension: Int

        /// Raises ``Failure/refused`` instead of embedding.
        ///
        /// - Parameter texts: The strings the caller asked to embed, ignored.
        /// - Returns: Never returns.
        /// - Throws: ``Failure/refused``, always.
        func embed(texts: [String]) async throws -> [[Float]] {
            throw Failure.refused
        }
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

        let spans = tracer.finishedSpans
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

    @Test("a failing embed rethrows the container's error and records it on the one span")
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
        let chosen: ModelRef = "org/emb-a"
        let embedder = RoutedEmbedder(
            slot: .embedding,
            chosen: chosen,
            footprintBytes: 0,
            resolution: SlotResolution(
                slot: .embedding, remainingBudgetBytes: 0, chosen: chosen, considered: []),
            container: ThrowingEmbeddingContainer(dimension: RouterTestFixtures.stubDimension),
            routerId: router.id,
            recorder: InMemoryRecorder(),
            gates: ResidentModelGates(maxConcurrentForks: defaultMaxConcurrentForks),
            tracer: tracer
        )

        await #expect(throws: ThrowingEmbeddingContainer.Failure.self) {
            _ = try await embedder.embed(texts: ["a"])
        }

        let spans = tracer.finishedSpans
        try #require(spans.count == 1)
        #expect(spans[0].errors.count == 1)
    }

    @Test("no span attribute carries any input text")
    func embedAttributesNeverCarryInputText() async throws {
        let dir = RouterTestFixtures.makeTempDir(prefix: "EmbedTracingTests")
        defer { try? FileManager.default.removeItem(at: dir) }

        let needle = "needle-7f3a"
        let tracer = InMemoryTracer()
        let (_, profile) = try await Self.resolveProfile(tracer: tracer, cacheDir: dir)

        _ = try await profile.embedding.embed(texts: [needle])

        let span = try #require(tracer.finishedSpans.first)
        var rendered: [String] = []
        span.attributes.forEach { _, value in rendered.append(String(describing: value)) }
        #expect(rendered.allSatisfy { !$0.contains(needle) })
        #expect(!rendered.isEmpty)
    }
}
