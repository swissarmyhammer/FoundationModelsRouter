import Foundation
import Testing

@testable import FoundationModelsRouter

/// Exercises the embedding prefix table and the query and document embed
/// calls of ``RoutedEmbedder``.
///
/// Each test builds a ``RoutedEmbedder`` over a ``RecordingEmbeddingContainer``
/// and reads the texts that the container received. No network and no GPU.
@Suite("Embedding prefixes")
struct EmbeddingPrefixTests {
    /// The repo that the prefix table knows.
    private static let knownRepo: ModelRef = "erjigit17/embeddinggemma-300m-ane-coreml"

    /// A repo that the prefix table does not know.
    private static let unknownRepo: ModelRef = "org/emb-a"

    /// Builds an embedder over a fresh recording container.
    private static func makeEmbedder(
        chosen: ModelRef
    ) -> (embedder: RoutedEmbedder, container: RecordingEmbeddingContainer) {
        let container = RecordingEmbeddingContainer()
        let embedder = HandBuiltProfileFixtures.makeEmbedder(
            chosen: chosen,
            container: container,
            routerId: ULID()
        )
        return (embedder, container)
    }

    @Test("embed(queries:) puts the query prefix in front of each text")
    func queriesGetQueryPrefix() async throws {
        let (embedder, container) = Self.makeEmbedder(chosen: Self.knownRepo)
        _ = try await embedder.embed(queries: ["cats", "dogs"])
        #expect(
            container.received == [
                ["task: search result | query: cats", "task: search result | query: dogs"]
            ])
    }

    @Test("embed(documents:) puts the document prefix in front of each text")
    func documentsGetDocumentPrefix() async throws {
        let (embedder, container) = Self.makeEmbedder(chosen: Self.knownRepo)
        _ = try await embedder.embed(documents: ["cats", "dogs"])
        #expect(container.received == [["title: none | text: cats", "title: none | text: dogs"]])
    }

    @Test("embed(texts:) adds no prefix, also for a model in the table")
    func textsGetNoPrefix() async throws {
        let (embedder, container) = Self.makeEmbedder(chosen: Self.knownRepo)
        _ = try await embedder.embed(texts: ["cats"])
        #expect(container.received == [["cats"]])
    }

    @Test("a model with no table entry gets no prefix on a query")
    func unknownModelQueryUnchanged() async throws {
        let (embedder, container) = Self.makeEmbedder(chosen: Self.unknownRepo)
        _ = try await embedder.embed(queries: ["cats"])
        #expect(container.received == [["cats"]])
    }

    @Test("a model with no table entry gets no prefix on a document")
    func unknownModelDocumentUnchanged() async throws {
        let (embedder, container) = Self.makeEmbedder(chosen: Self.unknownRepo)
        _ = try await embedder.embed(documents: ["cats"])
        #expect(container.received == [["cats"]])
    }

    @Test("a query call returns one vector per text")
    func queryReturnsVectors() async throws {
        let (embedder, _) = Self.makeEmbedder(chosen: Self.knownRepo)
        let vectors = try await embedder.embed(queries: ["a", "b", "c"])
        #expect(vectors.count == 3)
    }

    @Test("a revision on the model ref does not hide the table entry")
    func revisionKeepsEntry() async throws {
        let (embedder, container) = Self.makeEmbedder(
            chosen: "erjigit17/embeddinggemma-300m-ane-coreml@main")
        _ = try await embedder.embed(documents: ["cats"])
        #expect(container.received == [["title: none | text: cats"]])
    }
}
