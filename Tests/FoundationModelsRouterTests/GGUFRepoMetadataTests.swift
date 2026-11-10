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

    /// The bytes past the end of the metadata that a second read may fetch,
    /// as a divisor of the bytes of the metadata: a quarter more.
    private static let overreadDivisor = 4

    /// Sizes the one model file of a repo, and gives the ranges it read.
    ///
    /// - Parameter bytes: The bytes of the file.
    /// - Returns: Each range read, in the order of the reads.
    /// - Throws: The error of the read.
    private static func headerReadRanges(of bytes: Data) async throws -> [Range<Int>] {
        let (reader, cache, source) = try makeReader(
            treeJSON: HubTreeListing.json([.lfsFile("model.gguf", size: Int64(bytes.count))]),
            files: ["model.gguf": bytes])
        defer { cache.remove() }
        _ = try await reader.metadata(for: ModelRef(repo: repo))
        return await source.readRanges
    }

    /// Tells whether a header was read in two ranges: the first read, then
    /// one read that continues it past the end of the metadata, by at most a
    /// quarter of the bytes of the metadata.
    ///
    /// - Parameters:
    ///   - ranges: The ranges read.
    ///   - bytes: The bytes of the file.
    /// - Returns: `true` when the ranges are such two reads.
    /// - Throws: The error of the parse of the whole file.
    private static func readsInTwo(_ ranges: [Range<Int>], of bytes: Data) throws -> Bool {
        let metadataEnd = try GGUFHeader.parse(prefix: bytes).metadataByteCount
        guard ranges.count == 2 else { return false }
        return ranges[0] == 0..<firstReadBytes && ranges[1].lowerBound == firstReadBytes
            && (metadataEnd...(metadataEnd + metadataEnd / overreadDivisor)).contains(ranges[1].upperBound)
    }

    /// Sizes the one dense model file of a repo.
    ///
    /// - Returns: The metadata.
    /// - Throws: The error of the read.
    private static func singleFileMetadata() async throws -> RepoMetadata {
        let (reader, cache, _) = try makeReader(
            treeJSON: HubTreeListing.json([
                .lfsFile("model-Q4_K_M.gguf", size: modelBytes),
                .lfsFile("README.md", size: 10),
            ]),
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
            treeJSON: HubTreeListing.json(shards.map { .lfsFile($0, size: Self.shardBytes) }),
            files: [shards[0]: GGUFHeaderFixtures.denseBytes])
        defer { cache.remove() }

        let metadata = try await reader.metadata(for: ModelRef(repo: Self.repo, path: "Q8_0"))

        #expect(metadata.weightBytes == Self.shardBytes * Int64(shards.count))
    }

    @Test("the projector beside a GGUF model adds its bytes")
    func projectorAddsBytes() async throws {
        let (reader, cache, _) = try Self.makeReader(
            treeJSON: HubTreeListing.json([
                .lfsFile("model.gguf", size: Self.modelBytes),
                .lfsFile("mmproj-model-f16.gguf", size: Self.projectorBytes),
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
            treeJSON: HubTreeListing.json([.lfsFile("model.gguf", size: Self.modelBytes)]),
            files: ["model.gguf": GGUFHeaderFixtures.hybridBytes])
        defer { cache.remove() }
        let expected =
            header.keyValueBytes(contextSize: Self.unpaddedContext, cacheType: .float16)
            + header.recurrentStateBytes(sequenceCount: LlamaLanguageModel.Options.defaultMaxLiveSequences)

        let metadata = try await reader.metadata(for: ModelRef(repo: Self.repo))

        #expect(metadata.footprint.kvBytes(context: Self.unpaddedContext) == Int64(expected))
    }

    @Test("a header whose metadata runs past the first read in its token array takes one more read")
    func headerGrowsItsRange() async throws {
        let bytes = try Data(contentsOf: LlamaCppTestFixtures.vocabURL(named: "qwen35"))

        // The 5.9 MB metadata of the fixture runs past the first read inside
        // its 151,936 tokens, which size the second read.
        let ranges = try await Self.headerReadRanges(of: bytes)

        #expect(try Self.readsInTwo(ranges, of: bytes))
    }

    @Test("an 11 MB metadata section of Qwen3.5 takes two reads and about 11 MB")
    func largeVocabularyTakesTwoReads() async throws {
        let bytes = GGUFHeaderFixtures.largeVocabularyBytes

        let ranges = try await Self.headerReadRanges(of: bytes)

        #expect(try Self.readsInTwo(ranges, of: bytes))
    }

    @Test("a header read in two ranges sizes the model as the whole file sizes it")
    func largeVocabularySizesAsTheWholeFile() async throws {
        let bytes = GGUFHeaderFixtures.largeVocabularyBytes
        let expected = try RepoMetadata(
            ggufHeader: GGUFHeader.parse(prefix: bytes), weightBytes: Int64(bytes.count), name: Self.repo)
        let (reader, cache, _) = try Self.makeReader(
            treeJSON: HubTreeListing.json([.lfsFile("model.gguf", size: Int64(bytes.count))]),
            files: ["model.gguf": bytes])
        defer { cache.remove() }

        let metadata = try await reader.metadata(for: ModelRef(repo: Self.repo))

        #expect(metadata == expected)
    }

    @Test("an array of fixed-size elements that runs past the first read sizes the second read to its end")
    func integerArrayTakesTwoReads() async throws {
        let bytes = GGUFHeaderFixtures.largeIntegerArrayBytes

        let ranges = try await Self.headerReadRanges(of: bytes)

        #expect(try Self.readsInTwo(ranges, of: bytes))
    }

    @Test("an array of strings that runs past the first read sizes the second read from the strings read")
    func stringArrayTakesTwoReads() async throws {
        let bytes = GGUFHeaderFixtures.largeStringArrayBytes

        let ranges = try await Self.headerReadRanges(of: bytes)

        #expect(try Self.readsInTwo(ranges, of: bytes))
    }

    @Test("a string that runs past the first read is read to its end in the second read")
    func longStringTakesTwoReads() async throws {
        let bytes = GGUFHeaderFixtures.longChatTemplateBytes
        let metadataEnd = try GGUFHeader.parse(prefix: bytes).metadataByteCount

        let ranges = try await Self.headerReadRanges(of: bytes)

        // The parse asks for the whole 3 MB chat template, the last value.
        #expect(ranges == [0..<Self.firstReadBytes, Self.firstReadBytes..<metadataEnd])
    }

    @Test("metadata that runs past the first read in no array doubles the prefix with each read")
    func scalarValuesDoubleThePrefix() async throws {
        let ranges = try await Self.headerReadRanges(of: GGUFHeaderFixtures.manyValuesBytes)

        // No array runs past a read of the 2.2 MB of scalar values, so each
        // read doubles the prefix and fetches only the bytes past the last
        // read.
        let megabyte = Self.firstReadBytes
        #expect(ranges == [0..<megabyte, megabyte..<(2 * megabyte), (2 * megabyte)..<(4 * megabyte)])
    }

    @Test("a header read with larger ranges parses as the whole file parses")
    func grownHeaderParses() async throws {
        let bytes = try Data(contentsOf: LlamaCppTestFixtures.vocabURL(named: "qwen35"))
        let header = try GGUFHeader.parse(prefix: bytes)
        let (reader, cache, _) = try Self.makeReader(
            treeJSON: HubTreeListing.json([.lfsFile("model.gguf", size: Int64(bytes.count))]),
            files: ["model.gguf": bytes])
        defer { cache.remove() }

        let metadata = try await reader.metadata(for: ModelRef(repo: Self.repo))

        #expect(metadata.nativeMaxContext == header.trainingContextSize)
    }

    @Test("the first read of a header is one megabyte from the start of the file")
    func firstReadIsOneMegabyte() async throws {
        let (reader, cache, source) = try Self.makeReader(
            treeJSON: HubTreeListing.json([.lfsFile("model.gguf", size: Self.modelBytes)]),
            files: ["model.gguf": GGUFHeaderFixtures.denseBytes])
        defer { cache.remove() }

        _ = try await reader.metadata(for: ModelRef(repo: Self.repo))

        #expect(await source.readRanges == [0..<Self.firstReadBytes])
    }

    @Test("a file that ends before its header ends is an error, not a loop")
    func truncatedHeaderIsAnError() async throws {
        let truncated = GGUFHeaderFixtures.denseBytes.prefix(GGUFHeaderFixtures.denseBytes.count / 2)
        let (reader, cache, _) = try Self.makeReader(
            treeJSON: HubTreeListing.json([.lfsFile("model.gguf", size: Self.modelBytes)]),
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
            treeJSON: HubTreeListing.json([.lfsFile("model.gguf", size: Self.modelBytes)]), files: ["model.gguf": bytes])
        defer { cache.remove() }

        await #expect(throws: RepoMetadataError.self) {
            _ = try await reader.metadata(for: ModelRef(repo: Self.repo))
        }
    }

    @Test("a repo root that holds two GGUF models is an error that asks for a path")
    func ambiguousRootIsAnError() async throws {
        let (reader, cache, _) = try Self.makeReader(
            treeJSON: HubTreeListing.json([
                .lfsFile("Q4_K_M/model-Q4_K_M.gguf", size: Self.modelBytes),
                .lfsFile("Q8_0/model-Q8_0.gguf", size: Self.otherQuantBytes),
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
            treeJSON: HubTreeListing.json([.lfsFile("sub/model.safetensors", size: Self.modelBytes)]), files: [:])
        defer { cache.remove() }

        await #expect(throws: RepoMetadataError.self) {
            _ = try await reader.metadata(for: ModelRef(repo: Self.repo, path: "sub"))
        }
    }

    @Test("two quantizations in one pinned repo are sized and cached separately")
    func twoQuantsSizedSeparately() async throws {
        let (reader, cache, _) = try Self.makeReader(
            treeJSON: HubTreeListing.json([
                .lfsFile("Q4_K_M/model-Q4_K_M.gguf", size: Self.modelBytes),
                .lfsFile("Q8_0/model-Q8_0.gguf", size: Self.otherQuantBytes),
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
            treeJSON: HubTreeListing.json([
                .lfsFile("model-Q4_K_M.gguf", size: Self.modelBytes),
                .lfsFile("model-Q8_0.gguf", size: Self.otherQuantBytes),
            ]),
            files: ["model-Q8_0.gguf": GGUFHeaderFixtures.otherDenseBytes])
        defer { cache.remove() }

        let metadata = try await reader.metadata(for: ModelRef(repo: Self.repo, path: "model-Q8_0.gguf"))

        #expect(metadata.weightBytes == Self.otherQuantBytes)
    }
}
