import Foundation
import FoundationModels
import FoundationModelsRouter

/// The stubs a test target that imports the library with no `@testable`
/// gives a ``Router``, so that a resolve runs with no network, no download
/// and no GPU.
///
/// Each stub uses the public protocols of the library only. The public
/// surface suites share them, so the stubs have one location.
public enum PlainImportResolveStubs {
    /// The canned `config.json` payload behind ``rawMetadata``: a tiny, valid
    /// model config that the resolver can size.
    private static let configJSON = Data(
        """
        {
            "num_hidden_layers": 2,
            "max_position_embeddings": 8192,
            "num_attention_heads": 8,
            "num_key_value_heads": 2,
            "head_dim": 16,
            "hidden_size": 128
        }
        """.utf8)

    /// The canned file tree of the repository behind ``rawMetadata``: one
    /// weights file that the resolver can size.
    private static let treeJSON = Data(
        """
        [
            {"type": "file", "path": "model.safetensors", "size": 10000000}
        ]
        """.utf8)

    /// The canned metadata of the repository that ``CannedMetadataSource``
    /// gives for each candidate.
    public static var rawMetadata: RawRepoMetadata {
        RawRepoMetadata(configJSON: configJSON, treeJSON: treeJSON)
    }
}

/// A ``MachineProbe`` that reports fixed hardware facts.
public struct FixedMachineProbe: MachineProbe {
    /// The chip name that the probe reports.
    public let chip: String

    /// The physical RAM that the probe reports, in bytes.
    public let totalRAM: Int64

    /// The GPU working set that the probe reports, in bytes.
    public let recommendedMaxWorkingSetSize: Int64

    /// Makes a probe.
    ///
    /// - Parameters:
    ///   - chip: The chip name.
    ///   - totalRAM: The physical RAM, in bytes.
    ///   - recommendedMaxWorkingSetSize: The GPU working set, in bytes.
    public init(chip: String, totalRAM: Int64, recommendedMaxWorkingSetSize: Int64) {
        self.chip = chip
        self.totalRAM = totalRAM
        self.recommendedMaxWorkingSetSize = recommendedMaxWorkingSetSize
    }
}

/// A ``MetadataSource`` that answers each fetch with one canned payload.
public struct CannedMetadataSource: MetadataSource {
    /// The payload that each fetch returns.
    public let raw: RawRepoMetadata

    /// Makes a source.
    ///
    /// - Parameter raw: The payload that each fetch returns.
    public init(raw: RawRepoMetadata) {
        self.raw = raw
    }

    /// Returns ``raw`` for each repository and each revision.
    ///
    /// - Parameters:
    ///   - repo: The repository. The stub does not read it.
    ///   - revision: The revision. The stub does not read it.
    /// - Returns: ``raw``.
    public func fetchRawMetadata(repo: String, revision: String?) async throws -> RawRepoMetadata {
        raw
    }
}

/// A ``LoadedEmbeddingContainer`` that embeds each text as a zero vector of
/// the given dimension.
public struct ZeroEmbeddingContainer: LoadedEmbeddingContainer {
    /// The length of each vector.
    public let dimension: Int

    /// Makes a container.
    ///
    /// - Parameter dimension: The length of each vector.
    public init(dimension: Int) {
        self.dimension = dimension
    }

    /// Embeds each text as a zero vector.
    ///
    /// - Parameter texts: The texts to embed.
    /// - Returns: One zero vector of ``dimension`` for each text.
    public func embed(texts: [String]) async throws -> [[Float]] {
        texts.map { _ in [Float](repeating: 0, count: dimension) }
    }
}

/// A ``LoadedLLMContainer`` that a resolve can hold resident and that makes
/// no session.
///
/// A test that uses it only resolves, or only writes and reads recordings.
/// A request for a session is a programmer error in such a test, and each
/// factory says so instead of making a backend that the test cannot measure.
public struct ResolveOnlyContainer: LoadedLLMContainer {
    /// The message each factory stops with.
    private static let noSessionMessage =
        "ResolveOnlyContainer makes no session; the test that uses it never asks for one"

    /// The counter of this container: one token per `Character`.
    public let tokenCounter: any TokenCounter = CharacterTokenCounter()

    /// Makes a container.
    public init() {}

    /// Stops the test: this container makes no session.
    ///
    /// - Parameter instructions: The instructions. The container does not
    ///   read them.
    /// - Returns: Never.
    public func makeSession(instructions: String?) -> any LanguageModelSessionBackend {
        preconditionFailure(Self.noSessionMessage)
    }

    /// Stops the test: this container makes no session.
    ///
    /// - Parameter transcript: The transcript. The container does not read
    ///   it.
    /// - Returns: Never.
    public func makeSession(transcript: Transcript) -> any LanguageModelSessionBackend {
        preconditionFailure(Self.noSessionMessage)
    }
}

/// A ``ModelLoader`` that gives a ``ResolveOnlyContainer`` for each
/// generation slot and a ``ZeroEmbeddingContainer`` for the embedding slot,
/// and reports one known download observation for each model that it loads.
public struct ReportingLoader: ModelLoader {
    /// The observation that the loader reports for each generation model.
    public let generationDownload: DownloadProgress

    /// The observation that the loader reports for the embedding model.
    public let embeddingDownload: DownloadProgress

    /// The dimension of the embedder that the loader gives.
    public let dimension: Int

    /// Makes a loader.
    ///
    /// - Parameters:
    ///   - generationDownload: The observation for each generation model.
    ///   - embeddingDownload: The observation for the embedding model.
    ///   - dimension: The dimension of the embedder.
    public init(generationDownload: DownloadProgress, embeddingDownload: DownloadProgress, dimension: Int) {
        self.generationDownload = generationDownload
        self.embeddingDownload = embeddingDownload
        self.dimension = dimension
    }

    /// Reports ``generationDownload`` and gives a ``ResolveOnlyContainer``.
    ///
    /// - Parameters:
    ///   - ref: The model. The loader does not read it.
    ///   - slot: The slot. The loader does not read it.
    ///   - context: The context. The loader does not read it.
    ///   - kvCache: The cache quantization. The loader does not read it.
    ///   - reporting: The sink of the download observation.
    /// - Returns: A ``ResolveOnlyContainer``.
    public func loadLLM(
        ref: ModelRef,
        slot: ModelSlot,
        context: Int,
        kvCache: KVCacheQuantization?,
        reporting: @escaping @Sendable (DownloadProgress) -> Void
    ) async throws -> any LoadedLLMContainer {
        reporting(generationDownload)
        return ResolveOnlyContainer()
    }

    /// Reports ``embeddingDownload`` and gives a ``ZeroEmbeddingContainer``.
    ///
    /// - Parameters:
    ///   - ref: The model. The loader does not read it.
    ///   - slot: The slot. The loader does not read it.
    ///   - reporting: The sink of the download observation.
    /// - Returns: A ``ZeroEmbeddingContainer`` of ``dimension``.
    public func loadEmbedder(
        ref: ModelRef,
        slot: ModelSlot,
        reporting: @escaping @Sendable (DownloadProgress) -> Void
    ) async throws -> any LoadedEmbeddingContainer {
        reporting(embeddingDownload)
        return ZeroEmbeddingContainer(dimension: dimension)
    }

    /// Does nothing: a stub model needs no preload.
    ///
    /// - Parameter container: The container. The loader does not read it.
    public func preload(container: any LoadedModelContainer) async throws {}
}
