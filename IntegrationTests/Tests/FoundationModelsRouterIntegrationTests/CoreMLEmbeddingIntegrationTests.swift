import Foundation
import FoundationModelsExtras
import FoundationModelsRouterTestSupport
import Testing

@testable import FoundationModelsRouter

/// Gated real-model coverage of a Core ML embedding model through the router:
/// the router sizes the repository as a Core ML embedding model from the real
/// Hub listing, and the ``LiveModelLoader`` downloads it, loads it on the
/// Apple Neural Engine and embeds with it.
///
/// The model is `erjigit17/embeddinggemma-300m-ane-coreml`. The first load of
/// a commit downloads about 300 MB and compiles the package, which takes some
/// time. The Hub client reuses the download on a later run.
///
/// The suite lives in the nested `IntegrationTests/` package, so a root
/// `swift test` cannot see it. Run it with
/// `swift test --package-path IntegrationTests --filter CoreMLEmbeddingIntegrationTests`.
@Suite(
    "Gated real-model coverage: a Core ML embedding model through the router",
    .serialized,
    .exclusiveRealModel
)
struct CoreMLEmbeddingIntegrationTests {
    /// The Core ML embedding model of the suite.
    private static let ref: ModelRef = "erjigit17/embeddinggemma-300m-ane-coreml"

    /// A query in the form that the model expects.
    private static let query = "task: search result | query: save my work"

    /// A document in the form that the model expects.
    private static let document = "title: none | text: Press Command-S to save the file that you are editing."

    @Test("the real Hub listing of the repository sizes it as a Core ML embedding model")
    func hubListingSizesTheRepositoryAsCoreML() async throws {
        let cacheDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CoreMLEmbeddingIntegrationTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: cacheDir) }
        let reader = RepoMetadataReader(source: HuggingFaceMetadataSource(), cacheDir: cacheDir)

        let metadata = try await reader.metadata(for: Self.ref)

        #expect(metadata.isCoreMLEmbedding)
    }

    @Test("the live loader loads the Core ML model and gives one vector for each text")
    func liveLoaderEmbedsOnTheNeuralEngine() async throws {
        let loader = LiveModelLoader()

        let embedder = try await loader.loadEmbedder(ref: Self.ref, slot: .embedding, reporting: { _ in })
        let vectors = try await embedder.embed(texts: [Self.query, Self.document])
        await loader.evict(container: embedder)

        try #require(vectors.count == 2)
        #expect(vectors[0].count > 0)
        #expect(vectors[0].count == vectors[1].count)
        #expect(vectors[0] != vectors[1])
    }
}
