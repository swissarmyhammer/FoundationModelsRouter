import Foundation
import FoundationModelsExtras
import FoundationModelsLlamaCpp
import Testing

@testable import FoundationModelsRouter

/// Proves that the router sizes a local model folder from the files on the
/// disk, with no Hub call.
@Suite("Local model folder sizing")
struct LocalRepoMetadataTests {
    /// A source that counts its calls and fails each one. A local folder must
    /// never reach it.
    private actor FailingMetadataSource: MetadataSource {
        /// The error of each call.
        struct HubWasCalled: Error {}

        /// The repos that the router asked the Hub for.
        private(set) var askedRepos: [String] = []

        func fetchRawMetadata(repo: String, revision: String?) async throws -> RawRepoMetadata {
            askedRepos.append(repo)
            throw HubWasCalled()
        }
    }

    /// A `config.json` with a small attention shape.
    private static let configJSON = Data("""
        {
            "num_hidden_layers": 2,
            "num_attention_heads": 8,
            "num_key_value_heads": 2,
            "head_dim": 16,
            "hidden_size": 128,
            "max_position_embeddings": 4096
        }
        """.utf8)

    /// The window that ``configJSON`` declares.
    private static let declaredWindow = 4_096

    /// The size of the tokenizer file of the MLX folder.
    private static let tokenizerBytes = 50

    /// A Hub repo id.
    private static let hubRepo = "org/hub-model"

    /// The size of each weight shard of the MLX folder.
    private static let shardBytes = 1_000

    /// The size of the smaller Core ML package.
    private static let smallPackageBytes = 300

    /// The size of the larger Core ML package, in two files.
    private static let largePackageFileBytes = 500

    /// The size of a local GGUF model file: its header, then zero bytes.
    private static let ggufModelBytes = 20_000

    /// The size of the projector of a local GGUF folder.
    private static let ggufProjectorBytes = 3_000

    /// Writes a GGUF model file that holds the dense header of
    /// ``GGUFHeaderFixtures`` and zero bytes up to ``ggufModelBytes``.
    private static func writeGGUFModel(_ path: String, in folder: TempModelFolder) throws {
        let header = GGUFHeaderFixtures.denseBytes
        try folder.write(path, data: header + Data(count: ggufModelBytes - header.count))
    }

    /// Makes a reader over a fresh cache folder and the failing source.
    private static func makeReader() throws -> (reader: RepoMetadataReader, cache: TempModelFolder, source: FailingMetadataSource) {
        let cache = try TempModelFolder(prefix: "LocalRepoMetadataTests-cache")
        let source = FailingMetadataSource()
        return (RepoMetadataReader(source: source, cacheDir: cache.url), cache, source)
    }

    /// Writes an MLX model folder: two shards, a `config.json`, and a tokenizer.
    private static func writeMLXFolder(_ folder: TempModelFolder) throws {
        try folder.writeFile("model-00001.safetensors", byteCount: shardBytes)
        try folder.writeFile("model-00002.safetensors", byteCount: shardBytes)
        try folder.write("config.json", data: configJSON)
        try folder.writeFile("tokenizer.json", byteCount: tokenizerBytes)
    }

    /// Writes a Core ML model folder: two packages, the larger in two files.
    private static func writeCoreMLFolder(_ folder: TempModelFolder) throws {
        try folder.writeFile("small.mlpackage/Data/weight.bin", byteCount: smallPackageBytes)
        try folder.writeFile("large.mlpackage/Data/weight.bin", byteCount: largePackageFileBytes)
        try folder.writeFile("large.mlpackage/Manifest.json", byteCount: largePackageFileBytes)
    }

    @Test("an MLX folder is sized by the sum of its safetensors files")
    func mlxWeightBytes() async throws {
        let folder = try TempModelFolder(prefix: "LocalRepoMetadataTests-mlx")
        let (reader, cache, _) = try Self.makeReader()
        defer { folder.remove(); cache.remove() }
        try Self.writeMLXFolder(folder)

        let metadata = try await reader.metadata(for: ModelRef(repo: folder.url.path))

        #expect(metadata.weightBytes == Int64(2 * Self.shardBytes))
    }

