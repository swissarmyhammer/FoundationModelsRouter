import Foundation
import Testing

@testable import FoundationModelsRouter

@Suite("RepoMetadata")
struct RepoMetadataTests {
    /// A `MetadataSource` returning fixed canned bytes and counting how many
    /// times the network-shaped fetch was invoked, so cache behavior is testable
    /// without any I/O.
    private actor StubMetadataSource: MetadataSource {
        let raw: RawRepoMetadata
        private(set) var fetchCount = 0

        init(raw: RawRepoMetadata) {
            self.raw = raw
        }

        func fetchRawMetadata(repo: String, revision: String?) async throws -> RawRepoMetadata {
            fetchCount += 1
            return raw
        }
    }

    /// A canned `config.json` with all architecture fields present.
    private static let fullConfigJSON = Data("""
        {
            "num_hidden_layers": 4,
            "num_attention_heads": 32,
            "num_key_value_heads": 8,
            "head_dim": 128,
            "hidden_size": 4096,
            "quantization": {"bits": 4, "group_size": 64}
        }
        """.utf8)

    /// A canned tree listing exercising both size paths:
    /// - Two LFS shards whose top-level `size` is the small pointer size (135)
    ///   while the real bytes live in `lfs.size` (1.0 MB + 0.5 MB) — so summing
    ///   the plain `size` instead of `lfs.size` would give a different total.
    /// - One non-LFS shard with only a plain `size` (0.25 MB), exercising the
    ///   `lfs?.size ?? size` fallback.
    /// - Non-weight files that must not be summed.
    private static let weightTreeJSON = Data("""
        [
            {"type": "file", "path": "model-00001-of-00003.safetensors", "size": 135, "lfs": {"size": 1000000}},
            {"type": "file", "path": "model-00002-of-00003.safetensors", "size": 135, "lfs": {"size": 500000}},
            {"type": "file", "path": "model-00003-of-00003.safetensors", "size": 250000},
            {"type": "file", "path": "config.json", "size": 700},
            {"type": "file", "path": "tokenizer.json", "size": 2000}
        ]
        """.utf8)

    /// Σ of the safetensors sizes above: 1.0 MB + 0.5 MB (LFS) + 0.25 MB (plain).
    private static let expectedWeightBytes: Int64 = 1_750_000

    @Test("happy path parses architecture + weight bytes into the right metadata")
    func happyPathMetadata() async throws {
        let (reader, dir, _) = Self.makeReader(
            raw: RawRepoMetadata(configJSON: Self.fullConfigJSON, treeJSON: Self.weightTreeJSON)
        )
        defer { try? FileManager.default.removeItem(at: dir) }

        let metadata = try await reader.metadata(for: "org/model")

        #expect(metadata.weightBytes == Self.expectedWeightBytes)
        #expect(metadata.numHiddenLayers == 4)
        #expect(metadata.numAttentionHeads == 32)
        #expect(metadata.numKeyValueHeads == 8)
        #expect(metadata.headDim == 128)
    }

    @Test("happy-path footprint matches the hand-computed estimate")
    func happyPathFootprint() async throws {
        let (reader, dir, _) = Self.makeReader(
            raw: RawRepoMetadata(configJSON: Self.fullConfigJSON, treeJSON: Self.weightTreeJSON)
        )
        defer { try? FileManager.default.removeItem(at: dir) }

        let footprint = try await reader.footprint(for: "org/model")

        // kvBytes(16) = 2(K+V) * 4 layers * 16 ctx * 8 kvHeads * 128 headDim * 2(fp16) = 262144.
        #expect(footprint.kvBytes(context: 16) == 262_144)
        #expect(footprint.footprint(context: 16) == Self.expectedWeightBytes + 262_144)
    }

