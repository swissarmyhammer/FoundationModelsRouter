import Foundation
import FoundationModelsExtras
import FoundationModelsLlamaCpp
import LlamaCppTestFixtures
import Testing

@testable import FoundationModelsRouter

/// Proves that the router sizes a GGUF model before its download: the weight
/// bytes from the tree listing under the path of the reference, and the KV
/// cache and the native context from the GGUF header, which a range read of
/// the first shard gives. No network: a stub source answers each read.
@Suite("GGUF sizing")
struct GGUFRepoMetadataTests {
    /// The repo of the tests on the Hub.
    private static let repo = "org/model-GGUF"

    /// A full commit id, so the reader trusts its cache.
    private static let commitHash = "0f1e2d3c4b5a69788796a5b4c3d2e1f009182736"

    /// The size of a single-file model.
    private static let modelBytes: Int64 = 4_000_000

    /// The size of each shard of a split set.
    private static let shardBytes: Int64 = 3_000_000

    /// The size of an image projector.
    private static let projectorBytes: Int64 = 600_000

    /// The size of the second quantization of a repo.
    private static let otherQuantBytes: Int64 = 9_000_000

    /// A context that is not a multiple of the 256 cells llama.cpp pads to.
    private static let unpaddedContext = 3_000

    /// The first read of a header, in bytes.
    private static let firstReadBytes = 1 << 20

    /// One file of a tree listing.
    private static func treeFile(_ path: String, size: Int64) -> String {
        FileServingMetadataSource.treeFile(path, size: size)
    }

    /// A tree listing of some files.
    private static func tree(_ files: [String]) -> Data {
        FileServingMetadataSource.tree(files)
    }

    /// Makes a reader over a stub source and a fresh cache folder.
    ///
    /// - Parameters:
    ///   - treeJSON: The tree listing.
    ///   - files: The bytes of each file, by its path in ``repo``.
    /// - Returns: The reader, its cache folder, and the source.
    /// - Throws: The error of the folder creation.
    private static func makeReader(
        treeJSON: Data, files: [String: Data]
    ) throws -> (reader: RepoMetadataReader, cache: TempModelFolder, source: FileServingMetadataSource) {
        let cache = try TempModelFolder(prefix: "GGUFRepoMetadataTests-cache")
        let keyed = Dictionary(uniqueKeysWithValues: files.map { ("\(repo)/\($0.key)", $0.value) })
        let source = FileServingMetadataSource(
            rawByRepo: [:], defaultRaw: RawRepoMetadata(configJSON: nil, treeJSON: treeJSON), files: keyed)
        return (RepoMetadataReader(source: source, cacheDir: cache.url), cache, source)
    }

    /// Sizes the one dense model file of a repo.
    ///
    /// - Returns: The metadata.
    /// - Throws: The error of the read.
    private static func singleFileMetadata() async throws -> RepoMetadata {
        let (reader, cache, _) = try makeReader(
            treeJSON: tree([treeFile("model-Q4_K_M.gguf", size: modelBytes), treeFile("README.md", size: 10)]),
            files: ["model-Q4_K_M.gguf": GGUFHeaderFixtures.denseBytes])
        defer { cache.remove() }
        return try await reader.metadata(for: ModelRef(repo: repo))
    }

    @Test("a single GGUF file is sized by its own bytes")
    func singleFileWeightBytes() async throws {
        #expect(try await Self.singleFileMetadata().weightBytes == Self.modelBytes)
    }

    @Test("the native context of a GGUF model is the training context of its header")
    func nativeContextFromHeader() async throws {
        let header = try GGUFHeader.parse(prefix: GGUFHeaderFixtures.denseBytes)

        #expect(try await Self.singleFileMetadata().nativeMaxContext == header.trainingContextSize)
    }