    @Test("an MLX folder gets its native max context from its config.json")
    func mlxNativeMaxContext() async throws {
        let folder = try TempModelFolder(prefix: "LocalRepoMetadataTests-mlx")
        let (reader, cache, _) = try Self.makeReader()
        defer { folder.remove(); cache.remove() }
        try Self.writeMLXFolder(folder)

        let metadata = try await reader.metadata(for: ModelRef(repo: folder.url.path))

        #expect(metadata.nativeMaxContext == Self.declaredWindow)
    }

    @Test("a Core ML folder is sized by its largest package")
    func coreMLWeightBytes() async throws {
        let folder = try TempModelFolder(prefix: "LocalRepoMetadataTests-coreml")
        let (reader, cache, _) = try Self.makeReader()
        defer { folder.remove(); cache.remove() }
        try Self.writeCoreMLFolder(folder)

        let metadata = try await reader.metadata(for: ModelRef(repo: folder.url.path))

        #expect(metadata.weightBytes == Int64(2 * Self.largePackageFileBytes))
    }

    @Test("a Core ML folder is reported as a Core ML embedding model")
    func coreMLIsEmbedding() async throws {
        let folder = try TempModelFolder(prefix: "LocalRepoMetadataTests-coreml")
        let (reader, cache, _) = try Self.makeReader()
        defer { folder.remove(); cache.remove() }
        try Self.writeCoreMLFolder(folder)

        let metadata = try await reader.metadata(for: ModelRef(repo: folder.url.path))

        #expect(metadata.isCoreMLEmbedding)
    }

    @Test("a local folder is sized with no Hub call")
    func noHubCall() async throws {
        let folder = try TempModelFolder(prefix: "LocalRepoMetadataTests-mlx")
        let (reader, cache, source) = try Self.makeReader()
        defer { folder.remove(); cache.remove() }
        try Self.writeMLXFolder(folder)

        _ = try await reader.metadata(for: ModelRef(repo: folder.url.path))

        #expect(await source.askedRepos.isEmpty)
    }

    @Test("a local folder is read again at each call, because its files can change")
    func localFolderIsNotCached() async throws {
        let folder = try TempModelFolder(prefix: "LocalRepoMetadataTests-mlx")
        let (reader, cache, _) = try Self.makeReader()
        defer { folder.remove(); cache.remove() }
        try Self.writeMLXFolder(folder)
        _ = try await reader.metadata(for: ModelRef(repo: folder.url.path))
        try folder.writeFile("model-00003.safetensors", byteCount: Self.shardBytes)

        let metadata = try await reader.metadata(for: ModelRef(repo: folder.url.path))

        #expect(metadata.weightBytes == Int64(3 * Self.shardBytes))
    }

    @Test("a folder named with ~ is sized from the folder under the home folder")
    func tildeFolderIsSized() async throws {
        let home = try TempModelFolder(prefix: "LocalRepoMetadataTests-home")
        let (reader, cache, _) = try Self.makeReader()
        defer { home.remove(); cache.remove() }
        try home.writeFile("models/embedder.mlpackage/Data/weight.bin", byteCount: Self.smallPackageBytes)
        let ref = LocalModelPath.resolved(ModelRef(repo: "~/models"), home: home.url, workingDirectory: home.url)

        let metadata = try await reader.metadata(for: ref)

        #expect(metadata.weightBytes == Int64(Self.smallPackageBytes))
    }

    @Test("a folder named with ./ is sized from the folder under the working folder")
    func dotSlashFolderIsSized() async throws {
        let work = try TempModelFolder(prefix: "LocalRepoMetadataTests-work")
        let (reader, cache, _) = try Self.makeReader()
        defer { work.remove(); cache.remove() }
        try work.writeFile("models/embedder.mlpackage/Data/weight.bin", byteCount: Self.smallPackageBytes)
        let ref = LocalModelPath.resolved(ModelRef(repo: "./models"), home: work.url, workingDirectory: work.url)

        let metadata = try await reader.metadata(for: ref)

        #expect(metadata.weightBytes == Int64(Self.smallPackageBytes))
    }