    @Test("GQA fallback: absent num_key_value_heads uses num_attention_heads")
    func gqaFallback() async throws {
        let config = Data("""
            {"num_hidden_layers": 2, "num_attention_heads": 8, "head_dim": 16}
            """.utf8)
        let (reader, dir, _) = Self.makeReader(
            raw: RawRepoMetadata(configJSON: config, treeJSON: Self.weightTreeJSON)
        )
        defer { try? FileManager.default.removeItem(at: dir) }

        let footprint = try await reader.footprint(for: "org/model")

        #expect(footprint.kvHeads == 8)
    }

    @Test("head_dim fallback: absent head_dim uses hidden_size / num_attention_heads")
    func headDimFallback() async throws {
        let config = Data("""
            {"num_hidden_layers": 2, "num_attention_heads": 8, "hidden_size": 512}
            """.utf8)
        let (reader, dir, _) = Self.makeReader(
            raw: RawRepoMetadata(configJSON: config, treeJSON: Self.weightTreeJSON)
        )
        defer { try? FileManager.default.removeItem(at: dir) }

        let footprint = try await reader.footprint(for: "org/model")

        // hidden_size 512 / 8 heads = 64 head_dim.
        #expect(footprint.headDim == 64)
    }

    @Test("missing config.json surfaces metadataUnavailable, not a crash")
    func missingConfigUnavailable() async throws {
        let (reader, dir, _) = Self.makeReader(
            raw: RawRepoMetadata(configJSON: nil, treeJSON: Self.weightTreeJSON)
        )
        defer { try? FileManager.default.removeItem(at: dir) }

        await #expect(throws: RepoMetadataError.self) {
            _ = try await reader.metadata(for: "org/model")
        }
    }

    @Test("no *.safetensors in the tree surfaces metadataUnavailable")
    func noSafetensorsUnavailable() async throws {
        let tree = Data("""
            [
                {"type": "file", "path": "config.json", "size": 700},
                {"type": "file", "path": "tokenizer.json", "size": 2000}
            ]
            """.utf8)
        let (reader, dir, _) = Self.makeReader(
            raw: RawRepoMetadata(configJSON: Self.fullConfigJSON, treeJSON: tree)
        )
        defer { try? FileManager.default.removeItem(at: dir) }

        await #expect(throws: RepoMetadataError.self) {
            _ = try await reader.metadata(for: "org/model")
        }
    }

    @Test("a second read of the same (repo, revision) hits the cache; fetch runs once")
    func cacheHitFetchesOnce() async throws {
        let (reader, dir, source) = Self.makeReader(
            raw: RawRepoMetadata(configJSON: Self.fullConfigJSON, treeJSON: Self.weightTreeJSON)
        )
        defer { try? FileManager.default.removeItem(at: dir) }

        let ref: ModelRef = "org/model@abc123"
        let first = try await reader.metadata(for: ref)
        let second = try await reader.metadata(for: ref)

        #expect(first == second)
        #expect(await source.fetchCount == 1)
    }

    @Test("distinct (repo, revision) keys are cached independently")
    func cacheKeySeparation() async throws {
        let (reader, dir, source) = Self.makeReader(
            raw: RawRepoMetadata(configJSON: Self.fullConfigJSON, treeJSON: Self.weightTreeJSON)
        )
        defer { try? FileManager.default.removeItem(at: dir) }

        _ = try await reader.metadata(for: "org/model@rev1")
        _ = try await reader.metadata(for: "org/model@rev2")

        #expect(await source.fetchCount == 2)
    }

    /// Builds a reader over a fresh temp cache dir, returning the dir for cleanup
    /// and the stub source for fetch-count assertions.
    private static func makeReader(
        raw: RawRepoMetadata
    ) -> (reader: RepoMetadataReader, dir: URL, source: StubMetadataSource) {
        let dir = makeTempDir()
        let source = StubMetadataSource(raw: raw)
        return (RepoMetadataReader(source: source, cacheDir: dir), dir, source)
    }

    /// Creates a unique temporary directory for cache tests.
    private static func makeTempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("RepoMetadataTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
