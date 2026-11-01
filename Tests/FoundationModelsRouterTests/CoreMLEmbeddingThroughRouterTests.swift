import Foundation
import FoundationModelsExtras
import FoundationModelsRouterTestSupport
import InMemoryTracing
import Testing

@testable import FoundationModelsRouter

/// Proves that an embedding container of the Core ML loader works through the
/// router with no change to the router's embed surface.
///
/// The container of the Core ML loader is internal to the Extras package, so
/// these tests use a stub that conforms to the same ``PooledEmbedding``
/// protocol, as the Core ML container does. The stub is a type that the router
/// never saw. No test loads a model, and no test uses the network.
@Suite("Core ML embedding through the router")
struct CoreMLEmbeddingThroughRouterTests {
    /// The model of the stub.
    private static let ref: ModelRef = "org/coreml-embedder"

    /// The length of each vector of the stub.
    private static let dimension = 3

    /// The vector that the stub gives for each text.
    private static let vector: [Float] = [0.25, 0.5, 0.75]

    /// The name of the span of each embed call.
    private static let spanName = "FoundationModelsRouter.embed"

    /// A stand-in for the container of the Core ML loader: it conforms to the
    /// Extras embed protocol only.
    private struct StubCoreMLEmbedding: PooledEmbedding {
        func embed(texts: [String]) async throws -> [[Float]] {
            texts.map { _ in CoreMLEmbeddingThroughRouterTests.vector }
        }
    }

    /// The key that the stub loads for.
    private static var key: ModelPoolKey { ModelPoolKey(ref: ref, role: .embedding) }

    /// Makes the embedding handle of the stub, as the router makes it for a
    /// container that a model loader returned.
    private static func makeEmbedder(tracer: InMemoryTracer) throws -> RoutedEmbedder {
        let container = try LoadedPooledEmbedding(container: StubCoreMLEmbedding(), of: key)
        return HandBuiltProfileFixtures.makeEmbedder(
            chosen: ref, container: container, routerId: ULID(), tracer: tracer)
    }

    @Test("the container of the Core ML loader gives one vector for each text through the router")
    func embedsEachText() async throws {
        let embedder = try Self.makeEmbedder(tracer: InMemoryTracer())

        let vectors = try await embedder.embed(texts: ["a", "b"])

        #expect(vectors == [Self.vector, Self.vector])
    }

    @Test("an embed through a Core ML container records the model.ref attribute on its span")
    func spanCarriesModelRef() async throws {
        let tracer = InMemoryTracer()
        let embedder = try Self.makeEmbedder(tracer: tracer)

        _ = try await embedder.embed(texts: ["a"])

        let span = try #require(tracer.finishedSpans.first { $0.operationName == Self.spanName })
        #expect(span.attributes.get("model.ref") == .string(Self.ref.stringValue))
    }

    @Test("an embed through a Core ML container records the embedding.dimension attribute on its span")
    func spanCarriesDimension() async throws {
        let tracer = InMemoryTracer()
        let embedder = try Self.makeEmbedder(tracer: tracer)

        _ = try await embedder.embed(texts: ["a"])

        let span = try #require(tracer.finishedSpans.first { $0.operationName == Self.spanName })
        #expect(span.attributes.get("embedding.dimension") == .int64(Int64(Self.dimension)))
    }

    @Test("a container that is no embedding is refused with the type of the container")
    func refusesAContainerThatIsNoEmbedding() {
        struct NotAnEmbedding: Sendable {}

        #expect(
            throws: PooledEmbedderError.notAnEmbedding(key: Self.key, containerType: "NotAnEmbedding")
        ) {
            try LoadedPooledEmbedding(container: NotAnEmbedding(), of: Self.key)
        }
    }
}