    @Test("a local path that is not a folder cannot be sized, and does not reach the Hub")
    func missingFolderFails() async throws {
        let (reader, cache, source) = try Self.makeReader()
        defer { cache.remove() }
        let missing = ModelRef(repo: "/no/such/folder-\(UUID().uuidString)")

        await #expect(throws: RepoMetadataError.self) { try await reader.metadata(for: missing) }
        #expect(await source.askedRepos.isEmpty)
    }

    @Test("an empty local folder cannot be sized")
    func emptyFolderFails() async throws {
        let folder = try TempModelFolder(prefix: "LocalRepoMetadataTests-empty")
        let (reader, cache, _) = try Self.makeReader()
        defer { folder.remove(); cache.remove() }

        await #expect(throws: RepoMetadataError.self) {
            try await reader.metadata(for: ModelRef(repo: folder.url.path))
        }
    }

    @Test("a Hub repo id still goes to the Hub")
    func hubIdGoesToTheHub() async throws {
        let (reader, cache, source) = try Self.makeReader()
        defer { cache.remove() }

        await #expect(throws: FailingMetadataSource.HubWasCalled.self) {
            try await reader.metadata(for: ModelRef(repo: Self.hubRepo))
        }
        #expect(await source.askedRepos == [Self.hubRepo])
    }

    @Test("a local .gguf file is sized by its bytes")
    func localGGUFFileWeightBytes() async throws {
        let folder = try TempModelFolder(prefix: "LocalRepoMetadataTests-gguf-file")
        let (reader, cache, _) = try Self.makeReader()
        defer { folder.remove(); cache.remove() }
        try Self.writeGGUFModel("model-Q4_K_M.gguf", in: folder)

        let metadata = try await reader.metadata(
            for: ModelRef(repo: folder.url.appending(path: "model-Q4_K_M.gguf").path))

        #expect(metadata.weightBytes == Int64(Self.ggufModelBytes))
    }

    @Test("a local .gguf file gets its native context from its header")
    func localGGUFFileNativeContext() async throws {
        let folder = try TempModelFolder(prefix: "LocalRepoMetadataTests-gguf-file")
        let (reader, cache, _) = try Self.makeReader()
        defer { folder.remove(); cache.remove() }
        try Self.writeGGUFModel("model.gguf", in: folder)
        let header = try GGUFHeader.parse(prefix: GGUFHeaderFixtures.denseBytes)

        let metadata = try await reader.metadata(for: ModelRef(repo: folder.url.appending(path: "model.gguf").path))

        #expect(metadata.nativeMaxContext == header.trainingContextSize)
    }

    @Test("a local GGUF folder is sized by its model and its projector")
    func localGGUFFolderWeightBytes() async throws {
        let folder = try TempModelFolder(prefix: "LocalRepoMetadataTests-gguf-folder")
        let (reader, cache, _) = try Self.makeReader()
        defer { folder.remove(); cache.remove() }
        try Self.writeGGUFModel("model.gguf", in: folder)
        try folder.writeFile("mmproj-model-f16.gguf", byteCount: Self.ggufProjectorBytes)

        let metadata = try await reader.metadata(for: ModelRef(repo: folder.url.path))

        #expect(metadata.weightBytes == Int64(Self.ggufModelBytes + Self.ggufProjectorBytes))
    }

    @Test("a local GGUF folder is sized with no Hub call")
    func localGGUFFolderNoHubCall() async throws {
        let folder = try TempModelFolder(prefix: "LocalRepoMetadataTests-gguf-folder")
        let (reader, cache, source) = try Self.makeReader()
        defer { folder.remove(); cache.remove() }
        try Self.writeGGUFModel("model.gguf", in: folder)

        _ = try await reader.metadata(for: ModelRef(repo: folder.url.path))

        #expect(await source.askedRepos.isEmpty)
    }

    @Test("a local file that is not a .gguf file cannot be sized")
    func localNonGGUFFileFails() async throws {
        let folder = try TempModelFolder(prefix: "LocalRepoMetadataTests-not-gguf")
        let (reader, cache, _) = try Self.makeReader()
        defer { folder.remove(); cache.remove() }
        try folder.writeFile("model.bin", byteCount: Self.tokenizerBytes)

        await #expect(throws: RepoMetadataError.self) {
            try await reader.metadata(for: ModelRef(repo: folder.url.appending(path: "model.bin").path))
        }
    }
}