    @Test("the KV term of a GGUF model is the KV cache its header gives, padded as llama.cpp pads it")
    func kvBytesFromHeader() async throws {
        let header = try GGUFHeader.parse(prefix: GGUFHeaderFixtures.denseBytes)

        #expect(
            try await Self.singleFileMetadata().footprint.kvBytes(context: Self.unpaddedContext)
                == Int64(header.keyValueBytes(contextSize: Self.unpaddedContext, cacheType: .float16)))
    }

    @Test("a split set is sized by the sum of its shards, and its header comes from the first shard")
    func splitSetWeightBytes() async throws {
        let shards = (1...3).map { String(format: "Q8_0/model-Q8_0-%05d-of-00003.gguf", $0) }
        let (reader, cache, _) = try Self.makeReader(
            treeJSON: Self.tree(shards.map { Self.treeFile($0, size: Self.shardBytes) }),
            files: [shards[0]: GGUFHeaderFixtures.denseBytes])
        defer { cache.remove() }

        let metadata = try await reader.metadata(for: ModelRef(repo: Self.repo, path: "Q8_0"))

        #expect(metadata.weightBytes == Self.shardBytes * Int64(shards.count))
    }

    @Test("the projector beside a GGUF model adds its bytes")
    func projectorAddsBytes() async throws {
        let (reader, cache, _) = try Self.makeReader(
            treeJSON: Self.tree([
                Self.treeFile("model.gguf", size: Self.modelBytes),
                Self.treeFile("mmproj-model-f16.gguf", size: Self.projectorBytes),
            ]),
            files: ["model.gguf": GGUFHeaderFixtures.denseBytes])
        defer { cache.remove() }

        let metadata = try await reader.metadata(for: ModelRef(repo: Self.repo))

        #expect(metadata.weightBytes == Self.modelBytes + Self.projectorBytes)
    }

    @Test("a hybrid GGUF model adds the recurrent state of each live sequence to its KV term")
    func hybridAddsRecurrentState() async throws {
        let header = try GGUFHeader.parse(prefix: GGUFHeaderFixtures.hybridBytes)
        let (reader, cache, _) = try Self.makeReader(
            treeJSON: Self.tree([Self.treeFile("model.gguf", size: Self.modelBytes)]),
            files: ["model.gguf": GGUFHeaderFixtures.hybridBytes])
        defer { cache.remove() }
        let expected =
            header.keyValueBytes(contextSize: Self.unpaddedContext, cacheType: .float16)
            + header.recurrentStateBytes(sequenceCount: LlamaLanguageModel.Options.defaultMaxLiveSequences)

        let metadata = try await reader.metadata(for: ModelRef(repo: Self.repo))

        #expect(metadata.footprint.kvBytes(context: Self.unpaddedContext) == Int64(expected))
    }

    @Test("a header whose metadata runs past the first read is read with larger ranges that continue the prefix")
    func headerGrowsItsRange() async throws {
        let bytes = try Data(contentsOf: LlamaCppTestFixtures.vocabURL(named: "qwen35"))
        let (reader, cache, source) = try Self.makeReader(
            treeJSON: Self.tree([Self.treeFile("model.gguf", size: Int64(bytes.count))]),
            files: ["model.gguf": bytes])
        defer { cache.remove() }

        _ = try await reader.metadata(for: ModelRef(repo: Self.repo))

        // The 5.9 MB metadata of the fixture ends past 4 MB: each read
        // doubles the prefix and fetches only the bytes past the last read.
        let megabyte = Self.firstReadBytes
        #expect(
            await source.readRanges == [0..<megabyte, megabyte..<(2 * megabyte), (2 * megabyte)..<(4 * megabyte),
                (4 * megabyte)..<(8 * megabyte)])
    }

    @Test("a header read with larger ranges parses as the whole file parses")
    func grownHeaderParses() async throws {
        let bytes = try Data(contentsOf: LlamaCppTestFixtures.vocabURL(named: "qwen35"))
        let header = try GGUFHeader.parse(prefix: bytes)
        let (reader, cache, _) = try Self.makeReader(
            treeJSON: Self.tree([Self.treeFile("model.gguf", size: Int64(bytes.count))]),
            files: ["model.gguf": bytes])
        defer { cache.remove() }

        let metadata = try await reader.metadata(for: ModelRef(repo: Self.repo))

        #expect(metadata.nativeMaxContext == header.trainingContextSize)
    }

    @Test("the first read of a header is one megabyte from the start of the file")
    func firstReadIsOneMegabyte() async throws {
        let (reader, cache, source) = try Self.makeReader(
            treeJSON: Self.tree([Self.treeFile("model.gguf", size: Self.modelBytes)]),
            files: ["model.gguf": GGUFHeaderFixtures.denseBytes])
        defer { cache.remove() }

        _ = try await reader.metadata(for: ModelRef(repo: Self.repo))

        #expect(await source.readRanges == [0..<Self.firstReadBytes])
    }

    @Test("a file that ends before its header ends is an error, not a loop")
    func truncatedHeaderIsAnError() async throws {
        let truncated = GGUFHeaderFixtures.denseBytes.prefix(GGUFHeaderFixtures.denseBytes.count / 2)
        let (reader, cache, _) = try Self.makeReader(
            treeJSON: Self.tree([Self.treeFile("model.gguf", size: Self.modelBytes)]),
            files: ["model.gguf": Data(truncated)])
        defer { cache.remove() }

        await #expect(throws: RepoMetadataError.self) {
            _ = try await reader.metadata(for: ModelRef(repo: Self.repo))
        }
    }

    @Test("a GGUF header with no training context is an error, as a config.json with none is")
    func headerWithNoContextIsAnError() async throws {
        let bytes = GGUFHeaderFixtures.noContextBytes
        let (reader, cache, _) = try Self.makeReader(
            treeJSON: Self.tree([Self.treeFile("model.gguf", size: Self.modelBytes)]), files: ["model.gguf": bytes])
        defer { cache.remove() }

        await #expect(throws: RepoMetadataError.self) {
            _ = try await reader.metadata(for: ModelRef(repo: Self.repo))
        }
    }

    @Test("a repo root that holds two GGUF models is an error that asks for a path")
    func ambiguousRootIsAnError() async throws {
        let (reader, cache, _) = try Self.makeReader(
            treeJSON: Self.tree([
                Self.treeFile("Q4_K_M/model-Q4_K_M.gguf", size: Self.modelBytes),
                Self.treeFile("Q8_0/model-Q8_0.gguf", size: Self.otherQuantBytes),
            ]),
            files: [:])
        defer { cache.remove() }

        await #expect(throws: RepoMetadataError.self) {
            _ = try await reader.metadata(for: ModelRef(repo: Self.repo))
        }
    }

    @Test("a path inside a repo whose files are not GGUF is an error, as the loader refuses it")
    func pathToNonGGUFIsAnError() async throws {
        let (reader, cache, _) = try Self.makeReader(
            treeJSON: Self.tree([Self.treeFile("sub/model.safetensors", size: Self.modelBytes)]), files: [:])
        defer { cache.remove() }

        await #expect(throws: RepoMetadataError.self) {
            _ = try await reader.metadata(for: ModelRef(repo: Self.repo, path: "sub"))
        }
    }

    @Test("two quantizations in one pinned repo are sized and cached separately")
    func twoQuantsSizedSeparately() async throws {
        let (reader, cache, _) = try Self.makeReader(
            treeJSON: Self.tree([
                Self.treeFile("Q4_K_M/model-Q4_K_M.gguf", size: Self.modelBytes),
                Self.treeFile("Q8_0/model-Q8_0.gguf", size: Self.otherQuantBytes),
            ]),
            files: [
                "Q4_K_M/model-Q4_K_M.gguf": GGUFHeaderFixtures.denseBytes,
                "Q8_0/model-Q8_0.gguf": GGUFHeaderFixtures.otherDenseBytes,
            ])
        defer { cache.remove() }

        let small = try await reader.metadata(
            for: ModelRef(repo: Self.repo, path: "Q4_K_M", revision: Self.commitHash))
        let large = try await reader.metadata(for: ModelRef(repo: Self.repo, path: "Q8_0", revision: Self.commitHash))

        #expect([small.weightBytes, large.weightBytes] == [Self.modelBytes, Self.otherQuantBytes])
    }

    @Test("a path to one .gguf file inside a repo sizes that file")
    func pathToFileSizesThatFile() async throws {
        let (reader, cache, _) = try Self.makeReader(
            treeJSON: Self.tree([
                Self.treeFile("model-Q4_K_M.gguf", size: Self.modelBytes),
                Self.treeFile("model-Q8_0.gguf", size: Self.otherQuantBytes),
            ]),
            files: ["model-Q8_0.gguf": GGUFHeaderFixtures.otherDenseBytes])
        defer { cache.remove() }

        let metadata = try await reader.metadata(for: ModelRef(repo: Self.repo, path: "model-Q8_0.gguf"))

        #expect(metadata.weightBytes == Self.otherQuantBytes)
    }
}
